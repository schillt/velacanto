import Combine
import SwiftUI

@MainActor
final class FoundationBrowseModel: ObservableObject {
    enum Request { case initial, refresh, more }

    struct CollectionOwner: Equatable, Hashable, Sendable {
        let sourceScope: String
        let kind: FoundationItem.Kind
        let itemID: String
    }

    struct CollectionOccurrence: Identifiable, Equatable, Sendable {
        struct ID: Hashable, Sendable {
            let owner: CollectionOwner
            let token: UUID
        }
        let id: ID
        let item: FoundationItem
    }

    // Configured only by the existing account-owned collectionModels factory.
    // TrackList reads each admitted item/token pair atomically from this payload.
    @Published private(set) var collectionOccurrences: [CollectionOccurrence] = []
    // Current admission is one paired payload and advances BEFORE Published
    // willSet/objectWillChange can invoke a held action against its old getter.
    private var admittedCollectionOccurrences: [CollectionOccurrence] = []
    private var collectionOwner: CollectionOwner?

    private struct CollectionKey: Hashable {
        let kind: FoundationItem.Kind
        let itemID: String
        let membershipID: String?
    }

    func configureCollectionOccurrences(sourceScope: String, collection: FoundationItem) {
        guard [.album, .playlist, .track].contains(collection.kind), !deduplicatesCatalogItems
        else {
            return
        }
        let owner = CollectionOwner(
            sourceScope: sourceScope, kind: collection.kind, itemID: collection.id)
        guard owner != collectionOwner else { return }
        if collectionOwner != nil { clearRetainedData() }
        collectionOwner = owner
        if !rawItems.isEmpty {
            let admitted = replacementOccurrences(rawItems, owner: owner)
            admittedCollectionOccurrences = admitted
            collectionOccurrences = admitted
        }
    }

    /// Reuse only source-proven identity. Anonymous replacements retire their
    /// old tokens rather than guessing which identical membership survived.
    private func replacementOccurrences(_ items: [FoundationItem], owner: CollectionOwner)
        -> [CollectionOccurrence]
    {
        func counts(_ items: [FoundationItem]) -> (
            memberships: [String: Int], items: [CollectionKey: Int]
        ) {
            var memberships: [String: Int] = [:]
            var entities: [CollectionKey: Int] = [:]
            for item in items {
                if let id = item.playlistEntryID, !id.isEmpty { memberships[id, default: 0] += 1 }
                entities[
                    CollectionKey(kind: item.kind, itemID: item.id, membershipID: nil), default: 0] +=
                    1
            }
            return (memberships, entities)
        }
        func key(
            _ item: FoundationItem,
            counts: (memberships: [String: Int], items: [CollectionKey: Int])
        )
            -> CollectionKey?
        {
            guard !item.id.isEmpty else { return nil }
            if owner.kind == .playlist {
                guard let membership = item.playlistEntryID, !membership.isEmpty,
                    membership.utf8.count <= 128, counts.memberships[membership] == 1
                else { return nil }
                return CollectionKey(kind: item.kind, itemID: item.id, membershipID: membership)
            }
            let entity = CollectionKey(kind: item.kind, itemID: item.id, membershipID: nil)
            return counts.items[entity] == 1 ? entity : nil
        }
        let previousCounts = counts(admittedCollectionOccurrences.map(\.item))
        let currentCounts = counts(items)
        var previous: [CollectionKey: CollectionOccurrence.ID] = [:]
        for occurrence in admittedCollectionOccurrences where occurrence.id.owner == owner {
            if let key = key(occurrence.item, counts: previousCounts) {
                previous[key] = occurrence.id
            }
        }
        return items.map { item in
            let retained = key(item, counts: currentCounts).flatMap { previous[$0] }
            return CollectionOccurrence(
                id: retained ?? CollectionOccurrence.ID(owner: owner, token: UUID()), item: item)
        }
    }

