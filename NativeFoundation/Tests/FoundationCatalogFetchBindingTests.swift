import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCatalogFetchBindingTests: XCTestCase {
    private let remoteID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        .init(
            serverURL: URL(string: "https://example.invalid/proxy/jellyfin/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "00000000-0000-0000-0000-000000000003")
    }
    private nonisolated static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
    private nonisolated static var page: Data {
        Data(
            #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"Synthetic"}],"TotalRecordCount":1,"StartIndex":0}"#
                .utf8)
    }
    private actor Recorder {
        var requests: [URLRequest] = []
        var scans = 0
        func append(_ request: URLRequest) { requests.append(request) }
        func scan() { scans += 1 }
    }
    private struct LocalFixture {
        let root: URL
        let folder: URL
        let storage: URL
        let source: FoundationLocalSource
        let id: UUID
        let recorder: Recorder
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private func local(
        names: [String] = ["Synthetic"],
        inspectionLimit: Int = FoundationLocalCatalogIndex.inspectionLimit
    ) async throws -> LocalFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("music")
        let storage = root.appendingPathComponent("private-index")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data([1]).write(to: folder.appendingPathComponent(name + ".mp3")) }
        let recorder = Recorder()
        let source = FoundationLocalSource(
            storage: storage, makeBookmark: { _ in Data([1]) },
            scan: { _, id, index in
                await recorder.scan()
                return try await index.refresh(
                    sourceID: id, authorizedRoot: folder,
                    inspectionLimit: inspectionLimit)
            })
        let id = try await source.select(folder)
        _ = try await source.refresh()
        return .init(
            root: root, folder: folder, storage: storage, source: source, id: id,
            recorder: recorder)
    }
    private actor HeldTransport {
        var started = false
        var startWaiter: CheckedContinuation<Void, Never>?
        var finishWaiters: [CheckedContinuation<Void, Never>] = []
        func hold() async {
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
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
            for waiter in finishWaiters { waiter.resume() }
            finishWaiters.removeAll()
        }
    }

    func testConcreteHeldJellyfinDoesNotBlockPersistedLocalCacheOrStartIndexing() async throws {
        let fixture = try await local()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.folder)
        let gate = HeldTransport()
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let binding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: library,
            local: fixture.source, localID: fixture.id)
        let pending = Task { try await binding.loadJellyfin() }
        await gate.waitForStart()
        try await binding.loadLocal()
        let interim = await binding.snapshots()
        XCTAssertEqual(interim.map(\.state), [.loading, .ready])
        XCTAssertEqual(interim[1].items.count, 1)
        XCTAssertEqual(interim[1].items[0].catalogSource, .local(sourceID: fixture.id))
        let scans = await fixture.recorder.scans
        XCTAssertEqual(scans, 1, "Cached browsing must never acquire folder access or start a scan")
        await gate.release()
        try await pending.value
        let completed = await binding.snapshots()
        XCTAssertEqual(completed.map(\.state), [.ready, .ready])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testFixedSearchAndCapturedMusicSelectionReachActualAdapterAndLocalTitleFilter()
        async throws
    {
        let fixture = try await local(names: ["Café", "Other"])
        defer { fixture.remove() }
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Self.page, Self.response(request))
        }
        let selectedID = "00000000000000000000000000000011"
        var selected = library.scoped(to: selectedID)
        let originalScope = selected.catalogScopeID
        let binding = try FoundationCatalogFetchBinding(
            query: .search(text: "  cafe  ", kind: .track), jellyfin: selected,
            local: fixture.source, localID: fixture.id)
        selected = selected.scoped(to: "00000000000000000000000000000022")
        XCTAssertNotEqual(selected.catalogScopeID, originalScope)
        try await binding.loadLocal()
        try await binding.loadJellyfin()
        let snapshots = await binding.snapshots()
        XCTAssertEqual(snapshots.map(\.state), [.ready, .ready])
        XCTAssertEqual(snapshots[1].items.map(\.title), ["Café"])
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name.lowercased() == "searchterm" }?.value, "cafe")
        XCTAssertEqual(query.first { $0.name.lowercased() == "parentid" }?.value, selectedID)
    }

    func testReselectedFolderRetiresPriorLocalRecordsAndRouteBeforePublication() async throws {
        let fixture = try await local()
        defer { fixture.remove() }
        let binding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: nil,
            local: fixture.source, localID: fixture.id)
        try await binding.loadLocal()
        let original = await binding.snapshots()
        let item = try XCTUnwrap(original.first?.items.first)
        _ = try await fixture.source.select(fixture.folder)
        do {
            try await binding.loadLocal()
            XCTFail("A new folder identity must never receive old source records")
        } catch FoundationCatalogComposition.Failure.invalidSource {}
        let retired = await binding.snapshots()
        XCTAssertTrue(retired.isEmpty)
        do {
            _ = try await binding.route(for: item, requiring: .catalogPresence)
            XCTFail("Retired source still routed")
        } catch FoundationCatalogComposition.Failure.unavailable {}
    }

    func testChangedLocalIndexCannotReuseOldPaginationCursor() async throws {
        let fixture = try await local(names: (0..<51).map { "Synthetic\($0)" })
        defer { fixture.remove() }
        let binding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: nil,
            local: fixture.source, localID: fixture.id)
        try await binding.loadLocal()
        let first = await binding.snapshots()
        XCTAssertEqual(first.first?.items.count, 50)
        XCTAssertEqual(first.first?.nextStartIndex, 50)
        try Data([1]).write(to: fixture.folder.appendingPathComponent("Added.mp3"))
        _ = try await fixture.source.refresh()
        do {
            try await binding.loadLocal()
            XCTFail("Offset from an older index snapshot was reused")
        } catch FoundationCatalogComposition.Failure.stale {}
        let retired = await binding.snapshots()
        XCTAssertTrue(retired.isEmpty)
    }

    func testRetiredHeldServerCannotPublishOrDispatchAgainAndLocalSurvives() async throws {
        let fixture = try await local()
        defer { fixture.remove() }
        let gate = HeldTransport()
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            await gate.hold()
            return (Self.page, Self.response(request))
        }
        let binding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: library,
            local: fixture.source, localID: fixture.id)
        try await binding.loadLocal()
        let pending = Task { try await binding.loadJellyfin() }
        await gate.waitForStart()
        let remote = try FoundationCatalogSource.jellyfin(scope: library.catalogAccountIdentity)
        await binding.retire(remote)
        await gate.release()
        do {
            try await pending.value
            XCTFail("Late retired server page published")
        } catch FoundationCatalogComposition.Failure.stale {}
        let snapshots = await binding.snapshots()
        XCTAssertEqual(snapshots.map(\.source), [.local(sourceID: fixture.id)])
        XCTAssertEqual(snapshots.first?.state, .ready)
        do {
            try await binding.loadJellyfin()
            XCTFail("Retired server dispatched another request")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        let legacy = FoundationItem(
            id: remoteID, title: "Synthetic", subtitle: "", kind: .track,
            duration: nil)
        do {
            _ = try await binding.route(for: legacy, requiring: .playback)
            XCTFail("Retired server still routed a legacy item")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    func testPartialCorruptAndEmptyLocalStatesRemainHonest() async throws {
        let partial = try await local(names: ["One", "Two"], inspectionLimit: 1)
        defer { partial.remove() }
        let binding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: nil,
            local: partial.source, localID: partial.id)
        try await binding.loadLocal()
        let partialSnapshots = await binding.snapshots()
        XCTAssertEqual(partialSnapshots.first?.state, .partial)
        let file = partial.storage.appendingPathComponent("catalogs")
            .appendingPathComponent(partial.id.uuidString).appendingPathExtension("json")
        try Data([255]).write(to: file)
        let corruptBinding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: nil,
            local: partial.source, localID: partial.id)
        try await corruptBinding.loadLocal()
        let unavailable = await corruptBinding.snapshots()
        XCTAssertEqual(unavailable.first?.state, .unavailable)
        XCTAssertTrue(unavailable.first?.items.isEmpty == true)
        let empty = try await local(names: [])
        defer { empty.remove() }
        let emptyBinding = try FoundationCatalogFetchBinding(
            query: .songs, jellyfin: nil,
            local: empty.source, localID: empty.id)
        try await emptyBinding.loadLocal()
        let emptySnapshots = await emptyBinding.snapshots()
        XCTAssertEqual(emptySnapshots.first?.state, .empty)
    }

    func testNonTrackSearchDoesNotInventLocalAlbumsAndInvalidBindingFails() async throws {
        let fixture = try await local()
        defer { fixture.remove() }
        let binding = try FoundationCatalogFetchBinding(
            query: .search(text: "Synthetic", kind: .album), jellyfin: nil,
            local: fixture.source, localID: fixture.id)
        try await binding.loadLocal()
        let snapshots = await binding.snapshots()
        XCTAssertEqual(snapshots.first?.state, .empty)
        XCTAssertThrowsError(
            try FoundationCatalogFetchBinding(
                query: .songs, jellyfin: nil,
                local: fixture.source, localID: nil))
        XCTAssertThrowsError(
            try FoundationCatalogFetchBinding(
                query: .search(text: String(repeating: "x", count: 1025), kind: .track),
                jellyfin: nil, local: nil, localID: nil))
    }
}
