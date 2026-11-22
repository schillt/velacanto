import Combine
import Foundation

/// Home owns at most five feed models above its lazy rows, just like its other shelves.
@MainActor
final class FoundationHomeGenreFeeds: ObservableObject {
    nonisolated struct Selection: Equatable {
        let scope: FoundationPrimaryGenreIndex.Scope
        let censusID: UUID
        let genreIDs: [String]

        init(scope: FoundationPrimaryGenreIndex.Scope, censusID: UUID, genreIDs: [String]) {
            self.scope = scope
            self.censusID = censusID
            var seen = Set<String>()
            self.genreIDs = Array(genreIDs.filter { seen.insert($0).inserted }.prefix(5))
        }
    }

    @MainActor
    final class Feed {
        let model = FoundationBrowseModel()
        private(set) var consumedRefreshRevision: UInt64

        init(refreshRevision: UInt64) { consumedRefreshRevision = refreshRevision }

        /// A recreated row consumes an explicit refresh only once for this retained feed.
        func consumeRefresh(_ revision: UInt64) {
            guard consumedRefreshRevision != revision else { return }
            consumedRefreshRevision = revision
            model.request(.refresh)
        }
    }

    private var boundScope: FoundationPrimaryGenreIndex.Scope?
    private var selection: Selection?
    private var feeds: [String: Feed] = [:]
    @Published private(set) var refreshRevision: UInt64 = 0
    var count: Int { feeds.count }

    isolated deinit {
        for feed in feeds.values { feed.model.clearRetainedData() }
    }

    /// Missing readiness is not a new account or census, and must not discard usable owners.
    func bind(_ scope: FoundationPrimaryGenreIndex.Scope?) {
        guard let scope, boundScope != scope else { return }
        objectWillChange.send()
        retireFeeds()
        boundScope = scope
    }

    func reconcile(_ next: Selection) {
        bind(next.scope)
        guard selection != next else { return }
        objectWillChange.send()
        if selection?.censusID != next.censusID { retireFeeds() }
        let retained = Set(next.genreIDs)
        for (id, feed) in feeds where !retained.contains(id) {
            feed.model.clearRetainedData()
        }
        feeds = Dictionary(
            uniqueKeysWithValues: next.genreIDs.map { id in
                (id, feeds[id] ?? Feed(refreshRevision: refreshRevision))
            })
        selection = next
    }

    func feed(for id: String, selection expected: Selection) -> Feed? {
        guard selection == expected else { return nil }
        return feeds[id]
    }

    /// Changes intent only. Existing visible row tasks still own all loading and cancellation.
    func requestRefresh() {
        refreshRevision &+= 1
    }

    private func retireFeeds() {
        for feed in feeds.values { feed.model.clearRetainedData() }
        feeds.removeAll()
        selection = nil
    }
}
