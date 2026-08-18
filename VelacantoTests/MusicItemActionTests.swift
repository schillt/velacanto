import XCTest

@testable import Velacanto

@MainActor
final class MusicItemActionTests: XCTestCase {
    func testFavoriteRequestUsesProviderEndpointAndHTTPVerb() throws {
        let builder = JellyfinRequestBuilder(
            server: try JellyfinServerURL("https://music.example.com/jellyfin"),
            deviceID: "device-id",
            accessToken: "private-token"
        )

        let favorite = try builder.favoriteRequest(
            itemID: "item-id",
            userID: "user-id",
            isFavorite: true
        )
        let unfavorite = try builder.favoriteRequest(
            itemID: "item-id",
            userID: "user-id",
            isFavorite: false
        )

        XCTAssertEqual(favorite.httpMethod, "POST")
        XCTAssertEqual(unfavorite.httpMethod, "DELETE")
        XCTAssertEqual(
            favorite.url?.path,
            "/jellyfin/Users/user-id/FavoriteItems/item-id"
        )
        XCTAssertNil(favorite.url?.query)
        XCTAssertFalse(favorite.url?.absoluteString.contains("private-token") == true)
    }

    func testFavoriteChangeIsOptimisticAndReconcilesOnSuccess() async {
        let provider = RecordingFavoriteProvider()
        let owner = MusicItemActionStateOwner()
        let item = catalogItem(isFavorite: false)
        owner.configure(accountScope: item.id.accountScope, provider: provider)
        owner.reconcile([item])

        owner.toggleFavorite(item)

        XCTAssertTrue(owner.isFavorite(item))
        XCTAssertTrue(owner.isUpdatingFavorite(item.id))
        await waitUntil { !owner.isUpdatingFavorite(item.id) }
        XCTAssertTrue(owner.isFavorite(item))
        owner.reconcile([catalogItem(isFavorite: false)])
        XCTAssertTrue(owner.isFavorite(item), "A late refresh must not undo a successful request")
        owner.reconcile([catalogItem(isFavorite: true)])
        let states = await provider.recordedStates()
        XCTAssertEqual(states, [true])
        XCTAssertNil(owner.failure)
    }

    func testRejectedFavoriteRestoresConfirmedStateWithSafeError() async {
        let provider = RecordingFavoriteProvider(error: .rejected)
        let owner = MusicItemActionStateOwner()
        let item = catalogItem(isFavorite: false)
        owner.configure(accountScope: item.id.accountScope, provider: provider)
        owner.reconcile([item])

        owner.toggleFavorite(item)

        XCTAssertTrue(owner.isFavorite(item))
        await waitUntil { !owner.isUpdatingFavorite(item.id) }
        XCTAssertFalse(owner.isFavorite(item))
        XCTAssertEqual(
            owner.failure?.message,
            "Couldn’t update this favorite. Your previous choice was restored."
        )
    }

    func testRapidFavoriteChangesFinishInRequestOrder() async {
        let provider = RecordingFavoriteProvider(delay: .milliseconds(40))
        let owner = MusicItemActionStateOwner()
        let item = catalogItem(isFavorite: false)
        owner.configure(accountScope: item.id.accountScope, provider: provider)
        owner.reconcile([item])

        owner.toggleFavorite(item)
        await waitUntil { await provider.requestCount() == 1 }
        owner.toggleFavorite(item)

        XCTAssertFalse(owner.isFavorite(item))
        owner.reconcile([catalogItem(isFavorite: true)])
        XCTAssertFalse(owner.isFavorite(item), "A stale refresh must not replace the latest tap")

        await waitUntil { !owner.isUpdatingFavorite(item.id) }
        let states = await provider.recordedStates()
        XCTAssertEqual(states, [true, false])
        XCTAssertFalse(owner.isFavorite(item))
    }

    func testPinsPersistPerAccountAndExcludeSongs() {
        let store = InMemoryLibraryPinStore()
        let provider = RecordingFavoriteProvider()
        let album = catalogItem(isFavorite: false, kind: .album)
        let song = catalogItem(isFavorite: false, kind: .song)
        let owner = MusicItemActionStateOwner(pinStore: store)
        owner.configure(accountScope: album.id.accountScope, provider: provider)

        XCTAssertTrue(owner.canPin(album))
        XCTAssertFalse(owner.canPin(song))

        owner.togglePin(album)
        XCTAssertTrue(owner.isPinned(album))
        XCTAssertEqual(owner.pinnedItems.map(\.id), [album.id])

        let restoredOwner = MusicItemActionStateOwner(pinStore: store)
        restoredOwner.configure(accountScope: album.id.accountScope, provider: provider)
        XCTAssertEqual(restoredOwner.pinnedItems.map(\.id), [album.id])

        restoredOwner.togglePin(album)
        XCTAssertTrue(restoredOwner.pinnedItems.isEmpty)
    }

    private func catalogItem(
        isFavorite: Bool,
        kind: MusicCatalogItem.Kind = .song
    ) -> MusicCatalogItem {
        MusicCatalogItem(
            id: MusicCatalogItemID(
                source: .jellyfin,
                accountScope: "server-id|user-id",
                opaqueID: "item-id"
            ),
            name: kind == .album ? "Album" : "Song",
            kind: kind,
            sortName: nil,
            artists: ["Artist"],
            albumArtist: nil,
            album: "Album",
            trackNumber: 1,
            discNumber: 1,
            childCount: nil,
            duration: 180,
            artwork: nil,
            isFavorite: isFavorite,
            capabilities: [.play, .favorite]
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for favorite state", file: file, line: line)
    }
}

private final class InMemoryLibraryPinStore: MusicLibraryPinStoring {
    private var pins: [String: [MusicCatalogItem]] = [:]

    func loadPins(accountScope: String) throws -> [MusicCatalogItem] {
        pins[accountScope] ?? []
    }

    func savePins(_ items: [MusicCatalogItem], accountScope: String) throws {
        pins[accountScope] = items
    }
}

private actor RecordingFavoriteProvider: MusicItemActionProviding {
    enum TestError: Error {
        case rejected
    }

    private let delay: Duration?
    private let error: TestError?
    private var states: [Bool] = []

    init(delay: Duration? = nil, error: TestError? = nil) {
        self.delay = delay
        self.error = error
    }

    func setFavorite(
        _ isFavorite: Bool,
        for itemID: MusicCatalogItemID
    ) async throws {
        states.append(isFavorite)
        if let delay {
            try await Task.sleep(for: delay)
        }
        if let error { throw error }
    }

    func requestCount() -> Int {
        states.count
    }

    func recordedStates() -> [Bool] {
        states
    }
}
