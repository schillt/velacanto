import Combine
import Foundation

/// A bounded-search notice belongs only to the query and catalog that produced it.
struct FoundationSearchFallbackCoverage: Equatable {
    let query: String
    let metadataScope: String
    let localOnly: Bool
    let kinds: Set<FoundationItem.Kind>

    func hasUnwalkedPages(query: String, metadataScope: String, localOnly: Bool) -> Bool {
        self.query == query && self.metadataScope == metadataScope && self.localOnly == localOnly
            && !kinds.isEmpty
    }
}

/// A first-page snapshot is retired only after its owning browse model settles.
@MainActor final class FoundationSearchSeedLease {
    private let page: FoundationPage
    private(set) var pending = true
    private var offered = false

    init(page: FoundationPage) { self.page = page }

    func matches(_ candidate: FoundationPage) -> Bool {
        page.items == candidate.items && page.nextStartIndex == candidate.nextStartIndex
    }

    func offer(eligible: Bool) -> FoundationPage? {
        guard pending, eligible else { return nil }
        offered = true
        return page
    }

    func settle() {
        guard offered else { return }
        pending = false
        offered = false
    }

    func invalidate() {
        pending = false
        offered = false
    }
}

/// Resolves a bounded query snapshot. Callers own cancellation and source/query identity.
/// At most ten direct/fallback reads plus four relationship reads. Discovery adds
/// one similar read for album/artist, or up to three song-context reads when existing
/// relationship pages refer to different identities. No cursor is walked automatically.
struct FoundationSearchResolver: Sendable {
    struct FallbackCursor: Equatable, Sendable {
        let term: String
        let nextStartIndex: Int
    }

    struct DirectSection: Sendable {
        let kind: FoundationItem.Kind
        /// Pagination belongs to the original provider query, never to related/fuzzy results.
        let page: FoundationPage
        let includesFuzzyMatches: Bool
        /// Preserve provider failure categories for existing catalog error/retry presentation.
        let error: FoundationLibraryError?
        /// IDs from the provider page that owns `nextStartIndex`.
        let originalIDs: Set<String>
        let fallbackCursor: FallbackCursor?

        init(
            kind: FoundationItem.Kind, page: FoundationPage, includesFuzzyMatches: Bool,
            error: FoundationLibraryError?, originalIDs: Set<String> = [],
            fallbackCursor: FallbackCursor? = nil
        ) {
            self.kind = kind
            self.page = page
            self.includesFuzzyMatches = includesFuzzyMatches
            self.error = error
            self.originalIDs = originalIDs
            self.fallbackCursor = fallbackCursor
        }
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
        /// Fallback cursors are independent of the original provider cursor and are not walked.
        let unwalkedFallbackKinds: Set<FoundationItem.Kind>
        let discovery: [FoundationItem]
        let playlistContents: FoundationPlaylistContentPage?
        let musicContext: FoundationMusicSearchContext
        let playlistContentError: FoundationLibraryError?

