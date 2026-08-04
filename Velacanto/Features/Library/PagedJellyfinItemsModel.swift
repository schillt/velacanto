import SwiftUI

@MainActor
final class PagedJellyfinItemsModel: ObservableObject {
    typealias Loader = (JellyfinCatalogCursor?) async throws -> JellyfinCatalogPage
    typealias CacheLoader = () async -> [JellyfinItem]
    typealias CacheWriter = ([JellyfinItem]) async -> Void

    @Published private(set) var items: [JellyfinItem] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isLoadingMore = false
    @Published private(set) var hasMore = true
    @Published private(set) var totalRecordCount = 0
    @Published private(set) var errorMessage: String?

    private var cursor: JellyfinCatalogCursor?
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
        itemID: String,
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
                    items = page.items
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
}
