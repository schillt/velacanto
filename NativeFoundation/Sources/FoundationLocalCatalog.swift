import CryptoKit
import Darwin
import Foundation

/// Read-only local records are independent of server sessions and downloads.
struct FoundationLocalCatalog: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case ready, empty, partial, unavailable, corrupt }
    struct Record: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let relativePath: String
        let title: String
        let byteCount: Int64
        let modified: Date
        var missing: Bool
    }
    let version: Int
    let sourceID: UUID
    let state: State
    let records: [Record]

    var isReadOnly: Bool { true }

    init(sourceID: UUID, state: State, records: [Record] = []) {
        version = 1
        self.sourceID = sourceID
        self.state = state
        self.records = records
    }

    var isValid: Bool {
        version == 1 && records.count <= FoundationLocalCatalogIndex.recordLimit
            && Set(records.map(\.id)).count == records.count
            && records.allSatisfy {
                $0.id.hasPrefix(sourceID.uuidString + ":")
                    && $0.id.utf8.count == sourceID.uuidString.utf8.count + 65
                    && $0.id.suffix(64).allSatisfy { $0.isHexDigit && !$0.isUppercase }
                    && Self.safeRelativePath($0.relativePath)
                    && $0.relativePath.utf8.count <= 4096 && $0.title.utf8.count <= 4096
                    && $0.byteCount >= 0 && $0.modified.timeIntervalSince1970.isFinite
            }
    }

    static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

