import Foundation

/// Bounded catalog projections. The surface owns account validation and explicit playback requests.
@MainActor
enum FoundationCarPlayCatalog {
    enum Route: Equatable, Sendable {
        case playlists, favorites, albums, artists, songs, genres, downloads
        case collection(FoundationItem)
        case genre(FoundationItem)
        case artistAlbums(FoundationItem)

        var isPrimaryGenre: Bool {
            switch self {
            case .genres, .genre: true
            case .collection(let item): item.kind == .genre
            default: false
            }
        }
    }

    enum Shelf: String, CaseIterable, Sendable {
        case recentlyPlayed, recentMusic, mostPlayedAlbums, favorites
    }

    struct Snapshot: Sendable {
        var recentlyPlayed: [FoundationItem] = []
        var recentMusic: [FoundationItem] = []
        var mostPlayedAlbums: [FoundationItem] = []
        var favorites: [FoundationItem] = []
        var errors: [Shelf: FoundationLibraryError] = [:]
    }

    struct SearchSnapshot: Sendable {
        let items: [FoundationItem]
        let partialFailure: FoundationLibraryError?
        let nextStartIndex: Int?
    }

    static let pageSize = 40

    static func page(
        route: Route, startIndex: Int, library: any FoundationLibrary,
        downloads: FoundationDownloads?, localOnly: Bool,
        primaryGenres: FoundationPrimaryGenresModel? = nil
    ) async throws -> FoundationPage {
        try Task.checkCancellation()
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
        if route.isPrimaryGenre {
            guard let primaryGenres,
                let record = primaryGenres.completedRecord(
                    libraryScope: library.primaryGenreIndexScope)
            else { throw FoundationLibraryError.unavailable }
            if route == .genres {
                return primaryGenres.page(
                    startIndex: startIndex, limit: pageSize, localOnly: localOnly)
            }
            let genre: FoundationItem
            switch route {
            case .genre(let item), .collection(let item): genre = item
            default: throw FoundationLibraryError.invalidResponse
            }
            guard
                primaryGenres.canonicalRecord(
                    for: genre, libraryScope: library.primaryGenreIndexScope) != nil
            else { throw FoundationLibraryError.unavailable }
            if localOnly {
                return localPage(
                    record.readySongs(
                        membershipIDs: record.songIDs(for: genre.id),
                        from: downloads?.downloadedSongs ?? []), startIndex: startIndex)
            }
            let page = try await record.songPage(
                genreID: genre.id, startIndex: startIndex, limit: pageSize, library: library)
            guard
                primaryGenres.canonicalRecord(
                    for: genre, libraryScope: library.primaryGenreIndexScope) != nil
            else { throw FoundationLibraryError.unavailable }
            return page
        }
        if localOnly || route == .downloads {
            let items = localItems(route: route, downloads: downloads)
            return localPage(items, startIndex: startIndex)
        }
        let result: FoundationPage
        switch route {
        case .playlists: result = try await library.playlists(startIndex: startIndex)
        case .favorites: result = try await library.favorites(startIndex: startIndex)
        case .albums: result = try await library.albums(startIndex: startIndex)
        case .artists: result = try await library.artists(startIndex: startIndex)
        case .songs: result = try await library.songs(startIndex: startIndex)
        case .genres: throw FoundationLibraryError.unavailable
        case .downloads: result = .init(items: [], nextStartIndex: nil)
        case .artistAlbums(let item):
            guard item.kind == .artist else { throw FoundationLibraryError.invalidResponse }
            result = try await library.albums(artistID: item.id, startIndex: startIndex)
        case .genre: throw FoundationLibraryError.unavailable
        case .collection(let item):
            switch item.kind {
            case .album: result = try await library.tracks(albumID: item.id, startIndex: startIndex)
            case .artist:
                result = try await library.tracks(artistID: item.id, startIndex: startIndex)
            case .playlist:
                result = try await library.playlistTracks(
                    playlistID: item.id, startIndex: startIndex)
            case .genre: throw FoundationLibraryError.unavailable
            case .track: result = localPage([item], startIndex: startIndex)
            }
        }
        try Task.checkCancellation()
        // These provider APIs use item offsets, so a clipped page continues at the first omitted item.
        let next = result.items.count > pageSize ? startIndex + pageSize : result.nextStartIndex
        guard next == nil || next! > startIndex else {
            throw FoundationLibraryError.invalidResponse
        }
        return .init(items: Array(result.items.prefix(pageSize)), nextStartIndex: next)
    }

