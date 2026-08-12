import Foundation
import os

/// Fetches and merges catalog pages for one authenticated Jellyfin account.
///
/// A repository is a short-lived snapshot of the current session and libraries.
/// Its cursor is valid only for the query identity recorded in the cursor; callers
/// must discard it when the query, context, or library list changes.
actor JellyfinCatalogRepository: MusicLibraryProviding, MusicItemActionProviding {
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )

    private let api: any JellyfinAPIService
    private let userID: String
    private let accountScope: String
    private let mapper: JellyfinCatalogMapper
    private let libraryIDs: [String]

    init(
        api: any JellyfinAPIService,
        userID: String,
        accountScope: String,
        libraryIDs: [String]
    ) {
        self.api = api
        self.userID = userID
        self.accountScope = accountScope
        mapper = JellyfinCatalogMapper(accountScope: accountScope)
        self.libraryIDs = libraryIDs
    }

    func setFavorite(
        _ isFavorite: Bool,
        for itemID: MusicCatalogItemID
    ) async throws {
        guard itemID.source == .jellyfin, itemID.accountScope == accountScope else {
            throw JellyfinAPIError.invalidResponse
        }
        try await api.setFavorite(
            isFavorite,
            itemID: itemID.opaqueID,
            userID: userID
        )
    }

    func libraries() async throws -> [JellyfinItem] {
        try await api.libraries(userID: userID)
    }

    // MARK: - Artwork reads

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
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID? = nil,
        cursor: MusicCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> MusicCatalogPage {
        switch kind {
        case .albums, .artists, .songs, .artistTracks:
            return try await multiLibraryPage(
                kind: kind,
                contextID: contextID?.opaqueID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
        case .playlists, .search, .albumTracks, .playlistTracks, .favorites,
            .recentlyAdded:
            return try await singleSourcePage(
                kind: kind,
                contextID: contextID?.opaqueID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
        }
    }

    private func multiLibraryPage(
        kind: MusicCatalogKind,
        contextID: String?,
        cursor: MusicCatalogCursor?,
        limit: Int,
        searchTerm: String?
    ) async throws -> MusicCatalogPage {
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
            case .songs, .artistTracks:
                return try await api.songsPage(
                    userID: userID, libraryID: libraryID,
                    artistID: kind == .artistTracks ? contextID : nil, startIndex: offset,
                    limit: pageLimit, searchTerm: searchTerm
                )
            case .playlists, .search, .albumTracks, .playlistTracks, .favorites,
                .recentlyAdded:
                preconditionFailure("Multi-library paging only supports music views.")
            }
        }
    }

    private func singleSourcePage(
        kind: MusicCatalogKind,
        contextID: String?,
        cursor: MusicCatalogCursor?,
        limit: Int,
        searchTerm: String?
    ) async throws -> MusicCatalogPage {
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
            case .favorites:
                return try await api.homeItemsPage(
                    userID: userID, collection: .favorites,
                    startIndex: offset, limit: pageLimit
                )
            case .recentlyAdded:
                return try await api.homeItemsPage(
                    userID: userID, collection: .recentlyAdded,
                    startIndex: offset, limit: pageLimit
                )
            case .albums, .artists, .songs, .artistTracks:
                preconditionFailure("Single-source paging only supports global views.")
            }
        }
    }

    private func pageFromSources(
        kind: MusicCatalogKind,
        contextID: String?,
        sourceIDs: [String],
        cursor: MusicCatalogCursor?,
        limit: Int,
        searchTerm: String?,
        loader: @escaping @Sendable (String, Int, Int) async throws -> JellyfinItemPage
    ) async throws -> MusicCatalogPage {
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(.begin, log: Self.performanceLog, name: "Catalog Page", signpostID: signpostID)
        defer {
            os_signpost(
                .end, log: Self.performanceLog, name: "Catalog Page", signpostID: signpostID)
        }

        let safeLimit = max(limit, 1)
        let identity = [
            mapper.accountScope, kind.rawValue, contextID ?? "", searchTerm ?? "",
            sourceIDs.sorted().joined(separator: ","),
        ].joined(separator: "|")
        var state =
            cursor?.identity == identity
            ? cursor!
            : MusicCatalogCursor(
                identity: identity,
                offsets: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, 0) }),
                totals: [:],
                buffers: Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, []) }),
                exhaustedSources: [],
                seenItemIDs: []
            )

        var output: [MusicCatalogItem] = []
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
                    state.buffers[sourceID, default: []].append(
                        contentsOf: page.items.compactMap(mapper.map)
                    )
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
        return MusicCatalogPage(
            items: output, totalRecordCount: state.totals.values.reduce(0, +),
            cursor: hasMore ? state : nil)
    }

    private func catalogSortComparison(
        _ left: MusicCatalogItem, _ right: MusicCatalogItem, kind: MusicCatalogKind
    ) -> ComparisonResult {
        if kind == .albums {
            let artistComparison = (left.albumArtist ?? "").localizedStandardCompare(
                right.albumArtist ?? "")
            if artistComparison != .orderedSame { return artistComparison }
        }
        let nameComparison = (left.sortName ?? left.name).localizedStandardCompare(
            right.sortName ?? right.name)
        return nameComparison == .orderedSame
            ? left.id.opaqueID.localizedStandardCompare(right.id.opaqueID) : nameComparison
    }
}