    /// Existing rawItems observers retain their original publication semantics.
    /// The additional item/token payload is committed together, only for collections.
    private func publishRawItems(
        _ items: [FoundationItem], appending suffix: [FoundationItem]? = nil
    ) {
        let occurrences: [CollectionOccurrence]?
        if let owner = collectionOwner {
            if let suffix {
                // This is the actual owner append operation, not index/rank matching.
                occurrences =
                    admittedCollectionOccurrences
                    + suffix.map {
                        CollectionOccurrence(id: .init(owner: owner, token: UUID()), item: $0)
                    }
            } else {
                occurrences = replacementOccurrences(items, owner: owner)
            }
        } else {
            occurrences = nil
        }
        // Commit the complete paired payload first. Existing rawItems publishers
        // still receive their original value/willSet behavior, and a subscriber
        // receiving the new raw array can already read its matching token payload.
        if let occurrences {
            admittedCollectionOccurrences = occurrences
            collectionOccurrences = occurrences
        }
        rawItems = items
    }
    func visibleCollectionOccurrences(
        using actions: FoundationLibraryActions, albumID: String? = nil,
        isAvailable: @escaping (FoundationItem) -> Bool = { _ in true }
    ) -> [CollectionOccurrence] {
        guard let collectionOwner,
            actions.acceptsCatalogAccount(collectionOwner.sourceScope)
        else { return [] }
        let snapshot = admittedCollectionOccurrences
        let indices = actions.visibleTrackSourceIndices(
            snapshot.map(\.item), albumID: albumID, isAvailable: isAvailable)
        return indices.map { snapshot[$0] }
    }

    /// Resolve the exact current projected occurrence BEFORE the unchanged queue
    /// helper remaps unavailable songs. A raw or filtered offset is never an ID.
    func collectionTrackQueue(
        selecting id: CollectionOccurrence.ID, using actions: FoundationLibraryActions,
        albumID: String? = nil, isAvailable: @escaping (FoundationItem) -> Bool = { _ in true }
    ) -> FoundationTrackQueueSelection? {
        let rows = visibleCollectionOccurrences(
            using: actions, albumID: albumID, isAvailable: isAvailable)
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return FoundationTrackQueueSelection(
            in: rows.map(\.item), selecting: index, isAvailable: isAvailable)
    }

    // Unlike a request revision, this changes only when the retained catalog
    // context is cleared. A harmless refresh keeps logical row actions valid.
    private(set) var catalogIdentityContext = UUID()
    var hasUniqueCatalogIdentity: Bool { deduplicatesCatalogItems }
    @Published private(set) var rawItems: [FoundationItem] = [] {
        didSet {
            favoriteActions?.observeTrackCopies(rawItems)
            refreshTrackProjection()
        }
    }
    @Published private(set) var items: [FoundationItem] = []
    private func refreshTrackProjection() {
        let projected = favoriteActions?.visibleTracks(rawItems) ?? rawItems
        if projected != items { items = projected }
    }
    private var trackProjectionObservation: AnyCancellable?
    /// Separate streams: nextStartIndex always remains the original provider offset.
    struct SearchRefresh {
        let seed: FoundationSearchResolver.CategorySeed
        let fallback: FoundationSearchResolver.FallbackCursor?
        let coverageMessage: String?
    }

    struct SearchContinuation {
        let query: String
        let kind: FoundationItem.Kind
        let metadataScope: String
        let fetch: (String, FoundationItem.Kind, Int) async throws -> FoundationPage
        let refresh: (() async throws -> SearchRefresh)?
    }
    private var searchContinuation: SearchContinuation?
    var searchRefreshEnabled = true
    @Published private(set) var searchRefreshCoverageMessage: String?
    private(set) var hasRefreshedSearchRelations = false
    @Published private(set) var searchFallbackCursor: FoundationSearchResolver.FallbackCursor?
    // A combined overview cannot establish a contiguous raw provider-cache prefix.
    // Only successful replacement by an offset-zero read restores that provenance.
    private var searchSeedOwnsMembership = false
    private var searchSeedLease: FoundationSearchSeedLease?
    private var searchSeedOverflow: [FoundationItem] = []
    @Published private(set) var searchSeedOverflowCount = 0
    var hasMorePages: Bool {
        searchSeedOverflowCount > 0 || nextStartIndex != nil || searchFallbackCursor != nil
    }

