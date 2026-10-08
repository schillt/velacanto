import SwiftUI

@MainActor
final class FoundationBrowseModel: ObservableObject {
    enum Request { case initial, refresh, more }
    @Published private(set) var items: [FoundationItem] = []
    @Published private(set) var nextStartIndex: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var errorCategory: FoundationLibraryError?
    var hasConnectionIssue: Bool { errorCategory == .network }
    @Published private(set) var errorMessage: String?
    private(set) var loaded = false
    private(set) var isRetainedSnapshot = false
    private var revision = UUID()
    private var catalogRevision = UUID()
    private var writePermit = FoundationPageWritePermit()
    private var hasLiveLoad: Bool { isLoading && writePermit.isValid }
    private var pendingRequest = Request.initial
    private(set) var retryRequest = Request.initial

    private var pageCache: FoundationCatalogPageCache?
    private var cacheKey: String?
    private var restoredCache = false
    private var deduplicatesCatalogItems = false
    private var sortsCatalogByTitle = false
    private var cachedRawPrefix: [FoundationItem] = []
    private var lastRefreshAttempt: Date?
    private let now: () -> Date
    private let refreshInterval: TimeInterval

    init(refreshInterval: TimeInterval = 60, now: @escaping () -> Date = { Date() }) {
        self.refreshInterval = refreshInterval
        self.now = now
    }

    func configureCache(_ cache: FoundationCatalogPageCache?, key: String) {
        guard pageCache !== cache || cacheKey != key else { return }
        clearRetainedData()
        pageCache = cache
        cacheKey = key
    }

    /// Catalog indexes have unique items; collection track lists keep occurrence identity.
    func configureCatalogPagination(sortByTitle: Bool = false) {
        guard !deduplicatesCatalogItems || sortsCatalogByTitle != sortByTitle else { return }
        deduplicatesCatalogItems = true
        sortsCatalogByTitle = sortByTitle
        items = uniqueCatalogItems(items)
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
            nextStartIndex != nil, !Task.isCancelled
        else { return }
        await load(.more, using: loader)
    }

    /// Restore before any network work, including when the visible view is offline.
    private func restoreCache() async {
        guard !restoredCache, let pageCache, let cacheKey else { return }
        let owner = revision
        let record = await pageCache.read(cacheKey)
        guard !Task.isCancelled, revision == owner else { return }
        restoredCache = true
        guard !loaded, let record else { return }
        cachedRawPrefix = Array(record.page.items.prefix(200))
        items = deduplicatesCatalogItems ? uniqueCatalogItems(record.page.items) : record.page.items
        nextStartIndex = record.page.nextStartIndex
        loaded = true
        isRetainedSnapshot = true
    }

    /// Build only from already-loaded songs; preserve repeated occurrences.
    func trackQueue(selecting sourceIndex: Int) -> (items: [FoundationItem], index: Int)? {
        guard items.indices.contains(sourceIndex), items[sourceIndex].kind == .track else {
            return nil
        }
        return (
            items.filter { $0.kind == .track },
            items.prefix(sourceIndex).filter { $0.kind == .track }.count
        )
    }

    /// Install complete known membership without inventing a remote page or filtering occurrences.
    func installSnapshot(_ snapshot: [FoundationItem], complete: Bool = true) {
        writePermit.revoke()
        revision = UUID()
        catalogRevision = UUID()
        cachedRawPrefix = []
        items = deduplicatesCatalogItems ? uniqueCatalogItems(snapshot) : snapshot
        nextStartIndex = nil
        loaded = complete
        isRetainedSnapshot = true
        isLoading = false
        errorMessage = nil
        errorCategory = nil
        pendingRequest = .initial
    }

    func clearRetainedData() {
        writePermit.revoke()
        revision = UUID()
        catalogRevision = UUID()
        cachedRawPrefix = []
        items = []
        nextStartIndex = nil
        loaded = false
        isRetainedSnapshot = false
        isLoading = false
        errorMessage = nil
        errorCategory = nil
        pendingRequest = .initial
        restoredCache = false
        lastRefreshAttempt = nil
    }

