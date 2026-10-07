import CryptoKit
import Darwin
import Foundation

/// Private, recoverable download metadata. Requests and credentials never enter this representation.
nonisolated struct FoundationStoredDownloadItem: Codable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let kind: String
    let duration: Double?
    let artworkTag: String?
    let albumID: String?
    let albumTitle: String?
    let albumTag: String?

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
        albumTag = item.album?.primaryImageTag
    }

    var item: FoundationItem {
        var result = FoundationItem(
            id: id, title: title, subtitle: subtitle,
            kind: kind == "album" ? .album : kind == "playlist" ? .playlist : .track,
            duration: duration, primaryImageTag: artworkTag)
        if let albumID, let albumTitle {
            result.album = FoundationItemReference(
                id: albumID, title: albumTitle, primaryImageTag: albumTag)
        }
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
    }
    struct File: Codable, Sendable {
        let name: String
        let bytes: Int64
        let digest: String
    }
    struct Artwork: Codable, Sendable {
        let item: FoundationStoredDownloadItem
        let file: File
    }
    var artwork: [String: Artwork]? = nil
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
        let data = try JSONEncoder().encode(manifest)
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
        guard (1...2).contains(manifest.version), manifest.owners.count <= 10_000,
            (manifest.excludedTrackIDs?.count ?? 0) <= 100_000,
            (manifest.artwork?.count ?? 0) <= 100_000,
            Set(manifest.owners.map(\.id)).count == manifest.owners.count,
            manifest.owners.allSatisfy({ $0.tracks.count <= 10_000 })
        else { throw CocoaError(.fileReadCorruptFile) }
        manifest.version = 2
        return manifest
    }
}