    func configureSearchContinuation(
        query: String, kind: FoundationItem.Kind, metadataScope: String,
        fallback: FoundationSearchResolver.FallbackCursor?,
        seed: FoundationSearchResolver.CategorySeed? = nil,
        seedLease: FoundationSearchSeedLease? = nil,
        refresh: (() async throws -> SearchRefresh)? = nil,
        fetch: @escaping (String, FoundationItem.Kind, Int) async throws -> FoundationPage
    ) {
        guard !loaded, !isLoading else { return }
        if let seed,
            seed.kind != nil && seed.kind != kind || !catalogLimits.canRetain(seed.cost)
                || (seedLease.map { !$0.matches(seed.page) } ?? false)
        {
            errorCategory = .invalidResponse
            errorMessage = FoundationLibraryError.invalidResponse.errorDescription
            return
        }
        searchContinuation = .init(
            query: query, kind: kind, metadataScope: metadataScope, fetch: fetch, refresh: refresh)
        searchFallbackCursor = fallback
        searchSeedOwnsMembership = seed != nil
        searchSeedLease = seed.map { seedLease ?? FoundationSearchSeedLease(page: $0.page) }
        searchSeedOverflow = seed?.remaining ?? []
        searchSeedOverflowCount = searchSeedOverflow.count
    }

    @Published private(set) var nextStartIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorCategory: FoundationLibraryError?
    var hasConnectionIssue: Bool { errorCategory == .network }
    @Published private(set) var errorMessage: String?
    private(set) var loaded = false
    private(set) var isRetainedSnapshot = false
    private var revision = UUID()
    private var writePermit = FoundationPageWritePermit()
    private var hasLiveLoad: Bool { isLoading && writePermit.isValid }
    // A revoked write permit does not mean the underlying request has unwound.
    private var executingLoads: Set<UUID> = []
    private var initialDemandEpoch = UUID()
    private var initialLoadWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    var pendingInitialLoadDemandCount: Int { initialLoadWaiters.count }
    private var pendingRequest = Request.initial
    private(set) var retryRequest = Request.initial

    var hasFreshCachedContent: Bool {
        usesCachedFreshness
            && (lastRefreshAttempt.map { now().timeIntervalSince($0) < refreshInterval } ?? false)
    }
    private let usesCachedFreshness: Bool
    private var pageCache: FoundationCatalogPageCache?
    private var cacheKey: String?
    private var restoredCache = false
    private var deduplicatesCatalogItems = false
    private var sortsCatalogByTitle = false
    private var catalogBudget: FoundationCatalogBudget
    private let catalogLimits: FoundationCatalogBudget
    private var cachedRawPrefix: [FoundationItem] = []
    private var lastRefreshAttempt: Date?
    private let now: () -> Date
    private let refreshInterval: TimeInterval
    private let onLoadSettled: (() -> Void)?
    private weak var favoriteActions: FoundationLibraryActions?
    private var observesFavoriteMembership = false
    private var favoriteRefreshCandidates: [FoundationItem] = []
    private var favoriteRefreshRead: FoundationLibraryActions.FavoriteRead?

    func configureFavoriteObservations(
        _ actions: FoundationLibraryActions, knownFavorites: Bool = false
    ) {
        favoriteActions = actions
        actions.observeTrackCopies(rawItems)
        trackProjectionObservation = actions.$trackVisibilityRevision.dropFirst().sink {
            [weak self] _ in
            self?.refreshTrackProjection()
        }
        refreshTrackProjection()
        observesFavoriteMembership = knownFavorites
    }

    init(
        refreshInterval: TimeInterval = 60, now: @escaping () -> Date = { Date() },
        catalogLimits: FoundationCatalogBudget = FoundationCatalogBudget(),
        usesCachedFreshness: Bool = false, onLoadSettled: (() -> Void)? = nil
    ) {
        self.usesCachedFreshness = usesCachedFreshness
        self.catalogLimits = catalogLimits
        self.catalogBudget = catalogLimits
        self.refreshInterval = refreshInterval
        self.now = now
        self.onLoadSettled = onLoadSettled
    }

    func configureCache(_ cache: FoundationCatalogPageCache?, key: String) {
        guard pageCache !== cache || cacheKey != key else { return }
        clearRetainedData()
        pageCache = cache
        cacheKey = key
    }

    /// Catalog indexes have unique rawItems; collection track lists keep occurrence identity.
    func configureCatalogPagination(sortByTitle: Bool = false) {
        guard collectionOwner == nil else { return }
        guard !deduplicatesCatalogItems || sortsCatalogByTitle != sortByTitle else { return }
        deduplicatesCatalogItems = true
        sortsCatalogByTitle = sortByTitle
        publishRawItems(uniqueCatalogItems(rawItems))
    }

