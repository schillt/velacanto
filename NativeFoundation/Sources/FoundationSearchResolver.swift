import Foundation

/// Resolves a bounded query snapshot. Callers own cancellation and source/query identity.
/// At most ten direct/fallback reads plus four relationship reads. Discovery adds
/// one similar read for album/artist, or up to three song-context reads when existing
/// relationship pages refer to different identities. No cursor is walked automatically.
struct FoundationSearchResolver: Sendable {
    struct DirectSection: Sendable {
        let kind: FoundationItem.Kind
        /// Pagination belongs to the original provider query, never to related/fuzzy results.
        let page: FoundationPage
        let includesFuzzyMatches: Bool
        /// Preserve provider failure categories for existing catalog error/retry presentation.
        let error: FoundationLibraryError?
    }

    struct RelatedSection: Sendable {
        enum Role: String, Sendable {
            case artistAlbums, artistTracks, albumTracks, albumArtist, trackAlbum, trackArtist
        }
        let role: Role
        let source: FoundationItem
        let items: [FoundationItem]
    }

    enum Failure: Equatable, Sendable {
        case direct(FoundationItem.Kind)
        case fallback(FoundationItem.Kind)
        case artistAlbums, artistTracks, artistMostPlayed, albumTracks, discovery, playlistContents
    }

    struct Result: Sendable {
        let direct: [DirectSection]
        let related: [RelatedSection]
        let failures: [Failure]
        let discovery: [FoundationItem]
        let playlistContents: FoundationPlaylistContentPage?
        let musicContext: FoundationMusicSearchContext
        let playlistContentError: FoundationLibraryError?

        init(
            direct: [DirectSection], related: [RelatedSection], failures: [Failure],
            discovery: [FoundationItem] = [],
            playlistContents: FoundationPlaylistContentPage? = nil,
            musicContext: FoundationMusicSearchContext = .init(),
            playlistContentError: FoundationLibraryError? = nil
        ) {
            self.direct = direct
            self.related = related
            self.failures = failures
            self.discovery = discovery
            self.playlistContents = playlistContents
            self.musicContext = musicContext
            self.playlistContentError = playlistContentError
        }
    }

    struct DisplaySection: Sendable {
        enum Role: String, Sendable {
            case top, relatedSongs, relatedArtists, relatedAlbums, relatedPlaylists, relatedGenres
        }
        let role: Role
        /// Top Results spans kinds. Related sections retain a single kind.
        let kind: FoundationItem.Kind?
        /// All bounded retained rows, so a category can present the same snapshot.
        let items: [FoundationItem]
    }

    static func displaySections(
        direct: [DirectSection], related: [RelatedSection], query: String
    ) -> [DisplaySection] {
        let directItems = direct.flatMap { $0.page.items }
        // One strongest match per type preserves the song → album → artist hierarchy.
        let topKinds: [FoundationItem.Kind] = [.track, .album, .artist]
        let top = topKinds.compactMap { kind in
            displayRanked(directItems.filter { $0.kind == kind }, query: query).first
        }
        let topIdentities = Set(top.map(key))
        var result: [DisplaySection] = []
        if !top.isEmpty { result.append(.init(role: .top, kind: nil, items: top)) }
        let candidates = directItems + related.flatMap(\.items)
        let groups: [(DisplaySection.Role, FoundationItem.Kind)] = [
            (.relatedSongs, .track), (.relatedArtists, .artist),
            (.relatedAlbums, .album), (.relatedPlaylists, .playlist), (.relatedGenres, .genre),
        ]
        for (role, kind) in groups {
            let items = displayRanked(
                candidates.filter { $0.kind == kind && !topIdentities.contains(key($0)) },
                query: query)
            if !items.isEmpty { result.append(.init(role: role, kind: kind, items: items)) }
        }
        return result
    }

    private static func displayRanked(_ items: [FoundationItem], query: String) -> [FoundationItem]
    {
        unique(items).sorted {
            let left = score($0, query: query)
            let right = score($1, query: query)
            if left != right { return left > right }
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            let leftTitle = normalize($0.title)
            let rightTitle = normalize($1.title)
            return leftTitle == rightTitle ? key($0) < key($1) : leftTitle < rightTitle
        }
    }

