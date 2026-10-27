import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

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
    private actor Gate {
        var started = false
        var released = false
        var startWaiter: CheckedContinuation<Void, Never>?
        var waiters: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            if released { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
                started = true
                startWaiter?.resume()
                startWaiter = nil
            }
        }
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { startWaiter = $0 }
        }
        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
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
        await gate.waitForStart()
        let remote = model.loadNext(.jellyfin)
        await model.loadNext(.local)?.value
        XCTAssertEqual(model.sections.map(\.state), [.loading, .ready])
        let key = try XCTUnwrap(model.sections.last?.rows.first?.id)
        await model.open(key)?.value
        XCTAssertEqual(model.detail?.byteCount, 1)
        let detail = try XCTUnwrap(model.detail)
        XCTAssertFalse(String(reflecting: detail).contains("private-directory"))
        let previousRevision = fixture.owner.presentationRevision
        let forgetting = fixture.owner.forget()
        XCTAssertGreaterThan(fixture.owner.presentationRevision, previousRevision)
        XCTAssertFalse(model.sections.contains { $0.id.kind == .local })
        XCTAssertNil(model.detail, "The revision getter gates detail before any async cleanup")
        model.synchronizeLocalRevision()
        await forgetting.value
        model.synchronizeLocalRevision()
        await gate.release()
        await remote?.value
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
        await gate.waitForStart()
        let remote = model.loadNext(.jellyfin)
        await model.loadNext(.local)?.value
        let row = try XCTUnwrap(model.sections.last?.rows.first)
        await model.open(row.id)?.value
        XCTAssertNotNil(model.detail)
        currentOwner = UUID()
        XCTAssertTrue(model.sections.isEmpty)
        XCTAssertNil(model.detail)
        model.invalidate()
        await gate.release()
        await remote?.value
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
        await gate.waitForStart()
        let oldRemote = model.loadNext(.jellyfin)
        model.setFilter(.local)
        await model.loadNext(.local)?.value
        await gate.release()
        await oldRemote?.value
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
        await gate.waitForStart()
        let oldRequest = old.loadNext(.jellyfin)
        lifetime.update(next, isActive: true)
        XCTAssertTrue(old.sections.isEmpty)
        await next.loadNext(.local)?.value
        XCTAssertEqual(next.sections.first?.rows.count, 1)
        await gate.release()
        await oldRequest?.value
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
        await gate.waitForStart()
        let pending = model.loadNext(.jellyfin)
        await actions.setFavorite(for: item, isFavorite: true)
        await gate.release()
        await pending?.value
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
        await gate.waitForStart()
        await model.loadNext(.local)?.value
        XCTAssertFalse(model.canPerform(oldMenu, requiring: .playback))
        XCTAssertEqual(model.sections.first(where: { $0.id.kind == .jellyfin })?.state, .loading)
        XCTAssertEqual(model.sections.first(where: { $0.id.kind == .local })?.rows.count, 1)
        await gate.release()
        await refresh.value
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
        await gate.waitForStart()
        let pending = model.loadNext(.jellyfin)
        model.setFilter(.jellyfin, activate: false)
        lifetime.update(model, isActive: false)
        await gate.release()
        await pending?.value
        let requests = await counter.value
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.sections.isEmpty)
        lifetime.end()
    }

}