    private func uniqueCatalogItems(_ candidates: [FoundationItem]) -> [FoundationItem] {
        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert($0.kind.rawValue + ":" + $0.id).inserted }
        return sortsCatalogByTitle ? FoundationAlphabetAnchors.sorted(unique) : unique
    }

    /// One visible demand fetches one bounded server page. Errors require explicit retry.
    func loadNextPage(
        ifActive isActive: Bool = true, allowsNetwork: Bool = true,
        using loader: (Int) async throws -> FoundationPage
    ) async {
        guard isActive, allowsNetwork, !hasLiveLoad, errorMessage == nil,
            hasMorePages, !Task.isCancelled
        else { return }
        await load(.more, using: loader)
    }

    /// A visible pagination footer waits for its current publication, then consumes
    /// one bounded page. Its view task owns cancellation; failures still require Retry.
    func loadNextVisiblePage(
        ifActive isActive: @MainActor () -> Bool = { true },
        allowsNetwork: @MainActor () -> Bool = { true },
        using loader: (Int) async throws -> FoundationPage
    ) async {
        guard isActive(), allowsNetwork(), hasMorePages, !Task.isCancelled else { return }
        let demandEpoch = initialDemandEpoch
        if !loaded, errorMessage == nil {
            // A category footer may appear before its overview seed is settled.
            // Join the existing initial owner instead of consuming and losing demand.
            await loadPending(
                ifActive: isActive(), allowsNetwork: allowsNetwork(),
                waitForInitialLoad: true, using: loader)
        }
        for await _ in $isLoading.filter({ !$0 }).values {
            guard !Task.isCancelled, demandEpoch == initialDemandEpoch,
                isActive(), allowsNetwork()
            else { return }
            await loadNextPage(ifActive: isActive(), allowsNetwork: allowsNetwork(), using: loader)
            return
        }
    }

    /// Restore before any network work, including when the visible view is offline.
    private func restoreCache() async {
        // The overview snapshot owns initial demand; it is not a fresh provider page.
        guard !restoredCache, searchSeedLease?.pending != true, let pageCache, let cacheKey else {
            return
        }
        let owner = revision
        #if DEBUG
            let cacheTiming = FoundationLoadTiming(.snapshot)
            cacheTiming.record(.cacheReadStarted)
        #endif
        let record = await pageCache.read(cacheKey)
        #if DEBUG
            cacheTiming.record(.cacheReadFinished)
        #endif
        guard !Task.isCancelled, revision == owner else { return }
        restoredCache = true
        guard !loaded, let record else { return }
        if deduplicatesCatalogItems {
            guard let cost = catalogBudget.cost(of: record.page),
                catalogBudget.canRetain(cost)
            else { return }
            catalogBudget.retainedItems += cost.items
            catalogBudget.retainedBytes += cost.bytes
        }
        cachedRawPrefix = Array(record.page.items.prefix(200))
        publishRawItems(
            deduplicatesCatalogItems ? uniqueCatalogItems(record.page.items) : record.page.items)
        nextStartIndex = record.page.nextStartIndex
        loaded = true
        isRetainedSnapshot = true
        if usesCachedFreshness { lastRefreshAttempt = record.savedAt }
        #if DEBUG
            cacheTiming.record(.published)
        #endif
    }

    /// Build only from already-loaded songs; preserve repeated occurrences.
    func trackQueue(
        selecting sourceIndex: Int, isAvailable: (FoundationItem) -> Bool = { _ in true }
    ) -> FoundationTrackQueueSelection? {
        FoundationTrackQueueSelection(in: items, selecting: sourceIndex, isAvailable: isAvailable)
    }

    /// Install complete known membership without inventing a remote page or filtering occurrences.
    func installSnapshot(_ snapshot: [FoundationItem], complete: Bool = true) {
        invalidateInitialDemands()
        favoriteRefreshCandidates = []
        favoriteRefreshRead = nil
        writePermit.revoke()
        revision = UUID()
        cachedRawPrefix = []
        publishRawItems(deduplicatesCatalogItems ? uniqueCatalogItems(snapshot) : snapshot)
        nextStartIndex = nil
        searchFallbackCursor = nil
        searchRefreshCoverageMessage = nil
        hasRefreshedSearchRelations = false
        searchSeedLease?.invalidate()
        searchSeedLease = nil
        searchSeedOwnsMembership = false
        searchSeedOverflow = []
        searchSeedOverflowCount = 0
        loaded = complete
        isRetainedSnapshot = true
        lastRefreshAttempt = nil
        isLoading = false
        errorMessage = nil
        errorCategory = nil
        pendingRequest = .initial
        resetCatalogBudget()
    }

    func clearRetainedData() {
        invalidateInitialDemands()
        favoriteRefreshCandidates = []
        favoriteRefreshRead = nil
        writePermit.revoke()
        revision = UUID()
        cachedRawPrefix = []
        publishRawItems([])
        nextStartIndex = nil
        searchFallbackCursor = nil
        searchRefreshCoverageMessage = nil
        hasRefreshedSearchRelations = false
        searchSeedLease?.invalidate()
        searchSeedLease = nil
        searchSeedOwnsMembership = false
        searchSeedOverflow = []
        searchSeedOverflowCount = 0
        loaded = false
        isRetainedSnapshot = false
        isLoading = false
        errorMessage = nil
        errorCategory = nil
        pendingRequest = .initial
        restoredCache = false
        lastRefreshAttempt = nil
        resetCatalogBudget()
        // A synchronous willChange observer can still see the previous items.
        // Retire every such captured action only after the clear is complete.
        catalogIdentityContext = UUID()
    }

    func request(_ request: Request) {
        invalidateInitialDemands()
        writePermit.revoke()
        revision = UUID()
        pendingRequest = request
        isLoading = false
    }

    private func resetCatalogBudget() {
        catalogBudget = catalogLimits
    }

    func loadPending(
        ifActive isActive: Bool = true, allowsNetwork: Bool = true,
        waitForInitialLoad: Bool = false,
        using loader: (Int) async throws -> FoundationPage
    ) async {
        guard isActive, !Task.isCancelled else {
            #if DEBUG
                let disposition = isActive ? "cancelled-before-load" : "inactive"
                FoundationJournal.shared.record(
                    "browse disposition=\(disposition) \(FoundationTrace.fields)")
            #endif
            return
        }
        let demandEpoch = initialDemandEpoch
        await restoreCache()
        if waitForInitialLoad, case .initial = pendingRequest, !loaded, errorMessage == nil {
            guard allowsNetwork, demandEpoch == initialDemandEpoch else { return }
            // Keep visible initial demand alive when another view owns the same model.
            // Successful or failed work satisfies demand; only abandonment hands it over.
            while !executingLoads.isEmpty {
                await waitForExecutingLoad()
                guard !Task.isCancelled, demandEpoch == initialDemandEpoch else { return }
                if loaded || errorMessage != nil { return }
            }
            guard !Task.isCancelled, demandEpoch == initialDemandEpoch else { return }
        }
        guard allowsNetwork, !Task.isCancelled, !hasLiveLoad else { return }
        var request = pendingRequest
        if case .initial = request, pageCache != nil, loaded {
            guard !hasLiveLoad,
                lastRefreshAttempt.map({ now().timeIntervalSince($0) >= refreshInterval }) ?? true
            else { return }
            request = .refresh
        }
        pendingRequest = .initial
        await load(request, using: loader)
    }

    private func waitForExecutingLoad() async {
        let waiter = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard !Task.isCancelled, !executingLoads.isEmpty else {
                    continuation.resume()
                    return
                }
                initialLoadWaiters[waiter] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.initialLoadWaiters.removeValue(forKey: waiter)?.resume()
            }
        }
    }

    private func resumeInitialLoadWaiters() {
        let waiters = initialLoadWaiters.values
        initialLoadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func invalidateInitialDemands() {
        initialDemandEpoch = UUID()
        resumeInitialLoadWaiters()
    }

    /// Activation loads one page; further membership comes only from visible demand.
    func loadCatalogPage(using loader: (Int) async throws -> FoundationPage) async {
        if case .initial = pendingRequest, errorMessage != nil { return }
        if isRetainedSnapshot { request(.refresh) }
        await loadPending(using: loader)
    }

    /// The view owns this loop; disappearing/offline transitions cancel its network work.
    func refreshVisible(
        allowsNetwork: Bool, using loader: (Int) async throws -> FoundationPage
    ) async {
        // A replacement visible owner must retain its initial demand until any
        // abandoned request unwinds, rather than sleeping through an empty page.
        await loadPending(
            allowsNetwork: allowsNetwork, waitForInitialLoad: true, using: loader)
        guard allowsNetwork, pageCache != nil, errorMessage == nil else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(max(1, refreshInterval))) } catch { return }
            await loadPending(allowsNetwork: allowsNetwork, using: loader)
            if errorMessage != nil { return }
        }
    }

    func load(_ request: Request, using loader: (Int) async throws -> FoundationPage) async {
        guard !Task.isCancelled else {
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=cancelled-before-load \(FoundationTrace.fields)")
            #endif
            return
        }
        if case .initial = request, loaded || errorMessage != nil {
            #if DEBUG
                let reason = loaded ? "loaded" : "error"
                FoundationJournal.shared.record(
                    "browse disposition=retained reason=\(reason) \(FoundationTrace.fields)")
            #endif
            return
        }
        if case .refresh = request { searchSeedLease?.invalidate() }
        let initialSeedPage: FoundationPage?
        if case .initial = request {
            initialSeedPage = searchSeedLease?.offer(eligible: true)
        } else {
            initialSeedPage = nil
        }
        let offset: Int
        let seedPage: [FoundationItem]
        if case .more = request {
            seedPage = Array(searchSeedOverflow.prefix(FoundationCatalogComposition.pageLimit))
        } else {
            seedPage = []
        }
        let fallback: FoundationSearchResolver.FallbackCursor?
        if case .more = request, seedPage.isEmpty, nextStartIndex == nil {
            fallback = searchFallbackCursor
        } else {
            fallback = nil
        }
        if case .more = request {
            guard !hasLiveLoad, searchSeedLease?.pending != true,
                !searchSeedOwnsMembership || loaded
            else { return }
            guard
                let nextStartIndex = seedPage.isEmpty
                    ? (nextStartIndex ?? fallback?.nextStartIndex) : 0
            else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=retained reason=complete \(FoundationTrace.fields)")
                #endif
                return
            }
            offset = nextStartIndex
        } else {
            offset = 0
        }
        if case .initial = request { retryRequest = .refresh } else { retryRequest = request }
        let owner = UUID()
        let actions = favoriteActions
        let refreshSearch: (() async throws -> SearchRefresh)?
        if case .more = request {
            refreshSearch = nil
        } else {
            refreshSearch =
                searchRefreshEnabled && initialSeedPage == nil
                ? searchContinuation?.refresh : nil
        }
        let isRetainedSeed = initialSeedPage != nil || !seedPage.isEmpty || refreshSearch != nil
        var refreshedSearch: SearchRefresh?
        let favoriteRead = !isRetainedSeed ? actions?.beginFavoriteRead() : nil
        let knownFavorites = observesFavoriteMembership
        writePermit.revoke()
        let permit = FoundationPageWritePermit()
        writePermit = permit
        revision = owner
        isLoading = true
        if !isRetainedSeed { lastRefreshAttempt = now() }
        errorMessage = nil
        errorCategory = nil
        executingLoads.insert(owner)
        defer {
            if revision == owner { isLoading = false }
            executingLoads.remove(owner)
            resumeInitialLoadWaiters()
        }
        #if DEBUG
            FoundationJournal.shared.record(
                "browse disposition=\(String(describing: request)) \(FoundationTrace.fields)")
        #endif
        do {
            if deduplicatesCatalogItems {
                if case .more = request, seedPage.isEmpty {
                    guard catalogBudget.canRequestPage else {
                        throw FoundationLibraryError.invalidResponse
                    }
                    catalogBudget.requestedPages += 1
                }
            }
            #if DEBUG
                let timing = FoundationLoadTiming(.catalog)
            #endif
            let page = try await withTaskCancellationHandler {
                if let refreshSearch {
                    let fresh = try await refreshSearch()
                    try Task.checkCancellation()
                    refreshedSearch = fresh
                    return fresh.seed.page
                }
                if let initialSeedPage { return initialSeedPage }
                if !seedPage.isEmpty { return FoundationPage(items: seedPage, nextStartIndex: nil) }
                if let fallback, let searchContinuation {
                    return try await searchContinuation.fetch(
                        fallback.term, searchContinuation.kind, fallback.nextStartIndex)
                }
                #if DEBUG
                    return try await FoundationLoadTiming.$current.withValue(timing) {
                        try await loader(offset)
                    }
                #else
                    return try await loader(offset)
                #endif
            } onCancel: {
                permit.revoke()
            }
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=load-returned result=success \(FoundationTrace.fields)")
            #endif
            guard !Task.isCancelled, revision == owner else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=publication-discarded \(FoundationTrace.fields)")
                #endif
                return
            }
            if let refreshedSearch {
                guard refreshedSearch.seed.kind == searchContinuation?.kind,
                    catalogLimits.canRetain(refreshedSearch.seed.cost)
                else { throw FoundationLibraryError.invalidResponse }
            }
            let (rawEnd, overflow) = offset.addingReportingOverflow(page.items.count)
            guard !overflow else { throw FoundationLibraryError.invalidResponse }
            if deduplicatesCatalogItems, let next = page.nextStartIndex {
                guard next > offset,
                    !page.items.isEmpty || (offset == 0 && searchContinuation != nil)
                else {
                    throw FoundationLibraryError.invalidResponse
                }
            }
            if deduplicatesCatalogItems {
                var budget: FoundationCatalogBudget
                if case .more = request {
                    budget = catalogBudget
                } else {
                    budget = catalogLimits
                    budget.requestedPages = isRetainedSeed ? 0 : 1
                }
                // Count raw entries, including duplicates, before concatenation or title sorting.
                guard let cost = budget.cost(of: page) else {
                    throw FoundationLibraryError.invalidResponse
                }
                guard budget.canRetain(cost) else {
                    throw FoundationLibraryError.invalidResponse
                }
                budget.retainedItems += cost.items
                budget.retainedBytes += cost.bytes
                catalogBudget = budget
            }
            let visibleItems: [FoundationItem]
            if fallback != nil, let searchContinuation {
                visibleItems = page.items.filter {
                    $0.kind == searchContinuation.kind
                        && FoundationSearchResolver.titleScore(
                            $0.title, query: searchContinuation.query) >= 60
                }
            } else {
                visibleItems = page.items
            }
            if offset == 0, !isRetainedSeed {
                // Keep only this destination's previous membership, not account-wide guesses.
                favoriteRefreshCandidates = knownFavorites ? rawItems : []
                favoriteRefreshRead = favoriteRead
            }
            if case .more = request {
                if seedPage.isEmpty, !searchSeedOwnsMembership, cachedRawPrefix.count < 200 {
                    cachedRawPrefix.append(
                        contentsOf: page.items.prefix(200 - cachedRawPrefix.count))
                }
                publishRawItems(
                    deduplicatesCatalogItems
                        ? uniqueCatalogItems(rawItems + visibleItems) : rawItems + visibleItems,
                    appending: visibleItems)
            } else {
                if !isRetainedSeed { cachedRawPrefix = Array(page.items.prefix(200)) }
                publishRawItems(
                    deduplicatesCatalogItems ? uniqueCatalogItems(page.items) : page.items)
            }
            if let refreshedSearch {
                nextStartIndex = page.nextStartIndex
                searchSeedOwnsMembership = true
                searchFallbackCursor = refreshedSearch.fallback
                searchSeedOverflow = refreshedSearch.seed.remaining
                searchSeedOverflowCount = searchSeedOverflow.count
                cachedRawPrefix = []
                hasRefreshedSearchRelations = true
                searchRefreshCoverageMessage = refreshedSearch.coverageMessage
            } else if !seedPage.isEmpty {
                searchSeedOverflow.removeFirst(seedPage.count)
                searchSeedOverflowCount = searchSeedOverflow.count
            } else if let fallback {
                searchFallbackCursor = page.nextStartIndex.map {
                    .init(term: fallback.term, nextStartIndex: $0)
                }
            } else {
                nextStartIndex = page.nextStartIndex
                if case .refresh = request {
                    searchSeedOwnsMembership = false
                    searchFallbackCursor = nil
                    searchSeedOverflow = []
                    searchSeedOverflowCount = 0
                }
            }
            loaded = true
            isRetainedSnapshot = false
            if initialSeedPage != nil { searchSeedLease?.settle() }
            onLoadSettled?()
            if !isRetainedSeed, let actions, let favoriteRead {
                actions.observeFavorites(
                    in: page.items, knownFavorites: knownFavorites, read: favoriteRead)
                if knownFavorites, page.nextStartIndex == nil, let read = favoriteRefreshRead {
                    let membership = Set(rawItems.map { $0.kind.rawValue + ":" + $0.id })
                    let removed = favoriteRefreshCandidates.compactMap { item -> FoundationItem? in
                        guard !membership.contains(item.kind.rawValue + ":" + item.id) else {
                            return nil
                        }
                        var item = item
                        item.isFavorite = false
                        return item
                    }
                    actions.observeFavorites(in: removed, read: read)
                    favoriteRefreshCandidates = []
                    favoriteRefreshRead = nil
                }
            }
            #if DEBUG
                timing.record(.published)
            #endif
            if !isRetainedSeed, !searchSeedOwnsMembership, let pageCache, let cacheKey {
                #if DEBUG
                    timing.record(.persistStarted)
                #endif
                // Persist a bounded prefix; preserve the next offset so truncated pages stay usable.
                let limit = 200
                let retained =
                    deduplicatesCatalogItems
                    ? cachedRawPrefix : Array(rawItems.prefix(limit))
                // Cache raw entries so duplicate suppression never changes server offsets.
                let next =
                    deduplicatesCatalogItems
                    ? (rawEnd > limit ? limit : nextStartIndex)
                    : (rawItems.count > limit ? retained.count : nextStartIndex)
                await pageCache.write(
                    FoundationPage(items: retained, nextStartIndex: next), key: cacheKey,
                    permit: permit)
                #if DEBUG
                    timing.record(.persistFinished)
                #endif
            }
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=publication-committed \(FoundationTrace.fields)")
            #endif
        } catch {
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=load-returned result=failure \(FoundationTrace.fields)")
            #endif
            guard !Task.isCancelled, revision == owner else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "browse disposition=publication-discarded \(FoundationTrace.fields)")
                #endif
                return
            }
            errorCategory = FoundationLibraryError.category(error)
            errorMessage = errorCategory?.errorDescription
            if initialSeedPage != nil { searchSeedLease?.settle() }
            onLoadSettled?()
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=failure \(FoundationTrace.fields)")
            #endif
        }
    }
}