    /// History and ranking are server facts; downloaded membership is never presented as listening history.
    static func snapshot(
        library: any FoundationLibrary, downloads: FoundationDownloads?, localOnly: Bool
    ) async throws -> Snapshot {
        try Task.checkCancellation()
        if localOnly {
            return Snapshot(
                favorites: Array(localItems(route: .favorites, downloads: downloads).prefix(12)),
                errors: Dictionary(
                    uniqueKeysWithValues: Shelf.allCases.filter { $0 != .favorites }.map {
                        ($0, FoundationLibraryError.unavailable)
                    }))
        }
        var result = Snapshot()
        for shelf in Shelf.allCases {
            try Task.checkCancellation()
            do {
                let page: FoundationPage
                switch shelf {
                case .recentlyPlayed: page = try await library.recentlyPlayed(startIndex: 0)
                case .recentMusic: page = try await library.recentMusicSuggestions()
                case .mostPlayedAlbums: page = try await library.mostPlayedAlbums()
                case .favorites: page = try await library.favorites(startIndex: 0)
                }
                try Task.checkCancellation()
                let items = Array(page.items.prefix(12))
                switch shelf {
                case .recentlyPlayed: result.recentlyPlayed = items
                case .recentMusic: result.recentMusic = items
                case .mostPlayedAlbums: result.mostPlayedAlbums = items
                case .favorites: result.favorites = items
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError
                    || FoundationLibraryError.category(error) == .cancelled
                {
                    throw CancellationError()
                }
                result.errors[shelf] = FoundationLibraryError.category(error)
            }
        }
        return result
    }

    static func search(
        query: String, library: any FoundationLibrary, downloads: FoundationDownloads?,
        localOnly: Bool, primaryGenres: FoundationPrimaryGenresModel? = nil, startIndex: Int = 0
    ) async throws -> SearchSnapshot {
        try Task.checkCancellation()
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(items: [], partialFailure: nil, nextStartIndex: nil)
        }
        let record = primaryGenres?.completedRecord(libraryScope: library.primaryGenreIndexScope)
        let genreItems =
            record == nil ? [] : primaryGenres?.items(query: query, localOnly: localOnly) ?? []
        let genrePage: FoundationSearchResolver.Search = { _, _, limit in
            .init(items: Array(genreItems.prefix(limit)), nextStartIndex: nil)
        }
        let resolver: FoundationSearchResolver
        if localOnly {
            let candidates = downloads?.localCatalogItems() ?? []
            resolver = FoundationSearchResolver(localSearch: { term, kind, limit in
                try Task.checkCancellation()
                if kind == .genre { return try await genrePage(term, kind, limit) }
                let matches = candidates.filter {
                    $0.kind == kind
                        && [$0.title, $0.subtitle, $0.album?.title ?? "", $0.artist?.title ?? ""]
                            .contains { $0.localizedStandardContains(term) }
                }
                return .init(items: Array(matches.prefix(limit)), nextStartIndex: nil)
            })
        } else {
            resolver = FoundationSearchResolver(library: library, genreSearch: genrePage)
        }
        let result = try await resolver.resolve(query: query)
        try Task.checkCancellation()
        if let record {
            guard
                primaryGenres?.completedRecord(libraryScope: library.primaryGenreIndexScope)?
                    .snapshot.censusID == record.snapshot.censusID
            else { throw FoundationLibraryError.unavailable }
        }
        var sections = FoundationSearchResolver.displaySections(
            direct: result.direct, related: result.related, query: query)
        if let content = result.playlistContents {
            let index = sections.firstIndex { $0.role == .relatedPlaylists }
            let existing = index.map { sections[$0].items } ?? []
            var seen = Set(existing.map { $0.kind.rawValue + ":" + $0.id })
            let matches = content.items.filter {
                $0.kind == .playlist && seen.insert($0.kind.rawValue + ":" + $0.id).inserted
            }
            if !matches.isEmpty {
                let section = FoundationSearchResolver.DisplaySection(
                    role: .relatedPlaylists, kind: .playlist, items: existing + matches)
                if let index {
                    sections[index] = section
                } else {
                    let position =
                        sections.firstIndex { $0.role == .relatedGenres } ?? sections.endIndex
                    sections.insert(section, at: position)
                }
            }
        }
        let failure =
            result.direct.compactMap(\.error).first ?? result.playlistContentError
            ?? (!result.failures.isEmpty || (result.playlistContents?.partialFailureCount ?? 0) > 0
                ? FoundationLibraryError.unavailable : nil)
        let ranked = FoundationSearchResolver.ranked(
            sections.flatMap(\.items).filter { $0.kind != .genre } + genreItems, query: query)
        let page = localPage(ranked, startIndex: startIndex)
        return SearchSnapshot(
            items: page.items,
            partialFailure: failure
                ?? (record == nil || (localOnly && primaryGenres?.offlineErrorMessage != nil)
                    ? .unavailable : nil),
            nextStartIndex: page.nextStartIndex)
    }

    static func resolve(
        query: String, library: any FoundationLibrary, downloads: FoundationDownloads?,
        localOnly: Bool, primaryGenres: FoundationPrimaryGenresModel? = nil
    ) async throws -> [FoundationItem] {
        try await search(
            query: query, library: library, downloads: downloads, localOnly: localOnly,
            primaryGenres: primaryGenres
        )
        .items
    }

    private static func localItems(route: Route, downloads: FoundationDownloads?)
        -> [FoundationItem]
    {
        guard let downloads else { return [] }
        switch route {
        case .playlists: return downloads.downloadedPlaylists
        case .albums: return downloads.downloadedAlbums
        case .artists: return downloads.downloadedArtists
        case .songs, .downloads: return downloads.downloadedSongs
        case .favorites: return downloads.localCatalogItems().filter { $0.isFavorite == true }
        // The completed primary index handles these before local catalog routing.
        case .genres: return []
        case .artistAlbums(let artist): return downloads.downloadedAlbums(artistID: artist.id)
        case .genre: return []
        case .collection(let item):
            if item.kind == .genre {
                return []
            }
            return downloads.browseTracks(for: item)
        }
    }

    private static func localPage(_ items: [FoundationItem], startIndex: Int) -> FoundationPage {
        guard startIndex < items.count else { return .init(items: [], nextStartIndex: nil) }
        let end = min(items.count, startIndex + pageSize)
        return .init(
            items: Array(items[startIndex..<end]), nextStartIndex: end < items.count ? end : nil)
    }
}