    func request(_ request: Request) {
        writePermit.revoke()
        revision = UUID()
        catalogRevision = UUID()
        pendingRequest = request
        isLoading = false
    }

    func loadPending(
        ifActive isActive: Bool = true, allowsNetwork: Bool = true,
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
        await restoreCache()
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

    /// Songs load their full metadata membership on activation, independently of rail gestures.
    /// The view task owns cancellation; each page retains the normal cache and error policy.
    func loadCompleteCatalog(using loader: (Int) async throws -> FoundationPage) async {
        // Revisiting a failed catalog must not turn a cached snapshot into an implicit retry.
        if case .initial = pendingRequest, errorMessage != nil { return }
        if case .initial = pendingRequest, loaded, nextStartIndex == nil,
            !isRetainedSnapshot
        {
            return
        }
        if isRetainedSnapshot { request(.refresh) }
        let owner = catalogRevision
        await loadPending(using: loader)
        while !Task.isCancelled, catalogRevision == owner,
            errorMessage == nil, let offset = nextStartIndex
        {
            await loadNextPage(using: loader)
            guard !Task.isCancelled, nextStartIndex != offset else { return }
        }
    }

    /// The view owns this loop; disappearing/offline transitions cancel its network work.
    func refreshVisible(
        allowsNetwork: Bool, using loader: (Int) async throws -> FoundationPage
    ) async {
        await loadPending(allowsNetwork: allowsNetwork, using: loader)
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
        let offset: Int
        if case .more = request {
            guard !hasLiveLoad else { return }
            guard let nextStartIndex else {
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
        writePermit.revoke()
        let permit = FoundationPageWritePermit()
        writePermit = permit
        revision = owner
        isLoading = true
        lastRefreshAttempt = now()
        errorMessage = nil
        errorCategory = nil
        defer { if revision == owner { isLoading = false } }
        #if DEBUG
            FoundationJournal.shared.record(
                "browse disposition=\(String(describing: request)) \(FoundationTrace.fields)")
        #endif
        do {
            let page = try await withTaskCancellationHandler {
                try await loader(offset)
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
            let (rawEnd, overflow) = offset.addingReportingOverflow(page.items.count)
            guard !overflow else { throw FoundationLibraryError.invalidResponse }
            if deduplicatesCatalogItems, let next = page.nextStartIndex {
                guard next > offset, !page.items.isEmpty else {
                    throw FoundationLibraryError.invalidResponse
                }
            }
            if case .more = request {
                if cachedRawPrefix.count < 200 {
                    cachedRawPrefix.append(
                        contentsOf: page.items.prefix(200 - cachedRawPrefix.count))
                }
                items =
                    deduplicatesCatalogItems
                    ? uniqueCatalogItems(items + page.items) : items + page.items
            } else {
                cachedRawPrefix = Array(page.items.prefix(200))
                items = deduplicatesCatalogItems ? uniqueCatalogItems(page.items) : page.items
            }
            nextStartIndex = page.nextStartIndex
            loaded = true
            isRetainedSnapshot = false
            if let pageCache, let cacheKey {
                // Persist a bounded prefix; preserve the next offset so truncated pages stay usable.
                let limit = 200
                let retained =
                    deduplicatesCatalogItems
                    ? cachedRawPrefix : Array(items.prefix(limit))
                // Cache raw entries so duplicate suppression never changes server offsets.
                let next =
                    deduplicatesCatalogItems
                    ? (rawEnd > limit ? limit : nextStartIndex)
                    : (items.count > limit ? retained.count : nextStartIndex)
                await pageCache.write(
                    FoundationPage(items: retained, nextStartIndex: next), key: cacheKey,
                    permit: permit)
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
            #if DEBUG
                FoundationJournal.shared.record(
                    "browse disposition=failure \(FoundationTrace.fields)")
            #endif
        }
    }
}
