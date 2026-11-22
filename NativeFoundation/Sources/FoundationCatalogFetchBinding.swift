import Foundation

/// An overview snapshot is reusable only for its exact query and account/catalog scope.
struct FoundationCatalogSearchSeed: Sendable {
    let query: String
    let metadataScope: String
    let page: FoundationPage
    let supplementalIDs: Set<String>
    let fallbackCursor: FoundationSearchResolver.FallbackCursor?

    init(
        query: String, metadataScope: String, page: FoundationPage,
        supplementalIDs: Set<String>, fallbackCursor: FoundationSearchResolver.FallbackCursor? = nil
    ) {
        self.query = query
        self.metadataScope = metadataScope
        self.page = page
        self.supplementalIDs = supplementalIDs
        self.fallbackCursor = fallbackCursor
    }
}

/// One binding is one immutable browse/search result set. It cannot reuse cursors
/// for a changed query, account, music-library selection or local index snapshot.
enum FoundationCatalogQuery: Equatable, Sendable {
    case songs
    case search(text: String, kind: FoundationItem.Kind)

    func normalized() throws -> Self {
        switch self {
        case .songs: return self
        case .search(let text, let kind):
            guard text.utf8.count <= 1024 else {
                throw FoundationCatalogComposition.Failure.invalidPage
            }
            return .search(text: text.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        }
    }

    func includesLocalTitle(_ title: String) -> Bool {
        switch self {
        case .songs: return true
        case .search(let text, let kind):
            return kind == .track && !text.isEmpty
                && title.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

/// Concrete binding for Jellyfin and the app-owned selected-folder cache only.
/// It owns no scheduler/player and starts no work until a source is explicitly loaded.
actor FoundationCatalogFetchBinding {
    let query: FoundationCatalogQuery
    let jellyfinSource: FoundationCatalogSource?
    let localSource: FoundationCatalogSource?
    private let jellyfin: FoundationJellyfinLibrary?
    private let local: FoundationLocalSource?
    private let localID: UUID?
    private let composition: FoundationCatalogComposition
    private var localSnapshot: FoundationLocalCatalog?
    private var retired: Set<FoundationCatalogSource> = []
    private var searchSeed: FoundationCatalogSearchSeed?
    private let refreshSearchRelations: Bool

    init(
        query: FoundationCatalogQuery, jellyfin: FoundationJellyfinLibrary?,
        local: FoundationLocalSource?, localID: UUID?,
        searchSeed: FoundationCatalogSearchSeed? = nil,
        refreshSearchRelations: Bool = false
    ) throws {
        guard (local == nil) == (localID == nil) else {
            throw FoundationCatalogComposition.Failure.invalidSource
        }
        self.query = try query.normalized()
        self.jellyfin = jellyfin
        self.local = local
        self.localID = localID
        self.searchSeed = searchSeed
        self.refreshSearchRelations = refreshSearchRelations
        jellyfinSource = try jellyfin.map {
            try FoundationCatalogSource.jellyfin(scope: $0.catalogAccountIdentity)
        }
        localSource = localID.map { .local(sourceID: $0) }
        composition = try FoundationCatalogComposition(jellyfin: jellyfinSource, local: localSource)
    }

    func snapshots() async -> [FoundationCatalogComposition.Snapshot] {
        let values = await composition.snapshots()
        return values.filter { !retired.contains($0.source) }
    }

    func retire(_ source: FoundationCatalogSource) async {
        guard source == jellyfinSource || source == localSource else { return }
        retired.insert(source)
        if source == localSource { localSnapshot = nil }
        await composition.retire(source)
    }

    /// Captured library value freezes the selected Jellyfin music folder. The
    /// account scope never derives from catalogScopeID, which describes that filter.
    func loadJellyfin() async throws {
        try Task.checkCancellation()
        guard let source = jellyfinSource, let jellyfin, !retired.contains(source) else {
            throw FoundationCatalogComposition.Failure.unavailable
        }
        if let seed = searchSeed {
            // Attempt once: a rejected or cancelled seed cannot prevent an explicit fresh Retry.
            searchSeed = nil
            guard case .search(let text, .track) = query, text == seed.query,
                jellyfin.metadataScopeID == seed.metadataScope
            else { throw FoundationCatalogComposition.Failure.stale }
            try await composition.seedSearch(
                source, page: seed.page, supplementalIDs: seed.supplementalIDs,
                fallbackCursor: seed.fallbackCursor)
            try Task.checkCancellation()
            guard !retired.contains(source) else {
                throw FoundationCatalogComposition.Failure.stale
            }
            return
        }
        let query = query
        let snapshot = await composition.snapshots().first { $0.source == source }
        if refreshSearchRelations, case .search(let text, .track) = query,
            snapshot?.state == .idle,
            snapshot?.nextStartIndex == 0
        {
            let fresh = try await FoundationSearchResolver(library: jellyfin)
                .resolveCategory(query: text, kind: .track)
            try Task.checkCancellation()
            guard !retired.contains(source) else {
                throw FoundationCatalogComposition.Failure.stale
            }
            let supplemental = Set(fresh.page.items.map(\.id))
                .subtracting(fresh.direct.originalIDs)
            try await composition.seedSearch(
                source, page: fresh.page, supplementalIDs: supplemental,
                fallbackCursor: fresh.direct.fallbackCursor, incompleteCoverage: fresh.incomplete)
            try Task.checkCancellation()
            guard !retired.contains(source) else {
                throw FoundationCatalogComposition.Failure.stale
            }
            return
        }
        if (snapshot?.seedOverflowCount ?? 0) > 0 {
            try await composition.loadSeedOverflow(source)
            try Task.checkCancellation()
            guard !retired.contains(source) else {
                throw FoundationCatalogComposition.Failure.stale
            }
            return
        }
        if case .search(let text, .track) = query,
            snapshot?.nextStartIndex == nil, let fallback = snapshot?.fallbackCursor
        {
            try await composition.loadSearchFallback(source, query: text) { cursor in
                let page = try await jellyfin.search(
                    query: fallback.term, kind: .track, startIndex: cursor, limit: 50)
                return .init(page: page)
            }
            try Task.checkCancellation()
            guard !retired.contains(source) else {
                throw FoundationCatalogComposition.Failure.stale
            }
            return
        }
        try await composition.load(source) { cursor in
            let page: FoundationPage
            switch query {
            case .songs: page = try await jellyfin.songs(startIndex: cursor)
            case .search(let text, let kind):
                page = try await jellyfin.search(
                    query: text, kind: kind, startIndex: cursor, limit: 50)
            }
            return .init(page: page)
        }
        try Task.checkCancellation()
        guard !retired.contains(source) else { throw FoundationCatalogComposition.Failure.stale }
    }

    /// This reads the persisted index only. Folder access/indexing remain explicit
    /// native-library actions; browsing never silently starts a scan or retry.
    func loadLocal() async throws {
        try Task.checkCancellation()
        guard let source = localSource, let local, let localID, !retired.contains(source) else {
            throw FoundationCatalogComposition.Failure.unavailable
        }
        let cached: FoundationLocalCatalog?
        do {
            cached = try await local.cachedCatalog()
        } catch {
            if !(error is CancellationError) { await retire(source) }
            throw error
        }
        try Task.checkCancellation()
        guard !retired.contains(source) else { throw FoundationCatalogComposition.Failure.stale }
        guard let cached, cached.sourceID == localID else {
            await retire(source)
            throw FoundationCatalogComposition.Failure.invalidSource
        }
        if let localSnapshot, localSnapshot != cached {
            // Refreshed data needs a new bounded result set, not an old offset
            // applied to a changed list. Neither the old nor new records publish.
            await retire(source)
            throw FoundationCatalogComposition.Failure.stale
        }
        localSnapshot = cached
        let query = query
        try await composition.load(source) { cursor in
            try FoundationCatalogComposition.localPage(
                cached, startIndex: cursor, limit: 50, query: query)
        }
        try Task.checkCancellation()
        guard !retired.contains(source) else { throw FoundationCatalogComposition.Failure.stale }
    }

    func route(
        for item: FoundationItem, requiring capability: FoundationCatalogCapabilities
    ) async throws -> FoundationCatalogComposition.Route {
        try Task.checkCancellation()
        let key = try item.catalogKey(legacyJellyfinSource: jellyfinSource)
        guard !retired.contains(key.source) else {
            throw FoundationCatalogComposition.Failure.unavailable
        }
        if item.catalogSource?.kind == .local {
            guard let source = localSource, item.catalogSource == source,
                let local, !retired.contains(source)
            else {
                throw FoundationCatalogComposition.Failure.unavailable
            }
            let selection: FoundationLocalSource.Selection?
            do {
                selection = try await local.selection()
            } catch {
                await retire(source)
                throw error
            }
            guard !retired.contains(source), selection?.sourceID == localID else {
                await retire(source)
                throw FoundationCatalogComposition.Failure.invalidSource
            }
        }
        try Task.checkCancellation()
        let result = try await composition.route(for: item, requiring: capability)
        try Task.checkCancellation()
        guard !retired.contains(key.source) else {
            throw FoundationCatalogComposition.Failure.unavailable
        }
        return result
    }
}
