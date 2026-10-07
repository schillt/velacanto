import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationMusicLibrarySelectionTests: XCTestCase {
    private let first = FoundationMusicLibraryChoice(
        id: "00000000000000000000000000000011", name: "Fixture Library A")
    private let second = FoundationMusicLibraryChoice(
        id: "00000000000000000000000000000012", name: "Fixture Library B")
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid/")!, accessToken: "synthetic",
            userID: "00000000000000000000000000000001", deviceID: "synthetic")
    }

    func testScopedQueriesKeepAlbumDetailsAndPlaylistsCanonical() async throws {
        let recorder = Requests()
        let library = FoundationJellyfinLibrary(
            session: session,
            load: { request in
                await recorder.append(request)
                return (Data("{\"Items\":[],\"TotalRecordCount\":0}".utf8), Self.response(request))
            }
        ).scoped(to: first.id)
        _ = try await library.albums(startIndex: 0)
        _ = try await library.artists(startIndex: 0)
        _ = try await library.genres(startIndex: 0)
        _ = try await library.search(query: "fixture", kind: .track, startIndex: 50, limit: 50)
        _ = try await library.tracks(albumID: second.id, startIndex: 0)
        _ = try await library.playlists(startIndex: 0)
        let requests = await recorder.values
        XCTAssertEqual(requests.count, 6)
        for request in requests.prefix(4) {
            XCTAssertEqual(Self.query(request, "parentId"), first.id)
        }
        XCTAssertEqual(Self.query(requests[3], "startIndex"), "50")
        XCTAssertEqual(Self.query(requests[4], "parentId"), second.id)
        XCTAssertEqual(Self.query(requests[4], "recursive"), "false")
        XCTAssertNil(Self.query(requests[5], "parentId"))
        XCTAssertEqual(Self.query(requests[0], "recursive"), "true")
    }

    func testListingFiltersMusicAndRejectsDuplicateIDs() async throws {
        let first = first
        let valid = FoundationJellyfinLibrary(
            session: session,
            load: { request in
                XCTAssertTrue(request.url!.path.hasSuffix("/UserViews"))
                let body = """
                    {"Items":[{"Id":"\(first.id)","Name":"Fixture Library A","CollectionType":"music"},
                    {"Id":"00000000000000000000000000000013","Name":"Fixture Video","CollectionType":"movies"}]}
                    """
                return (Data(body.utf8), Self.response(request))
            })
        let choices = try await valid.musicLibraries()
        XCTAssertEqual(choices, [first])
        let invalid = FoundationJellyfinLibrary(
            session: session,
            load: { request in
                let entry =
                    "{\"Id\":\"\(first.id)\",\"Name\":\"Fixture\",\"CollectionType\":\"music\"}"
                return (Data("{\"Items\":[\(entry),\(entry)]}".utf8), Self.response(request))
            })
        do {
            _ = try await invalid.musicLibraries()
            XCTFail("Duplicate folders must not be published")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testSelectionStoreIsolatedRelaunchAndCleanup() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest("synthetic-account-a"), root: root)
        let secondStore = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest("synthetic-account-b"), root: root)
        XCTAssertNil(try firstStore.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try firstStore.save(first)
        try secondStore.save(second)
        XCTAssertEqual(try firstStore.load(), first)
        XCTAssertEqual(try secondStore.load(), second)
        XCTAssertTrue(FoundationMusicLibraryStore.clear(retaining: firstStore.scope, root: root))
        XCTAssertEqual(try firstStore.load(), first)
        XCTAssertNil(try secondStore.load())
        try firstStore.save(nil)
        XCTAssertNil(try firstStore.load())
    }

    func testStoreRejectsSymbolicLinksAndLeavesTargetUntouched() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let store = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest("synthetic-account"), root: link)
        XCTAssertThrowsError(try store.save(first))
        XCTAssertThrowsError(try store.load())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        XCTAssertFalse(FoundationMusicLibraryStore.clear(root: link))
    }

    @MainActor
    func testSelectionPersistsOnlyExplicitChoiceAndNeverChangesPlaybackOwner() async throws {
        let first = first
        var saved: FoundationMusicLibraryChoice?
        var applications: [String?] = []
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic.mp3") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
        player.setQueue(
            [
                FoundationItem(
                    id: "synthetic", title: "", subtitle: "", kind: .track, duration: nil)
            ], selectedIndex: 0)
        await player.selectionTask?.value
        await player.playTask?.value
        let nativeItem = try XCTUnwrap(player.nativePlayer.currentItem)
        let occurrence = player.selectedEntryID
        let intent = player.wantsPlayback
        defer { player.stop() }
        let identity = ObjectIdentifier(player)
        let model = FoundationMusicLibrarySelection(
            load: { [first] }, save: { saved = $0 },
            apply: { id, available in
                XCTAssertTrue(available)
                applications.append(id)
            })
        _ = try await model.loadChoices()
        XCTAssertNil(saved)
        XCTAssertTrue(applications.isEmpty)
        try await model.select(first)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(saved, first)
        XCTAssertEqual(applications, [first.id])
        XCTAssertEqual(ObjectIdentifier(player), identity)
        XCTAssertTrue(player.nativePlayer.currentItem === nativeItem)
        XCTAssertEqual(player.selectedEntryID, occurrence)
        XCTAssertEqual(player.wantsPlayback, intent)
        try await model.select(nil)
        XCTAssertNil(saved)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(applications.count, 2)
        XCTAssertTrue(player.nativePlayer.currentItem === nativeItem)
        XCTAssertEqual(player.selectedEntryID, occurrence)
        XCTAssertEqual(player.wantsPlayback, intent)
    }

    @MainActor
    func testOfflineGuardPreventsListingAndSelectionWrites() async {
        let recorder = Requests()
        var wrote = false
        var applied = false
        let model = FoundationMusicLibrarySelection(
            selected: first,
            load: {
                await recorder.markLoad()
                return []
            }, save: { _ in wrote = true }, allowsNetwork: { false },
            apply: { _, _ in applied = true })
        do {
            _ = try await model.loadChoices()
            XCTFail("Offline listing must fail")
        } catch {}
        do {
            try await model.select(nil)
            XCTFail("Offline Save must fail")
        } catch {}
        await model.validateSavedChoice()
        let count = await recorder.loadCount
        XCTAssertEqual(count, 0)
        XCTAssertFalse(wrote)
        XCTAssertFalse(applied)
        XCTAssertEqual(model.selectedID, first.id)
    }

    @MainActor
    func testMissingSavedChoiceRemainsSelectedAndExplicitAllRecovers() async throws {
        var availability: Bool?
        let model = FoundationMusicLibrarySelection(
            selected: first, load: { [] }, save: { _ in },
            apply: { _, available in availability = available })
        await model.validateSavedChoice()
        XCTAssertTrue(model.unavailable)
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(availability, false)
        try await model.select(nil)
        XCTAssertFalse(model.unavailable)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(availability, true)
    }

    @MainActor
    func testCorruptSelectionRequiresExplicitPersistedRecoveryAndHonorsFailureAndOffline()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest("synthetic-corrupt-account"), root: root)
        try store.save(first)
        let file = root.appendingPathComponent(store.scope, isDirectory: true)
            .appendingPathComponent("selection-v1.json")
        try Data(repeating: 0, count: 4097).write(to: file)
        XCTAssertThrowsError(try store.load())
        let account = FoundationJellyfinLibrary(session: session)
        var browse = account.scoped(to: nil, available: false)
        var events: [String] = []
        var online = true
        var saveFails = true
        let model = FoundationMusicLibrarySelection(
            selectionReadFailed: true,
            load: {
                XCTFail("Explicit All recovery needs no folder request")
                return []
            },
            save: { choice in
                events.append("save")
                if saveFails { throw CocoaError(.fileWriteUnknown) }
                try store.save(choice)
            }, allowsNetwork: { online },
            apply: { id, available in
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                events.append("apply")
                browse = account.scoped(to: id, available: available)
            })
        XCTAssertTrue(model.selectionReadFailed)
        XCTAssertTrue(browse.catalogScopeID.hasSuffix(".unavailable"))
        XCTAssertNotEqual(browse.catalogCacheKey("home-history"), "home-history")
        do {
            try await model.select(nil)
            XCTFail("Failed persistence must preserve the blocked catalog")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertEqual(events, ["save"])
        XCTAssertTrue(model.selectionReadFailed)
        XCTAssertTrue(browse.catalogScopeID.hasSuffix(".unavailable"))
        XCTAssertThrowsError(try store.load())
        online = false
        saveFails = false
        do {
            try await model.select(nil)
            XCTFail("Offline recovery must not write")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        XCTAssertEqual(events, ["save"])
        XCTAssertTrue(model.selectionReadFailed)
        online = true
        try await model.select(nil)
        XCTAssertEqual(events, ["save", "save", "apply"])
        XCTAssertFalse(model.selectionReadFailed)
        XCTAssertNil(model.selectedID)
        XCTAssertNil(try store.load())
        XCTAssertEqual(browse.catalogScopeID, "all")
        XCTAssertEqual(browse.catalogCacheKey("home-history"), "home-history")
    }

    @MainActor
    func testReplacementRelaunchAndFailedSaveKeepCommittedScopeAndDiskCoherent() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest("synthetic-replacement-account"), root: root)
        try store.save(first)
        let first = first
        let second = second
        var saveFails = true
        var applied: String? = first.id
        let model = FoundationMusicLibrarySelection(
            selected: try store.load(), load: { [first, second] },
            save: { choice in
                if saveFails { throw CocoaError(.fileWriteUnknown) }
                try store.save(choice)
            },
            apply: { id, available in
                XCTAssertTrue(available)
                applied = id
            })
        do {
            try await model.select(second)
            XCTFail("Save failure must preserve the previously committed choice")
        } catch { XCTAssertTrue(error is CocoaError) }
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(applied, first.id)
        XCTAssertEqual(try store.load(), first)
        saveFails = false
        try await model.select(second)
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertEqual(applied, second.id)
        XCTAssertEqual(try store.load(), second)
        let relaunched = FoundationMusicLibrarySelection(
            selected: try store.load(), load: { [first, second] }, save: { _ in },
            apply: { _, _ in })
        XCTAssertEqual(relaunched.selectedID, second.id)
        XCTAssertEqual(relaunched.selectedName, second.name)
    }

    @MainActor
    func testOfflineReconnectAndUncancellableOldValidationCannotOverrideNewSelection() async throws
    {
        let loader = ValidationBarrier(choices: [first, second])
        var online = false
        var applications: [(String?, Bool)] = []
        let model = FoundationMusicLibrarySelection(
            selected: first, load: { await loader.load() }, save: { _ in },
            allowsNetwork: { online }, apply: { applications.append(($0, $1)) })
        await model.validateSavedChoice()
        let offlineCount = await loader.count
        XCTAssertEqual(offlineCount, 0)
        XCTAssertTrue(applications.isEmpty)
        online = true
        let oldValidation = Task { await model.validateSavedChoice() }
        await loader.waitUntilFirstStarted()
        try await model.select(second)
        XCTAssertEqual(model.selectedID, second.id)
        await loader.releaseFirst(with: [])
        await oldValidation.value
        XCTAssertEqual(model.selectedID, second.id)
        XCTAssertFalse(model.unavailable)
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.0, second.id)
        XCTAssertEqual(applications.first?.1, true)
        await model.validateSavedChoice()
        let onlineCount = await loader.count
        XCTAssertEqual(onlineCount, 3)
        XCTAssertEqual(applications.count, 2)
        XCTAssertEqual(applications.last?.0, second.id)
        XCTAssertEqual(applications.last?.1, true)
    }

    func testDifferentServersAndAccountsRetainSeparateStoredChoices() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let accountA = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest(
                "jellyfin\0https://one.example.invalid/\0account-a"),
            root: root)
        let accountB = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest(
                "jellyfin\0https://one.example.invalid/\0account-b"),
            root: root)
        let serverB = FoundationMusicLibraryStore(
            scope: FoundationMusicLibraryStore.digest(
                "jellyfin\0https://two.example.invalid/\0account-a"),
            root: root)
        try accountA.save(first)
        XCTAssertNil(try accountB.load())
        XCTAssertNil(try serverB.load())
        try accountB.save(second)
        try serverB.save(second)
        try accountB.save(nil)
        XCTAssertEqual(try accountA.load(), first)
        XCTAssertNil(try accountB.load())
        XCTAssertEqual(try serverB.load(), second)
    }

    @MainActor
    func testCancellationAndInvalidationCannotPersistLateChoice() async {
        let first = first
        var wrote = false
        let model = FoundationMusicLibrarySelection(
            load: {
                try await Task.sleep(for: .seconds(5))
                return [first]
            }, save: { _ in wrote = true }, apply: { _, _ in XCTFail("Late scope change") })
        let task = Task { try await model.select(first) }
        await Task.yield()
        model.invalidate()
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch {}
        XCTAssertFalse(wrote)
        XCTAssertNil(model.selectedID)
    }

    func testBrowseScopeSharesAccountCacheButCannotReadAnotherFolderKey() async {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "synthetic-account", root: root)
        let account = FoundationJellyfinLibrary(session: session, catalogPageCache: cache)
        let firstLibrary = account.scoped(to: first.id)
        let secondLibrary = account.scoped(to: second.id)
        XCTAssertTrue(firstLibrary.catalogPageCache === account.catalogPageCache)
        XCTAssertTrue(secondLibrary.catalogPageCache === account.catalogPageCache)
        XCTAssertNotEqual(
            firstLibrary.catalogCacheKey("recent-albums"),
            secondLibrary.catalogCacheKey("recent-albums"))
        XCTAssertNotEqual(
            firstLibrary.catalogCacheKey("recent-albums"), account.catalogCacheKey("recent-albums"))
        XCTAssertEqual(account.catalogCacheKey("recent-albums"), "recent-albums")
        await cache.write(
            FoundationPage(
                items: [
                    FoundationItem(
                        id: first.id, title: "Fixture album", subtitle: "", kind: .album,
                        duration: nil)
                ],
                nextStartIndex: nil), key: firstLibrary.catalogCacheKey("recent-albums"))
        let firstPage = await cache.read(firstLibrary.catalogCacheKey("recent-albums"))
        let secondPage = await cache.read(secondLibrary.catalogCacheKey("recent-albums"))
        XCTAssertEqual(firstPage?.page.items.count, 1)
        XCTAssertNil(secondPage)
        let genreKey = "genre.albums.synthetic-genre"
        await cache.write(
            FoundationPage(
                items: [
                    FoundationItem(
                        id: first.id, title: "Fixture genre album", subtitle: "", kind: .album,
                        duration: nil)
                ], nextStartIndex: nil), key: firstLibrary.catalogCacheKey(genreKey))
        let firstGenrePage = await cache.read(firstLibrary.catalogCacheKey(genreKey))
        let secondGenrePage = await cache.read(secondLibrary.catalogCacheKey(genreKey))
        XCTAssertEqual(firstGenrePage?.page.items.first?.id, first.id)
        XCTAssertNil(secondGenrePage)
        let blocked = account.scoped(to: nil, available: false)
        XCTAssertNotEqual(
            blocked.catalogCacheKey("recent-albums"), account.catalogCacheKey("recent-albums"))
    }

    /// A held first response deliberately ignores cancellation to exercise the epoch guard.
    private actor ValidationBarrier {
        let choices: [FoundationMusicLibraryChoice]
        var count = 0
        private var first: CheckedContinuation<[FoundationMusicLibraryChoice], Never>?
        private var started: [CheckedContinuation<Void, Never>] = []

        init(choices: [FoundationMusicLibraryChoice]) { self.choices = choices }

        func load() async -> [FoundationMusicLibraryChoice] {
            count += 1
            guard count == 1 else { return choices }
            return await withCheckedContinuation { continuation in
                first = continuation
                for waiter in started { waiter.resume() }
                started = []
            }
        }

        func waitUntilFirstStarted() async {
            guard count == 0 else { return }
            await withCheckedContinuation { started.append($0) }
        }

        func releaseFirst(with choices: [FoundationMusicLibraryChoice]) {
            first?.resume(returning: choices)
            first = nil
        }
    }

    func testBlockedCatalogRecommendationsMakeNoAccountWideRequest() async throws {
        let recorder = Requests()
        let account = FoundationJellyfinLibrary(
            session: session,
            load: { request in
                await recorder.append(request)
                return (Data("{\"Items\":[],\"TotalRecordCount\":0}".utf8), Self.response(request))
            })
        let item = FoundationItem(
            id: first.id, title: "Fixture album", subtitle: "", kind: .album, duration: nil)
        let blocked = account.scoped(to: nil, available: false)
        let blockedPage = try await blocked.similarItems(for: item)
        XCTAssertTrue(blockedPage.items.isEmpty)
        let scopedPage = try await account.scoped(to: first.id).similarItems(for: item)
        XCTAssertTrue(scopedPage.items.isEmpty)
        let requests = await recorder.values
        XCTAssertTrue(requests.isEmpty)
    }

    private actor Requests {
        var values: [URLRequest] = []
        var loadCount = 0
        func append(_ value: URLRequest) { values.append(value) }
        func markLoad() { loadCount += 1 }
    }
    private static func response(_ request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
