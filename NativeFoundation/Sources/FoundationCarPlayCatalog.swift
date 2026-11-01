import Foundation

/// Bounded catalog projections. The surface owns account validation and explicit playback requests.
@MainActor
enum FoundationCarPlayCatalog {
    enum Route: Equatable, Sendable {
        case playlists, favorites, albums, artists, songs, genres, downloads
        case collection(FoundationItem)
        case genre(FoundationItem)
        case artistAlbums(FoundationItem)
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
    }

    static let pageSize = 40

    static func page(
        route: Route, startIndex: Int, library: any FoundationLibrary,
        downloads: FoundationDownloads?, localOnly: Bool
    ) async throws -> FoundationPage {
        try Task.checkCancellation()
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
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
        case .genres: result = try await library.genres(startIndex: startIndex)
        case .downloads: result = .init(items: [], nextStartIndex: nil)
        case .artistAlbums(let item):
            guard item.kind == .artist else { throw FoundationLibraryError.invalidResponse }
            result = try await library.albums(artistID: item.id, startIndex: startIndex)
        case .genre(let item):
            guard item.kind == .genre else { throw FoundationLibraryError.invalidResponse }
            result = try await library.albums(genreID: item.id, startIndex: startIndex)
        case .collection(let item):
            switch item.kind {
            case .album: result = try await library.tracks(albumID: item.id, startIndex: startIndex)
            case .artist:
                result = try await library.tracks(artistID: item.id, startIndex: startIndex)
            case .playlist:
                result = try await library.playlistTracks(
                    playlistID: item.id, startIndex: startIndex)
            case .genre:
                result = try await library.albums(genreID: item.id, startIndex: startIndex)
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
        localOnly: Bool
    ) async throws -> SearchSnapshot {
        try Task.checkCancellation()
        let resolver: FoundationSearchResolver
        if localOnly {
            let candidates = downloads?.localCatalogItems() ?? []
            resolver = FoundationSearchResolver(localSearch: { term, kind, limit in
                try Task.checkCancellation()
                let matches = candidates.filter {
                    $0.kind == kind
                        && [$0.title, $0.subtitle, $0.album?.title ?? "", $0.artist?.title ?? ""]
                            .contains { $0.localizedStandardContains(term) }
                }
                return .init(items: Array(matches.prefix(limit)), nextStartIndex: nil)
            })
        } else {
            resolver = FoundationSearchResolver(library: library)
        }
        let result = try await resolver.resolve(query: query)
        try Task.checkCancellation()
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
        return SearchSnapshot(
            items: Array(
                FoundationSearchResolver.ranked(sections.flatMap(\.items), query: query).prefix(
                    pageSize)),
            partialFailure: failure)
    }

    static func resolve(
        query: String, library: any FoundationLibrary, downloads: FoundationDownloads?,
        localOnly: Bool
    ) async throws -> [FoundationItem] {
        try await search(query: query, library: library, downloads: downloads, localOnly: localOnly)
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
        case .genres:
            var seen: Set<String> = []
            return (downloads.downloadedSongs + downloads.downloadedAlbums).flatMap(\.genres)
                .filter { seen.insert($0.id).inserted }.map {
                    FoundationItem(
                        id: $0.id, title: $0.title, subtitle: "", kind: .genre, duration: nil)
                }
        case .artistAlbums(let artist): return downloads.downloadedAlbums(artistID: artist.id)
        case .genre(let genre): return localGenreAlbums(genre.id, downloads: downloads)
        case .collection(let item):
            if item.kind == .genre {
                return localGenreAlbums(item.id, downloads: downloads)
            }
            return downloads.browseTracks(for: item)
        }
    }

    private static func localGenreAlbums(_ id: String, downloads: FoundationDownloads)
        -> [FoundationItem]
    {
        let albums = Set(
            downloads.downloadedSongs.filter { $0.genres.contains { $0.id == id } }
                .compactMap { $0.album?.id })
        return downloads.downloadedAlbums.filter {
            albums.contains($0.id) || $0.genres.contains { $0.id == id }
        }
    }

    private static func localPage(_ items: [FoundationItem], startIndex: Int) -> FoundationPage {
        guard startIndex < items.count else { return .init(items: [], nextStartIndex: nil) }
        let end = min(items.count, startIndex + pageSize)
        return .init(
            items: Array(items[startIndex..<end]), nextStartIndex: end < items.count ? end : nil)
    }
}
