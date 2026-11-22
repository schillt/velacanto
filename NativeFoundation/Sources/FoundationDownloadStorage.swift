import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Removes only one opaque account directory inside an app-owned root. Native package
/// authority is deliberately excluded; cooperating store owners must retire writers first.
nonisolated enum FoundationScopedAccountRemoval {
    private static let maximumDepth = 32
    static func removeAsync(
        root: URL, scope: String, entryLimit: Int = 200_000,
        requireOrdinaryDownloadManifest: Bool = false
    ) async -> Bool {
        guard !Task<Never, Never>.isCancelled else { return false }
        let work = Task.detached(priority: .utility) {
            remove(
                root: root, scope: scope, entryLimit: entryLimit,
                requireOrdinaryDownloadManifest: requireOrdinaryDownloadManifest)
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func remove(
        root: URL, scope: String, entryLimit: Int = 200_000,
        requireOrdinaryDownloadManifest: Bool = false
    ) -> Bool {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            entryLimit > 0
        else { return false }
        let parent: Int32
        switch openRoot(root) {
        case .missing: return true
        case .unavailable: return false
        case .directory(let fd): parent = fd
        }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if target < 0 { return errno == ENOENT }
        defer { close(target) }
        var targetInfo = stat()
        guard fstat(target, &targetInfo) == 0 else { return false }
        if requireOrdinaryDownloadManifest && !ordinaryDownloadManifest(target) { return false }
        var checked = 0
        guard
            walk(
                target, device: targetInfo.st_dev, depth: 0, count: &checked,
                limit: entryLimit, deleting: false)
        else { return false }
        var removed = 0
        guard
            walk(
                target, device: targetInfo.st_dev, depth: 0, count: &removed,
                limit: entryLimit, deleting: true)
        else { return false }
        var current = stat()
        guard fstatat(parent, scope, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == targetInfo.st_dev, current.st_ino == targetInfo.st_ino,
            (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
        else { return false }
        return unlinkat(parent, scope, AT_REMOVEDIR) == 0
    }

    /// Read only the already-open account directory. No native payload is resolved.
    private static func ordinaryDownloadManifest(_ directory: Int32) -> Bool {
        let fd = openat(directory, "manifest.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return errno == ENOENT }
        defer { close(fd) }
        var info = stat()
        let maximum = 16 * 1_024 * 1_024
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            info.st_size >= 0, info.st_size <= off_t(maximum)
        else { return false }
        var data = Data(count: Int(info.st_size) + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < buffer.count {
                guard !Task<Never, Never>.isCancelled else { return -1 }
                let n = Darwin.read(fd, base.advanced(by: total), buffer.count - total)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                total += n
            }
            return total
        }
        guard count == Int(info.st_size) else { return false }
        data.count = count
        guard let manifest = try? FoundationDownloadStorage.decodeManifest(data),
            manifest.nativePendingSessions?.isEmpty ?? true,
            manifest.files.values.allSatisfy({ $0.nativePackage == nil }),
            manifest.artwork?.values.allSatisfy({ $0.file.nativePackage == nil }) ?? true
        else { return false }
        return true
    }

    struct AuthorizedAllocated: Sendable {
        let trackID: String
        let package: FoundationNativeDownloadPackage
        let expectedFinalityProof: FoundationNativeAllocationStore.Receipt.ColdSignOutProof?

        init(
            trackID: String, package: FoundationNativeDownloadPackage,
            expectedFinalityProof: FoundationNativeAllocationStore.Receipt.ColdSignOutProof? = nil
        ) {
            self.trackID = trackID
            self.package = package
            self.expectedFinalityProof = expectedFinalityProof
        }
    }

    struct ColdAllocatedCandidate: Sendable {
        let identifier: String
        let trackID: String
        let package: FoundationNativeDownloadPackage
        let manifestAlreadyPublished: Bool
    }

    struct ColdTerminalCandidate: Sendable {
        let identifier: String
        let taskIdentifier: Int
        let finalityProved: Bool
    }

    static func coldTerminalCandidates(
        root: URL, scope: String, operation: UUID
    ) async -> [ColdTerminalCandidate]? {
        let task = Task.detached(priority: .utility) {
            coldTerminalCandidatesSync(root: root, scope: scope, operation: operation)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func coldTerminalCandidatesSync(
        root: URL, scope: String, operation: UUID
    ) -> [ColdTerminalCandidate]? {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        let parent: Int32
        switch openRoot(root) {
        case .missing: return []
        case .unavailable: return nil
        case .directory(let fd): parent = fd
        }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if target < 0 { return errno == ENOENT ? [] : nil }
        defer { close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { return nil }
        do {
            guard
                let file = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024)
            else {
                return !Task<Never, Never>.isCancelled
                    && pinnedDirectory(parent: parent, scope: scope, expected: info) ? [] : nil
            }
            guard let manifest = try? FoundationDownloadStorage.decodeManifest(file.data),
                manifest.artwork?.values.allSatisfy({ $0.file.nativePackage == nil }) ?? true
            else { return nil }
            var allocated: [String: AuthorizedAllocated] = [:]
            for (track, file) in manifest.files {
                guard let package = file.nativePackage else { continue }
                guard allocated[package.sessionIdentifier] == nil else { return nil }
                allocated[package.sessionIdentifier] = .init(trackID: track, package: package)
            }
            let directory = root.appendingPathComponent(scope, isDirectory: true)
            let receipts = try readNoFactoryReceipts(
                target, directory: directory,
                authorizedAllocatedSessions: allocated, coldOperation: operation,
                discoverTerminals: true)
            guard Set(receipts.map(\.identifier)).count == receipts.count,
                Set(allocated.keys).isSubset(
                    of: Set(receipts.filter(\.allocated).map(\.identifier))),
                (manifest.nativePendingSessions ?? []).isSubset(
                    of: Set(receipts.map(\.identifier))),
                !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return nil }
            return receipts.filter(\.terminal).map {
                .init(
                    identifier: $0.identifier, taskIdentifier: $0.taskIdentifier,
                    finalityProved: $0.terminalFinalityProved)
            }.sorted { $0.identifier < $1.identifier }
        } catch { return nil }
    }

    /// Nil means the bounded inventory failed. An empty result says only that no
    /// manifest-backed candidates were found; strict scoped cleanup still examines
    /// orphan receipts and native artifacts before it may remove anything.
    static func coldAllocatedCandidates(
        root: URL, scope: String, operation: UUID
    ) async -> [ColdAllocatedCandidate]? {
        let task = Task.detached(priority: .utility) {
            coldAllocatedCandidatesSync(root: root, scope: scope, operation: operation)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func coldAllocatedCandidatesSync(
        root: URL, scope: String, operation: UUID
    ) -> [ColdAllocatedCandidate]? {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        let parent: Int32
        switch openRoot(root) {
        case .missing: return []
        case .unavailable: return nil
        case .directory(let fd): parent = fd
        }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if target < 0 { return errno == ENOENT ? [] : nil }
        defer { close(target) }
        var targetInfo = stat()
        guard fstat(target, &targetInfo) == 0 else { return nil }
        do {
            guard
                let file = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024)
            else {
                return !Task<Never, Never>.isCancelled
                    && pinnedDirectory(parent: parent, scope: scope, expected: targetInfo)
                    ? [] : nil
            }
            let manifest = try FoundationDownloadStorage.decodeManifest(file.data)
            guard manifest.artwork?.values.allSatisfy({ $0.file.nativePackage == nil }) ?? true
            else { return nil }
            var authorized: [String: AuthorizedAllocated] = [:]
            for (track, file) in manifest.files {
                guard let package = file.nativePackage else { continue }
                guard authorized[package.sessionIdentifier] == nil else { return nil }
                authorized[package.sessionIdentifier] = .init(trackID: track, package: package)
            }
            let directory = root.appendingPathComponent(scope, isDirectory: true)
            let receipts = try readNoFactoryReceipts(
                target, directory: directory, authorizedAllocatedSessions: authorized,
                coldOperation: operation, discoverTerminals: true)
            let allocated = receipts.filter(\.allocated)
            guard Set(authorized.keys).isSubset(of: Set(allocated.map(\.identifier))),
                Set(receipts.map(\.identifier)).count == receipts.count,
                (manifest.nativePendingSessions ?? []).isSubset(of: Set(receipts.map(\.identifier)))
            else { return nil }
            var result: [ColdAllocatedCandidate] = []
            for receipt in allocated {
                guard let track = receipt.trackID, let package = receipt.package else { return nil }
                let expected = authorized[receipt.identifier]
                if let expected {
                    guard track == expected.trackID,
                        package.sessionIdentifier == expected.package.sessionIdentifier,
                        package.nativeURL == expected.package.nativeURL,
                        package.bookmark == expected.package.bookmark,
                        package.namespaceBookmark == expected.package.namespaceBookmark
                    else { return nil }
                } else {
                    guard manifest.files[track] == nil, receipt.retired else { return nil }
                }
                result.append(
                    .init(
                        identifier: receipt.identifier, trackID: track, package: package,
                        manifestAlreadyPublished: expected == nil))
            }
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: targetInfo)
            else { return nil }
            return result.sorted { $0.identifier < $1.identifier }
        } catch { return nil }
    }

    enum ColdPublicationCheckpoint: Sendable { case afterAuthorization, afterManifest }

    static func publishColdTerminalRetirement(
        root: URL, scope: String, operation: UUID, candidate: ColdTerminalCandidate,
        checkpoint: ColdPublicationCheckpoint? = nil
    ) async -> Bool {
        let task = Task.detached(priority: .utility) {
            publishColdTerminalRetirementSync(
                root: root, scope: scope, operation: operation,
                candidate: candidate, checkpoint: checkpoint)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func publishColdTerminalRetirementSync(
        root: URL, scope: String, operation: UUID, candidate: ColdTerminalCandidate,
        checkpoint: ColdPublicationCheckpoint?
    ) -> Bool {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            case .directory(let parent) = openRoot(root)
        else { return false }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { return false }
        defer { close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { return false }
        let directory = root.appendingPathComponent(scope, isDirectory: true)
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: candidate.identifier)
        do {
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info),
                let file = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024),
                var manifest = try? FoundationDownloadStorage.decodeManifest(file.data),
                let receiptFile = try readBoundedFile(
                    target, name: store.receiptURL.lastPathComponent, maximum: 1_048_576),
                let receipt = try? JSONDecoder().decode(
                    FoundationNativeAllocationStore.Receipt.self, from: receiptFile.data),
                receipt.taskIdentifier == candidate.taskIdentifier, receipt.hasProvenRetirement,
                try store.coldTerminalFinalityMatches(operation: operation),
                !manifest.files.values.contains(where: {
                    $0.nativePackage?.sessionIdentifier == candidate.identifier
                }),
                manifest.artwork?.values.allSatisfy({
                    $0.file.nativePackage?.sessionIdentifier != candidate.identifier
                }) ?? true,
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return false }
            try store.authorizeColdTerminalManifestRemoval(operation: operation)
            if checkpoint == .afterAuthorization { return false }
            manifest.nativePendingSessions?.remove(candidate.identifier)
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return false }
            try FoundationDownloadStorage.save(manifest, directory: directory)
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info),
                FoundationDownloadStorage.synchronizeManifest(directory: directory),
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return false }
            return checkpoint != .afterManifest
        } catch { return false }
    }

    static func publishColdAllocatedRetirement(
        root: URL, scope: String, operation: UUID, candidate: ColdAllocatedCandidate,
        checkpoint: ColdPublicationCheckpoint? = nil
    ) async -> Bool {
        let task = Task.detached(priority: .utility) {
            publishColdAllocatedRetirementSync(
                root: root, scope: scope, operation: operation,
                candidate: candidate, checkpoint: checkpoint)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func publishColdAllocatedRetirementSync(
        root: URL, scope: String, operation: UUID, candidate: ColdAllocatedCandidate,
        checkpoint: ColdPublicationCheckpoint? = nil
    ) -> Bool {
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            case .directory(let parent) = openRoot(root)
        else { return false }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { return false }
        defer { close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { return false }
        let directory = root.appendingPathComponent(scope, isDirectory: true)
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: candidate.identifier)
        do {
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info),
                let manifestFile = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024),
                var manifest = try? FoundationDownloadStorage.decodeManifest(manifestFile.data),
                let receiptFile = try readBoundedFile(
                    target, name: store.receiptURL.lastPathComponent, maximum: 1_048_576),
                let receipt = try? JSONDecoder().decode(
                    FoundationNativeAllocationStore.Receipt.self, from: receiptFile.data),
                receipt.hasProvenRetirement,
                try store.coldFinalityMatches(
                    operation: operation, expectedTrackID: candidate.trackID,
                    expectedPackage: candidate.package)
            else { return false }
            if let saved = manifest.files[candidate.trackID]?.nativePackage {
                guard saved.sessionIdentifier == candidate.identifier,
                    saved.nativeURL == candidate.package.nativeURL,
                    saved.bookmark == candidate.package.bookmark,
                    saved.namespaceBookmark == candidate.package.namespaceBookmark,
                    pinnedDirectory(parent: parent, scope: scope, expected: info)
                else { return false }
                try store.authorizeColdManifestRemoval(
                    operation: operation,
                    expectedTrackID: candidate.trackID, expectedPackage: candidate.package)
                if checkpoint == .afterAuthorization { return false }
                manifest.files.removeValue(forKey: candidate.trackID)
            } else {
                guard manifest.files[candidate.trackID] == nil,
                    try store.coldFinalityMatches(
                        operation: operation, expectedTrackID: candidate.trackID,
                        expectedPackage: candidate.package, requireManifestAuthorization: true)
                else { return false }
            }
            guard
                !manifest.files.values.contains(where: {
                    $0.nativePackage?.sessionIdentifier == candidate.identifier
                }),
                !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return false }
            manifest.nativePendingSessions?.remove(candidate.identifier)
            try FoundationDownloadStorage.save(manifest, directory: directory)
            guard !Task<Never, Never>.isCancelled,
                pinnedDirectory(parent: parent, scope: scope, expected: info),
                FoundationDownloadStorage.synchronizeManifest(directory: directory),
                pinnedDirectory(parent: parent, scope: scope, expected: info)
            else { return false }
            return checkpoint != .afterManifest
        } catch { return false }
    }

    /// Read-only absence of this exact session, not permission to mutate a
    /// directory or acknowledge an event. Native empty/drain/finality evidence
    /// and stable account/owner fences are separate caller requirements.
    static func nativeSessionIsUnrepresented(root: URL, identifier: String) async -> Bool {
        guard
            FoundationNativeAllocationStore.directoryScope(forSessionIdentifier: identifier) != nil,
            !Task<Never, Never>.isCancelled
        else { return false }
        let task = Task.detached(priority: .utility) {
            nativeSessionIsUnrepresentedSync(root: root, identifier: identifier)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    struct CompletedNativeSession: Sendable {
        let trackID: String
        let package: FoundationNativeDownloadPackage
    }

    /// Read-only receipt/manifest identity, never native finality or deletion authority.
    static func nativeSessionMetadataProof(
        root: URL, identifier: String, expected: CompletedNativeSession?,
        retirementOperation: UUID? = nil
    ) async -> Data? {
        let task = Task.detached(priority: .utility) {
            nativeSessionMetadataProofSync(
                root: root, identifier: identifier, expected: expected,
                retirementOperation: retirementOperation)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func nativeSessionMetadataProofSync(
        root: URL, identifier: String, expected: CompletedNativeSession?,
        retirementOperation: UUID?
    ) -> Data? {
        guard
            let scope = FoundationNativeAllocationStore.directoryScope(
                forSessionIdentifier: identifier),
            !Task<Never, Never>.isCancelled, case .directory(let parent) = openRoot(root)
        else { return nil }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard target >= 0 else { return nil }
        defer { close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { return nil }
        let store = FoundationNativeAllocationStore(
            directory: root.appendingPathComponent(scope, isDirectory: true),
            sessionIdentifier: identifier)
        func samePackage(_ a: FoundationNativeDownloadPackage, _ b: FoundationNativeDownloadPackage)
            -> Bool
        {
            a.sessionIdentifier == b.sessionIdentifier && a.nativeURL == b.nativeURL
                && a.bookmark == b.bookmark && a.namespaceBookmark == b.namespaceBookmark
        }
        do {
            guard
                let file = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024),
                let saved = try readBoundedFile(
                    target, name: store.receiptURL.lastPathComponent, maximum: 1_024 * 1_024)
            else { return nil }
            let manifest = try FoundationDownloadStorage.decodeManifest(file.data)
            let receipt = try JSONDecoder().decode(
                FoundationNativeAllocationStore.Receipt.self, from: saved.data)
            guard manifest.nativePendingSessions?.contains(identifier) != true,
                receipt.scope == scope, receipt.sessionIdentifier == identifier,
                !(manifest.artwork?.values.contains(where: {
                    $0.file.nativePackage?.sessionIdentifier == identifier
                }) ?? false)
            else { return nil }
            if let retirementOperation {
                guard receipt.hasProvenRetirement, let proof = receipt.coldSignOutProof,
                    proof.operation == retirementOperation,
                    proof.scope == scope, proof.sessionIdentifier == identifier,
                    proof.taskIdentifier == receipt.taskIdentifier,
                    proof.trackID == (receipt.trackID ?? "")
                else { return nil }
                if receipt.phase == .allocated {
                    guard proof.version == 1, receipt.completionAttempted == true,
                        let package = receipt.package, package.sessionIdentifier == identifier,
                        package.nativeURL == receipt.nativeURL,
                        package.namespaceBookmark == receipt.namespaceBookmark,
                        let track = receipt.trackID
                    else { return nil }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    guard
                        proof.packageDigest == Data(SHA256.hash(data: try encoder.encode(package)))
                    else { return nil }
                    if let file = manifest.files[track] {
                        guard let persisted = file.nativePackage, samePackage(package, persisted)
                        else { return nil }
                    }
                    guard
                        !manifest.files.contains(where: {
                            $0.value.nativePackage?.sessionIdentifier == identifier
                                && $0.key != track
                        })
                    else { return nil }
                } else {
                    guard proof.version == 2, receipt.phase == .terminalNoAllocation,
                        receipt.creationVersion == 1, receipt.taskIdentifier > 0,
                        receipt.nativeURL == nil, receipt.package == nil,
                        receipt.namespaceBookmark == nil, receipt.completionAttempted != true,
                        proof.packageDigest.isEmpty,
                        !manifest.files.values.contains(where: {
                            $0.nativePackage?.sessionIdentifier == identifier
                        })
                    else { return nil }
                }
            } else {
                guard receipt.phase == .allocated, receipt.creationVersion == 1,
                    receipt.taskIdentifier > 0, receipt.completionAttempted == true,
                    receipt.retired != true, receipt.coldSignOutProof == nil,
                    let track = receipt.trackID, let package = receipt.package,
                    let persisted = manifest.files[track]?.nativePackage,
                    package.sessionIdentifier == identifier, receipt.nativeURL == package.nativeURL,
                    let namespace = package.namespaceBookmark,
                    receipt.namespaceBookmark == namespace,
                    samePackage(package, persisted),
                    manifest.files.values.filter({
                        $0.nativePackage?.sessionIdentifier == identifier
                    }).count == 1
                else { return nil }
                if let expected {
                    guard expected.trackID == track, samePackage(expected.package, package) else {
                        return nil
                    }
                }
            }
            guard
                let again = try readBoundedFile(
                    target, name: "manifest.json", maximum: 16 * 1_024 * 1_024),
                let againReceipt = try readBoundedFile(
                    target, name: store.receiptURL.lastPathComponent, maximum: 1_024 * 1_024),
                again.device == file.device, again.inode == file.inode, again.data == file.data,
                againReceipt.device == saved.device, againReceipt.inode == saved.inode,
                againReceipt.data == saved.data,
                pinnedDirectory(parent: parent, scope: scope, expected: info),
                !Task<Never, Never>.isCancelled
            else { return nil }
            var digest = Data(SHA256.hash(data: file.data))
            digest.append(Data(SHA256.hash(data: saved.data)))
            return digest
        } catch { return nil }
    }

    private static func nativeSessionIsUnrepresentedSync(root: URL, identifier: String) -> Bool {
        guard
            let scope = FoundationNativeAllocationStore.directoryScope(
                forSessionIdentifier: identifier),
            !Task<Never, Never>.isCancelled
        else { return false }
        let parent: Int32
        switch openRoot(root) {
        case .missing: return !Task<Never, Never>.isCancelled
        case .unavailable: return false
        case .directory(let value): parent = value
        }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if target < 0 { return errno == ENOENT && !Task<Never, Never>.isCancelled }
        defer { close(target) }
        var info = stat()
        guard fstat(target, &info) == 0 else { return false }
        let directory = root.appendingPathComponent(scope, isDirectory: true)
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        func receiptAbsent() -> Bool {
            var status = stat()
            return fstatat(target, store.receiptURL.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW)
                == -1
                && errno == ENOENT
        }
        do {
            guard receiptAbsent() else { return false }
            let first = try readBoundedFile(
                target, name: "manifest.json", maximum: 16 * 1_024 * 1_024)
            if let first {
                let manifest = try FoundationDownloadStorage.decodeManifest(first.data)
                guard manifest.nativePendingSessions?.contains(identifier) != true,
                    !manifest.files.values.contains(where: {
                        $0.nativePackage?.sessionIdentifier == identifier
                    }),
                    !(manifest.artwork?.values.contains(where: {
                        $0.file.nativePackage?.sessionIdentifier == identifier
                    }) ?? false),
                    let repeatFile = try readBoundedFile(
                        target, name: "manifest.json", maximum: 16 * 1_024 * 1_024),
                    repeatFile.device == first.device, repeatFile.inode == first.inode,
                    repeatFile.data == first.data
                else { return false }
            } else {
                guard
                    case nil = try readBoundedFile(
                        target, name: "manifest.json", maximum: 16 * 1_024 * 1_024)
                else { return false }
            }
            return !Task<Never, Never>.isCancelled && receiptAbsent()
                && pinnedDirectory(parent: parent, scope: scope, expected: info)
        } catch { return false }
    }

    private struct ValidatedNoFactoryReceipt {
        let identifier: String
        let name: String
        let retired: Bool
        let allocated: Bool
        let terminal: Bool
        let terminalFinalityProved: Bool
        let taskIdentifier: Int
        let trackID: String?
        let package: FoundationNativeDownloadPackage?
        let device: dev_t
        let inode: ino_t
        let digest: Data
    }

    private struct BoundedFile {
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    enum NoFactoryCheckpoint: Sendable {
        case afterFirstTombstone, afterManifest, afterFirstReceiptUnlink, afterDirectoryRemoval
    }

    struct NoFactoryRemoval: Sendable {
        let removed: Bool
        let consumedSessions: Set<String>
    }

    #if FOUNDATION_ISOLATED_TEST_HOST
        static func isolatedRemoveNoFactory(
            root: URL, scope: String, requiredSessions: Set<String> = [],
            stopAfterFirstTombstone: Bool = false, stopAfterManifest: Bool = false
        ) -> NoFactoryRemoval {
            let checkpoint: NoFactoryCheckpoint? =
                stopAfterFirstTombstone
                ? .afterFirstTombstone : stopAfterManifest ? .afterManifest : nil
            return removeNoFactory(
                root: root, scope: scope, requiredSessions: requiredSessions,
                checkpoint: checkpoint)
        }
    #endif

    /// Reconciles only the versioned proof that no native factory was entered.
    /// Caller must own the account and drain all workers/leases before invoking.
    static func removeNoFactoryAsync(
        root: URL, scope: String, requiredSessions: Set<String> = [],
        checkpoint: NoFactoryCheckpoint? = nil,
        expectedAbsentSessions: Set<String> = [],
        authorizedAllocatedSessions: [String: AuthorizedAllocated] = [:],
        authorizedTerminalSessions: Set<String> = [],
        retireAllocated: @escaping @Sendable (FoundationNativeAllocationStore) throws -> Void = {
            try $0.retire()
        }
    ) async -> NoFactoryRemoval {
        guard !Task<Never, Never>.isCancelled else {
            return NoFactoryRemoval(removed: false, consumedSessions: [])
        }
        let task = Task.detached(priority: .utility) {
            removeNoFactory(
                root: root, scope: scope, requiredSessions: requiredSessions,
                checkpoint: checkpoint, expectedAbsentSessions: expectedAbsentSessions,
                authorizedAllocatedSessions: authorizedAllocatedSessions,
                authorizedTerminalSessions: authorizedTerminalSessions,
                retireAllocated: retireAllocated)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func removeNoFactory(
        root: URL, scope: String, requiredSessions: Set<String>,
        checkpoint: NoFactoryCheckpoint? = nil,
        expectedAbsentSessions: Set<String> = [],
        authorizedAllocatedSessions: [String: AuthorizedAllocated] = [:],
        authorizedTerminalSessions: Set<String> = [],
        retireAllocated: @Sendable (FoundationNativeAllocationStore) throws -> Void = {
            try $0.retire()
        }
    ) -> NoFactoryRemoval {
        var consumed: Set<String> = []
        func result(_ removed: Bool) -> NoFactoryRemoval {
            NoFactoryRemoval(removed: removed, consumedSessions: consumed)
        }
        guard scope.utf8.count == 64,
            scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return result(false) }
        let parent: Int32
        switch openRoot(root) {
        case .missing: return result(requiredSessions.isEmpty)
        case .unavailable: return result(false)
        case .directory(let fd): parent = fd
        }
        defer { close(parent) }
        let target = openat(parent, scope, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if target < 0 { return result(errno == ENOENT && requiredSessions.isEmpty) }
        defer { close(target) }
        var targetInfo = stat()
        guard fstat(target, &targetInfo) == 0 else { return result(false) }
        let directory = root.appendingPathComponent(scope, isDirectory: true)
        do {
            let manifestData = try readBoundedFile(
                target, name: "manifest.json", maximum: 16 * 1_024 * 1_024)
            var manifest = try manifestData.map {
                try FoundationDownloadStorage.decodeManifest($0.data)
            }
            guard manifest?.artwork?.values.allSatisfy({ $0.file.nativePackage == nil }) ?? true
            else { return result(false) }
            let pending = manifest?.nativePendingSessions ?? []
            let receipts = try readNoFactoryReceipts(
                target, directory: directory,
                authorizedAllocatedSessions: authorizedAllocatedSessions,
                authorizedTerminalSessions: authorizedTerminalSessions)
            let allocated = receipts.filter(\.allocated)
            guard
                allocated.allSatisfy({ receipt in
                    guard let track = receipt.trackID, let package = receipt.package,
                        let expected = authorizedAllocatedSessions[receipt.identifier],
                        expected.trackID == track,
                        expected.package.sessionIdentifier == receipt.identifier,
                        expected.package.nativeURL == package.nativeURL,
                        expected.package.bookmark == package.bookmark,
                        expected.package.namespaceBookmark == package.namespaceBookmark
                    else { return false }
                    if let proof = expected.expectedFinalityProof {
                        let store = FoundationNativeAllocationStore(
                            directory: directory, sessionIdentifier: receipt.identifier)
                        guard receipt.taskIdentifier == proof.taskIdentifier,
                            let current = try? store.load(), current.hasProvenRetirement,
                            current.coldSignOutProof == proof
                        else { return false }
                    }
                    guard let saved = manifest?.files[track]?.nativePackage else {
                        return receipt.retired
                    }
                    return saved.sessionIdentifier == receipt.identifier
                        && saved.nativeURL == package.nativeURL
                        && saved.bookmark == package.bookmark
                        && saved.namespaceBookmark == package.namespaceBookmark
                }),
                manifest?.files.allSatisfy({ track, file in
                    guard let package = file.nativePackage else { return true }
                    return allocated.contains {
                        $0.identifier == package.sessionIdentifier && $0.trackID == track
                    }
                }) ?? true
            else { return result(false) }
            let ids = Set(receipts.map(\.identifier))
            guard ids.count == receipts.count, requiredSessions.isSubset(of: ids),
                ids.isDisjoint(with: expectedAbsentSessions),
                pending.isSubset(of: ids),
                receipts.allSatisfy({
                    pending.contains($0.identifier) || $0.retired || $0.allocated
                })
            else { return result(false) }
            let allowed = Dictionary(uniqueKeysWithValues: receipts.map { ($0.name, $0) })
            var checked = 0
            guard
                walk(
                    target, device: targetInfo.st_dev, depth: 0, count: &checked,
                    limit: 200_000, deleting: false, allowedNoFactoryReceipts: allowed)
            else { return result(false) }
            for receipt in receipts {
                guard !Task<Never, Never>.isCancelled,
                    pinnedDirectory(parent: parent, scope: scope, expected: targetInfo)
                else { return result(false) }
                if !receipt.retired {
                    let store = FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: receipt.identifier)
                    if receipt.allocated { try retireAllocated(store) } else { try store.retire() }
                }
                guard pinnedDirectory(parent: parent, scope: scope, expected: targetInfo) else {
                    return result(false)
                }
                if checkpoint == .afterFirstTombstone { return result(false) }
            }
            let tombstones = try readNoFactoryReceipts(
                target, directory: directory,
                authorizedAllocatedSessions: authorizedAllocatedSessions,
                authorizedTerminalSessions: authorizedTerminalSessions)
            guard Set(tombstones.map(\.identifier)) == ids,
                tombstones.allSatisfy(\.retired)
            else { return result(false) }
            let allowedTombstones = Dictionary(
                uniqueKeysWithValues: tombstones.map { ($0.name, $0) })
            if var current = manifest, !pending.isEmpty || !allocated.isEmpty {
                guard pinnedDirectory(parent: parent, scope: scope, expected: targetInfo) else {
                    return result(false)
                }
                current.nativePendingSessions?.subtract(pending)
                for receipt in allocated {
                    guard let track = receipt.trackID else { return result(false) }
                    current.files.removeValue(forKey: track)
                }
                try FoundationDownloadStorage.save(current, directory: directory)
                guard pinnedDirectory(parent: parent, scope: scope, expected: targetInfo) else {
                    return result(false)
                }
                manifest = current
            }
            if manifest != nil {
                guard pinnedDirectory(parent: parent, scope: scope, expected: targetInfo),
                    FoundationDownloadStorage.synchronizeManifest(directory: directory),
                    pinnedDirectory(parent: parent, scope: scope, expected: targetInfo)
                else { return result(false) }
            }
            if checkpoint == .afterManifest { return result(false) }
            guard !Task<Never, Never>.isCancelled else { return result(false) }
            var removed = 0
            guard
                walk(
                    target, device: targetInfo.st_dev, depth: 0, count: &removed,
                    limit: 200_000, deleting: true, allowedNoFactoryReceipts: allowedTombstones,
                    onNoFactoryReceiptUnlinked: { receipt in
                        consumed.insert(receipt.identifier)
                        return checkpoint != .afterFirstReceiptUnlink
                    })
            else { return result(false) }
            var current = stat()
            guard fstatat(parent, scope, &current, AT_SYMLINK_NOFOLLOW) == 0,
                current.st_dev == targetInfo.st_dev, current.st_ino == targetInfo.st_ino,
                (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            else { return result(false) }
            let removedDirectory = unlinkat(parent, scope, AT_REMOVEDIR) == 0
            if checkpoint == .afterDirectoryRemoval { return result(false) }
            return result(removedDirectory)
        } catch { return result(false) }
    }

    private static func readNoFactoryReceipts(
        _ directoryFD: Int32, directory: URL,
        authorizedAllocatedSessions: [String: AuthorizedAllocated] = [:],
        authorizedTerminalSessions: Set<String> = [], coldOperation: UUID? = nil,
        discoverTerminals: Bool = false
    ) throws -> [ValidatedNoFactoryReceipt] {
        let duplicate = openat(directoryFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(stream) }
        var result: [ValidatedNoFactoryReceipt] = []
        var count = 0
        var receiptBytes = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw CocoaError(.fileReadUnknown) }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 200_000, !Task<Never, Never>.isCancelled else {
                throw CocoaError(.fileReadUnknown)
            }
            guard name.hasPrefix("native-receipt-") else { continue }
            guard let file = try readBoundedFile(directoryFD, name: name, maximum: 1_048_576),
                let receipt = try? JSONDecoder().decode(
                    FoundationNativeAllocationStore.Receipt.self, from: file.data)
            else { throw CocoaError(.fileReadCorruptFile) }
            receiptBytes += file.data.count
            guard result.count < 10_000, receiptBytes <= 16 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let store = FoundationNativeAllocationStore(
                directory: directory, sessionIdentifier: receipt.sessionIdentifier)
            guard store.validSession, store.receiptURL.lastPathComponent == name,
                receipt.scope == directory.lastPathComponent
            else { throw CocoaError(.fileReadCorruptFile) }
            let noFactory =
                receipt.phase == .reserved && receipt.creationVersion == 1
                && receipt.taskIdentifier == 0 && receipt.nativeURL == nil && receipt.package == nil
                && receipt.namespaceBookmark == nil && receipt.completionAttempted != true
            let coldAuthorized: Bool
            if let operation = coldOperation, receipt.retired == true,
                let track = receipt.trackID, let package = receipt.package
            {
                coldAuthorized =
                    (try? store.coldFinalityMatches(
                        operation: operation, expectedTrackID: track,
                        expectedPackage: package, requireManifestAuthorization: true)) == true
            } else {
                coldAuthorized = false
            }
            let allocated =
                (authorizedAllocatedSessions[receipt.sessionIdentifier] != nil || coldAuthorized)
                && receipt.phase == .allocated && receipt.isRetirementEligible
                && receipt.package?.sessionIdentifier == receipt.sessionIdentifier
                && receipt.package?.nativeURL == receipt.nativeURL && receipt.trackID != nil
                && receipt.completionAttempted == true
            let terminal =
                receipt.phase == .terminalNoAllocation && receipt.creationVersion == 1
                && receipt.taskIdentifier > 0 && receipt.nativeURL == nil && receipt.package == nil
                && receipt.namespaceBookmark == nil && receipt.completionAttempted != true
            let terminalAuthorized =
                terminal
                && (discoverTerminals
                    || (authorizedTerminalSessions.contains(receipt.sessionIdentifier)
                        && receipt.hasProvenRetirement))
            let terminalFinalityProved: Bool
            if terminal, receipt.hasProvenRetirement, let operation = coldOperation {
                terminalFinalityProved =
                    (try? store.coldTerminalFinalityMatches(operation: operation)) == true
            } else {
                terminalFinalityProved = false
            }
            guard noFactory || allocated || terminalAuthorized else {
                throw CocoaError(.fileReadCorruptFile)
            }
            result.append(
                .init(
                    identifier: receipt.sessionIdentifier, name: name,
                    retired: receipt.retired == true, allocated: allocated, terminal: terminal,
                    terminalFinalityProved: terminalFinalityProved,
                    taskIdentifier: receipt.taskIdentifier,
                    trackID: receipt.trackID, package: receipt.package, device: file.device,
                    inode: file.inode,
                    digest: Data(SHA256.hash(data: file.data))))
        }
    }

    private static func pinnedDirectory(parent: Int32, scope: String, expected: stat) -> Bool {
        var current = stat()
        return fstatat(parent, scope, &current, AT_SYMLINK_NOFOLLOW) == 0
            && current.st_dev == expected.st_dev && current.st_ino == expected.st_ino
            && (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    /// `nil` means a genuinely absent file; all other lookup or decoding errors fail closed.
    private static func readBoundedFile(_ directory: Int32, name: String, maximum: Int) throws
        -> BoundedFile?
    {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            info.st_size >= 0, info.st_size <= off_t(maximum)
        else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data(count: Int(info.st_size) + 1)
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            var total = 0
            while total < buffer.count {
                guard !Task<Never, Never>.isCancelled else { return -1 }
                let n = Darwin.read(fd, base.advanced(by: total), buffer.count - total)
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    return -1
                }
                total += n
            }
            return total
        }
        guard count == Int(info.st_size) else { throw CocoaError(.fileReadCorruptFile) }
        data.count = count
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == info.st_dev, current.st_ino == info.st_ino,
            (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return BoundedFile(data: data, device: info.st_dev, inode: info.st_ino)
    }

    private enum RootResult {
        case missing
        case unavailable
        case directory(Int32)
    }

    private static func openRoot(_ root: URL) -> RootResult {
        guard root.isFileURL else { return .unavailable }
        let files = FileManager.default
        let anchors = [
            files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            files.urls(for: .cachesDirectory, in: .userDomainMask).first,
            files.temporaryDirectory,
        ].compactMap { $0 }
        let anchor: String
        let components: [String]
        if let match = anchors.compactMap({ candidate -> (URL, [String])? in
            FoundationTrustedAccountPath.components(root, below: candidate).map { (candidate, $0) }
        }).first {
            anchor = match.0.path
            components = match.1
        } else {
            var path = root.standardizedFileURL.path
            if path == "/var" || path.hasPrefix("/var/") || path == "/tmp"
                || path.hasPrefix("/tmp/")
            {
                path = "/private" + path
            }
            guard path.hasPrefix("/") else { return .unavailable }
            anchor = "/"
            components = path.split(separator: "/").map(String.init)
        }
        var parent = Darwin.open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if parent < 0 { return errno == ENOENT ? .missing : .unavailable }
        for name in components {
            let next = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                let missing = errno == ENOENT
                close(parent)
                return missing ? .missing : .unavailable
            }
            close(parent)
            parent = next
        }
        return .directory(parent)
    }

    /// Bounded, no-follow inventory used only for deciding whether an upgrade needs consent.
    static func inventory(root: URL, retained: String, limit: Int = 4096) throws -> (Bool, Bool) {
        let parent: Int32
        switch openRoot(root) {
        case .missing: return (false, false)
        case .unavailable: throw FoundationLibraryError.credentials
        case .directory(let fd): parent = fd
        }
        defer { close(parent) }
        let descriptor = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0, let stream = fdopendir(descriptor) else {
            if descriptor >= 0 { close(descriptor) }
            throw FoundationLibraryError.credentials
        }
        defer { closedir(stream) }
        var matching = false
        var unrelated = false
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw FoundationLibraryError.credentials }
                return (matching, unrelated)
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= limit else { throw FoundationLibraryError.credentials }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            else { throw FoundationLibraryError.credentials }
            if name == retained { matching = true } else { unrelated = true }
        }
    }

    private static func walk(
        _ directory: Int32, device: dev_t, depth: Int, count: inout Int,
        limit: Int, deleting: Bool,
        allowedNoFactoryReceipts: [String: ValidatedNoFactoryReceipt] = [:],
        onNoFactoryReceiptUnlinked: (ValidatedNoFactoryReceipt) -> Bool = { _ in true }
    ) -> Bool {
        guard depth <= maximumDepth, !Task<Never, Never>.isCancelled else { return false }
        let duplicate = openat(directory, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            return false
        }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else { return errno == 0 }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= limit, !name.hasPrefix("stage-native-"),
                !name.lowercased().hasSuffix(".movpkg"),
                !Task<Never, Never>.isCancelled
            else { return false }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                info.st_dev == device
            else { return false }
            if name.hasPrefix("native-receipt-") {
                guard depth == 0, let expected = allowedNoFactoryReceipts[name],
                    !deleting || expected.retired,
                    info.st_dev == expected.device, info.st_ino == expected.inode,
                    let file = try? readBoundedFile(directory, name: name, maximum: 1_048_576),
                    file.device == expected.device, file.inode == expected.inode,
                    Data(SHA256.hash(data: file.data)) == expected.digest
                else { return false }
            }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                if deleting {
                    guard unlinkat(directory, name, 0) == 0 else { return false }
                    if let receipt = allowedNoFactoryReceipts[name],
                        !onNoFactoryReceiptUnlinked(receipt)
                    {
                        return false
                    }
                }
            case mode_t(S_IFDIR):
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { return false }
                var opened = stat()
                let matches =
                    fstat(child, &opened) == 0 && opened.st_dev == info.st_dev
                    && opened.st_ino == info.st_ino
                let success =
                    matches
                    && walk(
                        child, device: device, depth: depth + 1, count: &count,
                        limit: limit, deleting: deleting,
                        allowedNoFactoryReceipts: allowedNoFactoryReceipts,
                        onNoFactoryReceiptUnlinked: onNoFactoryReceiptUnlinked)
                close(child)
                guard success else { return false }
                if deleting, unlinkat(directory, name, AT_REMOVEDIR) != 0 { return false }
            default:
                return false
            }
        }
    }
}

/// Private, recoverable download metadata. Requests and credentials never enter this representation.
nonisolated struct FoundationStoredDownloadItem: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let duration: Double?
    let artworkTag: String?
    let albumID: String?
    let albumTitle: String?
    let albumTag: String?
    var artist: FoundationItemReference? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil

    init(_ item: FoundationItem) {
        id = item.id
        title = item.title
        subtitle = item.subtitle
        kind =
            switch item.kind {
            case .track: "track"
            case .album: "album"
            case .playlist: "playlist"
            case .artist: "artist"
            case .genre: "genre"
            }
        duration = item.duration
        artworkTag = item.primaryImageTag
        albumID = item.album?.id
        albumTitle = item.album?.title
        artist = item.artist
        albumTag = item.album?.primaryImageTag
        trackNumber = item.trackNumber
        discNumber = item.discNumber
    }

    var item: FoundationItem {
        var result = FoundationItem(
            id: id, title: title, subtitle: subtitle,
            kind: FoundationItem.Kind(rawValue: kind) ?? .track,
            duration: duration, primaryImageTag: artworkTag)
        if let albumID, let albumTitle {
            result.album = FoundationItemReference(
                id: albumID, title: albumTitle, primaryImageTag: albumTag)
        }
        result.artist = artist
        result.trackNumber = trackNumber
        result.discNumber = discNumber
        return result
    }
}

nonisolated struct FoundationDownloadManifest: Codable, Sendable {
    struct Owner: Codable, Sendable {
        let id: String
        let item: FoundationStoredDownloadItem
        let tracks: [FoundationStoredDownloadItem]
        let paused: Bool
        let expanded: Bool
        // Absent in existing manifests: ordinary intent never clears local exclusions.
        var reacquiresExcludedTracks: Bool? = nil
        // Absent in existing manifests means Original. Never resample on retry/reconcile.
        var requestedQuality: FoundationDownloadQuality? = nil
        var systemManaged: Bool? = nil
    }
    struct File: Codable, Sendable {
        let name: String
        let bytes: Int64
        let digest: String
        // Nil means a historical/original file. Requested quality belongs to the owner.
        var convertedRendition: FoundationConvertedDownloadRendition? = nil
        var nativePackage: FoundationNativeDownloadPackage? = nil
        // Native HLS records declaration/intent, never fabricated file-reader measurements.
        var nativeRendition: FoundationNativeDownloadRendition? = nil
    }
    struct Artwork: Codable, Sendable {
        let item: FoundationStoredDownloadItem
        let file: File
    }
    struct Collection: Codable, Equatable, Sendable {
        let item: FoundationStoredDownloadItem
        let tracks: [FoundationStoredDownloadItem]
        let complete: Bool
    }
    // Discovery metadata has no ownership claim on audio or retained artwork.
    var collections: [Collection]? = nil
    var artwork: [String: Artwork]? = nil
    // Opaque background-session IDs only; no network request or credential is persisted.
    var nativePendingSessions: Set<String>? = nil
    var version = 2
    // Optional for version-one manifests; absence means no deliberate local removals.
    var excludedTrackIDs: Set<String>? = nil
    var allowsCellular = false
    var owners: [Owner] = []
    var files: [String: File] = [:]
}

/// All filesystem operations stay within one opaque account directory.
nonisolated enum FoundationDownloadStorage {
    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VelacantoDownloads", isDirectory: true)
    }

    static func directory(scope: String, root: URL?) -> URL {
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return (root ?? base).appendingPathComponent(key, isDirectory: true)
    }

    static func protect(_ url: URL) throws {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try target.setResourceValues(values)
        guard
            try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true
        else { throw CocoaError(.fileWriteUnknown) }
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path)
        #else
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            try FileManager.default.setAttributes(
                [.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        #endif
    }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
    }

    static func fileURL(_ file: FoundationDownloadManifest.File, directory: URL) -> URL? {
        if let package = file.nativePackage {
            return package.resolveOwnedURL(scope: directory.lastPathComponent)
        }
        guard file.name == URL(fileURLWithPath: file.name).lastPathComponent,
            !file.name.hasPrefix("."), file.name != "manifest.json", !file.name.contains("/")
        else { return nil }
        return directory.appendingPathComponent(file.name)
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 256 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func verifiedFiles(
        _ files: [String: FoundationDownloadManifest.File], directory: URL
    ) async throws -> [String: FoundationDownloadManifest.File] {
        let task = Task.detached(priority: .utility) {
            var verified: [String: FoundationDownloadManifest.File] = [:]
            for (id, file) in files {
                try Task.checkCancellation()
                if valid(file, directory: directory) { verified[id] = file }
            }
            try Task.checkCancellation()
            return verified
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func digestOffMain(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) { try digest(url) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func valid(_ file: FoundationDownloadManifest.File, directory: URL) -> Bool {
        if let package = file.nativePackage {
            guard file.bytes > 0,
                let url = package.resolveOwnedURL(scope: directory.lastPathComponent)
            else { return false }
            // Never query native cache until bookmark/resource ownership is established.
            return AVURLAsset(
                url: url,
                options: [
                    AVURLAssetReferenceRestrictionsKey:
                        NSNumber(
                            value: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote
                                .rawValue),
                    AVURLAssetAllowsCellularAccessKey: false,
                    AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                    AVURLAssetAllowsConstrainedNetworkAccessKey: false,
                ]
            ).assetCache?.isPlayableOffline == true
                && (try? FoundationNativeDownloadTransport.protectedAllocationBytes(url)) != nil
        }
        guard let url = fileURL(file, directory: directory), file.bytes > 0,
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ]),
            values.isRegularFile == true, values.isSymbolicLink != true,
            Int64(values.fileSize ?? -1) == file.bytes,
            (try? digest(url)) == file.digest
        else { return false }
        return true
    }

    static func save(_ manifest: FoundationDownloadManifest, directory: URL) throws {
        let target = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        var persisted = manifest
        if manifest.files.values.contains(where: { $0.nativePackage != nil })
            || manifest.owners.contains(where: { $0.systemManaged == true })
            || !(manifest.nativePendingSessions?.isEmpty ?? true)
        {
            persisted.version = 3
        }
        let data = try JSONEncoder().encode(persisted)
        guard data.count <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let stage = directory.appendingPathComponent(
            "stage-manifest-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: stage) }
        #if os(iOS)
            try data.write(
                to: stage, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: stage, options: .atomic)
        #endif
        try protect(stage)
        // Same-directory POSIX rename atomically publishes the already-protected inode.
        // No fallible work follows publication, so a thrown save leaves the previous manifest intact.
        let result = stage.path.withCString { source in
            target.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Confirms that the currently published manifest and its directory reached the filesystem.
    /// A false result is uncertain publication, not evidence that the previous state survived.
    static func synchronizeManifest(directory: URL) -> Bool {
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        let file = openat(parent, "manifest.json", O_RDONLY | O_NOFOLLOW)
        guard file >= 0 else { return false }
        defer { close(file) }
        var opened = stat()
        var current = stat()
        guard fstat(file, &opened) == 0,
            (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            fsync(file) == 0, fsync(parent) == 0,
            fstatat(parent, "manifest.json", &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
            (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
        else { return false }
        return true
    }

    static func load(directory: URL) throws -> FoundationDownloadManifest {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return FoundationDownloadManifest()
        }
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16 * 1_024 * 1_024
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try decodeManifest(Data(contentsOf: manifestURL))
    }

    static func decodeManifest(_ data: Data) throws -> FoundationDownloadManifest {
        var manifest = try JSONDecoder().decode(FoundationDownloadManifest.self, from: data)
        guard (1...3).contains(manifest.version), manifest.owners.count <= 10_000,
            (manifest.nativePendingSessions?.count ?? 0) <= 10_000,
            (manifest.excludedTrackIDs?.count ?? 0) <= 100_000,
            (manifest.artwork?.count ?? 0) <= 100_000,
            Set(manifest.owners.map(\.id)).count == manifest.owners.count,
            manifest.owners.allSatisfy({ $0.tracks.count <= 10_000 }),
            (manifest.collections?.count ?? 0) <= 128,
            (manifest.collections ?? []).reduce(0, { $0 + $1.tracks.count }) <= 10_000,
            (try JSONEncoder().encode(manifest.collections ?? [])).count <= 2 * 1_024 * 1_024,
            (manifest.collections ?? []).allSatisfy({
                ["album", "playlist"].contains($0.item.kind)
                    && $0.tracks.allSatisfy { $0.kind == "track" }
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        manifest.version = 2
        return manifest
    }
}

/// A completed OS-owned allocation, never a source URL or private package layout.
nonisolated struct FoundationNativeDownloadPackage: Codable, Sendable {
    let nativeURL: URL
    let bookmark: Data
    let sessionIdentifier: String

    // Snapshot the real namespace as well as the package, without reconstructing paths.
    var namespaceBookmark: Data? = nil

    enum Resolution: Sendable {
        case available(URL)
        case provenMissing
        case unverifiable
        var url: URL? {
            if case .available(let url) = self { return url }
            return nil
        }
    }

    func resolution(
        scope: String? = nil,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        inspect: ((FoundationNativeDownloadPackage) -> FoundationManagedPackageMetadata.Result)? =
            nil,
        missing: ((FoundationNativeDownloadPackage) -> Bool)? = nil
    ) -> Resolution {
        if let scope, !sessionIdentifier.hasPrefix("dev.novoluxor.velacanto.offline." + scope + ".")
        {
            return .unverifiable
        }
        var report = FoundationManagedPackageMetadata.Report()
        report.bound = true
        let result =
            inspect?(self)
            ?? FoundationManagedPackageMetadata.inspectResult(
                .init(nativeURL: nativeURL, canonicalURL: nativeURL, completedBookmark: bookmark),
                home: home, initial: report)
        if let url = result.resolvedURL { return .available(url) }
        // Bookmark failure, stale identity, denied metadata or an unreadable package
        // NEVER imply deletion. Confirm ENOENT twice under a pinned, owned namespace.
        if missing?(self) ?? provesMissing(home: home) { return .provenMissing }
        return .unverifiable
    }

    func resolveOwnedURL(scope: String? = nil) -> URL? { resolution(scope: scope).url }

    func removeOwnedPackage(scope: String? = nil) throws {
        switch resolution(scope: scope) {
        case .available(let url): try FileManager.default.removeItem(at: url)
        case .provenMissing: return
        case .unverifiable: throw FoundationDownloadError.cleanup
        }
    }

    static func ownsNamespace(
        _ nativeURL: URL,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        resources: (URL) throws -> [URLResourceKey: Any] = FoundationManagedPackageMetadata
            .resources
    ) -> Bool {
        typealias Metadata = FoundationManagedPackageMetadata
        let namespace = nativeURL.deletingLastPathComponent()
        let library = namespace.deletingLastPathComponent()
        let owner = library.deletingLastPathComponent()
        guard Metadata.plain(nativeURL), Metadata.plain(home),
            Metadata.validNamespace(namespace.lastPathComponent),
            library.lastPathComponent == "Library"
        else { return false }
        do {
            func same(_ a: [URLResourceKey: Any], _ b: [URLResourceKey: Any]) -> Bool {
                let delta = Metadata.comparison(a, b)
                return b[.isDirectoryKey] as? Bool == true
                    && b[.isSymbolicLinkKey] as? Bool == false
                    && delta.file == .equal && delta.volume == .equal
            }
            let firstHome = try resources(home)
            let firstOwner = try resources(owner)
            let firstLibrary = try resources(home.appendingPathComponent("Library"))
            let actualLibrary = try resources(library)
            let firstNamespace = try resources(namespace)
            guard same(firstHome, firstOwner), same(firstLibrary, actualLibrary) else {
                return false
            }
            let repeatHome = try resources(home)
            let repeatOwner = try resources(owner)
            let repeatLibrary = try resources(home.appendingPathComponent("Library"))
            let repeatActualLibrary = try resources(library)
            let repeatNamespace = try resources(namespace)
            return same(firstHome, repeatHome) && same(firstOwner, repeatOwner)
                && same(firstLibrary, repeatLibrary) && same(actualLibrary, repeatActualLibrary)
                && same(firstNamespace, repeatNamespace)
        } catch { return false }
    }

    func provesMissing(
        home: URL,
        resources: (URL) throws -> [URLResourceKey: Any] = FoundationManagedPackageMetadata
            .resources,
        absent: (URL) -> Bool = { url in
            var status = stat()
            return url.path.withCString { lstat($0, &status) } == -1 && errno == ENOENT
        }
    ) -> Bool {
        typealias Metadata = FoundationManagedPackageMetadata
        guard Metadata.plain(nativeURL), Metadata.plain(home), let namespaceBookmark,
            let saved = NSURL.resourceValues(
                forKeys: Metadata.keys, fromBookmarkData: namespaceBookmark)
        else { return false }
        // The exact issued URL is retained, including /.nofollow. No prefix stripping,
        // basename guessing, path reconstitution or native cache getter is involved.
        let namespace = nativeURL.deletingLastPathComponent()
        let library = namespace.deletingLastPathComponent()
        let owner = library.deletingLastPathComponent()
        guard Metadata.validNamespace(namespace.lastPathComponent),
            library.lastPathComponent == "Library"
        else { return false }
        do {
            let first = try resources(namespace)
            func directory(_ data: [URLResourceKey: Any]) -> Bool {
                data[.isDirectoryKey] as? Bool == true && data[.isSymbolicLinkKey] as? Bool == false
            }
            func same(_ a: [URLResourceKey: Any], _ b: [URLResourceKey: Any]) -> Bool {
                let delta = Metadata.comparison(a, b)
                return directory(b) && delta.file == .equal && delta.volume == .equal
            }
            let homeFirst = try resources(home)
            let ownerFirst = try resources(owner)
            let libraryFirst = try resources(home.appendingPathComponent("Library"))
            let resolvedLibraryFirst = try resources(library)
            guard directory(first), same(saved, first), same(homeFirst, ownerFirst),
                same(libraryFirst, resolvedLibraryFirst), absent(nativeURL), absent(nativeURL)
            else { return false }
            let last = try resources(namespace)
            let delta = Metadata.comparison(first, last)
            guard same(first, last), delta.generation == .equal else { return false }
            let repeatHome = try resources(home)
            let repeatOwner = try resources(owner)
            let repeatLibrary = try resources(home.appendingPathComponent("Library"))
            let repeatResolvedLibrary = try resources(library)
            return same(homeFirst, repeatHome) && same(ownerFirst, repeatOwner)
                && same(libraryFirst, repeatLibrary)
                && same(resolvedLibraryFirst, repeatResolvedLibrary)
        } catch { return false }
    }

}

/// Metadata only. Never obtains a media object, refreshes a bookmark, or changes the package.
nonisolated enum FoundationManagedPackageMetadata {
    enum Flag: String, Codable { case yes, no, unavailable }
    enum Equality: String, Codable { case equal, different, unavailable }
    enum Stage: String, Codable {
        case receipt, recordBinding, urlSyntax, containment, directory, savedSnapshot
        case resolution, resolvedContainment, ownership, finished
    }
    enum Domain: String, Codable { case cocoa, posix, other }
    struct ErrorCode: Codable {
        let domain: Domain
        let code: Int
    }
    struct Identity: Codable {
        var file: Equality = .unavailable
        var volume: Equality = .unavailable
        var generation: Equality = .unavailable
    }
    struct Report: Encodable {
        var stage: Stage = .receipt
        var bound = false
        var plainURLs = false
        var nativeRecordedCanonicalEqual: Bool?
        var originalLexicalLibraryContained: Bool?
        var recordedLexicalLibraryContained: Bool?
        var resolvedRecordedCanonicalEqual: Bool?
        var contained = false
        var resolvedCanonicalLibraryContained: Bool?
        var namespaceValid = false
        var ownerFile: Equality = .unavailable
        var ownerVolume: Equality = .unavailable
        var ownerLibraryFile: Equality = .unavailable
        var ownerLibraryVolume: Equality = .unavailable
        var ownerRepeatStable = false
        var ownerProved = false
        var ownerFinalStable = false
        var sameStoredResource = false
        var namespaceDirectory: Bool?
        var namespaceSymlink: Bool?
        var namespaceReadable: Bool?
        var readable: Bool?
        var directory: Bool?
        var symlink: Bool?
        enum Protection: String, Codable {
            case complete, completeUnlessOpen, completeUntilFirstAuthentication, none, unavailable,
                other
        }
        var protection: Protection = .unavailable
        var savedSnapshot = false
        var savedFileAvailable = false
        var savedVolumeAvailable = false
        var savedGenerationAvailable = false
        var bookmarkStale: Bool?
        var resolvedCanonicalEqual: Bool?
        var savedToResolved = Identity()
        var repeatResolved = Identity()
        var repeatNamespace = Identity()
        var error: ErrorCode?
        let nativeCacheQueried = false
        let receiptWritten = false
    }
    struct Allocation: Codable {
        let nativeURL: URL
        let canonicalURL: URL
        let completedBookmark: Data?
    }
    struct Record: Decodable {
        let run: UUID
        let session: String
        let source: URL
        let task: Int?
        let allocation: Allocation?
        let completed: Bool
        let removed: Bool
    }
    static let keys: [URLResourceKey] = [
        .fileResourceIdentifierKey, .volumeIdentifierKey, .generationIdentifierKey,
    ]
    static func plain(_ u: URL) -> Bool {
        u.isFileURL && u.baseURL == nil && u.path.hasPrefix("/")
            && (u.host == nil || u.host == "" || u.host?.lowercased() == "localhost")
            && u.user == nil && u.password == nil && u.query == nil && u.fragment == nil
    }
    static func canonical(_ u: URL) -> URL { u.standardizedFileURL.resolvingSymlinksInPath() }
    static func equalPath(_ a: URL, _ b: URL) -> Bool { a.pathComponents == b.pathComponents }
    static func contained(_ u: URL, in root: URL) -> Bool {
        let a = u.pathComponents
        let b = root.pathComponents
        return a.count > b.count && Array(a.prefix(b.count)) == b
    }
    static func resources(_ u: URL) throws -> [URLResourceKey: Any] {
        let fresh = NSURL(fileURLWithPath: u.path)
        fresh.removeAllCachedResourceValues()
        return try fresh.resourceValues(forKeys: keys + [.isDirectoryKey, .isSymbolicLinkKey])
    }
    static func comparison(_ a: [URLResourceKey: Any], _ b: [URLResourceKey: Any]) -> Identity {
        func one(_ key: URLResourceKey) -> Equality {
            guard let x = a[key] as? any NSObjectProtocol,
                let y = b[key] as? any NSObjectProtocol
            else { return .unavailable }
            return x.isEqual(y) ? .equal : .different
        }
        return Identity(file: one(keys[0]), volume: one(keys[1]), generation: one(keys[2]))
    }
    static func validNamespace(_ name: String) -> Bool {
        let prefix = "com.apple.UserManagedAssets."
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        return (1...64).contains(suffix.utf8.count)
            && suffix.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 95
            }
    }
    struct Result {
        let report: Report
        /// Private runtime value only; never encoded or displayed.
        let resolvedURL: URL?
    }
    static func inspect(
        _ allocation: Allocation, home: URL, initial: Report,
        readResources: (URL) throws -> [URLResourceKey: Any] = resources,
        readAncestorResources: (URL) throws -> [URLResourceKey: Any] = resources
    ) -> Report {
        inspectResult(
            allocation, home: home, initial: initial,
            readResources: readResources, readAncestorResources: readAncestorResources
        ).report
    }
    /// Saved snapshot and bookmark resolution precede ANY package metadata read.
    /// The original native path is never canonicalized or accessed, even if it has
    /// a /.nofollow-style prefix. No prefix stripping or path reconstruction occurs.
    static func inspectResult(
        _ allocation: Allocation, home: URL, initial: Report,
        readResources: (URL) throws -> [URLResourceKey: Any] = resources,
        readAncestorResources: (URL) throws -> [URLResourceKey: Any] = resources
    ) -> Result {
        var r = initial
        guard r.bound else { return Result(report: r, resolvedURL: nil) }
        do {
            r.stage = .urlSyntax
            r.plainURLs =
                plain(allocation.nativeURL) && plain(allocation.canonicalURL) && plain(home)
            guard r.plainURLs else { return Result(report: r, resolvedURL: nil) }
            r.nativeRecordedCanonicalEqual = equalPath(
                allocation.nativeURL, allocation.canonicalURL)
            let currentHome = canonical(home)
            let library = canonical(home.appendingPathComponent("Library", isDirectory: true))
            r.originalLexicalLibraryContained = contained(
                allocation.nativeURL.standardizedFileURL, in: library)
            r.recordedLexicalLibraryContained = contained(
                allocation.canonicalURL.standardizedFileURL, in: library)
            guard contained(library, in: currentHome) else {
                r.stage = .containment
                return Result(report: r, resolvedURL: nil)
            }
            r.stage = .savedSnapshot
            guard let bookmark = allocation.completedBookmark,
                let saved = NSURL.resourceValues(forKeys: keys, fromBookmarkData: bookmark)
            else { return Result(report: r, resolvedURL: nil) }
            r.savedSnapshot = true
            r.savedFileAvailable = saved[.fileResourceIdentifierKey] is any NSObjectProtocol
            r.savedVolumeAvailable = saved[.volumeIdentifierKey] is any NSObjectProtocol
            r.savedGenerationAvailable = saved[.generationIdentifierKey] is any NSObjectProtocol
            r.stage = .resolution
            var stale = false
            let resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing],
                relativeTo: nil, bookmarkDataIsStale: &stale)
            r.bookmarkStale = stale
            r.stage = .resolvedContainment
            guard plain(resolved) else { return Result(report: r, resolvedURL: nil) }
            let target = canonical(resolved)
            r.resolvedCanonicalLibraryContained = contained(target, in: library)
            // Derive only ancestors of the SAME bookmark-resolved URL. A system URL
            // can preserve /.nofollow; no removal, guessed normal path or matching of
            // basenames is performed. Shape limits which ancestors may be inspected.
            let namespace = resolved.deletingLastPathComponent()
            let resolvedLibrary = namespace.deletingLastPathComponent()
            let resolvedHome = resolvedLibrary.deletingLastPathComponent()
            guard resolvedLibrary.lastPathComponent == "Library",
                validNamespace(namespace.lastPathComponent),
                !resolved.lastPathComponent.isEmpty,
                plain(namespace), plain(resolvedLibrary), plain(resolvedHome)
            else { return Result(report: r, resolvedURL: nil) }
            r.namespaceValid = true
            r.stage = .ownership
            let homeFirst = try readAncestorResources(home)
            let resolvedHomeFirst = try readAncestorResources(resolvedHome)
            let libraryFirst = try readAncestorResources(home.appendingPathComponent("Library"))
            let resolvedLibraryFirst = try readAncestorResources(resolvedLibrary)
            func directory(_ values: [URLResourceKey: Any]) -> Bool {
                values[.isDirectoryKey] as? Bool == true
                    && values[.isSymbolicLinkKey] as? Bool == false
            }
            guard
                [homeFirst, resolvedHomeFirst, libraryFirst, resolvedLibraryFirst].allSatisfy(
                    directory)
            else { return Result(report: r, resolvedURL: nil) }
            let owner = comparison(homeFirst, resolvedHomeFirst)
            let ownerLibrary = comparison(libraryFirst, resolvedLibraryFirst)
            r.ownerFile = owner.file
            r.ownerVolume = owner.volume
            r.ownerLibraryFile = ownerLibrary.file
            r.ownerLibraryVolume = ownerLibrary.volume
            guard owner.file == .equal, owner.volume == .equal,
                ownerLibrary.file == .equal, ownerLibrary.volume == .equal
            else { return Result(report: r, resolvedURL: nil) }
            func stable(_ before: [URLResourceKey: Any], _ after: [URLResourceKey: Any]) -> Bool {
                let delta = comparison(before, after)
                return directory(after) && delta.file == .equal && delta.volume == .equal
            }
            // Repeat both sides before namespace/package attribute reads. Missing IDs
            // cannot establish ownership; generation is NOT substituted for file ID.
            let homeRepeat = try readAncestorResources(home)
            let resolvedHomeRepeat = try readAncestorResources(resolvedHome)
            let libraryRepeat = try readAncestorResources(home.appendingPathComponent("Library"))
            let resolvedLibraryRepeat = try readAncestorResources(resolvedLibrary)
            r.ownerRepeatStable =
                stable(homeFirst, homeRepeat)
                && stable(resolvedHomeFirst, resolvedHomeRepeat)
                && stable(libraryFirst, libraryRepeat)
                && stable(resolvedLibraryFirst, resolvedLibraryRepeat)
            guard r.ownerRepeatStable else { return Result(report: r, resolvedURL: nil) }
            r.ownerProved = true
            // The only metadata-reader calls are now bound to the resolved contained URL.
            let nsFirst = try readResources(namespace)
            r.namespaceDirectory = nsFirst[.isDirectoryKey] as? Bool
            r.namespaceSymlink = nsFirst[.isSymbolicLinkKey] as? Bool
            r.namespaceReadable = FileManager.default.isReadableFile(atPath: namespace.path)
            guard r.namespaceDirectory == true, r.namespaceSymlink == false,
                r.namespaceReadable == true
            else { return Result(report: r, resolvedURL: nil) }
            r.contained = true
            r.resolvedRecordedCanonicalEqual = equalPath(target, allocation.canonicalURL)
            r.stage = .directory
            let first = try readResources(resolved)
            r.directory = first[.isDirectoryKey] as? Bool
            r.symlink = first[.isSymbolicLinkKey] as? Bool
            r.readable = FileManager.default.isReadableFile(atPath: resolved.path)
            guard r.directory == true, r.symlink == false else {
                return Result(report: r, resolvedURL: nil)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: resolved.path)
            if let p = attrs[.protectionKey] as? String {
                switch p {
                case "NSFileProtectionComplete": r.protection = .complete
                case "NSFileProtectionCompleteUnlessOpen": r.protection = .completeUnlessOpen
                case "NSFileProtectionCompleteUntilFirstUserAuthentication":
                    r.protection = .completeUntilFirstAuthentication
                case "NSFileProtectionNone": r.protection = .none
                default: r.protection = .other
                }
            }
            r.savedToResolved = comparison(saved, first)
            r.repeatResolved = comparison(first, try readResources(resolved))
            let nsRepeat = try readResources(namespace)
            r.repeatNamespace = comparison(nsFirst, nsRepeat)
            let homeFinal = try readAncestorResources(home)
            let resolvedHomeFinal = try readAncestorResources(resolvedHome)
            let libraryFinal = try readAncestorResources(home.appendingPathComponent("Library"))
            let resolvedLibraryFinal = try readAncestorResources(resolvedLibrary)
            r.ownerFinalStable =
                stable(homeFirst, homeFinal)
                && stable(resolvedHomeFirst, resolvedHomeFinal)
                && stable(libraryFirst, libraryFinal)
                && stable(resolvedLibraryFirst, resolvedLibraryFinal)
            guard nsRepeat[.isDirectoryKey] as? Bool == true,
                nsRepeat[.isSymbolicLinkKey] as? Bool == false,
                equalPath(canonical(resolved), target), r.ownerFinalStable
            else { return Result(report: r, resolvedURL: nil) }
            r.stage = .finished
            // Persisted directory generation is a mutable observation. It must not
            // substitute for stored file+volume identity. Fresh repeat reads still
            // require all available identity keys to stay stable during validation.
            r.sameStoredResource =
                !stale && r.readable == true
                && r.savedToResolved.file == .equal && r.savedToResolved.volume == .equal
                && r.repeatResolved.file == .equal && r.repeatResolved.volume == .equal
                && r.repeatResolved.generation == .equal
                && r.repeatNamespace.file == .equal && r.repeatNamespace.volume == .equal
                && r.repeatNamespace.generation == .equal
            return Result(report: r, resolvedURL: r.sameStoredResource ? resolved : nil)
        } catch {
            let e = error as NSError
            r.error = ErrorCode(
                domain: e.domain == NSCocoaErrorDomain
                    ? .cocoa
                    : e.domain == NSPOSIXErrorDomain ? .posix : .other, code: e.code)
        }
        return Result(report: r, resolvedURL: nil)
    }
}

/// A protected acquisition receipt binds the OS callback to one account/session/task.
/// It is app metadata outside the package, not media or an Original sidecar.
nonisolated struct FoundationNativeAllocationStore: Sendable {
    struct Receipt: Codable, Sendable {
        let scope: String
        let sessionIdentifier: String
        let taskIdentifier: Int
        var trackID: String? = nil
        var nativeURL: URL?
        enum Phase: String, Codable, Sendable {
            case reserved, creating, resuming, allocated, terminalNoAllocation
        }
        var phase: Phase? = nil
        var namespaceBookmark: Data?
        var package: FoundationNativeDownloadPackage?
        var retired: Bool? = nil
        // Only this lifecycle writes creating BEFORE the OS session/task factory.
        // Missing on older receipts: reserved could already have issued a factory.
        var creationVersion: Int? = nil
        var completionAttempted: Bool? = nil

        struct ColdSignOutProof: Codable, Equatable, Sendable {
            let version: Int
            let operation: UUID
            let scope: String
            let sessionIdentifier: String
            let taskIdentifier: Int
            let trackID: String
            let packageDigest: Data
            var manifestRemovalAuthorized: Bool
        }
        var coldSignOutProof: ColdSignOutProof? = nil

        var isRetirementEligible: Bool {
            if nativeURL == nil {
                return (phase == .reserved && creationVersion == 1)
                    || phase == .terminalNoAllocation
            }
            guard phase == .allocated, creationVersion == 1, taskIdentifier > 0,
                let namespaceBookmark
            else { return false }
            return package == nil || package?.namespaceBookmark == namespaceBookmark
        }

        var hasProvenRetirement: Bool { retired == true && isRetirementEligible }
    }
    let directory: URL
    let sessionIdentifier: String
    var trackID: String? = nil
    var scope: String { directory.lastPathComponent }
    var receiptURL: URL {
        let key = SHA256.hash(data: Data(sessionIdentifier.utf8)).map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("native-receipt-" + key + ".json")
    }

    /// New reservations precede every native asset factory. Legacy reservations do not prove
    /// allocation absence: older versions could create a task before durable binding.
    func reserve(taskIdentifier: Int = 0) throws {
        guard validSession, taskIdentifier >= 0 else { throw FoundationDownloadError.cleanup }
        var receipt: Receipt
        var status = stat()
        let found = receiptURL.path.withCString { lstat($0, &status) }
        if found == 0 {
            receipt = try load()
            guard receipt.phase == .reserved, receipt.creationVersion == 1,
                receipt.retired != true,
                receipt.taskIdentifier == 0 || receipt.taskIdentifier == taskIdentifier
            else {
                throw FoundationDownloadError.cleanup
            }
            receipt = Receipt(
                scope: scope, sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier, trackID: trackID ?? receipt.trackID, nativeURL: nil,
                phase: .reserved, creationVersion: 1)
        } else {
            guard errno == ENOENT else { throw FoundationDownloadError.cleanup }
            receipt = Receipt(
                scope: scope, sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier, trackID: trackID, nativeURL: nil, phase: .reserved,
                creationVersion: 1)
        }
        try write(receipt)
    }

    /// Durable unknown authority MUST precede creation of the OS session/task.
    func beginCreating() throws {
        var receipt = try load()
        guard receipt.phase == .reserved, receipt.creationVersion == 1,
            receipt.taskIdentifier == 0, receipt.nativeURL == nil, receipt.package == nil,
            receipt.retired != true
        else { throw FoundationDownloadError.cleanup }
        receipt.phase = .creating
        try write(receipt)
    }

    /// Adopt only the task returned by our own factory while delegate delivery is gated.
    /// Callback IDs never establish this binding, and existing captured state is never reset.
    func bindCreatedTask(taskIdentifier: Int) throws {
        var receipt = try load()
        guard receipt.phase == .creating, receipt.creationVersion == 1,
            receipt.taskIdentifier == 0, taskIdentifier > 0,
            receipt.nativeURL == nil, receipt.package == nil, receipt.retired != true
        else { throw FoundationDownloadError.cleanup }
        receipt = Receipt(
            scope: receipt.scope, sessionIdentifier: receipt.sessionIdentifier,
            taskIdentifier: taskIdentifier, trackID: receipt.trackID, nativeURL: nil,
            phase: .creating, creationVersion: 1)
        try write(receipt)
    }

    func beginResuming(taskIdentifier: Int) throws {
        var receipt = try load()
        guard receipt.phase == .reserved || receipt.phase == .creating,
            receipt.creationVersion == 1, receipt.taskIdentifier == taskIdentifier,
            taskIdentifier > 0, receipt.retired != true
        else { throw FoundationDownloadError.cleanup }
        receipt.phase = .resuming
        try write(receipt)
    }

    /// Only the original live delegate, observing this task's complete callback sequence,
    /// may record this phase. A cold delegate with no allocation callback has no such proof.
    func recordTerminalNoAllocation(taskIdentifier: Int) throws {
        var receipt = try load()
        guard receipt.taskIdentifier == taskIdentifier, receipt.nativeURL == nil,
            receipt.package == nil, receipt.retired != true,
            receipt.phase == .reserved || receipt.phase == .creating || receipt.phase == .resuming
        else {
            throw FoundationDownloadError.cleanup
        }
        receipt.phase = .terminalNoAllocation
        try write(receipt)
    }

    /// Record only native announcement authority. The destination need not exist yet.
    func announce(
        _ location: URL, taskIdentifier: Int,
        snapshot: (URL) throws -> Data = {
            try $0.bookmarkData(
                options: [],
                includingResourceValuesForKeys: Set(FoundationManagedPackageMetadata.keys),
                relativeTo: nil)
        }, namespaceProof: (URL) -> Bool = { FoundationNativeDownloadPackage.ownsNamespace($0) },
        resources: (URL) throws -> [URLResourceKey: Any] = FoundationManagedPackageMetadata
            .resources,
        embedded: (Data) -> [URLResourceKey: Any]? = {
            NSURL.resourceValues(
                forKeys: FoundationManagedPackageMetadata.keys, fromBookmarkData: $0)
        }
    ) throws {
        #if DEBUG
            var stage = FoundationNativeDownloadErrorFields.CaptureStage.binding
        #endif
        do {
            var receipt = try load()
            guard validSession, taskIdentifier > 0, receipt.taskIdentifier == taskIdentifier,
                receipt.creationVersion == 1, receipt.retired != true,
                FoundationManagedPackageMetadata.plain(location),
                receipt.phase == .creating || receipt.phase == .resuming
                    || receipt.phase == .allocated,
                receipt.nativeURL == nil || receipt.nativeURL == location
            else { throw FoundationDownloadError.cleanup }
            if receipt.nativeURL != nil {
                // Never refresh a previously pinned namespace, even on a duplicate.
                guard receipt.namespaceBookmark != nil else {
                    throw FoundationDownloadError.cleanup
                }
                return
            }
            receipt.nativeURL = location
            receipt.phase = .allocated
            #if DEBUG
                stage = .allocatedWrite
            #endif
            try write(receipt)
            #if DEBUG
                stage = .namespace
            #endif
            guard namespaceProof(location) else { throw FoundationDownloadError.cleanup }
            #if DEBUG
                stage = .parentBookmark
            #endif
            let namespace = location.deletingLastPathComponent()
            let before = try resources(namespace)
            let bookmark = try snapshot(namespace)
            guard let saved = embedded(bookmark) else { throw FoundationDownloadError.cleanup }
            let after = try resources(namespace)
            func stable(_ other: [URLResourceKey: Any]) -> Bool {
                let identity = FoundationManagedPackageMetadata.comparison(before, other)
                return identity.file == .equal && identity.volume == .equal
                    && identity.generation == .equal
            }
            guard before[.isDirectoryKey] as? Bool == true,
                before[.isSymbolicLinkKey] as? Bool == false,
                after[.isDirectoryKey] as? Bool == true,
                after[.isSymbolicLinkKey] as? Bool == false,
                stable(saved), stable(after), namespaceProof(location)
            else { throw FoundationDownloadError.cleanup }
            receipt.namespaceBookmark = bookmark
            try write(receipt)
        } catch {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload") {
                    FoundationJournal.shared.record(
                        FoundationNativeDownloadErrorFields.capture(
                            stage: stage, location: location, writeError: error))
                }
            #endif
            throw FoundationDownloadError.cleanup
        }
    }

    /// Called only by the original live bound delegate's successful task callback.
    /// The first completed identity is created once; cold recovery never calls this.
    func sealAnnouncement(
        _ location: URL, taskIdentifier: Int,
        snapshot: (URL) throws -> Data = {
            try $0.bookmarkData(
                options: [],
                includingResourceValuesForKeys: Set(FoundationManagedPackageMetadata.keys),
                relativeTo: nil)
        }, namespaceProof: (URL) -> Bool = { FoundationNativeDownloadPackage.ownsNamespace($0) },
        resources: (URL) throws -> [URLResourceKey: Any] = FoundationManagedPackageMetadata
            .resources,
        embedded: (Data) -> [URLResourceKey: Any]? = {
            NSURL.resourceValues(
                forKeys: FoundationManagedPackageMetadata.keys, fromBookmarkData: $0)
        }, prove: (FoundationNativeDownloadPackage) -> Bool = { $0.resolveOwnedURL() != nil }
    ) throws {
        typealias Metadata = FoundationManagedPackageMetadata
        #if DEBUG
            var stage = FoundationNativeDownloadErrorFields.CaptureStage.binding
        #endif
        do {
            var receipt = try load()
            guard validSession, receipt.creationVersion == 1, taskIdentifier > 0,
                receipt.taskIdentifier == taskIdentifier, receipt.phase == .allocated,
                receipt.nativeURL == location, Metadata.plain(location), receipt.retired != true,
                receipt.package == nil, receipt.completionAttempted != true,
                let namespaceBookmark = receipt.namespaceBookmark
            else { throw FoundationDownloadError.cleanup }
            // A consumed attempt is durable even if a later proof fails. Never retry a
            // first snapshot from an ambient path or replace a failed/stale snapshot.
            receipt.completionAttempted = true
            #if DEBUG
                stage = .completionClaim
            #endif
            try write(receipt)
            #if DEBUG
                stage = .namespace
            #endif
            // Establish the pinned parent BEFORE any resource read at the target.
            let namespace = location.deletingLastPathComponent()
            guard namespaceProof(location), let savedParent = embedded(namespaceBookmark) else {
                throw FoundationDownloadError.cleanup
            }
            func directory(_ values: [URLResourceKey: Any]) -> Bool {
                values[.isDirectoryKey] as? Bool == true
                    && values[.isSymbolicLinkKey] as? Bool == false
            }
            func same(_ a: [URLResourceKey: Any], _ b: [URLResourceKey: Any], generation: Bool)
                -> Bool
            {
                let result = Metadata.comparison(a, b)
                return result.file == .equal && result.volume == .equal
                    && (!generation || result.generation == .equal)
            }
            let parentBefore = try resources(namespace)
            guard directory(parentBefore), same(savedParent, parentBefore, generation: false) else {
                throw FoundationDownloadError.cleanup
            }
            #if DEBUG
                stage = .packageBookmark
            #endif
            let before = try resources(location)
            guard directory(before) else { throw FoundationDownloadError.cleanup }
            let bookmark = try snapshot(location)
            guard let saved = embedded(bookmark), same(before, saved, generation: true) else {
                throw FoundationDownloadError.cleanup
            }
            let after = try resources(location)
            let parentAfter = try resources(namespace)
            guard directory(after), same(before, after, generation: true),
                directory(parentAfter), same(parentBefore, parentAfter, generation: true),
                namespaceProof(location)
            else { throw FoundationDownloadError.cleanup }
            let package = FoundationNativeDownloadPackage(
                nativeURL: location, bookmark: bookmark, sessionIdentifier: sessionIdentifier,
                namespaceBookmark: namespaceBookmark)
            #if DEBUG
                stage = .ownershipProof
            #endif
            guard prove(package) else { throw FoundationDownloadError.cleanup }
            receipt.package = package
            #if DEBUG
                stage = .packageWrite
            #endif
            try write(receipt)
        } catch {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload") {
                    FoundationJournal.shared.record(
                        FoundationNativeDownloadErrorFields.capture(
                            stage: stage, location: location, writeError: error))
                }
            #endif
            throw FoundationDownloadError.cleanup
        }
    }

    /// The callback doesn't return until its protected authority record is atomically
    /// written and synchronized. Any bookmark/proof/write failure cancels acquisition
    /// and retains the observed receipt/pending session; it never becomes a network error.
    func capture(
        _ location: URL, taskIdentifier: Int,
        snapshot: (URL) throws -> Data = {
            try $0.bookmarkData(
                options: [],
                includingResourceValuesForKeys: Set(FoundationManagedPackageMetadata.keys),
                relativeTo: nil)
        }, prove: (FoundationNativeDownloadPackage) -> Bool = { $0.resolveOwnedURL() != nil },
        namespaceProof: (URL) -> Bool = { FoundationNativeDownloadPackage.ownsNamespace($0) }
    ) throws {
        #if DEBUG
            var stage = FoundationNativeDownloadErrorFields.CaptureStage.initialURL
            var writing: FoundationNativeDownloadErrorFields.PersistenceStage?
            var writeError: Error?
            var binding: FoundationNativeDownloadErrorFields.Binding?
        #endif
        do {
            #if DEBUG
                stage = .initialURL
            #endif
            guard validSession, taskIdentifier > 0, FoundationManagedPackageMetadata.plain(location)
            else {
                #if DEBUG
                    if !validSession {
                        stage = .session
                    } else if taskIdentifier <= 0 {
                        stage = .task
                    }
                #endif
                throw FoundationDownloadError.cleanup
            }
            #if DEBUG
                stage = .existingReceipt
            #endif
            var creationVersion: Int?
            var status = stat()
            let existing = receiptURL.path.withCString { lstat($0, &status) }
            guard existing == 0 || errno == ENOENT else { throw FoundationDownloadError.cleanup }
            if existing == 0 {
                let existing = try load()
                creationVersion = existing.creationVersion
                #if DEBUG
                    stage = .binding
                    binding = .init(
                        taskZero: existing.taskIdentifier == 0,
                        taskMatches: existing.taskIdentifier == taskIdentifier,
                        urlPresent: existing.nativeURL != nil,
                        urlMatches: existing.nativeURL == location,
                        retired: existing.retired == true, phase: existing.phase)
                #endif
                guard existing.taskIdentifier == taskIdentifier,
                    existing.nativeURL == nil || existing.nativeURL == location
                else {
                    throw FoundationDownloadError.cleanup
                }
                guard existing.retired != true, existing.phase != .terminalNoAllocation else {
                    throw FoundationDownloadError.cleanup
                }
                if existing.package != nil { return }  // Never replace a pinned resource snapshot.
                guard existing.completionAttempted != true else {
                    throw FoundationDownloadError.cleanup
                }
            }
            var receipt = Receipt(
                scope: scope, sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier, trackID: trackID, nativeURL: location,
                phase: .allocated, creationVersion: creationVersion
            )
            #if DEBUG
                stage = .allocatedWrite
                writing = .allocatedWrite
            #endif
            try write(receipt)  // Preserve callback authority BEFORE any fallible bookmark call.
            #if DEBUG
                writing = nil
            #endif
            do {
                #if DEBUG
                    stage = .namespace
                #endif
                guard namespaceProof(location) else { throw FoundationDownloadError.cleanup }
                #if DEBUG
                    stage = .parentBookmark
                #endif
                receipt.namespaceBookmark = try snapshot(location.deletingLastPathComponent())
                #if DEBUG
                    writing = .parentBookmark
                #endif
                try write(receipt)
                #if DEBUG
                    writing = nil
                    stage = .packageBookmark
                #endif
                let bookmark = try snapshot(location)
                let package = FoundationNativeDownloadPackage(
                    nativeURL: location, bookmark: bookmark,
                    sessionIdentifier: sessionIdentifier,
                    namespaceBookmark: receipt.namespaceBookmark)
                #if DEBUG
                    stage = .ownershipProof
                #endif
                guard prove(package) else { throw FoundationDownloadError.cleanup }
                receipt.package = package
                #if DEBUG
                    stage = .packageWrite
                    writing = .packageWrite
                #endif
                try write(receipt)
                #if DEBUG
                    writing = nil
                #endif
            } catch {
                #if DEBUG
                    // Keep the original bookmark error before cleanup remapping.
                    if writing != nil || stage == .parentBookmark || stage == .packageBookmark {
                        writeError = error
                    }
                #endif
                throw FoundationDownloadError.cleanup
            }
        } catch {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload") {
                    FoundationJournal.shared.record(
                        FoundationNativeDownloadErrorFields.capture(
                            stage: stage, location: location,
                            writeError: writeError ?? (writing != nil ? error : nil),
                            binding: stage == .binding ? binding : nil))
                }
            #endif
            throw error
        }
    }

    /// Parse only this app's fixed identifier grammar. The returned directory
    /// scope is not account authorization and the original identifier is unchanged.
    static func directoryScope(forSessionIdentifier identifier: String) -> String? {
        let prefix = "dev.novoluxor.velacanto.offline."
        guard identifier.hasPrefix(prefix), identifier.utf8.count == prefix.utf8.count + 64 + 1 + 36
        else {
            return nil
        }
        let suffix = identifier.dropFirst(prefix.count)
        let scope = String(suffix.prefix(64))
        let token = suffix.dropFirst(65)
        guard scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
            suffix.dropFirst(64).first == ".", UUID(uuidString: String(token)) != nil
        else { return nil }
        return scope
    }

    var validSession: Bool {
        let prefix = "dev.novoluxor.velacanto.offline." + scope + "."
        return sessionIdentifier.hasPrefix(prefix)
            && UUID(uuidString: String(sessionIdentifier.dropFirst(prefix.count))) != nil
    }

    func load() throws -> Receipt {
        guard validSession else { throw FoundationDownloadError.cleanup }
        let values = try receiptURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= 1_048_576
        else { throw FoundationDownloadError.cleanup }
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
        guard receipt.scope == scope, receipt.sessionIdentifier == sessionIdentifier,
            receipt.taskIdentifier >= 0,
            receipt.nativeURL.map(FoundationManagedPackageMetadata.plain)
                ?? ([Receipt.Phase.reserved, .creating, .resuming, .terminalNoAllocation].contains(
                    receipt.phase ?? .allocated)),
            receipt.package == nil
                || (receipt.package?.sessionIdentifier == sessionIdentifier
                    && receipt.package?.nativeURL == receipt.nativeURL)
        else { throw FoundationDownloadError.cleanup }
        if receipt.completionAttempted == true {
            guard receipt.phase == .allocated, receipt.creationVersion == 1,
                receipt.nativeURL != nil, receipt.namespaceBookmark != nil
            else { throw FoundationDownloadError.cleanup }
        }
        if receipt.phase == .creating {
            guard receipt.creationVersion == 1, receipt.nativeURL == nil, receipt.package == nil
            else { throw FoundationDownloadError.cleanup }
        }
        if receipt.phase == .resuming || receipt.phase == .terminalNoAllocation {
            guard receipt.taskIdentifier > 0, receipt.nativeURL == nil, receipt.package == nil
            else {
                throw FoundationDownloadError.cleanup
            }
        }
        if receipt.nativeURL != nil {
            guard receipt.taskIdentifier > 0, receipt.phase == nil || receipt.phase == .allocated
            else {
                throw FoundationDownloadError.cleanup
            }
        }
        return receipt
    }

    static func existingReceipt(at url: URL, directory: URL) throws -> Self {
        // Private receipt metadata may have multiple URL representations. Bind the
        // enumerated file to the computed account/session/hash location by identity,
        // not a URL spelling. This never rewrites or canonicalizes a native package URL.
        func snapshot(_ location: URL, directory: Bool) throws -> [URLResourceKey: Any] {
            guard FoundationManagedPackageMetadata.plain(location) else {
                throw FoundationDownloadError.cleanup
            }
            let fresh = NSURL(fileURLWithPath: location.path)
            fresh.removeAllCachedResourceValues()
            let values = try fresh.resourceValues(forKeys: [
                .fileResourceIdentifierKey, .volumeIdentifierKey, .isRegularFileKey,
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values[.isSymbolicLinkKey] as? Bool == false else {
                throw FoundationDownloadError.cleanup
            }
            if directory {
                guard values[.isDirectoryKey] as? Bool == true else {
                    throw FoundationDownloadError.cleanup
                }
            } else {
                guard values[.isRegularFileKey] as? Bool == true,
                    let size = values[.fileSizeKey] as? Int, (0...1_048_576).contains(size)
                else {
                    throw FoundationDownloadError.cleanup
                }
            }
            return values
        }
        func same(_ first: [URLResourceKey: Any], _ second: [URLResourceKey: Any]) -> Bool {
            let identity = FoundationManagedPackageMetadata.comparison(first, second)
            return identity.file == .equal && identity.volume == .equal
        }
        let enumerated = try snapshot(url, directory: false)
        let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        let store = Self(directory: directory, sessionIdentifier: receipt.sessionIdentifier)
        guard store.validSession, url.lastPathComponent == store.receiptURL.lastPathComponent else {
            throw FoundationDownloadError.cleanup
        }
        let expected = try snapshot(store.receiptURL, directory: false)
        let account = try snapshot(directory, directory: true)
        let enumeratedParent = try snapshot(url.deletingLastPathComponent(), directory: true)
        guard same(enumerated, expected), same(account, enumeratedParent) else {
            throw FoundationDownloadError.cleanup
        }
        _ = try store.load()  // Scope/session/task/phase/content validation at computed location.
        let expectedRepeat = try snapshot(store.receiptURL, directory: false)
        let enumeratedRepeat = try snapshot(url, directory: false)
        let accountRepeat = try snapshot(directory, directory: true)
        let parentRepeat = try snapshot(url.deletingLastPathComponent(), directory: true)
        guard same(expected, expectedRepeat), same(enumerated, enumeratedRepeat),
            same(expectedRepeat, enumeratedRepeat), same(account, accountRepeat),
            same(enumeratedParent, parentRepeat), same(accountRepeat, parentRepeat)
        else {
            throw FoundationDownloadError.cleanup
        }
        return store
    }

    private static func coldPackageDigest(_ package: FoundationNativeDownloadPackage) throws -> Data
    {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(package)))
    }

    private func coldProofMatches(
        _ proof: Receipt.ColdSignOutProof, receipt: Receipt, operation: UUID,
        expectedTrackID: String, expectedPackage: FoundationNativeDownloadPackage
    ) throws -> Bool {
        guard proof.version == 1, proof.operation == operation, proof.scope == scope,
            proof.sessionIdentifier == sessionIdentifier,
            proof.taskIdentifier == receipt.taskIdentifier,
            proof.trackID == expectedTrackID, receipt.trackID == expectedTrackID,
            receipt.phase == .allocated, receipt.isRetirementEligible,
            receipt.completionAttempted == true,
            let package = receipt.package,
            package.sessionIdentifier == expectedPackage.sessionIdentifier,
            package.nativeURL == expectedPackage.nativeURL,
            package.bookmark == expectedPackage.bookmark,
            package.namespaceBookmark == expectedPackage.namespaceBookmark
        else { return false }
        return proof.packageDigest == (try Self.coldPackageDigest(package))
    }

    func recordColdFinality(
        operation: UUID, expectedTrackID: String, expectedPackage: FoundationNativeDownloadPackage
    ) throws {
        var receipt = try load()
        guard receipt.phase == .allocated, receipt.isRetirementEligible,
            receipt.completionAttempted == true, receipt.trackID == expectedTrackID,
            let package = receipt.package,
            package.sessionIdentifier == expectedPackage.sessionIdentifier,
            package.nativeURL == expectedPackage.nativeURL,
            package.bookmark == expectedPackage.bookmark,
            package.namespaceBookmark == expectedPackage.namespaceBookmark
        else { throw FoundationDownloadError.cleanup }
        let proof = Receipt.ColdSignOutProof(
            version: 1, operation: operation, scope: scope, sessionIdentifier: sessionIdentifier,
            taskIdentifier: receipt.taskIdentifier, trackID: expectedTrackID,
            packageDigest: try Self.coldPackageDigest(package), manifestRemovalAuthorized: false)
        if let existing = receipt.coldSignOutProof, existing != proof {
            guard existing.version == proof.version, existing.operation == proof.operation,
                existing.scope == proof.scope,
                existing.sessionIdentifier == proof.sessionIdentifier,
                existing.taskIdentifier == proof.taskIdentifier, existing.trackID == proof.trackID,
                existing.packageDigest == proof.packageDigest
            else { throw FoundationDownloadError.cleanup }
            return
        }
        receipt.coldSignOutProof = proof
        try write(receipt)
        guard try load().coldSignOutProof == proof else { throw FoundationDownloadError.cleanup }
    }

    func coldFinalityMatches(
        operation: UUID, expectedTrackID: String, expectedPackage: FoundationNativeDownloadPackage,
        requireManifestAuthorization: Bool = false
    ) throws -> Bool {
        let receipt = try load()
        guard let proof = receipt.coldSignOutProof,
            !requireManifestAuthorization || proof.manifestRemovalAuthorized
        else { return false }
        return try coldProofMatches(
            proof, receipt: receipt, operation: operation,
            expectedTrackID: expectedTrackID, expectedPackage: expectedPackage)
    }

    /// The caller must first validate the exact entry in a descriptor-pinned manifest.
    fileprivate func authorizeColdManifestRemoval(
        operation: UUID, expectedTrackID: String, expectedPackage: FoundationNativeDownloadPackage
    ) throws {
        var receipt = try load()
        guard receipt.hasProvenRetirement, var proof = receipt.coldSignOutProof,
            try coldProofMatches(
                proof, receipt: receipt, operation: operation,
                expectedTrackID: expectedTrackID, expectedPackage: expectedPackage)
        else { throw FoundationDownloadError.cleanup }
        if proof.manifestRemovalAuthorized { return }
        proof.manifestRemovalAuthorized = true
        receipt.coldSignOutProof = proof
        try write(receipt)
        guard try load().coldSignOutProof == proof else { throw FoundationDownloadError.cleanup }
    }

    private func coldTerminalProofMatches(
        _ proof: Receipt.ColdSignOutProof, receipt: Receipt, operation: UUID
    ) -> Bool {
        proof.version == 2 && proof.operation == operation && proof.scope == scope
            && proof.sessionIdentifier == sessionIdentifier
            && proof.taskIdentifier == receipt.taskIdentifier
            && proof.trackID == (receipt.trackID ?? "") && proof.packageDigest.isEmpty
            && receipt.phase == .terminalNoAllocation && receipt.creationVersion == 1
            && receipt.taskIdentifier > 0 && receipt.nativeURL == nil && receipt.package == nil
            && receipt.namespaceBookmark == nil && receipt.completionAttempted != true
    }

    func recordColdTerminalFinality(operation: UUID) throws {
        var receipt = try load()
        let proof = Receipt.ColdSignOutProof(
            version: 2, operation: operation, scope: scope,
            sessionIdentifier: sessionIdentifier, taskIdentifier: receipt.taskIdentifier,
            trackID: receipt.trackID ?? "", packageDigest: Data(), manifestRemovalAuthorized: false)
        guard coldTerminalProofMatches(proof, receipt: receipt, operation: operation)
        else { throw FoundationDownloadError.cleanup }
        if let existing = receipt.coldSignOutProof {
            guard coldTerminalProofMatches(existing, receipt: receipt, operation: operation)
            else { throw FoundationDownloadError.cleanup }
            return
        }
        receipt.coldSignOutProof = proof
        try write(receipt)
        guard try load().coldSignOutProof == proof else { throw FoundationDownloadError.cleanup }
    }

    func coldTerminalFinalityMatches(operation: UUID, requireManifestAuthorization: Bool = false)
        throws -> Bool
    {
        let receipt = try load()
        guard let proof = receipt.coldSignOutProof,
            !requireManifestAuthorization || proof.manifestRemovalAuthorized
        else { return false }
        return coldTerminalProofMatches(proof, receipt: receipt, operation: operation)
    }

    /// Caller must hold the scoped operation and validate the existing manifest first.
    fileprivate func authorizeColdTerminalManifestRemoval(operation: UUID) throws {
        var receipt = try load()
        guard receipt.hasProvenRetirement, var proof = receipt.coldSignOutProof,
            coldTerminalProofMatches(proof, receipt: receipt, operation: operation)
        else { throw FoundationDownloadError.cleanup }
        if proof.manifestRemovalAuthorized { return }
        proof.manifestRemovalAuthorized = true
        receipt.coldSignOutProof = proof
        try write(receipt)
        guard try load().coldSignOutProof == proof else { throw FoundationDownloadError.cleanup }
    }

    func completedPackage(taskIdentifier: Int) throws -> FoundationNativeDownloadPackage {
        let receipt = try load()
        guard receipt.taskIdentifier == taskIdentifier, receipt.retired != true,
            let package = receipt.package
        else {
            throw FoundationDownloadError.cleanup
        }
        return package
    }

    /// Absence of a pending receipt is not absence of an OS allocation.
    func retire(
        resolve: (FoundationNativeDownloadPackage) -> FoundationNativeDownloadPackage.Resolution = {
            $0.resolution()
        },
        remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
        var receipt = try load()
        // Ambiguous legacy allocations are retained before any resolution or deletion.
        guard receipt.isRetirementEligible else { throw FoundationDownloadError.cleanup }
        if receipt.nativeURL == nil {
            // Check the proof before trusting a legacy tombstone. An older reserved
            // receipt (even retired) may have issued a factory without recording it.
            guard
                (receipt.phase == .reserved && receipt.creationVersion == 1)
                    || receipt.phase == .terminalNoAllocation
            else {
                throw FoundationDownloadError.cleanup
            }
            if receipt.retired == true {
                guard receipt.hasProvenRetirement else { throw FoundationDownloadError.cleanup }
                return
            }
            receipt.retired = true
            try write(receipt)
            return
        }
        if receipt.retired == true {
            guard receipt.hasProvenRetirement else { throw FoundationDownloadError.cleanup }
            return
        }
        guard let nativeURL = receipt.nativeURL else { throw FoundationDownloadError.cleanup }
        let package =
            receipt.package
            ?? FoundationNativeDownloadPackage(
                nativeURL: nativeURL,
                bookmark: Data(), sessionIdentifier: sessionIdentifier,
                namespaceBookmark: receipt.namespaceBookmark)
        switch resolve(package) {
        case .available(let url): try remove(url)
        case .provenMissing: break
        case .unverifiable: throw FoundationDownloadError.cleanup
        }
        // Retain a durable tombstone until the account manifest no longer needs the
        // receipt. A crash between package deletion and manifest publication is safe.
        receipt.retired = true
        try write(receipt)
    }

    private func write(_ receipt: Receipt) throws {
        let data = try JSONEncoder().encode(receipt)
        guard data.count <= 1_048_576 else { throw FoundationDownloadError.cleanup }
        let stage = directory.appendingPathComponent("stage-native-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        #if os(iOS)
            try data.write(
                to: stage, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try data.write(to: stage, options: .atomic)
        #endif
        try FoundationDownloadStorage.protect(stage)
        let file = try FileHandle(forWritingTo: stage)
        defer { try? file.close() }
        try file.synchronize()
        guard
            stage.path.withCString({ source in
                receiptURL.path.withCString { Darwin.rename(source, $0) }
            }) == 0
        else {
            throw FoundationDownloadError.cleanup
        }
        let descriptor = directory.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else { throw FoundationDownloadError.cleanup }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw FoundationDownloadError.cleanup }
    }
}
