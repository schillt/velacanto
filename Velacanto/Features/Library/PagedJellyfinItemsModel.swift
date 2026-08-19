import SwiftUI

/// Owns one paged catalog snapshot for a SwiftUI screen.
///
/// The model is main-actor isolated. Each reset advances the generation and
/// cancels only its internally-owned pagination task, so a late loader, cache,
/// or retry result can never update a newer query. A cursor belongs only to its
/// generation and is passed unchanged to the next request. Cached snapshots are
/// hydrated immediately; the first refreshed page replaces matching cached items
/// but retains cached later pages, so an in-flight refresh never shrinks a visible
/// paged collection. New pages preserve the existing server order, then append
/// only first-seen item IDs in page order.
///
/// Transient failures retry twice with a short backoff; terminal failures become
/// `errorMessage` for the view to present. Cancellation is expected during view
/// changes and leaves no error state. See `docs/architecture.md` for the
/// catalog snapshot and paging boundary.
@MainActor
final class PagedMusicCatalogModel: ObservableObject {
    typealias Loader = (MusicCatalogCursor?) async throws -> MusicCatalogPage
    typealias CacheLoader = () async -> [MusicCatalogItem]
    typealias CacheWriter = ([MusicCatalogItem]) async -> Void

    @Published private(set) var items: [MusicCatalogItem] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var totalRecordCount = 0
    @Published private(set) var errorMessage: String?

    private var cursor: MusicCatalogCursor?
    private var generation = UUID()
    private var paginationTask: Task<Void, Never>?
    private var paginationTaskID: UUID?

    func reset(
        debounce: Duration? = nil,
        cachedItems: CacheLoader? = nil,
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        paginationTask?.cancel()
        paginationTask = nil
        paginationTaskID = nil
        isLoadingMore = false
        let currentGeneration = UUID()
        generation = currentGeneration
        cursor = nil
        hasMore = true
        totalRecordCount = 0
        errorMessage = nil

        if let cachedItems {
            let cached = await cachedItems()
            guard generation == currentGeneration else { return }
            items = cached
        } else {
            items = []
        }
        isInitialLoading = items.isEmpty

        if let debounce {
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
        }
        guard generation == currentGeneration else { return }
        await loadNext(
            generation: currentGeneration,
            replacing: true,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    @discardableResult
    func loadMoreIfNeeded(
        itemID: MusicCatalogItemID,
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) -> Task<Void, Never>? {
        guard
            hasMore,
            let index = items.firstIndex(where: { $0.id == itemID }),
            index >= max(items.count - 10, 0)
        else {
            return paginationTask
        }
        guard paginationTask == nil else { return paginationTask }

        let currentGeneration = generation
        let taskID = UUID()
        paginationTaskID = taskID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await loadNext(
                generation: currentGeneration,
                replacing: false,
                loader: loader,
                cacheWriter: cacheWriter
            )
            guard paginationTaskID == taskID else { return }
            paginationTask = nil
            paginationTaskID = nil
        }
        paginationTask = task
        return task
    }

    func retry(
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        await loadNext(
            generation: generation,
            replacing: items.isEmpty,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    func loadNextPage(
        loader: @escaping Loader,
        cacheWriter: CacheWriter? = nil
    ) async {
        await loadNext(
            generation: generation,
            replacing: false,
            loader: loader,
            cacheWriter: cacheWriter
        )
    }

    private func loadNext(
        generation currentGeneration: UUID,
        replacing: Bool,
        loader: @escaping Loader,
        cacheWriter: CacheWriter?
    ) async {
        guard !isLoadingMore, replacing || hasMore else { return }
        isLoadingMore = true
        if replacing, items.isEmpty {
            isInitialLoading = true
        }
        errorMessage = nil
        defer {
            if generation == currentGeneration {
                isLoadingMore = false
                isInitialLoading = false
            }
        }

        var retryCount = 0
        while true {
            do {
                let page = try await loader(replacing ? nil : cursor)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }

                if replacing {
                    items = mergedInitialPage(page.items, with: items)
                } else {
                    var seen = Set(items.map(\.id))
                    items.append(
                        contentsOf: page.items.filter {
                            seen.insert($0.id).inserted
                        }
                    )
                }
                cursor = page.cursor
                hasMore = page.hasMore
                totalRecordCount = max(page.totalRecordCount, items.count)
                if let cacheWriter {
                    await cacheWriter(items)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else {
                    return
                }
                guard retryCount < 2, Self.isTransient(error) else {
                    errorMessage = error.localizedDescription
                    return
                }
                retryCount += 1
                do {
                    try await Task.sleep(
                        for: .milliseconds(250 * retryCount)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? JellyfinAPIError else {
            return error is URLError
        }
        switch error {
        case .unreachable, .offline, .network:
            return true
        case .httpStatus(let status):
            return status == 408
                || status == 425
                || status == 429
                || (500...504).contains(status)
        case .unauthorized, .transportSecurity, .invalidResponse:
            return false
        }
    }

    private func mergedInitialPage(
        _ refreshedItems: [MusicCatalogItem],
        with cachedItems: [MusicCatalogItem]
    ) -> [MusicCatalogItem] {
        var seen = Set<MusicCatalogItemID>()
        return (refreshedItems + cachedItems).filter {
            seen.insert($0.id).inserted
        }
    }
}

/// Keeps a SwiftUI scroll target only for the currently displayed catalog snapshot.
///
/// Views retain this object while navigating to detail, so `scrollPosition` can
/// restore the visible target on Back. A changed source, query, or explicit
/// refresh starts a new identity and intentionally discards the old target.
@MainActor
final class CatalogScrollPositionState<Anchor: Hashable>: ObservableObject {
    @Published private(set) var anchor: Anchor?
    private(set) var identity: String?

    func begin(identity newIdentity: String, forceReset: Bool = false) -> Bool {
        guard forceReset || identity != newIdentity else { return false }
        identity = newIdentity
        anchor = nil
        return true
    }

    func record(_ visibleAnchor: Anchor?, identity: String) {
        // A transient empty target layout (for example, while a detail route is
        // popping) must not erase the last logical position. Identities reset it.
        guard self.identity == identity, let visibleAnchor else { return }
        anchor = visibleAnchor
    }

    /// Preserves the position known at selection time when SwiftUI has not yet
    /// reported a visible target for the current catalog snapshot.
    func capture(fallback: Anchor, identity: String) {
        guard self.identity == identity else { return }
        anchor = anchor ?? fallback
    }

    func binding(identity: String) -> Binding<Anchor?> {
        Binding(
            get: { self.anchor },
            set: { self.record($0, identity: identity) }
        )
    }

    func restorationAnchor(in anchors: [Anchor]) -> Anchor? {
        guard let anchor, anchors.contains(anchor) else { return nil }
        return anchor
    }
}