        init(
            direct: [DirectSection], related: [RelatedSection], failures: [Failure],
            unwalkedFallbackKinds: Set<FoundationItem.Kind> = [],
            discovery: [FoundationItem] = [],
            playlistContents: FoundationPlaylistContentPage? = nil,
            musicContext: FoundationMusicSearchContext = .init(),
            playlistContentError: FoundationLibraryError? = nil
        ) {
            self.direct = direct
            self.related = related
            self.failures = failures
            self.unwalkedFallbackKinds = unwalkedFallbackKinds
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

    /// Category snapshots include the overview's top row as well as typed rows.
    /// The provider cursor still belongs to the direct section, not these projections.
    static func categoryItems(
        direct: [DirectSection], related: [RelatedSection], kind: FoundationItem.Kind,
        query: String
    ) -> [FoundationItem] {
        displaySections(direct: direct, related: related, query: query)
            .flatMap(\.items).filter { $0.kind == kind }
    }

    static func continuationCoverageMessage(_ message: String?, hasFallback: Bool) -> String? {
        let sentence = "More close matches may exist. Narrow your search."
        let retained = message?.replacingOccurrences(of: sentence, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [
            retained,
            hasFallback
                ? "More close matches may exist. Continue scrolling to search further." : nil,
        ]
        .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    struct CategorySeed: Sendable {
        let page: FoundationPage
        let remaining: [FoundationItem]
        let kind: FoundationItem.Kind?
        let cost: (items: Int, bytes: Int)

        // Only the whole-membership validator below may create this payload.
        fileprivate init(
            page: FoundationPage, remaining: [FoundationItem],
            kind: FoundationItem.Kind?, cost: (items: Int, bytes: Int)
        ) {
            self.page = page
            self.remaining = remaining
            self.kind = kind
            self.cost = cost
        }
    }

    /// Validate every retained row before publishing any prefix. Query/folder/
    /// account lifetime remains fenced by the selection's metadataScope lease;
    /// a concrete Jellyfin adapter also supplies its canonical source identity.
    static func categorySeed(
        _ page: FoundationPage, kind: FoundationItem.Kind? = nil,
        source: FoundationCatalogSource? = nil,
        limits: FoundationCatalogBudget = FoundationCatalogBudget()
    ) -> CategorySeed? {
        guard page.items.count <= FoundationCatalogComposition.itemLimit else { return nil }
        let kind = kind ?? page.items.first?.kind
        let inferredSource = source ?? page.items.lazy.compactMap(\.catalogSource).first
        var identities: Set<String> = []
        for item in page.items {
            guard item.kind == kind, !item.id.isEmpty, item.id.utf8.count <= 4096,
                identities.insert(item.id).inserted,
                item.catalogSource == nil || item.catalogSource == inferredSource
            else { return nil }
            if let inferredSource,
                (try? item.catalogKey(legacyJellyfinSource: inferredSource)) == nil
            {
                return nil
            }
            for reference in [item.album, item.artist].compactMap({ $0 }) + item.genres {
                guard reference.catalogSource == nil || reference.catalogSource == inferredSource
                else { return nil }
            }
        }
        var budget = limits
        var bytes = 0
        for offset in stride(
            from: 0, to: page.items.count, by: FoundationCatalogComposition.pageLimit)
        {
            let chunk = FoundationPage(
                items: Array(
                    page.items[
                        offset..<min(
                            offset + FoundationCatalogComposition.pageLimit, page.items.count)]),
                nextStartIndex: nil)
            guard let cost = budget.cost(of: chunk), budget.canRetain(cost) else { return nil }
            budget.retainedItems += cost.items
            budget.retainedBytes += cost.bytes
            bytes += cost.bytes
        }
        return .init(
            page: .init(
                items: Array(page.items.prefix(FoundationCatalogComposition.pageLimit)),
                nextStartIndex: page.nextStartIndex),
            remaining: Array(page.items.dropFirst(FoundationCatalogComposition.pageLimit)),
            kind: kind, cost: (page.items.count, bytes))
    }

    static func categoryCoverageMessage(
        hasPartialFailure: Bool, itemCount: Int, hasUnwalkedFallback: Bool = false
    ) -> String? {
        let exceedsPage = itemCount > FoundationCatalogComposition.itemLimit
        let bounded =
            hasUnwalkedFallback
            ? "More close matches may exist. Narrow your search." : nil
        let existing: String?
        if exceedsPage && hasPartialFailure {
            existing =
                "Some matches could not be loaded, and this category is too large to show "
                + "all related results. Return to Search to retry or narrow your search."
        } else if exceedsPage {
            existing =
                "This category is too large to show all related results. "
                + "Return to Search and narrow your search."
        } else if hasPartialFailure {
            existing =
                "Some close or related matches could not be loaded. Return to Search to retry."
        } else {
            existing = nil
        }
        let parts = [existing, bounded].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Any missing direct kind can also suppress relationships in another category.
    static func categoryHasPartialFailure(
        direct: [DirectSection], kind: FoundationItem.Kind, hasOtherFailures: Bool
    ) -> Bool {
        hasOtherFailures || !direct.contains { $0.kind == kind }
            || direct.contains { $0.error != nil }
    }

    /// Keep a category entry reachable even when its projected first page is empty.
    static func showsCategoryContinuationPlaceholder(
        hasOriginalPage: Bool, hasFallbackPage: Bool, hasVisibleSection: Bool
    ) -> Bool {
        !hasVisibleSection && (hasOriginalPage || hasFallbackPage)
    }

    static func canSeedCategory(directSucceeded: Bool, itemCount: Int, hasNextPage: Bool) -> Bool {
        directSucceeded && itemCount <= FoundationCatalogComposition.itemLimit
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

    struct DirectResolution: Sendable {
        let section: DirectSection
        let failures: [Failure]
        let fallbackHasMore: Bool
    }

    /// At most two bounded reads for one kind, shared with offline category refresh.
    func resolveDirect(query: String, kind: FoundationItem.Kind) async throws -> DirectResolution {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var failures: [Failure] = []
        var original = FoundationPage(items: [], nextStartIndex: nil)
        var directError: FoundationLibraryError?
        var fallbackCursor: FallbackCursor?
        if !term.isEmpty {
            try Task.checkCancellation()
            do { original = try await search(term, kind, 50) } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                directError = FoundationLibraryError.category(error)
                failures.append(.direct(kind))
            }
        }
        try Task.checkCancellation()
        var candidates = Array(original.items.filter { $0.kind == kind }.prefix(50))
        var fuzzy = false
        if directError == nil, !term.isEmpty,
            !candidates.contains(where: { Self.titleScore($0.title, query: term) >= 80 }),
            let fallback = Self.fallbackQuery(term)
        {
            do {
                let page = try await search(fallback, kind, 50)
                try Task.checkCancellation()
                if let next = page.nextStartIndex {
                    fallbackCursor = .init(term: fallback, nextStartIndex: next)
                }
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
        let section = DirectSection(
            kind: kind,
            page: .init(
                items: Self.ranked(candidates, query: term),
                nextStartIndex: original.nextStartIndex),
            includesFuzzyMatches: fuzzy, error: directError,
            originalIDs: Set(original.items.filter { $0.kind == kind }.prefix(50).map(\.id)),
            fallbackCursor: fallbackCursor)
        return .init(section: section, failures: failures, fallbackHasMore: fallbackCursor != nil)
    }

    /// Resolve only first relationship pages needed by the selected category.
    private func resolveRelationships(
        direct: [DirectSection], query term: String, targetKind: FoundationItem.Kind? = nil
    ) async throws -> (related: [RelatedSection], failures: [Failure], incomplete: Bool) {
        try Task.checkCancellation()
        var failures: [Failure] = []
        var incomplete = false
        var related: [RelatedSection] = []
        let matchingTracks =
            direct.first { $0.kind == .track }?.page.items.filter {
                Self.titleScore($0.title, query: term) >= 60
            } ?? []
        for track in matchingTracks {
            if targetKind == nil || targetKind == .album, let album = track.relatedAlbum {
                related.append(.init(role: .trackAlbum, source: track, items: [album]))
            }
            if targetKind == nil || targetKind == .artist, let artist = track.relatedArtist {
                related.append(.init(role: .trackArtist, source: track, items: [artist]))
            }
        }
        let album = direct.first { $0.kind == .album }?.page.items.first {
            Self.titleScore($0.title, query: term) >= 60
        }
        let artist = direct.first { $0.kind == .artist }?.page.items.first {
            Self.titleScore($0.title, query: term) >= 60
        }
        if targetKind == nil || targetKind == .artist,
            let album, let reference = album.relatedArtist
        {
            related.append(.init(role: .albumArtist, source: album, items: [reference]))
        }
        if !localOnly {
            if let artist {
                if targetKind == nil || targetKind == .album {
                    do {
                        try Task.checkCancellation()
                        let page = try await artistAlbums(artist.id)
                        incomplete =
                            incomplete || page.nextStartIndex != nil || page.items.count > 12
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
                }
                if targetKind == nil || targetKind == .track {
                    var tracks: [FoundationItem] = []
                    do {
                        try Task.checkCancellation()
                        let page = try await artistMostPlayed(artist.id)
                        incomplete =
                            incomplete || page.nextStartIndex != nil || page.items.count > 12
                        try Task.checkCancellation()
                        tracks = Array(page.items.prefix(12)).filter { $0.kind == .track }
                    } catch {
                        try Task.checkCancellation()
                        if error is CancellationError { throw error }
                        failures.append(.artistMostPlayed)
                    }
                    if tracks.isEmpty {
                        do {
                            try Task.checkCancellation()
                            let page = try await artistTracks(artist.id)
                            incomplete =
                                incomplete || page.nextStartIndex != nil || page.items.count > 20
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
            }
            if targetKind == nil || targetKind == .track, let album {
                do {
                    try Task.checkCancellation()
                    let page = try await albumTracks(album.id)
                    incomplete = incomplete || page.nextStartIndex != nil || page.items.count > 20
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
        return (related, failures, incomplete)
    }

    struct CategoryResolution: Sendable {
        let page: FoundationPage
        let direct: DirectSection
        let failures: [Failure]
        let incomplete: Bool
    }

    /// Fresh typed results retain related rows without re-running all five overview kinds.
    /// Direct/fallback anchors cost at most six reads. Albums add one relation,
    /// Artists none, Tracks at most three; Playlists/Genres use their own two reads.
    /// Every relation is one first page; no continuation is walked here.
    func resolveCategory(query: String, kind: FoundationItem.Kind) async throws
        -> CategoryResolution
    {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = try await resolveDirect(query: term, kind: kind)
        if let error = primary.section.error { throw error }
        var direct = [primary.section]
        var failures = primary.failures
        var incomplete = primary.fallbackHasMore
        if [.track, .album, .artist].contains(kind), !term.isEmpty {
            for anchor in [FoundationItem.Kind.track, .album, .artist] where anchor != kind {
                let resolved = try await resolveDirect(query: term, kind: anchor)
                direct.append(resolved.section)
                failures += resolved.failures
                incomplete =
                    incomplete || resolved.fallbackHasMore
                    || resolved.section.page.nextStartIndex != nil
            }
        }
        let relations = try await resolveRelationships(
            direct: direct, query: term, targetKind: kind)
        try Task.checkCancellation()
        failures += relations.failures
        return .init(
            page: .init(
                items: Self.categoryItems(
                    direct: direct, related: relations.related, kind: kind, query: term),
                nextStartIndex: primary.section.page.nextStartIndex),
            direct: primary.section, failures: failures,
            incomplete: incomplete || relations.incomplete || !failures.isEmpty)
    }

    /// Publish each completed bounded direct/fallback section without waiting for later kinds.
    /// A retiring owner may throw cancellation; publication adds no reads or cursor walking.
    func resolve(
        query: String,
        onDirectSection: (@MainActor @Sendable (DirectResolution) async throws -> Void)? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return .init(direct: [], related: [], failures: []) }
        var direct: [DirectSection] = []
        var failures: [Failure] = []
        var unwalkedFallbackKinds: Set<FoundationItem.Kind> = []
        for kind in Self.kinds {
            let resolved = try await resolveDirect(query: term, kind: kind)
            direct.append(resolved.section)
            failures += resolved.failures
            if resolved.fallbackHasMore { unwalkedFallbackKinds.insert(kind) }
            try Task.checkCancellation()
            try await onDirectSection?(resolved)
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        let relationships = try await resolveRelationships(direct: direct, query: term)
        let related = relationships.related
        failures += relationships.failures
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
            unwalkedFallbackKinds: unwalkedFallbackKinds,
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

    /// A low-confidence title match must not be presented as an exact result.
    static func titleMatchExplanation(_ title: String, query: String) -> String? {
        titleScore(title, query: query) == 60 ? "Possible match" : nil
    }

    static func explainedSubtitle(_ subtitle: String?, item: FoundationItem, query: String)
        -> String?
    {
        guard let explanation = titleMatchExplanation(item.title, query: query) else {
            return subtitle
        }
        let base = subtitle ?? item.subtitle
        // Lead with confidence so a one-line truncation does not hide it.
        return base.isEmpty ? explanation : explanation + " · " + base
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
        let available = title.split(separator: " ").map(String.init)
        guard queryTokens.count > 1, queryTokens.count <= 8,
            queryTokens.count <= available.count
        else { return false }
        // Each title token may explain one query token. Greedy pairing can consume
        // the only suitable word too early and change recall when words are reordered.
        // At most 256 states retain the cheapest assignment, capped at two edits.
        let complete = (1 << queryTokens.count) - 1
        var costs = Array(repeating: 3, count: complete + 1)
        costs[0] = 0
        for word in available {
            let distances = queryTokens.map { token in
                let limit = token.count < 4 ? 0 : (token.count >= 8 ? 2 : 1)
                let distance = editDistance(word, token, limit: limit)
                return distance <= limit ? distance : 3
            }
            var next = costs
            for mask in costs.indices where costs[mask] <= 2 {
                for index in queryTokens.indices where mask & (1 << index) == 0 {
                    let cost = costs[mask] + distances[index]
                    if cost <= 2 {
                        let assigned = mask | (1 << index)
                        next[assigned] = min(next[assigned], cost)
                    }
                }
            }
            costs = next
        }
        return costs[complete] <= 2
    }

    /// Adjacent transpositions are one common typo; other edits retain unit cost.
    /// This bounded optimal-string-alignment distance does not reuse transposed text.
    private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        if lhs == rhs { return 0 }
        guard limit > 0 else { return 1 }
        let left = Array(lhs)
        let right = Array(rhs)
        let unreachable = limit + 1
        guard abs(left.count - right.count) <= limit else { return unreachable }
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        // A path within the edit limit cannot leave this diagonal band: its
        // insertion/deletion cost alone would already exceed the limit. Keep
        // two preceding rows so adjacent transpositions retain their unit cost.
        var previous = Array(repeating: unreachable, count: right.count + 1)
        for column in 0...min(limit, right.count) { previous[column] = column }
        var beforePrevious = previous
        for (index, character) in left.enumerated() {
            let rowIndex = index + 1
            var row = Array(repeating: unreachable, count: right.count + 1)
            row[0] = min(rowIndex, unreachable)
            let lower = max(1, rowIndex - limit)
            let upper = min(right.count, rowIndex + limit)
            guard lower <= upper else { return unreachable }
            var best = row[0]
            for column in lower...upper {
                var cost = min(
                    row[column - 1] + 1, previous[column] + 1,
                    previous[column - 1] + (character == right[column - 1] ? 0 : 1))
                if index > 0, column > 1,
                    character == right[column - 2], left[index - 1] == right[column - 1]
                {
                    cost = min(cost, beforePrevious[column - 2] + 1)
                }
                row[column] = cost
                best = min(best, cost)
            }
            if best > limit { return unreachable }
            beforePrevious = previous
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

/// Visible query-owned lookup: empty matching pages may still advance the inspected cursor.
@MainActor final class FoundationPlaylistLookupModel: ObservableObject {
    @Published private(set) var items: [FoundationItem]
    @Published private(set) var cursor: FoundationPlaylistContentCursor?
    @Published private(set) var incomplete: Bool
    @Published private(set) var error: FoundationLibraryError?
    @Published private(set) var loading = false
    @Published private(set) var searching = false
    @Published private(set) var hasStartedSearch = false
    var showsSearchProgress: Bool {
        searching || (!hasStartedSearch && cursor != nil && error == nil)
    }
    var canRetryContinuation: Bool {
        !searching && !loading && cursor != nil && budget.canRequestPage
            && (error == .network || error == .unavailable)
    }
    private var searchOwner = UUID()
    private var visibleClients: Set<UUID> = []
    private var visibleTask: Task<Void, Never>?
    private var visibleJob = UUID()
    private var visibilityRevision = 0
    private var owner = UUID()
    private var budget = FoundationCatalogBudget()
    private let scope: String

    init(
        scope: String, seed: FoundationPlaylistContentPage,
        limits: FoundationCatalogBudget = .init()
    ) {
        self.scope = scope
        budget = limits
        items = seed.items
        cursor =
            seed.continuation
            ?? seed.nextStartIndex.map {
                .init(candidateOffset: $0, pending: [])
            }
        incomplete = seed.hasIncompleteCoverage
        let page = FoundationPage(items: seed.items, nextStartIndex: nil)
        guard seed.items.count <= FoundationPlaylistContentSearch.candidateLimit,
            seed.items.allSatisfy({ $0.kind == .playlist }),
            let cost = budget.cost(of: page), budget.canRetain(cost)
        else {
            items = []
            cursor = nil
            incomplete = true
            error = .invalidResponse
            return
        }
        budget.requestedPages += 1
        budget.retainedItems += cost.items
        budget.retainedBytes += cost.bytes
        if seed.partialFailureCount > 0 { error = .network }
    }

    /// Inline and full results register independently while sharing one producer.
    @discardableResult
    func registerVisible(
        _ client: UUID, context: FoundationMusicSearchContext,
        library: any FoundationLibrary
    ) -> Task<Void, Never>? {
        guard library.metadataScopeID == scope else { return nil }
        visibleClients.insert(client)
        visibilityRevision += 1
        guard visibleTask == nil, error == nil, cursor != nil else { return visibleTask }
        let job = UUID()
        visibleJob = job
        visibleTask = Task { [weak self] in
            guard let self else { return }
            defer { if visibleJob == job { visibleTask = nil } }
            guard visibleJob == job, !visibleClients.isEmpty, !Task.isCancelled else { return }
            await searchWhileVisible(context: context, library: library)
        }
        return visibleTask
    }

    func releaseVisible(_ client: UUID) {
        guard visibleClients.remove(client) != nil else { return }
        visibilityRevision += 1
        guard visibleClients.isEmpty else { return }
        let revision = visibilityRevision
        // Defer cleanup to the next actor turn so synchronous SwiftUI view
        // handover can register its successor without cancelling a shared read.
        Task { [weak self] in
            guard let self, visibilityRevision == revision, visibleClients.isEmpty else { return }
            cancel()
        }
    }

    /// Only an explicit action from a current visible client can resume a failed
    /// cursor. Preserve results and the existing budget; redraws never retry.
    @discardableResult
    func retryVisible(
        _ client: UUID, context: FoundationMusicSearchContext,
        library: any FoundationLibrary
    ) -> Task<Void, Never>? {
        guard visibleClients.contains(client), library.metadataScopeID == scope,
            canRetryContinuation
        else { return nil }
        error = nil
        return registerVisible(client, context: context, library: library)
    }

    /// The caller owns visibility/query lifetime. Each step uses the unchanged
    /// bounded provider batch and ordinary admission; errors never auto-retry.
    func searchWhileVisible(context: FoundationMusicSearchContext, library: any FoundationLibrary)
        async
    {
        guard !searching, !loading, error == nil, library.metadataScopeID == scope else { return }
        let identity = UUID()
        searchOwner = identity
        hasStartedSearch = true
        searching = true
        defer { if searchOwner == identity { searching = false } }
        while let previous = cursor, searchOwner == identity, !Task.isCancelled, error == nil {
            guard await load(context: context, library: library) else { return }
            guard searchOwner == identity, !Task.isCancelled, error == nil else { return }
            if cursor == previous {
                error = .invalidResponse
                return
            }
        }
    }

    func cancel() {
        visibleClients.removeAll()
        visibilityRevision += 1
        visibleJob = UUID()
        visibleTask?.cancel()
        visibleTask = nil
        owner = UUID()
        searchOwner = UUID()
        loading = false
        searching = false
    }

    @discardableResult
    func load(context: FoundationMusicSearchContext, library: any FoundationLibrary) async -> Bool {
        guard !loading, library.metadataScopeID == scope, let cursor else { return false }
        guard budget.canRequestPage else {
            error = .invalidResponse
            return false
        }
        let identity = UUID()
        owner = identity
        budget.requestedPages += 1
        loading = true
        error = nil
        defer { if owner == identity { loading = false } }
        do {
            let page = try await library.playlistsContainingMusic(context: context, cursor: cursor)
            try Task.checkCancellation()
            guard owner == identity, library.metadataScopeID == scope else { return false }
            let raw = FoundationPage(items: page.items, nextStartIndex: nil)
            guard let cost = budget.cost(of: raw), budget.canRetain(cost) else {
                throw FoundationLibraryError.invalidResponse
            }
            budget.retainedItems += cost.items
            budget.retainedBytes += cost.bytes
            var seen = Set(items.map(\.id))
            items += page.items.filter { seen.insert($0.id).inserted }
            self.cursor =
                page.continuation
                ?? page.nextStartIndex.map {
                    .init(candidateOffset: $0, pending: [])
                }
            incomplete = page.hasIncompleteCoverage
            if page.partialFailureCount > 0 { error = .network }
            return true
        } catch {
            guard owner == identity, library.metadataScopeID == scope, !Task.isCancelled else {
                return false
            }
            let category = FoundationLibraryError.category(error)
            if category != .cancelled { self.error = category }
            return false
        }
    }
}