/// Synchronous filesystem work belongs on this actor, never the UI/player owner.
/// The caller supplies an explicitly selected, currently authorized root.
actor FoundationLocalCatalogIndex {
    static let recordLimit = 10_000
    static let inspectionLimit = 25_000
    static let byteLimit = 8 * 1024 * 1024
    private let storage: URL
    private let files: FileManager

    init(storage: URL, files: FileManager = .default) {
        self.storage = storage
        self.files = files
    }

    func restore(sourceID: UUID) -> FoundationLocalCatalog {
        let file = indexURL(sourceID)
        guard files.fileExists(atPath: file.path) else {
            return .init(sourceID: sourceID, state: .empty)
        }
        do {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true, let size = values.fileSize,
                size <= Self.byteLimit
            else { return .init(sourceID: sourceID, state: .corrupt) }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
            guard data.count <= Self.byteLimit else {
                return .init(sourceID: sourceID, state: .corrupt)
            }
            let catalog = try JSONDecoder().decode(FoundationLocalCatalog.self, from: data)
            guard catalog.sourceID == sourceID, catalog.isValid else {
                return .init(sourceID: sourceID, state: .corrupt)
            }
            return catalog
        } catch {
            return .init(sourceID: sourceID, state: .corrupt)
        }
    }

    /// Refresh never writes a music file or follows a symbolic link. Incomplete
    /// enumeration preserves prior availability instead of falsely deleting tracks.
    func refresh(
        sourceID: UUID, authorizedRoot root: URL,
        inspectionLimit: Int = FoundationLocalCatalogIndex.inspectionLimit
    ) throws -> FoundationLocalCatalog {
        try Task.checkCancellation()
        guard root.isFileURL, storage.isFileURL else { throw Failure.invalidRoot }
        let root = root.standardizedFileURL
        guard root.isFileURL,
            Self.storageIsOutsideRoot(storage, root: root),
            inspectionLimit > 0,
            inspectionLimit <= Self.inspectionLimit
        else { throw Failure.invalidRoot }
        let previous = restore(sourceID: sourceID)
        let rootValues = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues?.isDirectory == true, rootValues?.isSymbolicLink != true else {
            return .init(sourceID: sourceID, state: .unavailable, records: previous.records)
        }
        var incomplete = false
        guard
            let enumerator = files.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in
                    incomplete = true
                    return true
                })
        else { return .init(sourceID: sourceID, state: .unavailable, records: previous.records) }
        var inspected = 0
        var found: [String: FoundationLocalCatalog.Record] = [:]
        let rootComponents = root.pathComponents
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard inspected < inspectionLimit else {
                incomplete = true
                break
            }
            inspected += 1
            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count,
                Array(components.prefix(rootComponents.count)) == rootComponents
            else {
                incomplete = true
                enumerator.skipDescendants()
                continue
            }
            do {
                let values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true,
                    Self.audioExtensions.contains(url.pathExtension.lowercased())
                else { continue }
                let path = components.dropFirst(rootComponents.count).joined(separator: "/")
                guard FoundationLocalCatalog.safeRelativePath(path), path.utf8.count <= 4096 else {
                    incomplete = true
                    continue
                }
                let resolved = url.resolvingSymlinksInPath().pathComponents
                let resolvedRoot = root.resolvingSymlinksInPath().pathComponents
                guard resolved.count > resolvedRoot.count, resolved.starts(with: resolvedRoot)
                else {
                    incomplete = true
                    continue
                }
                let attributes = try files.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    incomplete = true
                    continue
                }
                guard let volume = attributes[.systemNumber] as? NSNumber,
                    let inode = attributes[.systemFileNumber] as? NSNumber,
                    let created = attributes[.creationDate] as? Date,
                    let modified = attributes[.modificationDate] as? Date,
                    let size = attributes[.size] as? NSNumber
                else {
                    incomplete = true
                    continue
                }
                let identity =
                    "\(volume.uint64Value):\(inode.uint64Value):\(created.timeIntervalSince1970)"
                let digest = SHA256.hash(data: Data(identity.utf8)).map {
                    String(format: "%02x", $0)
                }.joined()
                let id = sourceID.uuidString + ":" + digest
                let title = url.deletingPathExtension().lastPathComponent
                guard title.utf8.count <= 4096, size.int64Value >= 0 else {
                    incomplete = true
                    continue
                }
                let record = FoundationLocalCatalog.Record(
                    id: id, relativePath: path, title: title, byteCount: size.int64Value,
                    modified: modified, missing: false)
                if let existing = found[id], existing.relativePath < path { continue }
                found[id] = record
                if found.count == Self.recordLimit {
                    incomplete = true
                    break
                }
            } catch {
                incomplete = true
            }
        }
        try Task.checkCancellation()
        let previousIDs = Set(previous.records.map(\.id))
        let additions = found.values.filter { !previousIDs.contains($0.id) }.sorted {
            $0.id < $1.id
        }
        if previous.records.count + additions.count > Self.recordLimit { incomplete = true }
        // A bounded publication never evicts an old occurrence to make space for
        // a newly observed one. Existing records update in place; excess additions
        // remain unindexed and the source explicitly reports a partial result.
        var merged = previous.records.map { old in
            if let current = found[old.id] { return current }
            var retained = old
            if !incomplete { retained.missing = true }
            return retained
        }
        merged.append(contentsOf: additions.prefix(Self.recordLimit - merged.count))
        let records = merged.sorted { $0.id < $1.id }
        let result = FoundationLocalCatalog(
            sourceID: sourceID,
            state: incomplete
                ? .partial : records.contains(where: { !$0.missing }) ? .ready : .empty,
            records: records)
        guard result.isValid else { throw Failure.invalidIndex }
        try save(result, authorizedRoot: root)
        return result
    }

    /// Resolve existing ancestors before checking containment, including when the
    /// final index directory does not yet exist. Recheck at the write boundary;
    /// this does not claim descriptor-relative protection against concurrent swaps.
    static func storageIsOutsideRoot(_ storage: URL, root: URL) -> Bool {
        guard storage.isFileURL, root.isFileURL else { return false }
        guard let destination = canonicalPotentialDirectory(storage),
            let source = canonicalPotentialDirectory(root)
        else { return false }
        guard !destination.pathComponents.starts(with: source.pathComponents) else { return false }
        // Resource identity catches equivalent case-insensitive directory spellings
        // even when canonical URL strings retain a different spelling.
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return true }
        guard let attributes = try? manager.attributesOfItem(atPath: source.path),
            let volume = attributes[.systemNumber] as? NSNumber,
            let inode = attributes[.systemFileNumber] as? NSNumber
        else { return false }
        let components = destination.pathComponents
        // Foundation directory URLs can turn the parent of "/" into "/.."
        // instead of a fixed point. The finite prefix count is the termination
        // proof; no URL parent operation participates in this traversal.
        for count in stride(from: components.count, through: 1, by: -1) {
            let path = NSString.path(withComponents: Array(components.prefix(count)))
            if let values = try? manager.attributesOfItem(atPath: path),
                values[.systemNumber] as? NSNumber == volume,
                values[.systemFileNumber] as? NSNumber == inode
            {
                return false
            }
        }
        return true
    }

    /// Resolve the nearest existing ancestor first. Resolving an entire URL with
    /// a missing final component can leave an existing symlink ancestor unresolved.
    /// lstat detects dangling links instead of treating them as missing directories.
    private static func canonicalPotentialDirectory(_ url: URL) -> URL? {
        let components = url.standardizedFileURL.pathComponents
        guard components.first == "/" else { return nil }
        for count in stride(from: components.count, through: 1, by: -1) {
            let path = NSString.path(withComponents: Array(components.prefix(count)))
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT else { return nil }
                continue
            }
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            let resolvedPath = String(cString: resolved)
            var target = stat()
            guard stat(resolvedPath, &target) == 0,
                target.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            else { return nil }
            var canonical = URL(fileURLWithPath: resolvedPath, isDirectory: true)
            for component in components.dropFirst(count) {
                canonical.appendPathComponent(component, isDirectory: true)
            }
            return canonical
        }
        return nil
    }

    private func save(_ catalog: FoundationLocalCatalog, authorizedRoot root: URL) throws {
        guard Self.storageIsOutsideRoot(storage, root: root) else { throw Failure.invalidRoot }
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= Self.byteLimit else { throw Failure.limit }
        if files.fileExists(atPath: storage.path) {
            let values = try storage.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw Failure.invalidRoot
            }
        }
        try files.createDirectory(at: storage, withIntermediateDirectories: true)
        guard Self.storageIsOutsideRoot(storage, root: root) else { throw Failure.invalidRoot }
        try data.write(to: indexURL(catalog.sourceID), options: [.atomic, .completeFileProtection])
    }

    private func indexURL(_ sourceID: UUID) -> URL {
        storage.appendingPathComponent(sourceID.uuidString).appendingPathExtension("json")
    }

    enum Failure: Error { case invalidRoot, invalidIndex, limit }
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "caf", "alac", "ogg", "opus",
    ]
}

/// Bookmark selection/persistence belongs to a future user-selected source owner,
/// separate from Jellyfin account cleanup. Never fall back to an unscoped path.
enum FoundationLocalFolderAccess {
    static func bookmark(for selectedFolder: URL) throws -> Data {
        #if os(macOS)
            try selectedFolder.bookmarkData(options: [
                .withSecurityScope, .securityScopeAllowOnlyReadAccess,
            ])
        #else
            try selectedFolder.bookmarkData(options: .minimalBookmark)
        #endif
    }

    static func withAccess<T: Sendable>(
        to bookmark: Data, operation: @Sendable (URL) async throws -> T
    ) async throws -> T {
        var stale = false
        #if os(macOS)
            let root = try URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope,
                bookmarkDataIsStale: &stale)
        #else
            let root = try URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale)
        #endif
        guard !stale, root.startAccessingSecurityScopedResource() else {
            throw AccessFailure.unavailable
        }
        defer { root.stopAccessingSecurityScopedResource() }
        return try await operation(root)
    }

    enum AccessFailure: Error { case unavailable }
}
