import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

/// Observes the captured production task, including bounded failure cleanup.
/// Cancellation cannot force arbitrary production work to terminate.
@MainActor
private func requireOfflineSearchTask<Success: Sendable, Failure: Error>(
    _ task: Task<Success, Failure>, context: String,
    stopOnCancellation: Bool = true, cleanup: @MainActor () async -> Void
) async -> Bool {
    var returnedAt: ContinuousClock.Instant?
    let observer = Task {
        _ = await task.result
        returnedAt = .now
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while returnedAt == nil, ContinuousClock.now < deadline,
        !stopOnCancellation || !Task.isCancelled
    {
        await Task.yield()
    }
    if let returnedAt, returnedAt <= deadline, !stopOnCancellation || !Task.isCancelled {
        return true
    }
    task.cancel()
    await cleanup()
    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while returnedAt == nil, ContinuousClock.now < cleanupDeadline { await Task.yield() }
    observer.cancel()
    XCTFail("Timed out or cancelled waiting for \(context)")
    if !(returnedAt.map { $0 <= cleanupDeadline } ?? false) {
        XCTFail("Captured task did not return during cleanup: \(context)")
    }
    return false
}

@MainActor
final class FoundationComposedCatalogModelTests: XCTestCase {
    private var session: FoundationSession {
        .init(
            serverURL: URL(string: "https://example.invalid/jellyfin/")!, accessToken: "synthetic",
            userID: "00000000000000000000000000000002", deviceID: "synthetic-device")
    }
    private nonisolated static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private nonisolated static var page: Data {
        Data(
            #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"Synthetic"}],"TotalRecordCount":1,"StartIndex":0}"#
                .utf8)
    }
    private struct Fixture {
        let root: URL
        let owner: FoundationLocalLibraryModel
        let source: FoundationLocalSource
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(count: Int = 1) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("private-directory")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for number in 0..<count {
            try Data([7]).write(to: folder.appendingPathComponent("Synthetic\(number).mp3"))
        }
        let source = FoundationLocalSource(
            storage: root.appendingPathComponent("index"),
            makeBookmark: { _ in Data([1, 2, 3]) },
            scan: { _, id, index in try await index.refresh(sourceID: id, authorizedRoot: folder) })
        _ = try await source.select(folder)
        _ = try await source.refresh()
        let owner = FoundationLocalLibraryModel(source: source)
        await owner.restore().value
        return .init(root: root, owner: owner, source: source)
    }
    @MainActor
    private final class Gate {
        private var started = false
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                started = true
            }
        }
        func waitForStart() async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !started && !Task.isCancelled && clock.now < deadline {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            }
            return started && !Task.isCancelled
        }
        func release() {
            released = true
            let held = waiters
            waiters.removeAll()
            for waiter in held { waiter.resume() }
        }
    }

    private func requireHeldCatalogTask(
        _ task: Task<Void, Never>?, context: String, cleanup: @MainActor () -> Void
    ) async -> Bool {
        guard let task else { return true }
        let finished = XCTestExpectation(description: context)
        let observer = Task {
            await task.value
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            task.cancel()
            cleanup()
            observer.cancel()
            XCTFail("\(context) did not finish within 5 seconds")
            return false
        }
        return true
    }

    private func requireHeldCatalogEntry(
        _ gate: Gate, task: Task<Void, Never>?, context: String, cleanup: @MainActor () -> Void
    ) async -> Bool {
        guard await gate.waitForStart() else {
            task?.cancel()
            cleanup()
            _ = await requireHeldCatalogTask(
                task, context: "\(context) abandoned work", cleanup: cleanup)
            XCTFail("\(context) did not enter within 5 seconds")
            return false
        }
        return true
    }

    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    private actor OfflineSearchFixture {
        private var items: [FoundationItem]
        private(set) var calls: [String] = []
        init(items: [FoundationItem]) { self.items = items }
        func setItems(_ items: [FoundationItem]) { self.items = items }
        func search(_ query: String, kind: FoundationItem.Kind, limit: Int) -> FoundationPage {
            calls.append(query)
            let result = kind == .track && query == "gar" ? Array(items.prefix(limit)) : []
            return .init(items: result, nextStartIndex: nil)
        }
    }

    private actor OfflineHeldSearch {
        private let entered: XCTestExpectation
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var announced = false
        private var released = false
        init(entered: XCTestExpectation) { self.entered = entered }
        func hold() async {
            guard !released else { return }
            await withCheckedContinuation {
                continuations.append($0)
                if !announced {
                    announced = true
                    entered.fulfill()
                }
            }
        }
        func release() {
            released = true
            let held = continuations
            continuations.removeAll()
            for continuation in held { continuation.resume() }
        }
    }

    private actor OfflineFailThenSucceed {
        private var attempts = 0
        let item: FoundationItem
        init(item: FoundationItem) { self.item = item }
        func search() throws -> FoundationPage {
            attempts += 1
            if attempts == 1 { throw FoundationLibraryError.unavailable }
            return .init(items: [item], nextStartIndex: nil)
        }
    }

    func testOfflineSearchRetainsFuzzyResultsAndReprojectsRemovedDownloads() async throws {
        let serverCalls = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await serverCalls.increment()
            return (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let items = (1...7).map {
            FoundationItem(
                id: String(format: "%032x", $0), title: "Garden", subtitle: "", kind: .track,
                duration: nil)
        }
        var ready = items
        let search = OfflineSearchFixture(items: items)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Gardenx", kind: .track),
            jellyfin: library, localLibrary: local, allowsNetwork: { false },
            offlineJellyfinItems: { [] }, offlineReadyTracks: { ready },
            offlineSearch: { text, kind, limit in
                await search.search(text, kind: kind, limit: limit)
            },
            isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(model.jellyfinItems.count, 7)
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        let calls = await search.calls
        XCTAssertEqual(calls, ["Gardenx", "gar"])
        let oldKey = try XCTUnwrap(model.jellyfinItems.first?.catalogKey())
        let oldIntent = try XCTUnwrap(model.jellyfinIntent(for: oldKey))
        ready[0].title = "Gardeny"
        await search.setItems(ready)
        model.refreshOfflineJellyfin()
        XCTAssertFalse(model.canPerform(oldIntent, requiring: .playback))
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(model.jellyfinItems.count, 7)
        XCTAssertEqual(
            model.jellyfinItems.first(where: { $0.id == oldKey.itemID })?.title, "Gardeny")
        let updatedIntent = try XCTUnwrap(model.jellyfinIntent(for: oldKey))
        ready.removeFirst()
        model.refreshOfflineJellyfin()
        XCTAssertFalse(model.canPerform(updatedIntent, requiring: .playback))
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(model.jellyfinItems.count, 6)
        XCTAssertFalse(model.jellyfinItems.contains { $0.id == oldKey.itemID })
        await model.refresh()
        XCTAssertEqual(model.jellyfinItems.count, 6)
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        let requests = await serverCalls.value
        XCTAssertEqual(requests, 0)
        model.invalidate()
    }

    func testOfflineSearchRetirementRejectsHeldResults() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let item = FoundationItem(
            id: "00000000000000000000000000000001", title: "Garden", subtitle: "",
            kind: .track, duration: nil)
        let entered = expectation(description: "offline search entered")
        let gate = OfflineHeldSearch(entered: entered)
        var ownerIsCurrent = true
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Garden", kind: .track),
            jellyfin: library, localLibrary: local, allowsNetwork: { false },
            offlineReadyTracks: { [item] },
            offlineSearch: { _, _, _ in
                await gate.hold()
                return .init(items: [item], nextStartIndex: nil)
            }, isCurrent: { _ in ownerIsCurrent })
        model.activate()
        guard let task = model.loadNext(.jellyfin) else {
            model.invalidate()
            await gate.release()
            XCTFail("Offline search did not create its owned load task")
            return
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard entry == .completed else {
            model.invalidate()
            await gate.release()
            guard
                await requireOfflineSearchTask(
                    task, context: "task completion",
                    cleanup: {
                        model.invalidate()
                        await gate.release()
                    })
            else { return }
            await task.value
            XCTFail("Offline search did not enter")
            return
        }
        ownerIsCurrent = false
        model.invalidate()
        await gate.release()
        guard
            await requireOfflineSearchTask(
                task, context: "task completion",
                cleanup: {
                    model.invalidate()
                    await gate.release()
                })
        else { return }
        await task.value
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertTrue(model.jellyfinItems.isEmpty)
    }

    func testOfflineSearchFailureRetainsRetryAndNeverStartsServerRead() async throws {
        let serverCalls = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await serverCalls.increment()
            return (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let item = FoundationItem(
            id: "00000000000000000000000000000001", title: "Garden", subtitle: "",
            kind: .track, duration: nil)
        let search = OfflineFailThenSucceed(item: item)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Garden", kind: .track),
            jellyfin: library, localLibrary: local, allowsNetwork: { false },
            offlineReadyTracks: { [item] }, offlineSearch: { _, _, _ in try await search.search() },
            isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertTrue(model.sections.first(where: { $0.id.kind == .jellyfin })?.failed == true)
        await model.retry(.jellyfin)?.value
        XCTAssertEqual(model.jellyfinItems.map(\.id), [item.id])
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        let requests = await serverCalls.value
        XCTAssertEqual(requests, 0)
        model.invalidate()
    }

    func testSearchSeedIsConsumedOnceAndExplicitRefreshReadsFreshProviderPage() async throws {
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(value("limit"), "50")
            XCTAssertEqual(value("startIndex"), "0")
            XCTAssertTrue(["garden", "gar"].contains(value("searchTerm") ?? ""))
            if url.path.hasSuffix("/Artists/AlbumArtists")
                || value("includeItemTypes") == "MusicAlbum"
            {
                // These fresh anchors have no matches. An Audio DTO here would be
                // a malformed provider response, not proof of empty relationships.
                let empty = Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8)
                return (empty, Self.response(request))
            }
            XCTAssertTrue(url.path.hasSuffix("/Items"))
            XCTAssertEqual(value("includeItemTypes"), "Audio")
            return (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let seedItem = FoundationItem(
            id: "00000000000000000000000000000001", title: "Seeded", subtitle: "",
            kind: .track, duration: nil)
        let seed = FoundationCatalogSearchSeed(
            query: "garden", metadataScope: library.metadataScopeID,
            page: .init(items: [seedItem], nextStartIndex: nil), supplementalIDs: [seedItem.id])
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "garden", kind: .track),
            jellyfin: library, localLibrary: local, initialSearchSeed: seed,
            isCurrent: { _ in true })
        model.setFilter(.jellyfin, activate: false)
        model.activate()
        await model.loadNext(.jellyfin)?.value
        let firstCount = await counter.value
        XCTAssertEqual(firstCount, 0)
        XCTAssertEqual(model.jellyfinItems.map(\.title), ["Seeded"])
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        await model.refresh()
        let refreshedCount = await counter.value
        XCTAssertEqual(refreshedCount, 6, "Fresh refresh bounds all three direct/fallback anchors")
        XCTAssertEqual(model.jellyfinItems.map(\.title), ["Synthetic"])
        XCTAssertFalse(
            model.searchRelatedCoverageIncomplete,
            "Fresh relationships are now resolved, even when none match")
        model.invalidate()
    }

    func testSearchFilterRoundTripPreservesSeedCoverage() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let item = FoundationItem(
            id: "00000000000000000000000000000001", title: "Seeded", subtitle: "",
            kind: .track, duration: nil)
        let seed = FoundationCatalogSearchSeed(
            query: "garden", metadataScope: library.metadataScopeID,
            page: .init(items: [item], nextStartIndex: nil), supplementalIDs: [item.id])
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "garden", kind: .track),
            jellyfin: library, localLibrary: local, initialSearchSeed: seed,
            isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        model.setFilter(.local)
        model.setFilter(.all)
        await model.loadNext(.jellyfin)?.value
        XCTAssertFalse(model.searchRelatedCoverageIncomplete)
        XCTAssertEqual(model.jellyfinItems.map(\.title), ["Seeded"])
        model.invalidate()
    }

    func testSeedOverlapObservesFreshFavoriteAndTrackMetadata() async throws {
        let response = Data(
            #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"Synthetic","AlbumId":"00000000000000000000000000000004","Album":"Synthetic Album","IndexNumber":1,"UserData":{"Key":"synthetic","IsFavorite":true}}],"TotalRecordCount":51,"StartIndex":50}"#
                .utf8)
        let library = FoundationJellyfinLibrary(session: session) { request in
            (response, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let actions = actions(for: library)
        let seedItem = FoundationItem(
            id: "00000000000000000000000000000001", title: "Synthetic", subtitle: "",
            kind: .track, duration: nil, isFavorite: false)
        let seed = FoundationCatalogSearchSeed(
            query: "garden", metadataScope: library.metadataScopeID,
            page: .init(items: [seedItem], nextStartIndex: 50), supplementalIDs: [seedItem.id])
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "garden", kind: .track),
            jellyfin: library, localLibrary: local, actions: actions, initialSearchSeed: seed,
            isCurrent: { _ in true })
        model.setFilter(.jellyfin, activate: false)
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(actions.favoriteState(for: seedItem, initial: false), false)
        await model.loadNext(.jellyfin)?.value
        let updated = try XCTUnwrap(model.jellyfinItems.first)
        XCTAssertEqual(updated.id, seedItem.id)
        XCTAssertEqual(actions.favoriteState(for: updated, initial: false), true)
        XCTAssertNotNil(updated.album)
        XCTAssertEqual(updated.trackNumber, 1)
        let alternate = FoundationItem(
            id: "00000000000000000000000000000005", title: updated.title, subtitle: "",
            kind: .track, duration: nil, album: updated.album, trackNumber: updated.trackNumber)
        XCTAssertTrue(actions.visibleTracks([alternate]).isEmpty)
        model.invalidate()
    }

    func testReusedSeedDoesNotRepublishOlderFavoriteAsFresh() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let local = FoundationLocalLibraryModel(
            source: FoundationLocalSource(
                storage: FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)))
        let actions = actions(for: library)
        let item = FoundationItem(
            id: "00000000000000000000000000000001", title: "Synthetic", subtitle: "",
            kind: .track, duration: nil, isFavorite: false)
        await actions.setFavorite(for: item, isFavorite: true)
        let seed = FoundationCatalogSearchSeed(
            query: "garden", metadataScope: library.metadataScopeID,
            page: .init(items: [item], nextStartIndex: nil), supplementalIDs: [item.id])
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "garden", kind: .track),
            jellyfin: library, localLibrary: local, actions: actions, initialSearchSeed: seed,
            isCurrent: { _ in true })
        model.setFilter(.jellyfin, activate: false)
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), true)
        model.invalidate()
    }

    func testForgetImmediatelyHidesLocalRowsAndDetailWhileRemoteLoadContinues() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        let remote = model.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            model.invalidate()
            gate.release()
        }
        defer {
            remote?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: remote, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        guard
            await requireHeldCatalogTask(
                model.loadNext(.local), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(model.sections.map(\.state), [.loading, .ready])
        let key = try XCTUnwrap(model.sections.last?.rows.first?.id)
        guard
            await requireHeldCatalogTask(
                model.open(key), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(model.detail?.byteCount, 1)
        let detail = try XCTUnwrap(model.detail)
        XCTAssertFalse(String(reflecting: detail).contains("private-directory"))
        let previousRevision = fixture.owner.presentationRevision
        let forgetting = fixture.owner.forget()
        XCTAssertGreaterThan(fixture.owner.presentationRevision, previousRevision)
        XCTAssertFalse(model.sections.contains { $0.id.kind == .local })
        XCTAssertNil(model.detail, "The revision getter gates detail before any async cleanup")
        model.synchronizeLocalRevision()
        guard
            await requireHeldCatalogTask(
                forgetting, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        model.synchronizeLocalRevision()
        gate.release()
        guard
            await requireHeldCatalogTask(
                remote, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(model.sections.map { $0.id.kind }, [.jellyfin])
        XCTAssertEqual(model.sections.first?.state, .ready)
        model.invalidate()
    }

    func testAccountOrQueryContextReplacementRejectsLatePublicationAndExistingDetail() async throws
    {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        var currentOwner = UUID()
        let model = try FoundationComposedCatalogModel(
            ownerID: currentOwner, query: .songs,
            jellyfin: library, localLibrary: fixture.owner,
            isCurrent: { $0.ownerID == currentOwner })
        model.activate()
        let remote = model.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            model.invalidate()
            gate.release()
        }
        defer {
            remote?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: remote, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        guard
            await requireHeldCatalogTask(
                model.loadNext(.local), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        let row = try XCTUnwrap(model.sections.last?.rows.first)
        guard
            await requireHeldCatalogTask(
                model.open(row.id), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertNotNil(model.detail)
        currentOwner = UUID()
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNil(model.detail)
        model.invalidate()
        gate.release()
        guard
            await requireHeldCatalogTask(
                remote, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNotNil(
            fixture.owner.catalog, "Account retirement must not erase local index ownership")
    }

    func testFilterChangeCancelsOldRemotePresentationAndKeepsReadOnlyLocal() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        let oldRemote = model.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            model.invalidate()
            gate.release()
        }
        defer {
            oldRemote?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: oldRemote, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        model.setFilter(.local)
        guard
            await requireHeldCatalogTask(
                model.loadNext(.local), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        gate.release()
        guard
            await requireHeldCatalogTask(
                oldRemote, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(model.sections.map { $0.id.kind }, [.local])
        let row = try XCTUnwrap(model.sections.first?.rows.first)
        XCTAssertEqual(row.id.source.capabilities(for: .track), [.catalogPresence])
        model.invalidate()
    }

    func testLocalRefreshHidesOldSnapshotSynchronouslyAndSettledRevisionRebuilds() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: nil, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.sections.first?.rows.count, 1)
        let refresh = fixture.owner.refresh()
        XCTAssertTrue(model.sections.isEmpty)
        model.synchronizeLocalRevision()
        await refresh.value
        model.synchronizeLocalRevision()
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.sections.first?.rows.count, 1)
        XCTAssertEqual(model.sections.first?.state, .ready)
        model.invalidate()
    }

    func testExplicitPagesAppendWithoutCollisionsAndFinishedSourceHasNoMoreAction() async throws {
        let fixture = try await fixture(count: 51)
        defer { fixture.remove() }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: nil, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.sections.first?.rows.count, 50)
        XCTAssertTrue(model.sections.first?.hasMore == true)
        await model.loadNext(.local)?.value
        let rows = try XCTUnwrap(model.sections.first?.rows)
        XCTAssertEqual(rows.count, 51)
        XCTAssertEqual(Set(rows.map(\.id)).count, 51)
        XCTAssertFalse(model.sections.first?.hasMore == true)
        XCTAssertNil(model.loadNext(.local))
        model.invalidate()
    }

    func testRemoteFailureHasFixedStateAndExplicitRetryDoesNotBlockLocalOrLeakErrors() async throws
    {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { _ in
            await counter.increment()
            throw URLError(.cannotConnectToHost)
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        let remote = model.loadNext(.jellyfin)
        await model.loadNext(.local)?.value
        await remote?.value
        XCTAssertEqual(model.sections.map(\.state), [.failed, .ready])
        XCTAssertEqual(model.sections.last?.rows.count, 1)
        await model.retry(.jellyfin)?.value
        let count = await counter.value
        XCTAssertEqual(count, 2)
        XCTAssertEqual(model.sections.map(\.state), [.failed, .ready])
        model.invalidate()
    }

    func testLocalPaginationFailurePreservesAnUnrelatedJellyfinDetail() async throws {
        let fixture = try await fixture(count: 51)
        defer { fixture.remove() }
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        let remote = model.loadNext(.jellyfin)
        await model.loadNext(.local)?.value
        await remote?.value
        let key = try XCTUnwrap(model.sections.first { $0.id.kind == .jellyfin }?.rows.first?.id)
        await model.open(key)?.value
        XCTAssertEqual(model.detail?.id, key)
        let id = try XCTUnwrap(fixture.owner.catalog?.sourceID)
        let index = fixture.root.appendingPathComponent("index/catalogs")
            .appendingPathComponent(id.uuidString).appendingPathExtension("json")
        try Data([255]).write(to: index)
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.sections.first { $0.id.kind == .local }?.state, .failed)
        XCTAssertEqual(
            model.detail?.id, key, "A local failure cannot dismiss another source's detail")
        model.invalidate()
    }

    func testRevokedLocalRouteShowsDismissibleDetailFailureAndRevisionGatesIt() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: nil, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.local)?.value
        let key = try XCTUnwrap(model.sections.first?.rows.first?.id)
        try await fixture.source.removeSelection()
        await model.open(key)?.value
        XCTAssertTrue(
            model.detailUnavailable, "The view's alert must receive an explicit failure state")
        XCTAssertNil(model.detail)
        model.dismissDetailFailure()
        XCTAssertFalse(model.detailUnavailable)
        await model.open(key)?.value
        XCTAssertTrue(model.detailUnavailable)
        let forgetting = fixture.owner.forget()
        XCTAssertFalse(
            model.detailUnavailable, "An older local error cannot outlive its source revision")
        model.synchronizeLocalRevision()
        await forgetting.value
        model.invalidate()
    }

    func testMountedOwnerReplacementRetiresOldWorkBeforeActivatingNewModel() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let old = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        let next = try FoundationComposedCatalogModel(
            ownerID: UUID(),
            query: .search(text: "Synthetic", kind: .track), jellyfin: nil,
            localLibrary: fixture.owner, isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        lifetime.update(old, isActive: true)
        let oldRequest = old.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            lifetime.end()
            gate.release()
        }
        defer {
            oldRequest?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: oldRequest, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        lifetime.update(next, isActive: true)
        XCTAssertTrue(old.sections.isEmpty)
        guard
            await requireHeldCatalogTask(
                next.loadNext(.local), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(next.sections.first?.rows.count, 1)
        gate.release()
        guard
            await requireHeldCatalogTask(
                oldRequest, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertTrue(
            old.sections.isEmpty, "The old model cannot publish into a mounted replacement")
        lifetime.end()
        XCTAssertTrue(next.sections.isEmpty)
        XCTAssertNotNil(fixture.owner.catalog)
    }

    private actor Offsets {
        var values: [Int] = []
        func append(_ offset: Int) { values.append(offset) }
    }

    func testActualSongsAdapterPublishesAll100ItemsThenAdvancesWithoutLoss() async throws {
        let fixture = try await fixture(count: 0)
        defer { fixture.remove() }
        let offsets = Offsets()
        let library = FoundationJellyfinLibrary(session: session) { request in
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = Int(query.first { $0.name.lowercased() == "startindex" }?.value ?? "0") ?? 0
            XCTAssertEqual(query.first { $0.name.lowercased() == "limit" }?.value, "100")
            await offsets.append(start)
            let items: [[String: Any]] = (start..<min(start + 100, 101)).map {
                ["Id": String(format: "%032x", $0 + 1), "Type": "Audio", "Name": "Synthetic \($0)"]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": items, "TotalRecordCount": 101, "StartIndex": start,
            ])
            return (data, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs,
            jellyfin: library, localLibrary: fixture.owner, isCurrent: { _ in true })
        model.setFilter(.jellyfin)
        model.activate()
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(model.sections.first?.rows.count, 100)
        XCTAssertTrue(model.sections.first?.hasMore == true)
        await model.loadNext(.jellyfin)?.value
        let rows = try XCTUnwrap(model.sections.first?.rows)
        XCTAssertEqual(rows.count, 101)
        XCTAssertEqual(rows.map { $0.id.itemID }, (1...101).map { String(format: "%032x", $0) })
        XCTAssertEqual(Set(rows.map(\.id)).count, 101)
        XCTAssertFalse(model.sections.first?.hasMore == true)
        let requested = await offsets.values
        XCTAssertEqual(requested, [0, 100])
        model.invalidate()
    }

    /// Acknowledges actual task completion; a timeout cancels demand without
    /// claiming arbitrary noncooperative work has terminated.
    private func requireContinuationTaskCompletion(
        _ task: Task<Void, Never>?, context: String, stopOnCancellation: Bool = true
    ) async -> Bool {
        guard let task else {
            XCTFail("Missing task for \(context)")
            return false
        }
        let completed = expectation(description: context)
        let observer = Task {
            await task.value
            completed.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        guard result == .completed, !stopOnCancellation || !Task.isCancelled else {
            task.cancel()
            observer.cancel()
            XCTFail("Timed out or cancelled waiting for \(context)")
            return false
        }
        return true
    }

    func testSearchSourceRoundTripRetainsContinuedRowsAndCursorWithoutReads() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let cursor = try XCTUnwrap(
                Int(
                    query.first(where: { $0.name.lowercased() == "startindex" })?.value ?? ""))
            XCTAssertTrue(cursor == 50 || cursor == 51)
            XCTAssertEqual(
                query.first(where: { $0.name.lowercased() == "searchterm" })?.value, "gar")
            let id =
                cursor == 50
                ? "00000000000000000000000000000050" : "00000000000000000000000000000051"
            let data = Data(
                "{\"Items\":[{\"Id\":\"\(id)\",\"Type\":\"Audio\",\"Name\":\"Garden\"}],\"TotalRecordCount\":52,\"StartIndex\":\(cursor)}"
                    .utf8)
            return (data, Self.response(request))
        }
        let seedItem = FoundationItem(
            id: "seed", title: "Garden", subtitle: "", kind: .track, duration: nil)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Gardenx", kind: .track), jellyfin: library,
            localLibrary: fixture.owner,
            initialSearchSeed: .init(
                query: "Gardenx", metadataScope: library.metadataScopeID,
                page: .init(items: [seedItem], nextStartIndex: nil), supplementalIDs: ["seed"],
                fallbackCursor: .init(term: "gar", nextStartIndex: 50)),
            isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        defer { lifetime.end() }
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        let initialCount = await counter.value
        XCTAssertEqual(initialCount, 0)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        let continued = model.jellyfinItems.map(\.id)
        XCTAssertEqual(continued.count, 2)
        XCTAssertTrue(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore == true)
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        XCTAssertTrue(model.sections.isEmpty)
        model.setFilter(.all, activate: false)
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        XCTAssertEqual(model.jellyfinItems.map(\.id), continued)
        let resumedCount = await counter.value
        XCTAssertEqual(
            resumedCount, 1, "Reactivation restores committed state without another read")
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 3)
        XCTAssertFalse(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore ?? true)
        let finalCount = await counter.value
        XCTAssertEqual(finalCount, 2, "Explicit continuation retains the next fallback cursor")
        lifetime.end()
        XCTAssertTrue(model.sections.isEmpty)
    }

    func testSearchFilterSuspensionDrainsAndRejectsLateFallbackThenRetriesSameCursor() async throws
    {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let entered = expectation(description: "Fallback read entered")
        let gate = OfflineHeldSearch(entered: entered)
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let calls = await counter.value
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(
                query.first(where: { $0.name.lowercased() == "startindex" })?.value, "50")
            if calls == 1 {
                await gate.hold()
            }
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000050","Type":"Audio","Name":"Garden"}],"TotalRecordCount":51,"StartIndex":50}"#
                        .utf8), Self.response(request)
            )
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Gardenx", kind: .track), jellyfin: library,
            localLibrary: fixture.owner,
            initialSearchSeed: .init(
                query: "Gardenx", metadataScope: library.metadataScopeID,
                page: .init(items: [], nextStartIndex: nil), supplementalIDs: [],
                fallbackCursor: .init(term: "gar", nextStartIndex: 50)),
            isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        defer { lifetime.end() }
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "initial search seed")
        else {
            lifetime.end()
            await gate.release()
            return
        }
        let held = model.loadNext(.jellyfin)
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard entry == .completed, !Task.isCancelled else {
            XCTFail("Timed out or cancelled waiting for fallback read entry")
            lifetime.end()
            await gate.release()
            if let held {
                _ = await requireContinuationTaskCompletion(
                    held, context: "fallback entry failure cleanup", stopOnCancellation: false)
            }
            return
        }
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        await gate.release()
        guard await requireContinuationTaskCompletion(held, context: "suspended fallback drain")
        else {
            lifetime.end()
            await gate.release()
            if let held {
                _ = await requireContinuationTaskCompletion(
                    held, context: "fallback drain failure cleanup", stopOnCancellation: false)
            }
            return
        }
        XCTAssertTrue(model.sections.isEmpty)
        model.setFilter(.all, activate: false)
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        XCTAssertTrue(model.jellyfinItems.isEmpty, "The inactive read did not publish")
        XCTAssertTrue(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore == true)
        let beforeRetry = await counter.value
        XCTAssertEqual(beforeRetry, 1, "Resuming does not automatically retry cancelled work")
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 1)
        let afterRetry = await counter.value
        XCTAssertEqual(afterRetry, 2)
    }

    func testCappedSearchSourceRoundTripCannotExposeAnotherRead() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let offset =
                Int(query.first(where: { $0.name.lowercased() == "startindex" })?.value ?? "") ?? 0
            XCTAssertEqual(query.first(where: { $0.name.lowercased() == "limit" })?.value, "50")
            let items = (offset..<(offset + 50)).map { index in
                "{\"Id\":\"\(String(format: "%032d", index))\",\"Type\":\"Audio\",\"Name\":\"Garden\"}"
            }.joined(separator: ",")
            return (
                Data(
                    "{\"Items\":[\(items)],\"TotalRecordCount\":10200,\"StartIndex\":\(offset)}"
                        .utf8),
                Self.response(request)
            )
        }
        let items = (0..<200).map { index in
            FoundationItem(
                id: String(format: "%032d", index), title: "Garden", subtitle: "", kind: .track,
                duration: nil)
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Garden", kind: .track), jellyfin: library,
            localLibrary: fixture.owner,
            initialSearchSeed: .init(
                query: "Garden", metadataScope: library.metadataScopeID,
                page: .init(items: items, nextStartIndex: 200), supplementalIDs: []),
            isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        defer { lifetime.end() }
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        for _ in 0..<196 {
            guard
                await requireContinuationTaskCompletion(
                    model.loadNext(.jellyfin), context: "capped search page")
            else { return }
        }
        XCTAssertEqual(model.jellyfinItems.count, FoundationCatalogComposition.itemLimit)
        XCTAssertTrue(
            model.sections.first(where: { $0.id.kind == .jellyfin })?.limitReached == true)
        XCTAssertFalse(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore ?? true)
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        model.setFilter(.all, activate: false)
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "search continuation operation")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, FoundationCatalogComposition.itemLimit)
        XCTAssertTrue(
            model.sections.first(where: { $0.id.kind == .jellyfin })?.limitReached == true)
        XCTAssertFalse(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore ?? true)
        XCTAssertNil(model.loadNext(.jellyfin))
        let reads = await counter.value
        XCTAssertEqual(
            reads, 196, "Source choice preserves the lifetime ceiling without another read")
    }

    private func actions(for library: FoundationJellyfinLibrary) -> FoundationLibraryActions {
        FoundationLibraryActions(
            sourceScope: library.catalogAccountIdentity, read: { _ in nil },
            write: { _, _ in }, mutateFavorite: { _, _ in })
    }

    private func player() -> FoundationPlayer {
        FoundationPlayer(
            resolve: { _ in throw FoundationLibraryError.unavailable },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
    }

    func testNativePlaybackIntentIsClaimedSynchronouslyAndRejectsLocalOrRetiredContext()
        async throws
    {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let actions = actions(for: library)
        var currentOwner = UUID()
        let model = try FoundationComposedCatalogModel(
            ownerID: currentOwner, query: .songs, jellyfin: library, localLibrary: fixture.owner,
            actions: actions,
            isCurrent: {
                $0.ownerID == currentOwner
                    && actions.acceptsCatalogAccount(library.catalogAccountIdentity)
            })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        await model.loadNext(.local)?.value
        let remoteKey = try XCTUnwrap(
            model.sections.first(where: { $0.id.kind == .jellyfin })?.rows.first?.id)
        let localKey = try XCTUnwrap(
            model.sections.first(where: { $0.id.kind == .local })?.rows.first?.id)
        XCTAssertNil(model.jellyfinIntent(for: localKey))
        let intent = try XCTUnwrap(model.jellyfinIntent(for: remoteKey))
        XCTAssertFalse(
            model.canPerform(intent, requiring: .playlistManagement),
            "A track is not a playlist-management capability")
        let player = player()
        defer {
            player.stop()
            model.invalidate()
        }
        XCTAssertTrue(
            model.withCurrentJellyfinItem(intent, requiring: .playback) {
                player.setQueue([$0], selectedIndex: 0)
            })
        XCTAssertEqual(player.queue.map(\.item.id), [remoteKey.itemID])
        let selection = player.selectedEntryID
        XCTAssertNotNil(selection, "The native player claims selection before dispatch returns")
        currentOwner = UUID()
        XCTAssertFalse(
            model.withCurrentJellyfinItem(intent, requiring: .playback) {
                player.setQueue([$0, $0], selectedIndex: 1)
            })
        XCTAssertEqual(player.selectedEntryID, selection)
        XCTAssertEqual(player.queue.count, 1)
    }

    func testDismissedMenuIntentCannotReviveAfterSourceFilterCycle() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        let key = try XCTUnwrap(model.sections.first?.rows.first?.id)
        let old = try XCTUnwrap(model.jellyfinIntent(for: key))
        let capturedRemoval = FoundationDownloadRemovalRequest(
            item: try XCTUnwrap(model.jellyfinItems.first),
            isCurrent: { model.canPerform(old, requiring: .downloads) })
        XCTAssertTrue(capturedRemoval.isCurrent())
        model.setFilter(.local)
        model.setFilter(.all)
        await model.loadNext(.jellyfin)?.value
        XCTAssertNotNil(model.jellyfinIntent(for: key), "The same item was published again")
        XCTAssertFalse(model.canPerform(old, requiring: .playback))
        XCTAssertFalse(
            capturedRemoval.isCurrent(), "Deferred confirmation retains its original generation")
        let current = try XCTUnwrap(model.jellyfinIntent(for: key))
        XCTAssertTrue(model.canPerform(current, requiring: .downloads))
        model.invalidate()
    }

    func testAccountInvalidationAndForeignScopeRejectNativeDispatch() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Self.page, Self.response(request))
        }
        let actions = actions(for: library)
        let foreign = FoundationJellyfinLibrary(
            session: .init(
                serverURL: session.serverURL, accessToken: "synthetic",
                userID: String(repeating: "3", count: 32),
                deviceID: "synthetic-device"))
        XCTAssertTrue(actions.acceptsCatalogAccount(library.catalogAccountIdentity))
        XCTAssertFalse(actions.acceptsCatalogAccount(foreign.catalogAccountIdentity))
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            actions: actions,
            isCurrent: { _ in actions.acceptsCatalogAccount(library.catalogAccountIdentity) })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        let key = try XCTUnwrap(model.sections.first?.rows.first?.id)
        let intent = try XCTUnwrap(model.jellyfinIntent(for: key))
        let player = player()
        defer {
            player.stop()
            model.invalidate()
        }
        actions.invalidate()
        XCTAssertFalse(actions.acceptsCatalogAccount(library.catalogAccountIdentity))
        XCTAssertFalse(
            model.withCurrentJellyfinItem(intent, requiring: .playback) {
                player.setQueue([$0], selectedIndex: 0)
            })
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testOfflineProjectionMakesNoServerReadAndRemovalRetiresCapturedIntent() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            return (Self.page, Self.response(request))
        }
        var ready = [
            FoundationItem(
                id: String(repeating: "1", count: 32), title: "Ready", subtitle: "",
                kind: .track, duration: 1)
        ]
        var offline = true
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            allowsNetwork: { !offline }, offlineJellyfinItems: { ready },
            isCurrent: { _ in offline })
        model.activate()
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.jellyfinItems.map(\.id), ready.map(\.id))
        let key = try XCTUnwrap(model.jellyfinItems.first?.catalogKey())
        let intent = try XCTUnwrap(model.jellyfinIntent(for: key))
        XCTAssertTrue(model.canPerform(intent, requiring: .playback))
        ready = []
        model.refreshOfflineJellyfin()
        XCTAssertTrue(model.jellyfinItems.isEmpty)
        XCTAssertFalse(model.canPerform(intent, requiring: .playback))
        let requests = await counter.value
        XCTAssertEqual(requests, 0)
        offline = false
        XCTAssertTrue(
            model.sections.isEmpty, "Mode replacement rejects the old offline owner immediately")
        model.invalidate()
    }

    func testLateComposedReadCannotUndoNewerFavoriteMutation() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let gate = Gate()
        let falsePage = Data(
            #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"Synthetic","UserData":{"Key":"synthetic","IsFavorite":false}}],"TotalRecordCount":1,"StartIndex":0}"#
                .utf8)
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.hold()
            return (falsePage, Self.response(request))
        }
        let actions = actions(for: library)
        let item = FoundationItem(
            id: String(repeating: "0", count: 31) + "1", title: "Synthetic",
            subtitle: "", kind: .track, duration: nil, isFavorite: false)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            actions: actions, isCurrent: { _ in true })
        model.activate()
        let pending = model.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            model.invalidate()
            gate.release()
        }
        defer {
            pending?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: pending, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        await actions.setFavorite(for: item, isFavorite: true)
        gate.release()
        guard
            await requireHeldCatalogTask(
                pending, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 1)
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), true)
        model.invalidate()
    }

    func testNewPageDoesNotRepublishAccumulatedOldFavoriteMetadataAsFresh() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let library = FoundationJellyfinLibrary(session: session) { request in
            let offset =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name.lowercased() == "startindex" })?.value ?? "0"
            let number = offset == "0" ? "1" : "3"
            let data = Data(
                ("{\"Items\":[{\"Id\":\"" + String(repeating: "0", count: 31) + number
                    + "\",\"Type\":\"Audio\",\"Name\":\"Synthetic\",\"UserData\":{\"Key\":\"synthetic\",\"IsFavorite\":false}}],\"TotalRecordCount\":2,\"StartIndex\":"
                    + offset + "}").utf8)
            return (data, Self.response(request))
        }
        let actions = actions(for: library)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            actions: actions, isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        let first = try XCTUnwrap(model.jellyfinItems.first)
        XCTAssertEqual(actions.favoriteState(for: first, initial: nil), false)
        await actions.setFavorite(for: first, isFavorite: true)
        await model.loadNext(.jellyfin)?.value
        XCTAssertEqual(model.jellyfinItems.count, 2)
        XCTAssertEqual(actions.favoriteState(for: first, initial: false), true)
        model.invalidate()
    }

    func testExplicitRefreshRetiresMenuBeforeAwaitAndPublishesLocalWhileRemoteIsHeld() async throws
    {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let count = await counter.value
            if count > 1 { await gate.hold() }
            return (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            isCurrent: { _ in true })
        model.activate()
        await model.loadNext(.jellyfin)?.value
        let key = try XCTUnwrap(model.jellyfinItems.first?.catalogKey())
        let oldMenu = try XCTUnwrap(model.jellyfinIntent(for: key))
        let refresh = Task { await model.refresh() }
        let cleanup: @MainActor () -> Void = {
            model.invalidate()
            gate.release()
        }
        defer {
            refresh.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: refresh, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        guard
            await requireHeldCatalogTask(
                model.loadNext(.local), context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertFalse(model.canPerform(oldMenu, requiring: .playback))
        XCTAssertEqual(model.sections.first(where: { $0.id.kind == .jellyfin })?.state, .loading)
        XCTAssertEqual(model.sections.first(where: { $0.id.kind == .local })?.rows.count, 1)
        gate.release()
        guard
            await requireHeldCatalogTask(
                refresh, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        XCTAssertNotNil(model.jellyfinIntent(for: key))
        XCTAssertFalse(model.canPerform(oldMenu, requiring: .downloads))
        model.invalidate()
    }

    func testNativeIndexModeLeavesComposedLoaderInactiveAndRejectsItsLatePage() async throws {
        let fixture = try await fixture()
        defer { fixture.remove() }
        let counter = Counter()
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .songs, jellyfin: library, localLibrary: fixture.owner,
            isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        await model.loadNext(.jellyfin)?.value
        let initially = await counter.value
        XCTAssertEqual(
            initially, 0, "The existing native index is the sole Jellyfin loader in this mode")
        model.setFilter(.all, activate: false)
        lifetime.update(model, isActive: true)
        let pending = model.loadNext(.jellyfin)
        let cleanup: @MainActor () -> Void = {
            lifetime.end()
            gate.release()
        }
        defer {
            pending?.cancel()
            cleanup()
        }
        guard
            await requireHeldCatalogEntry(
                gate, task: pending, context: "held catalog entry",
                cleanup: cleanup
            )
        else { return }
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        gate.release()
        guard
            await requireHeldCatalogTask(
                pending, context: "held catalog completion",
                cleanup: cleanup
            )
        else { return }
        let requests = await counter.value
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.sections.isEmpty)
        lifetime.end()
    }

    func testSearchSeedOverflowSurvivesSourceSwitchWithoutReadsOrFavoriteReplay() async throws {
        let fixture = try await fixture(count: 0)
        defer { fixture.remove() }
        let counter = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await counter.increment()
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(
                query.first(where: { $0.name.lowercased() == "searchterm" })?.value, "gar")
            XCTAssertEqual(
                query.first(where: { $0.name.lowercased() == "startindex" })?.value, "50")
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000202","Type":"Audio","Name":"Garden"}],"TotalRecordCount":51,"StartIndex":50}"#
                        .utf8), Self.response(request)
            )
        }
        let actions = actions(for: library)
        let items = (1...201).map {
            FoundationItem(
                id: String(format: "%032d", $0), title: "Garden", subtitle: "", kind: .track,
                duration: nil, isFavorite: false)
        }
        let last = try XCTUnwrap(items.last)
        let model = try FoundationComposedCatalogModel(
            ownerID: UUID(), query: .search(text: "Gardenx", kind: .track), jellyfin: library,
            localLibrary: fixture.owner, actions: actions,
            initialSearchSeed: .init(
                query: "Gardenx", metadataScope: library.metadataScopeID,
                page: .init(items: items, nextStartIndex: nil),
                supplementalIDs: Set(items.map(\.id)),
                fallbackCursor: .init(term: "gar", nextStartIndex: 50)), isCurrent: { _ in true })
        let lifetime = FoundationComposedCatalogLifetime()
        defer { lifetime.end() }
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "overflow initial seed")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 200)
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        model.setFilter(.all, activate: false)
        lifetime.update(model, isActive: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "overflow source resume")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 200)
        let initialReads = await counter.value
        XCTAssertEqual(initialReads, 0)
        await actions.setFavorite(for: last, isFavorite: true)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "overflow retained next page")
        else { return }
        XCTAssertEqual(model.jellyfinItems.map(\.id), items.map(\.id))
        XCTAssertEqual(actions.favoriteState(for: last, initial: false), true)
        let overflowReads = await counter.value
        XCTAssertEqual(
            overflowReads, 0, "The category reveals retained overflow without another server read")
        XCTAssertTrue(model.hasSearchFallback)
        guard
            await requireContinuationTaskCompletion(
                model.loadNext(.jellyfin), context: "fallback after retained overflow")
        else { return }
        XCTAssertEqual(model.jellyfinItems.count, 202)
        let finalReads = await counter.value
        XCTAssertEqual(finalReads, 1)
        XCTAssertFalse(model.hasSearchFallback)
        XCTAssertFalse(model.sections.first(where: { $0.id.kind == .jellyfin })?.hasMore ?? true)
    }

}
