import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCatalogRoutingTests: XCTestCase {
    private let itemID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        .init(
            serverURL: URL(string: "https://example.invalid/proxy/jellyfin/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "00000000-0000-0000-0000-000000000003")
    }
    private func item(_ kind: FoundationItem.Kind, source: FoundationCatalogSource? = nil)
        -> FoundationItem
    {
        .init(
            id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil,
            catalogSource: source)
    }
    private nonisolated static func response(_ request: URLRequest, status: Int = 200)
        -> HTTPURLResponse
    {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    private actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    func testEveryItemBoundaryRejectsForeignAndLocalBeforeSentinelTransport() async throws {
        let requests = Counter()
        let library = FoundationJellyfinLibrary(session: session) { _ in
            await requests.increment()
            throw FoundationLibraryError.invalidResponse
        }
        let operations: [(FoundationItem.Kind, @Sendable (FoundationItem) async throws -> Void)] = [
            (.album, { _ = try await library.similarItems(for: $0) }),
            (.track, { _ = try await library.itemMetadata(for: $0) }),
            (.artist, { _ = try await library.overview(for: $0) }),
            (.artist, { _ = try await library.itemDetails(for: $0) }),
            (.track, { try await library.setFavorite(for: $0, isFavorite: true) }),
            (.track, { _ = try await library.lyrics(for: $0) }),
            (.track, { _ = try await library.downloadSource(for: $0) }),
            (.track, { _ = try await library.downloadPreparation(for: $0, quality: .original) }),
            (
                .track,
                { _ = try await library.convertedDownloadProposal(for: $0, quality: .aac128) }
            ),
            (.track, { _ = try await library.playbackResource(for: $0) }),
            (.track, { _ = try await library.playbackURL(for: $0) }),
            (.album, { _ = try await library.cachedArtworkResult(for: $0, size: 160) }),
            (.album, { _ = try await library.artwork(for: $0) }),
            (.album, { _ = try await library.artwork(for: $0, size: 160) }),
            (
                .album,
                { _ = try await library.downloadArtwork(for: $0, size: 160, allowsCellular: false) }
            ),
            (
                .album,
                { _ = try await library.artworkResult(for: $0, size: 160, allowsNetwork: false) }
            ),
            (.track, { try await library.addTracks(to: "playlist", tracks: [$0]) }),
        ]
        for source in [
            try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64)),
            .local(sourceID: UUID()),
        ] {
            for (kind, operation) in operations {
                do {
                    try await operation(item(kind, source: source))
                    XCTFail("Foreign source reached an item operation")
                } catch {
                    XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
                }
            }
            let cached = await library.cachedArtistDetails(for: item(.artist, source: source))
            XCTAssertNil(cached)
            await library.invalidateItemDetails(for: item(.artist, source: source))
            await library.retryArtwork(for: item(.album, source: source))
        }
        let count = await requests.value
        XCTAssertEqual(count, 0)
    }

    func testExplicitMatchingSourceAndLegacyStillUseExactAccountAcrossCatalogSelection()
        async throws
    {
        let requests = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await requests.increment()
            return (Data(#"{"Lyrics":[]}"#.utf8), Self.response(request))
        }
        let expected = FoundationMusicLibraryStore.digest(
            "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID)
        XCTAssertEqual(library.catalogAccountIdentity, expected)
        let selected = library.scoped(to: "music-folder")
        XCTAssertEqual(selected.catalogAccountIdentity, library.catalogAccountIdentity)
        XCTAssertNotEqual(selected.catalogScopeID, selected.catalogAccountIdentity)
        let source = try FoundationCatalogSource.jellyfin(scope: expected)
        _ = try await selected.lyrics(for: item(.track, source: source))
        _ = try await selected.lyrics(for: item(.track))
        let count = await requests.value
        XCTAssertEqual(count, 2)
    }

    func testForeignReferenceRejectsLegacyParentBeforeTransportAndMixedTrackArrayIsAtomic()
        async throws
    {
        let requests = Counter()
        let library = FoundationJellyfinLibrary(session: session) { _ in
            await requests.increment()
            throw FoundationLibraryError.invalidResponse
        }
        var parent = item(.album)
        parent.artist = .init(
            id: "artist", title: "Synthetic", catalogSource: .local(sourceID: UUID()))
        do {
            _ = try await library.similarItems(for: parent)
            XCTFail("Foreign related source reached server endpoint")
        } catch {
            XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
        }
        do {
            try await library.addTracks(
                to: "playlist",
                tracks: [
                    item(.track),
                    item(
                        .track,
                        source: .local(sourceID: UUID())),
                ])
            XCTFail("Mixed-source tracks reached mutation")
        } catch {
            XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
        }
        let count = await requests.value
        XCTAssertEqual(count, 0)
    }

    func testForeignArtistCannotReadOrInvalidateMatchingAccountMemo() async throws {
        let requests = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await requests.increment()
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Synthetic","Overview":"Cached"}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = item(.artist)
        _ = try await library.overview(for: artist)
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64))
        let foreign = item(.artist, source: source)
        let hidden = await library.cachedArtistDetails(for: foreign)
        XCTAssertNil(hidden)
        await library.invalidateItemDetails(for: foreign)
        let retained = await library.cachedArtistDetails(for: artist)
        XCTAssertEqual(retained?.overview, "Cached")
        let count = await requests.value
        XCTAssertEqual(count, 1)
    }

    func testForeignRetryCannotClearMatchingAccountArtworkNegativeCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic-routing", root: root)
        let loads = Counter()
        let album = item(.album)
        _ = try await cache.result(for: album, pixels: 160, allowsNetwork: true) { _, _ in
            await loads.increment()
            return nil
        }
        let library = FoundationJellyfinLibrary(
            session: session,
            load: { _ in
                XCTFail("Foreign artwork must never reach transport")
                throw FoundationLibraryError.invalidResponse
            }, artworkCache: cache)
        for source in [
            try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64)),
            .local(sourceID: UUID()),
        ] {
            let foreign = item(.album, source: source)
            await library.retryArtwork(for: foreign)
            do {
                _ = try await library.cachedArtworkResult(for: foreign, size: 160)
                XCTFail("Foreign cache read accepted")
            } catch {
                XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
            }
        }
        _ = try await cache.result(for: album, pixels: 160, allowsNetwork: true) { _, _ in
            await loads.increment()
            return nil
        }
        let count = await loads.value
        XCTAssertEqual(
            count, 1, "A foreign retry must not revoke the current account's failure entry")
        _ = await cache.invalidate(removeDisk: true)
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

    func testForeignAndLocalMetadataRejectWhileMatchingTransportIsHeld() async throws {
        let gate = HeldTransport()
        let requests = Counter()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await requests.increment()
            await gate.hold()
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Synthetic","Overview":"Ready"}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = item(.artist)
        let matching = Task { try await library.overview(for: artist) }
        await gate.waitForStart()
        let completed = expectation(
            description: "Foreign and local rejection precedes transport release")
        completed.expectedFulfillmentCount = 2
        let foreign = item(.artist, source: try .jellyfin(scope: String(repeating: "b", count: 64)))
        let local = item(.artist, source: .local(sourceID: UUID()))
        let checks = [foreign, local].map { candidate in
            Task {
                do {
                    _ = try await library.overview(for: candidate)
                    XCTFail("Foreign source joined matching account's pending memo")
                } catch {
                    XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
                }
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 2)
        await gate.release()
        _ = try await matching.value
        for check in checks { await check.value }
        let count = await requests.value
        XCTAssertEqual(count, 1)
    }

}
