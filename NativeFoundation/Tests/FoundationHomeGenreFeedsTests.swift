import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationHomeGenreFeedsTests: XCTestCase {
    private func selection(
        account: String = "account-a", library: String? = nil,
        census: UUID = UUID(), ids: [String] = ["one", "two"]
    ) throws -> FoundationHomeGenreFeeds.Selection {
        .init(
            scope: .init(source: try .jellyfin(scope: account), libraryID: library),
            censusID: census, genreIDs: ids)
    }

    func testRecreatedRowsReuseLoadedFeedWithoutAnotherProviderDemand() async throws {
        let owner = FoundationHomeGenreFeeds()
        let selected = try selection()
        owner.reconcile(selected)
        let first = try XCTUnwrap(owner.feed(for: "one", selection: selected))
        var calls = 0
        func load(_ offset: Int) async throws -> FoundationPage {
            calls += 1
            return .init(items: [], nextStartIndex: nil)
        }
        first.consumeRefresh(owner.refreshRevision)
        await first.model.refreshVisible(allowsNetwork: true, using: load)
        for _ in 0..<6 {
            owner.reconcile(selected)
            let recreated = try XCTUnwrap(owner.feed(for: "one", selection: selected))
            XCTAssertTrue(recreated === first)
            recreated.consumeRefresh(owner.refreshRevision)
            await recreated.model.refreshVisible(allowsNetwork: true, using: load)
        }
        XCTAssertEqual(calls, 1)
    }

    func testExplicitRefreshConsumedOncePerFeedEvenWhenRowReturns() async throws {
        let owner = FoundationHomeGenreFeeds()
        let selected = try selection()
        owner.reconcile(selected)
        let feed = try XCTUnwrap(owner.feed(for: "one", selection: selected))
        var calls = 0
        func load(_ offset: Int) async throws -> FoundationPage {
            calls += 1
            return .init(items: [], nextStartIndex: nil)
        }
        await feed.model.refreshVisible(allowsNetwork: true, using: load)
        owner.requestRefresh()
        XCTAssertEqual(calls, 1, "Refresh intent must not start invisible work")
        for _ in 0..<3 {
            let row = try XCTUnwrap(owner.feed(for: "one", selection: selected))
            row.consumeRefresh(owner.refreshRevision)
            await row.model.refreshVisible(allowsNetwork: true, using: load)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(feed.consumedRefreshRevision, owner.refreshRevision)
    }

    func testMissingReadinessRetainsOwnersButWrongCanonicalSelectionCannotReadThem() throws {
        let owner = FoundationHomeGenreFeeds()
        let selected = try selection()
        owner.reconcile(selected)
        let feed = try XCTUnwrap(owner.feed(for: "one", selection: selected))
        owner.bind(nil)
        XCTAssertTrue(owner.feed(for: "one", selection: selected) === feed)
        XCTAssertNil(owner.feed(for: "one", selection: try selection()))
        XCTAssertNil(owner.feed(for: "one", selection: try selection(account: "account-b")))
    }

    func testAccountLibraryAndCensusChangesRetireOldData() throws {
        let owner = FoundationHomeGenreFeeds()
        let initial = try selection()
        owner.reconcile(initial)
        let feed = try XCTUnwrap(owner.feed(for: "one", selection: initial))
        feed.model.installSnapshot([
            .init(id: "track", title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        ])
        let changed = try selection(library: "library-b")
        owner.reconcile(changed)
        XCTAssertTrue(feed.model.items.isEmpty)
        XCTAssertNil(owner.feed(for: "one", selection: initial))
        let replacement = try XCTUnwrap(owner.feed(for: "one", selection: changed))
        XCTAssertFalse(replacement === feed)
        let accountChanged = try selection(account: "account-b", library: "library-b")
        owner.reconcile(accountChanged)
        XCTAssertFalse(owner.feed(for: "one", selection: accountChanged) === replacement)
        let accountFeed = try XCTUnwrap(owner.feed(for: "one", selection: accountChanged))
        let newCensus = try selection(account: "account-b", library: "library-b")
        owner.reconcile(newCensus)
        XCTAssertFalse(owner.feed(for: "one", selection: newCensus) === accountFeed)
    }

    func testRetiringScopeRejectsAnAlreadyRunningOldFeedPublication() async throws {
        let owner = FoundationHomeGenreFeeds()
        let selected = try selection()
        owner.reconcile(selected)
        let old = try XCTUnwrap(owner.feed(for: "one", selection: selected))
        let gate = HomeGenreFeedGate()
        let entered = expectation(description: "Old visible feed entered its provider")
        let task = Task {
            await old.model.refreshVisible(allowsNetwork: true) { _ in
                entered.fulfill()
                return await gate.wait()
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        let changed = try selection(account: "new-account")
        owner.reconcile(changed)
        await gate.release(
            .init(
                items: [
                    .init(id: "late", title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: nil))
        await task.value
        XCTAssertTrue(old.model.items.isEmpty)
        XCTAssertTrue(owner.feed(for: "one", selection: changed)?.model.items.isEmpty == true)
    }

    func testFiveFeedBoundAndMeaningfulMembershipChanges() throws {
        let owner = FoundationHomeGenreFeeds()
        let selected = try selection(ids: ["one", "two", "three", "four", "five", "six"])
        owner.reconcile(selected)
        XCTAssertEqual(owner.count, 5)
        XCTAssertNil(owner.feed(for: "six", selection: selected))
        let retained = try XCTUnwrap(owner.feed(for: "two", selection: selected))
        let changed = FoundationHomeGenreFeeds.Selection(
            scope: selected.scope, censusID: selected.censusID, genreIDs: ["two", "new"])
        owner.reconcile(changed)
        XCTAssertEqual(owner.count, 2)
        XCTAssertTrue(owner.feed(for: "two", selection: changed) === retained)
    }
}

private actor HomeGenreFeedGate {
    private var continuation: CheckedContinuation<FoundationPage, Never>?
    private var released: FoundationPage?
    func wait() async -> FoundationPage {
        if let released { return released }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ page: FoundationPage) {
        released = page
        continuation?.resume(returning: page)
        continuation = nil
    }
}
