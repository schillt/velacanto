import Foundation
import os

enum JellyfinCatalogKind: String, Codable, Sendable {
    case albums
    case artists
    case songs
    case playlists
    case search
    case albumTracks
    case playlistTracks
}

struct JellyfinCatalogCursor: Sendable {
    let identity: String
    var offsets: [String: Int]
    var totals: [String: Int]
    var buffers: [String: [JellyfinItem]]
    var exhaustedSources: Set<String>
    var seenItemIDs: Set<String>
}

struct JellyfinCatalogPage: Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int
    let cursor: JellyfinCatalogCursor?

    var hasMore: Bool {
        cursor != nil
    }
}

/// Fetches and merges catalog pages for one authenticated Jellyfin account.
///
/// A repository is a short-lived snapshot of the current session and libraries.
/// Its cursor is valid only for the query identity recorded in the cursor; callers
/// must discard it when the query, context, or library list changes.
actor JellyfinCatalogRepository {
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )

    private let api: any JellyfinAPIService
    private let userID: String
    private let libraryIDs: [String]

    init(
        api: any JellyfinAPIService,
        userID: String,
        libraryIDs: [String]
    ) {
        self.api = api
        self.userID = userID
        self.libraryIDs = libraryIDs
    }

    // MARK: - Catalog reads

    func albums(in library: JellyfinItem) async throws -> [JellyfinItem] {
        try await api.albums(userID: userID, libraryID: library.id)
    }

    func libraries() async throws -> [JellyfinItem] {
        try await api.libraries(userID: userID)
    }

    func musicAlbums(for artist: JellyfinItem?) async throws -> [JellyfinItem] {
        var results: [JellyfinItem] = []
        for libraryID in libraryIDs {
            if let artist {
                results += try await api.albums(
                    userID: userID,
                    libraryID: libraryID,
                    artistID: artist.id
                )
            } else {
                results += try await api.albums(
                    userID: userID,
                    libraryID: libraryID
                )
            }
        }
        return uniqueAndSorted(results)
    }

    func musicArtists() async throws -> [JellyfinItem] {
        var results: [JellyfinItem] = []
        for libraryID in libraryIDs {
            results += try await api.artists(userID: userID, libraryID: libraryID)
        }
        return uniqueAndSorted(results)
    }

    func musicSongs() async throws -> [JellyfinItem] {
        var results: [JellyfinItem] = []
        for libraryID in libraryIDs {
            results += try await api.songs(userID: userID, libraryID: libraryID)
        }
        return uniqueAndSorted(results)
    }

    func musicPlaylists() async throws -> [JellyfinItem] {
        uniqueAndSorted(try await api.playlists(userID: userID))
    }

    func searchMusic(query: String) async throws -> [JellyfinItem] {
        try await api.searchMusic(userID: userID, query: query, limit: 60)
    }

    func tracks(inPlaylist playlist: JellyfinItem) async throws -> [JellyfinItem] {
        try await api.playlistItems(userID: userID, playlistID: playlist.id)
    }

    func tracks(in album: JellyfinItem) async throws -> [JellyfinItem] {
        try await api.tracks(userID: userID, albumID: album.id)
    }

    // MARK: - Artwork reads

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URL {
        try await api.artworkURL(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
        try await api.artworkRequest(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func userImageURL(
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URL {
        try await api.userImageURL(
            userID: userID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func userImageRequest(
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
        try await api.userImageRequest(
            userID: userID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    // MARK: - Paging

    func page(
        kind: JellyfinCatalogKind,
        contextID: String? = nil,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        switch kind {
        case .albums, .artists, .songs:
            return try await multiLibraryPage(
                kind: kind,
                contextID: contextID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
        case .playlists, .search, .albumTracks, .playlistTracks:
            return try await singleSourcePage(
                kind: kind,
                contextID: contextID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
        }
    }

    private func multiLibraryPage(
        kind: JellyfinCatalogKind,
        contextID: String?,
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinCatalogPage {
        try await pageFromSources(
            kind: kind,
            contextID: contextID,
            sourceIDs: libraryIDs,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { [api, userID] libraryID, offset, pageLimit in
            switch kind {
            case .albums:
                return try await api.albumsPage(
                    userID: userID, libraryID: libraryID, artistID: contextID,
                    startIndex: offset, limit: pageLimit, searchTerm: searchTerm
                )
            case .artists:
                return try await api.artistsPage(
                    userID: userID, libraryID: libraryID, startIndex: offset,
                    limit: pageLimit, searchTerm: searchTerm
                )
            case .songs:
                return try await api.songsPage(
                    userID: userID, libraryID: libraryID, startIndex: offset,
                    limit: pageLimit, searchTerm: searchTerm
                )
            case .playlists, .search, .albumTracks, .playlistTracks:
                preconditionFailure("Multi-library paging only supports music views.")
            }
        }
    }

    private func singleSourcePage(
        kind: JellyfinCatalogKind,
        contextID: String?,
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinCatalogPage {
        try await pageFromSources(
            kind: kind,
            contextID: contextID,
            sourceIDs: ["global"],
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { [api, userID] _, offset, pageLimit in
            switch kind {
            case .playlists:
                return try await api.playlistsPage(
                    userID: userID, startIndex: offset, limit: pageLimit,
                    searchTerm: searchTerm
                )
            case .search:
                return try await api.searchMusicPage(
                    userID: userID, query: searchTerm ?? "", startIndex: offset,
                    limit: pageLimit
                )
            case .albumTracks:
                return try await api.tracksPage(
                    userID: userID, albumID: contextID ?? "", startIndex: offset,
                    limit: pageLimit
                )
            case .playlistTracks:
                return try await api.playlistItemsPage(
                    userID: userID, playlistID: contextID ?? "", startIndex: offset,
                    limit: pageLimit
                )
            case .albums, .artists, .songs:
                preconditionFailure("Single-source paging only supports global views.")
            }
        }
    }

    private func pageFromSources(
        kind: JellyfinCatalogKind,
        contextID: String?,
        sourceIDs: [String],
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?,
        loader: @escaping @Sendable (String, Int, Int) async throws -> JellyfinItemPage
    ) async throws -> JellyfinCatalogPage {
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Catalog Page", signpostID: signpostID)
        defer {
            os_signpost(
                .end, log: Self.performanceLog, name: "Catalog Page", signpostID: signpostID)
        }

        let safeLimit = max(limit, 1)
        let identity = [
            kind.rawValue, contextID ?? "", searchTerm ?? "",
            sourceIDs.sorted().joined(separator: ","),
        ].joined(separator: "|")
        var state =
            cursor?.identity == identity
            ? cursor!
            : JellyfinCatalogCursor(
                identity: identity,
                offsets: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, 0) }),
                totals: [:],
                buffers: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, []) }),
                exhaustedSources: [],
                seenItemIDs: []
            )

        var output: [JellyfinItem] = []
        while output.count < safeLimit {
            let sourcesToFill = sourceIDs.filter {
                state.buffers[$0, default: []].isEmpty && !state.exhaustedSources.contains($0)
            }
            if !sourcesToFill.isEmpty {
                let offsets = state.offsets
                let responses = try await withThrowingTaskGroup(of: (String, JellyfinItemPage).self)
                { group in
                    for sourceID in sourcesToFill {
                        group.addTask {
                            (
                                sourceID,
                                try await loader(sourceID, offsets[sourceID, default: 0], safeLimit)
                            )
                        }
                    }
                    var values: [(String, JellyfinItemPage)] = []
                    for try await value in group { values.append(value) }
                    return values
                }
                for (sourceID, page) in responses {
                    state.buffers[sourceID, default: []].append(contentsOf: page.items)
                    state.offsets[sourceID] = page.nextStartIndex
                    state.totals[sourceID] = page.totalRecordCount
                    if page.items.isEmpty
                        || (page.totalRecordCount > 0
                            && page.nextStartIndex >= page.totalRecordCount)
                    {
                        state.exhaustedSources.insert(sourceID)
                    }
                }
            }

            let nextSourceID = sourceIDs.filter { !state.buffers[$0, default: []].isEmpty }.min {
                lhs, rhs in
                guard let left = state.buffers[lhs]?.first, let right = state.buffers[rhs]?.first
                else { return lhs < rhs }
                return catalogSortComparison(left, right, kind: kind) == .orderedAscending
            }
            guard let nextSourceID else { break }
            let candidate = state.buffers[nextSourceID, default: []].removeFirst()
            if state.seenItemIDs.insert(candidate.id).inserted { output.append(candidate) }
        }

        let hasMore = sourceIDs.contains {
            !state.exhaustedSources.contains($0) || !state.buffers[$0, default: []].isEmpty
        }
        return JellyfinCatalogPage(
            items: output, totalRecordCount: state.totals.values.reduce(0, +),
            cursor: hasMore ? state : nil)
    }

    private func uniqueAndSorted(_ items: [JellyfinItem]) -> [JellyfinItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func catalogSortComparison(
        _ left: JellyfinItem, _ right: JellyfinItem, kind: JellyfinCatalogKind
    ) -> ComparisonResult {
        if kind == .albums {
            let artistComparison = (left.albumArtist ?? "").localizedStandardCompare(
                right.albumArtist ?? "")
            if artistComparison != .orderedSame { return artistComparison }
        }
        let nameComparison = (left.sortName ?? left.name).localizedStandardCompare(
            right.sortName ?? right.name)
        return nameComparison == .orderedSame
            ? left.id.localizedStandardCompare(right.id) : nameComparison
    }
}

/// Disk-backed cache for non-search catalog results.
///
/// The actor serializes each read-modify-write operation. Corrupt, obsolete,
/// and version-mismatched files are cache misses rather than session failures.
/// The injectable clock makes expiry behavior deterministic under test.
actor JellyfinCatalogCache {
    private struct Record: Codable {
        var items: [JellyfinItem]
        var updatedAt: Date
        var lastAccessedAt: Date
        let isDetail: Bool
    }

    private struct Envelope: Codable {
        let version: Int
        var records: [String: Record]
    }

    private let directory: URL
    private let fileManager: FileManager
    private let maxBytes = 10 * 1_024 * 1_024
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let now: @Sendable () -> Date

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let baseDirectory =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory =
            directory
            ?? baseDirectory.appending(path: "VelacantoCatalog", directoryHint: .isDirectory)
        self.fileManager = fileManager
        self.now = now
    }

    func load(serverID: String, userID: String, key: String) -> [JellyfinItem] {
        var envelope = readEnvelope(serverID: serverID, userID: userID)
        guard var record = envelope.records[key] else { return [] }
        guard now().timeIntervalSince(record.updatedAt) <= maxAge else {
            envelope.records.removeValue(forKey: key)
            writeEnvelope(envelope, serverID: serverID, userID: userID)
            return []
        }
        record.lastAccessedAt = now()
        envelope.records[key] = record
        writeEnvelope(envelope, serverID: serverID, userID: userID)
        return record.items
    }

    func save(
        _ items: [JellyfinItem], serverID: String, userID: String, key: String, isDetail: Bool
    ) {
        var envelope = readEnvelope(serverID: serverID, userID: userID)
        let now = now()
        envelope.records[key] = Record(
            items: Array(items.prefix(200)), updatedAt: now, lastAccessedAt: now, isDetail: isDetail
        )
        for detailKey in envelope.records.filter(\.value.isDetail).sorted(by: {
            $0.value.lastAccessedAt > $1.value.lastAccessedAt
        }).dropFirst(20).map(\.key) {
            envelope.records.removeValue(forKey: detailKey)
        }
        var sortedKeys = envelope.records.keys.sorted {
            (envelope.records[$0]?.lastAccessedAt ?? .distantPast)
                < (envelope.records[$1]?.lastAccessedAt ?? .distantPast)
        }
        while let data = try? encoder.encode(envelope), data.count > maxBytes,
            let oldestKey = sortedKeys.first
        {
            envelope.records.removeValue(forKey: oldestKey)
            sortedKeys.removeFirst()
        }
        writeEnvelope(envelope, serverID: serverID, userID: userID)
    }

    func clear(serverID: String, userID: String) {
        try? fileManager.removeItem(at: fileURL(serverID: serverID, userID: userID))
    }

    private func readEnvelope(serverID: String, userID: String) -> Envelope {
        guard let data = try? Data(contentsOf: fileURL(serverID: serverID, userID: userID)),
            let envelope = try? decoder.decode(Envelope.self, from: data), envelope.version == 1
        else {
            return Envelope(version: 1, records: [:])
        }
        return envelope
    }

    private func writeEnvelope(_ envelope: Envelope, serverID: String, userID: String) {
        guard let data = try? encoder.encode(envelope) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(serverID: serverID, userID: userID), options: .atomic)
    }

    private func fileURL(serverID: String, userID: String) -> URL {
        let safeID = "\(serverID)-\(userID)".map {
            $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-"
        }
        return directory.appending(path: "\(String(safeID)).json")
    }
}