/// A lifetime ceiling for one catalog membership, reset only by replacement or scope reset.
struct FoundationCatalogBudget {
    var maximumPages: Int = 2_000
    var maximumItems: Int = 100_000
    var maximumBytes: Int = 128 * 1_024 * 1_024
    var requestedPages = 0
    var retainedItems = 0
    var retainedBytes = 0

    var canRequestPage: Bool {
        requestedPages < maximumPages && retainedItems < maximumItems
            && retainedBytes < maximumBytes
    }

    func canRetain(_ cost: (items: Int, bytes: Int)) -> Bool {
        cost.items <= maximumItems - retainedItems
            && cost.bytes <= maximumBytes - retainedBytes
    }

    func cost(of page: FoundationPage) -> (items: Int, bytes: Int)? {
        guard page.items.count <= 200 else { return nil }
        var bytes = 0
        func addBytes(_ count: Int) -> Bool {
            guard count <= maximumBytes - bytes else { return false }
            bytes += count
            return true
        }
        func add(_ text: String?) -> Bool {
            addBytes(text?.utf8.count ?? 0)
        }
        func reference(_ value: FoundationItemReference?) -> Bool {
            guard let value else { return true }
            return addBytes(MemoryLayout<FoundationItemReference>.stride)
                && add(value.id) && add(value.title) && add(value.primaryImageTag)
        }
        for item in page.items {
            guard addBytes(MemoryLayout<FoundationItem>.stride),
                add(item.id), add(item.title), add(item.subtitle), add(item.primaryImageTag),
                add(item.sortName), reference(item.album), reference(item.artist)
            else { return nil }
            for genre in item.genres { guard reference(genre) else { return nil } }
        }
        return (page.items.count, bytes)
    }
}