struct JellyfinCatalogMapper: Sendable {
    let accountScope: String

    func map(_ item: JellyfinItem) -> MusicCatalogItem? {
        guard let kind = item.kind.map(MusicCatalogItem.Kind.init) else { return nil }
        return MusicCatalogItem(
            id: MusicCatalogItemID(
                source: .jellyfin,
                accountScope: accountScope,
                opaqueID: item.id
            ),
            name: item.name,
            kind: kind,
            sortName: item.sortName,
            artists: item.artists,
            albumArtist: item.albumArtist,
            album: item.album,
            albumID: item.albumID,
            artistIDs: item.artistItems.map(\.id),
            trackNumber: item.indexNumber,
            discNumber: item.parentIndexNumber,
            childCount: item.childCount,
            duration: item.duration,
            artwork: MusicArtworkReference(
                opaqueItemID: item.artworkItemID,
                imageTag: item.primaryImageTag
            ),
            isFavorite: item.isFavorite,
            capabilities: capabilities(for: kind)
        )
    }

    func capabilities(
        for kind: MusicCatalogItem.Kind
    ) -> MusicItemCapabilities {
        switch kind {
        case .song:
            [.play, .favorite, .playNext, .playLast]
        case .album, .artist, .playlist:
            [.navigate, .play, .shuffle, .favorite]
        }
    }
}

extension MusicCatalogItem.Kind {
    init(_ jellyfinKind: JellyfinItemKind) {
        switch jellyfinKind {
        case .song: self = .song
        case .album: self = .album
        case .artist: self = .artist
        case .playlist: self = .playlist
        }
    }
}

/// Disk-backed cache for non-search catalog results.
///
/// The actor serializes each read-modify-write operation. Corrupt, obsolete,
/// and version-mismatched files are cache misses rather than session failures.
/// Invalid files are quarantined before rebuilding. The injectable clock makes
/// expiry behavior deterministic under test. See `docs/architecture.md` for
/// the account-scoped cache policy.
actor JellyfinCatalogCache {
    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "CatalogCache"
    )
    private struct Record: Codable {
        var items: [MusicCatalogItem]
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

    func load(serverID: String, userID: String, key: String) -> [MusicCatalogItem] {
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
        _ items: [MusicCatalogItem], serverID: String, userID: String, key: String, isDetail: Bool
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
        while let oldestKey = sortedKeys.first {
            let data: Data
            do {
                data = try encoder.encode(envelope)
            } catch {
                Self.logger.error("Could not encode catalog cache envelope")
                return
            }
            guard data.count > maxBytes else { break }
            envelope.records.removeValue(forKey: oldestKey)
            sortedKeys.removeFirst()
        }
        writeEnvelope(envelope, serverID: serverID, userID: userID)
    }

    func clear(serverID: String, userID: String) {
        let url = fileURL(serverID: serverID, userID: userID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            Self.logger.error("Could not clear catalog cache")
        }
    }

    private func readEnvelope(serverID: String, userID: String) -> Envelope {
        let url = fileURL(serverID: serverID, userID: userID)
        guard fileManager.fileExists(atPath: url.path) else {
            return Envelope(version: 1, records: [:])
        }
        do {
            let envelope = try decoder.decode(Envelope.self, from: Data(contentsOf: url))
            guard envelope.version == 1 else {
                quarantine(url, reason: "incompatible")
                return Envelope(version: 1, records: [:])
            }
            return envelope
        } catch {
            quarantine(url, reason: "corrupt")
            return Envelope(version: 1, records: [:])
        }
    }

    private func writeEnvelope(_ envelope: Envelope, serverID: String, userID: String) {
        do {
            let data = try encoder.encode(envelope)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(serverID: serverID, userID: userID), options: .atomic)
        } catch {
            // The network result remains valid; only the offline cache is lost.
            Self.logger.error("Could not write catalog cache")
        }
    }

    private func quarantine(_ url: URL, reason: String) {
        let quarantinedURL = url.deletingLastPathComponent().appending(
            path: [
                url.deletingPathExtension().lastPathComponent,
                UUID().uuidString,
                reason,
                "json",
            ].joined(separator: ".")
        )
        do {
            try fileManager.moveItem(at: url, to: quarantinedURL)
        } catch {
            // A failed quarantine is still a cache miss; do not surface it as a
            // session failure or log file paths that identify an account.
            Self.logger.error("Could not quarantine invalid catalog cache")
        }
        Self.logger.error("Discarded invalid catalog cache")
    }

    private func fileURL(serverID: String, userID: String) -> URL {
        let safeID = "\(serverID)-\(userID)".map {
            $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-"
        }
        return directory.appending(path: "\(String(safeID)).json")
    }
}