    typealias Search = @Sendable (String, FoundationItem.Kind, Int) async throws -> FoundationPage
    typealias Relation = @Sendable (String) async throws -> FoundationPage
    typealias Similar = @Sendable (FoundationItem) async throws -> FoundationPage
    typealias PlaylistContents =
        @Sendable (FoundationMusicSearchContext, Int) async throws
        -> FoundationPlaylistContentPage
    private let search: Search
    private let artistAlbums: Relation
    private let artistTracks: Relation
    private let artistMostPlayed: Relation
    private let albumTracks: Relation
    private let similarItems: Similar
    private let playlistContents: PlaylistContents
    private let localOnly: Bool
    private static let kinds: [FoundationItem.Kind] = [.track, .album, .artist, .playlist, .genre]

    init(library: any FoundationLibrary, genreSearch: Search? = nil) {
        self.init(
            search: { query, kind, limit in
                if kind == .genre, let genreSearch {
                    return try await genreSearch(query, kind, limit)
                }
                return try await library.search(
                    query: query, kind: kind, startIndex: 0, limit: limit)
            },
            artistAlbums: { try await library.albums(artistID: $0, startIndex: 0) },
            artistTracks: { try await library.tracks(artistID: $0, startIndex: 0) },
            artistMostPlayed: { try await library.mostPlayed(artistID: $0) },
            albumTracks: { try await library.tracks(albumID: $0, startIndex: 0) },
            similarItems: { try await library.similarItems(for: $0) },
            playlistContents: {
                try await library.playlistsContainingMusic(context: $0, startIndex: $1)
            })
    }

    /// Local search supplies only account-owned downloaded candidates; relations never read remotely.
    init(localSearch: @escaping Search) {
        self.init(search: localSearch, localOnly: true)
    }

    init(
        search: @escaping Search,
        artistAlbums: @escaping Relation = { _ in .init(items: [], nextStartIndex: nil) },
        artistTracks: @escaping Relation = { _ in .init(items: [], nextStartIndex: nil) },
        artistMostPlayed: @escaping Relation = { _ in .init(items: [], nextStartIndex: nil) },
        albumTracks: @escaping Relation = { _ in .init(items: [], nextStartIndex: nil) },
        similarItems: @escaping Similar = { _ in .init(items: [], nextStartIndex: nil) },
        playlistContents: @escaping PlaylistContents = { _, _ in
            throw FoundationLibraryError.unavailable
        },
        localOnly: Bool = false
    ) {
        self.search = search
        self.artistAlbums = artistAlbums
        self.artistTracks = artistTracks
        self.artistMostPlayed = artistMostPlayed
        self.albumTracks = albumTracks
        self.similarItems = similarItems
        self.playlistContents = playlistContents
        self.localOnly = localOnly
    }

