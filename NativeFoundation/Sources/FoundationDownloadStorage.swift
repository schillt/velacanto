import AVFoundation
import CryptoKit
import Darwin
import Foundation

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
        var manifest = try JSONDecoder().decode(
            FoundationDownloadManifest.self, from: Data(contentsOf: manifestURL))
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
            case reserved, resuming, allocated, terminalNoAllocation
        }
        var phase: Phase? = nil
        var namespaceBookmark: Data?
        var package: FoundationNativeDownloadPackage?
        var retired: Bool? = nil
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

    /// Persisted before task creation/resume. A reserved receipt proves this code has
    /// not issued resume; resuming is written BEFORE resume and is unknown after loss.
    func reserve(taskIdentifier: Int = 0) throws {
        guard validSession, taskIdentifier >= 0 else { throw FoundationDownloadError.cleanup }
        var receipt: Receipt
        var status = stat()
        let found = receiptURL.path.withCString { lstat($0, &status) }
        if found == 0 {
            receipt = try load()
            guard receipt.phase == .reserved, receipt.retired != true,
                receipt.taskIdentifier == 0 || receipt.taskIdentifier == taskIdentifier
            else {
                throw FoundationDownloadError.cleanup
            }
            receipt = Receipt(
                scope: scope, sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier, trackID: trackID ?? receipt.trackID, nativeURL: nil,
                phase: .reserved)
        } else {
            guard errno == ENOENT else { throw FoundationDownloadError.cleanup }
            receipt = Receipt(
                scope: scope, sessionIdentifier: sessionIdentifier,
                taskIdentifier: taskIdentifier, trackID: trackID, nativeURL: nil, phase: .reserved)
        }
        try write(receipt)
    }

    func beginResuming(taskIdentifier: Int) throws {
        var receipt = try load()
        guard receipt.phase == .reserved, receipt.taskIdentifier == taskIdentifier,
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
            receipt.phase == .reserved || receipt.phase == .resuming
        else {
            throw FoundationDownloadError.cleanup
        }
        receipt.phase = .terminalNoAllocation
        try write(receipt)
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
        guard validSession, taskIdentifier > 0, FoundationManagedPackageMetadata.plain(location)
        else {
            throw FoundationDownloadError.cleanup
        }
        var status = stat()
        let existing = receiptURL.path.withCString { lstat($0, &status) }
        guard existing == 0 || errno == ENOENT else { throw FoundationDownloadError.cleanup }
        if existing == 0 {
            let existing = try load()
            guard existing.taskIdentifier == taskIdentifier,
                existing.nativeURL == nil || existing.nativeURL == location
            else {
                throw FoundationDownloadError.cleanup
            }
            guard existing.retired != true, existing.phase != .terminalNoAllocation else {
                throw FoundationDownloadError.cleanup
            }
            if existing.package != nil { return }  // Never replace a pinned resource snapshot.
        }
        var receipt = Receipt(
            scope: scope, sessionIdentifier: sessionIdentifier,
            taskIdentifier: taskIdentifier, trackID: trackID, nativeURL: location, phase: .allocated
        )
        try write(receipt)  // Preserve callback authority BEFORE any fallible bookmark call.
        do {
            guard namespaceProof(location) else { throw FoundationDownloadError.cleanup }
            receipt.namespaceBookmark = try snapshot(location.deletingLastPathComponent())
            try write(receipt)
            let bookmark = try snapshot(location)
            let package = FoundationNativeDownloadPackage(
                nativeURL: location, bookmark: bookmark,
                sessionIdentifier: sessionIdentifier, namespaceBookmark: receipt.namespaceBookmark)
            guard prove(package) else { throw FoundationDownloadError.cleanup }
            receipt.package = package
            try write(receipt)
        } catch { throw FoundationDownloadError.cleanup }
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
                ?? ([Receipt.Phase.reserved, .resuming, .terminalNoAllocation].contains(
                    receipt.phase ?? .allocated)),
            receipt.package == nil
                || (receipt.package?.sessionIdentifier == sessionIdentifier
                    && receipt.package?.nativeURL == receipt.nativeURL)
        else { throw FoundationDownloadError.cleanup }
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
        if receipt.retired == true { return }
        if receipt.nativeURL == nil {
            guard receipt.phase == .reserved || receipt.phase == .terminalNoAllocation else {
                throw FoundationDownloadError.cleanup
            }
            receipt.retired = true
            try write(receipt)
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
