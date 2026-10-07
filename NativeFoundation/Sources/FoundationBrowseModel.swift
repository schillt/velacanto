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
    private var writePermit = FoundationPageWritePermit()
    private var hasLiveLoad: Bool { isLoading && writePermit.isValid }
    private var pendingRequest = Request.initial
    private(set) var retryRequest = Request.initial

    private var pageCache: FoundationCatalogPageCache?
    private var cacheKey: String?
    private var restoredCache = false
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

    /// Restore before any network work, including when the visible view is offline.
    private func restoreCache() async {
        guard !restoredCache, let pageCache, let cacheKey else { return }
        let owner = revision
        let record = await pageCache.read(cacheKey)
        guard !Task.isCancelled, revision == owner else { return }
        restoredCache = true
        guard !loaded, let record else { return }
        items = record.page.items
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
        items = snapshot
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
            if case .more = request {
                items.append(contentsOf: page.items)
            } else {
                items = page.items
            }
            nextStartIndex = page.nextStartIndex
            loaded = true
            isRetainedSnapshot = false
            if let pageCache, let cacheKey {
                // Persist a bounded prefix; preserve the next offset so truncated pages stay usable.
                let limit = 200
                let retained = Array(items.prefix(limit))
                let next = items.count > limit ? retained.count : nextStartIndex
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