    func resolve(query: String) async throws -> Result {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .init(direct: [], related: [], failures: []) }
        var direct: [DirectSection] = []
        var failures: [Failure] = []
        for kind in Self.kinds {
            try Task.checkCancellation()
            var original = FoundationPage(items: [], nextStartIndex: nil)
            var directError: FoundationLibraryError?
            do { original = try await search(term, kind, 50) } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                directError = FoundationLibraryError.category(error)
                failures.append(.direct(kind))
            }
            try Task.checkCancellation()
            var candidates = Array(original.items.filter { $0.kind == kind }.prefix(50))
            var fuzzy = false
            if directError == nil,
                !candidates.contains(where: { Self.titleScore($0.title, query: term) >= 80 }),
                let fallback = Self.fallbackQuery(term)
            {
                do {
                    let page = try await search(fallback, kind, 50)
                    try Task.checkCancellation()
                    let recovered = page.items.prefix(50).filter {
                        $0.kind == kind && Self.titleScore($0.title, query: term) >= 60
                    }
                    let existing = Set(candidates.map(Self.key))
                    fuzzy = recovered.contains { !existing.contains(Self.key($0)) }
                    candidates += recovered
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    failures.append(.fallback(kind))
                }
            }
            direct.append(
                .init(
                    kind: kind,
                    page: .init(
                        items: Self.ranked(candidates, query: term),
                        nextStartIndex: original.nextStartIndex),
                    includesFuzzyMatches: fuzzy, error: directError))
        }
        try Task.checkCancellation()
        var related: [RelatedSection] = []
        let matchingTracks =
            direct.first { $0.kind == .track }?.page.items.filter {
                Self.titleScore($0.title, query: term) >= 60
            } ?? []
        for track in matchingTracks {
            if let album = track.relatedAlbum {
                related.append(.init(role: .trackAlbum, source: track, items: [album]))
            }
            if let artist = track.relatedArtist {
                related.append(.init(role: .trackArtist, source: track, items: [artist]))
            }
        }
        let album = direct.first { $0.kind == .album }?.page.items.first {
            Self.titleScore($0.title, query: term) >= 60
        }
        let artist = direct.first { $0.kind == .artist }?.page.items.first {
            Self.titleScore($0.title, query: term) >= 60
        }
        if let album, let reference = album.relatedArtist {
            related.append(.init(role: .albumArtist, source: album, items: [reference]))
        }
        if !localOnly {
            if let artist {
                do {
                    let page = try await artistAlbums(artist.id)
                    try Task.checkCancellation()
                    related.append(
                        .init(
                            role: .artistAlbums, source: artist,
                            items: Array(
                                Self.unique(
                                    Array(page.items.prefix(50)).filter { $0.kind == .album }
                                ).prefix(12))))
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    failures.append(.artistAlbums)
                }
                var tracks: [FoundationItem] = []
                do {
                    let page = try await artistMostPlayed(artist.id)
                    try Task.checkCancellation()
                    tracks = Array(page.items.prefix(12)).filter { $0.kind == .track }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    failures.append(.artistMostPlayed)
                }
                if tracks.isEmpty {
                    do {
                        let page = try await artistTracks(artist.id)
                        try Task.checkCancellation()
                        tracks = Array(page.items.prefix(100)).filter { $0.kind == .track }
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        failures.append(.artistTracks)
                    }
                }
                tracks = Self.unique(tracks).sorted {
                    $0.playCount == $1.playCount
                        ? Self.key($0) < Self.key($1) : $0.playCount > $1.playCount
                }
                related.append(
                    .init(role: .artistTracks, source: artist, items: Array(tracks.prefix(20))))
            }
            if let album {
                do {
                    let page = try await albumTracks(album.id)
                    try Task.checkCancellation()
                    related.append(
                        .init(
                            role: .albumTracks, source: album,
                            items: Array(
                                Self.unique(
                                    Array(page.items.prefix(100)).filter { $0.kind == .track }
                                ).prefix(20))))
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    failures.append(.albumTracks)
                }
            }
        }
        try Task.checkCancellation()
        var discovery: [FoundationItem] = []
        let directItems = Self.unique(direct.flatMap { $0.page.items })
        let displayed = Self.displaySections(direct: direct, related: related, query: term)
        let discoverySource = displayed.first { $0.role == .top }?.items.first
        if !localOnly, directItems.count <= 5, direct.allSatisfy({ $0.error == nil }),
            let discoverySource, Self.score(discoverySource, query: term) >= 50
        {
            var candidates: [FoundationItem] = []
            if discoverySource.kind == .track {
                // Reuse known relationship provenance even when a provider omits item metadata.
                for section in related {
                    if section.role == .albumTracks,
                        section.source.id == discoverySource.album?.id
                    {
                        candidates += section.items
                    } else if section.role == .artistTracks,
                        section.source.id == discoverySource.artist?.id
                    {
                        candidates += section.items
                    } else {
                        candidates += section.items.filter {
                            $0.kind == .track && Self.contextScore($0, source: discoverySource) > 0
                        }
                    }
                }
                if let reference = discoverySource.album,
                    !related.contains(where: {
                        $0.role == .albumTracks && $0.source.id == reference.id
                    })
                {
                    do {
                        let page = try await albumTracks(reference.id)
                        try Task.checkCancellation()
                        candidates += page.items.prefix(100).filter { $0.kind == .track }.prefix(20)
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        if FoundationLibraryError.category(error) != .unavailable {
                            failures.append(.discovery)
                        }
                    }
                }
                if let reference = discoverySource.artist,
                    !related.contains(where: {
                        $0.role == .artistTracks && $0.source.id == reference.id
                    })
                {
                    var tracks: [FoundationItem] = []
                    do {
                        let page = try await artistMostPlayed(reference.id)
                        try Task.checkCancellation()
                        tracks = Array(page.items.prefix(12)).filter { $0.kind == .track }
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        if FoundationLibraryError.category(error) != .unavailable {
                            failures.append(.discovery)
                        }
                    }
                    if tracks.isEmpty {
                        do {
                            let page = try await artistTracks(reference.id)
                            try Task.checkCancellation()
                            tracks = Array(page.items.prefix(100)).filter { $0.kind == .track }
                        } catch {
                            try Task.checkCancellation()
                            if error is CancellationError { throw error }
                            if FoundationLibraryError.category(error) != .unavailable {
                                failures.append(.discovery)
                            }
                        }
                    }
                    candidates += tracks.prefix(20)
                }
            } else {
                do {
                    let page = try await similarItems(discoverySource)
                    try Task.checkCancellation()
                    candidates += page.items.prefix(12).filter { $0.kind == discoverySource.kind }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    if FoundationLibraryError.category(error) != .unavailable {
                        failures.append(.discovery)
                    }
                }
                for section in related {
                    if discoverySource.kind == .album, section.role == .artistAlbums,
                        section.source.id == discoverySource.artist?.id
                    {
                        candidates += section.items
                    } else {
                        candidates += section.items.filter {
                            $0.kind == discoverySource.kind
                                && Self.contextScore($0, source: discoverySource) > 0
                        }
                    }
                }
            }
            let visibleIdentities = Set(displayed.flatMap { $0.items.prefix(5) }.map(Self.key))
            candidates = Self.unique(candidates).filter {
                $0.kind == discoverySource.kind && !visibleIdentities.contains(Self.key($0))
            }
            discovery = Array(
                Self.contextRanked(candidates, source: discoverySource, query: term).prefix(8))
        }
        try Task.checkCancellation()
        let context = Self.musicContext(direct: direct, related: related, query: term)
        var contentPage: FoundationPlaylistContentPage?
        var contentError: FoundationLibraryError?
        if !localOnly, direct.allSatisfy({ $0.error == nil }), !context.isEmpty {
            do {
                contentPage = try await playlistContents(context, 0)
                try Task.checkCancellation()
                if (contentPage?.partialFailureCount ?? 0) > 0 {
                    failures.append(.playlistContents)
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if FoundationLibraryError.category(error) != .unavailable {
                    failures.append(.playlistContents)
                    contentError = FoundationLibraryError.category(error)
                }
            }
        }
        try Task.checkCancellation()
        return .init(
            direct: direct, related: related.filter { !$0.items.isEmpty },
            failures: failures.reduce(into: [Failure]()) { if !$0.contains($1) { $0.append($1) } },
            discovery: discovery, playlistContents: contentPage, musicContext: context,
            playlistContentError: contentError)
    }

    /// Only strong query matches establish identity context; song matches never expand
    /// to every song by their artist. Related tracks retain their matched collection scope.
    static func musicContext(
        direct: [DirectSection], related: [RelatedSection], query: String
    ) -> FoundationMusicSearchContext {
        let matches = unique(direct.flatMap { $0.page.items }).filter {
            titleScore($0.title, query: query) >= 60
        }
        let albumIDs = Set(matches.filter { $0.kind == .album }.map(\.id))
        let artistIDs = Set(matches.filter { $0.kind == .artist }.map(\.id))
        let relatedTracks = related.filter {
            ($0.role == .albumTracks && albumIDs.contains($0.source.id))
                || ($0.role == .artistTracks && artistIDs.contains($0.source.id))
        }.flatMap(\.items).filter { $0.kind == .track }
        return .init(
            trackIDs: Set(
                (matches.filter { $0.kind == .track } + relatedTracks).prefix(100).map(\.id)),
            albumIDs: Set(albumIDs.sorted().prefix(50)),
            artistIDs: Set(artistIDs.sorted().prefix(25)),
            genreIDs: Set(matches.filter { $0.kind == .genre }.prefix(25).map(\.id)))
    }

    private static func contextScore(_ item: FoundationItem, source: FoundationItem) -> Int {
        var value = 0
        if let album = source.album, item.album?.id == album.id { value += 3 }
        if let artist = source.artist, item.artist?.id == artist.id { value += 2 }
        let genres = Set(source.genres.map(\.id))
        if item.genres.contains(where: { genres.contains($0.id) }) { value += 1 }
        return value
    }

    private static func contextRanked(
        _ items: [FoundationItem], source: FoundationItem, query: String
    ) -> [FoundationItem] {
        items.sorted {
            let leftContext = contextScore($0, source: source)
            let rightContext = contextScore($1, source: source)
            if leftContext != rightContext { return leftContext > rightContext }
            let left = score($0, query: query)
            let right = score($1, query: query)
            if left != right { return left > right }
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            return key($0) < key($1)
        }
    }

    static func ranked(_ items: [FoundationItem], query: String) -> [FoundationItem] {
        unique(items).sorted {
            let left = score($0, query: query)
            let right = score($1, query: query)
            if left != right { return left > right }
            let leftTitle = normalize($0.title)
            let rightTitle = normalize($1.title)
            return leftTitle == rightTitle ? key($0) < key($1) : leftTitle < rightTitle
        }
    }

    private static func score(_ item: FoundationItem, query: String) -> Int {
        max(
            titleScore(item.title, query: query),
            [item.subtitle, item.artist?.title ?? "", item.album?.title ?? ""].map {
                min(50, titleScore($0, query: query))
            }.max() ?? 0)
    }

    static func titleScore(_ title: String, query: String) -> Int {
        let title = normalize(title)
        let query = normalize(query)
        guard !query.isEmpty, !title.isEmpty else { return 0 }
        if title == query { return 100 }
        if title.hasPrefix(query) { return 90 }
        let tokens = query.split(separator: " ")
        if tokens.allSatisfy({ title.contains($0) }) { return 80 }
        // Short terms are too ambiguous for typo correction. Bound edit-distance work.
        guard query.count >= 4, query.count <= 128, title.count <= 128 else { return 0 }
        let tolerance = query.count >= 8 ? 2 : 1
        if tokens.count == 1, editDistance(title, query, limit: tolerance) <= tolerance {
            return 60
        }
        if fuzzyTokens(title: title, query: query) { return 60 }
        return 0
    }

    static func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
        .joined().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func fallbackQuery(_ query: String) -> String? {
        let term = normalize(query)
        guard let token = term.split(separator: " ").first, token.count >= 4 else { return nil }
        // One three-character prefix page improves middle/end typo recall. A typo in
        // that prefix or a candidate beyond the first 50 remains undiscoverable.
        let prefix = String(token.prefix(3))
        return prefix == term ? nil : prefix
    }

    private static func fuzzyTokens(title: String, query: String) -> Bool {
        let queryTokens = query.split(separator: " ").map(String.init)
        var available = title.split(separator: " ").map(String.init)
        guard queryTokens.count > 1, queryTokens.count <= 8,
            queryTokens.count <= available.count
        else { return false }
        var totalEdits = 0
        for token in queryTokens {
            let limit = token.count < 4 ? 0 : (token.count >= 8 ? 2 : 1)
            guard
                let best = available.indices.min(by: {
                    editDistance(available[$0], token, limit: limit)
                        < editDistance(available[$1], token, limit: limit)
                })
            else { return false }
            let distance = editDistance(available[best], token, limit: limit)
            guard distance <= limit else { return false }
            totalEdits += distance
            guard totalEdits <= 2 else { return false }
            available.remove(at: best)
        }
        return true
    }

    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        guard abs(left.count - right.count) <= limit else { return limit + 1 }
        var previous = Array(0...right.count)
        for (index, character) in left.enumerated() {
            var row = [index + 1]
            for (column, other) in right.enumerated() {
                row.append(
                    min(
                        row[column] + 1, previous[column + 1] + 1,
                        previous[column] + (character == other ? 0 : 1)))
            }
            if row.min()! > limit { return limit + 1 }
            previous = row
        }
        return previous[right.count]
    }

    private static func key(_ item: FoundationItem) -> String { item.kind.rawValue + ":" + item.id }
    private static func unique(_ items: [FoundationItem]) -> [FoundationItem] {
        var seen: Set<String> = []
        return items.filter { seen.insert(key($0)).inserted }
    }
}
