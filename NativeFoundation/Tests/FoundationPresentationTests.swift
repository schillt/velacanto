import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPresentationTests: XCTestCase {
    func testArtworkMorphUsesCanonicalIdentityAndExactArtworkRectangles() {
        let compact = CGRect(x: 18, y: 730, width: 34, height: 34)
        let expanded = CGRect(x: 0, y: 60, width: 390, height: 430)
        XCTAssertEqual(
            artworkTransition(compact: compact, expanded: expanded),
            .morph(compact: compact, expanded: expanded))
        XCTAssertEqual(
            artworkTransition(compact: compact, expanded: expanded, compactIdentity: "other"),
            .fade(.differentIdentity))
    }

    func testArtworkMorphNeverGuessesMissingOrOffscreenSourceGeometry() {
        let expanded = CGRect(x: 0, y: 60, width: 390, height: 430)
        XCTAssertEqual(
            artworkTransition(compact: nil, expanded: expanded), .fade(.unavailableGeometry))
        XCTAssertEqual(
            artworkTransition(compact: .zero, expanded: expanded), .fade(.unavailableGeometry))
        XCTAssertEqual(
            artworkTransition(
                compact: CGRect(x: 18, y: 830, width: 34, height: 34), expanded: expanded),
            .fade(.offscreenSource))
        XCTAssertEqual(
            artworkTransition(
                compact: CGRect(x: 18, y: 730, width: .infinity, height: 34), expanded: expanded),
            .fade(.unavailableGeometry))
    }

    func testArtworkMorphRequiresAnImageAndHonorsReduceMotion() {
        let compact = CGRect(x: 18, y: 730, width: 34, height: 34)
        let expanded = CGRect(x: 0, y: 60, width: 390, height: 430)
        XCTAssertEqual(
            artworkTransition(compact: compact, expanded: expanded, artworkIdentity: nil),
            .fade(.missingArtwork))
        XCTAssertEqual(
            artworkTransition(compact: compact, expanded: expanded, reduceMotion: true),
            .fade(.reduceMotion))
    }

    private func artworkTransition(
        compact: CGRect?, expanded: CGRect?, artworkIdentity: String? = "album",
        compactIdentity: String? = "album", reduceMotion: Bool = false
    ) -> FoundationPlayerArtworkTransitionDecision {
        FoundationPlayerArtworkTransitionDecision.resolve(
            artworkIdentity: artworkIdentity, compactIdentity: compactIdentity,
            expandedIdentity: "album", compactRect: compact, expandedRect: expanded,
            containerBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            reduceMotion: reduceMotion)
    }

    func testRelatedCatalogRoutesRetainCanonicalMetadataAndArtworkIdentity() throws {
        let artist = FoundationItemReference(
            id: "artist", title: "Album Artist", primaryImageTag: "artist-revision")
        let album = FoundationItemReference(
            id: "album", title: "Album", primaryImageTag: "album-revision")
        let track = FoundationItem(
            id: "track", title: "Song", subtitle: "Track credit", kind: .track, duration: 60,
            album: album, artist: artist)
        let albumRoute = try XCTUnwrap(track.relatedAlbum)
        let artistRoute = try XCTUnwrap(track.relatedArtist)
        XCTAssertEqual(albumRoute.artist, artist)
        XCTAssertEqual(albumRoute.subtitle, "Album Artist")
        XCTAssertEqual(albumRoute.primaryImageTag, "album-revision")
        XCTAssertEqual(artistRoute.primaryImageTag, "artist-revision")
        XCTAssertEqual(albumRoute.relatedArtist, artistRoute)
        XCTAssertEqual(albumRoute.sharedArtworkIdentity, track.sharedArtworkIdentity)
        XCTAssertNotEqual(artistRoute.sharedArtworkIdentity, albumRoute.sharedArtworkIdentity)
    }

    func testMissingRelatedMetadataCannotRouteToAnInventedCatalogItem() {
        var track = FoundationItem(
            id: "track", title: "Song", subtitle: "Track credit", kind: .track, duration: nil)
        XCTAssertNil(track.relatedAlbum)
        XCTAssertNil(track.relatedArtist)
        track.album = FoundationItemReference(id: "", title: "Album")
        track.artist = FoundationItemReference(id: "", title: "Artist")
        XCTAssertNil(track.relatedAlbum)
        XCTAssertNil(track.relatedArtist)
    }

    func testKnownRelatedIdentityWithUnknownTitleKeepsUsableFallback() throws {
        let track = FoundationItem(
            id: "track", title: "Song", subtitle: "Track credit", kind: .track, duration: nil,
            album: FoundationItemReference(id: "album", title: ""),
            artist: FoundationItemReference(id: "artist", title: ""))
        let album = try XCTUnwrap(track.relatedAlbum)
        let artist = try XCTUnwrap(track.relatedArtist)
        XCTAssertEqual(album.id, "album")
        XCTAssertEqual(album.title, "Album")
        XCTAssertEqual(album.subtitle, "Track credit")
        XCTAssertEqual(artist.id, "artist")
        XCTAssertEqual(artist.title, "Artist")
        XCTAssertNil(album.primaryImageTag)
        XCTAssertNil(artist.primaryImageTag)
    }

    func testAccountAlertDismissalDefersModelChangeAndKeepsNewNotice() async {
        let model = FoundationAppModel()
        model.signOutNotice = "First sign-out result"
        let view = FoundationRootView(model: model)

        view.accountAlertPresented.wrappedValue = false
        XCTAssertEqual(model.signOutNotice, "First sign-out result")
        model.signOutNotice = "New sign-out result"
        await nextMainQueueTurn()
        XCTAssertEqual(model.signOutNotice, "New sign-out result")

        view.accountAlertPresented.wrappedValue = false
        await nextMainQueueTurn()
        XCTAssertNil(model.signOutNotice)
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testMixedFavoritesQueueUsesOnlyLoadedTracksAndPreservesDuplicateSelection() async {
        let model = FoundationBrowseModel()
        let track = FoundationItem(
            id: "same", title: "Track", subtitle: "", kind: .track, duration: nil)
        let album = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        await model.loadPending { _ in
            FoundationPage(items: [album, track, album, track], nextStartIndex: 50)
        }
        let selection = model.trackQueue(selecting: 3)
        XCTAssertEqual(selection?.items, [track, track])
        XCTAssertEqual(selection?.index, 1)
        XCTAssertNil(model.trackQueue(selecting: 0))
        XCTAssertNil(model.trackQueue(selecting: 4))
    }

    func testOriginalNavigationOrderIsPreserved() {
        XCTAssertEqual(
            FoundationDestination.allCases.map(\.title), ["Home", "New", "Library", "Search"])
    }

    func testInactiveTabMakesNoReadAndRetainsPendingExplicitAction() async {
        let model = FoundationBrowseModel()
        var offsets: [Int] = []
        let loader: (Int) async throws -> FoundationPage = { offset in
            offsets.append(offset)
            return FoundationPage(items: [], nextStartIndex: 50)
        }
        await model.loadPending(ifActive: false, using: loader)
        XCTAssertTrue(offsets.isEmpty)
        await model.loadPending(ifActive: true, using: loader)
        model.request(.more)
        await model.loadPending(ifActive: false, using: loader)
        XCTAssertEqual(offsets, [0])
        await model.loadPending(ifActive: true, using: loader)
        await model.loadPending(ifActive: true, using: loader)
        XCTAssertEqual(offsets, [0, 50])
    }

    func testAlbumAndArtistTabsRetainIndependentEmptyPages() async {
        let albums = FoundationBrowseModel()
        let artists = FoundationBrowseModel()
        var albumReads = 0
        var artistReads = 0
        let albumLoader: (Int) async throws -> FoundationPage = { _ in
            albumReads += 1
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        let artistLoader: (Int) async throws -> FoundationPage = { _ in
            artistReads += 1
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        await albums.loadPending(ifActive: true, using: albumLoader)
        await artists.loadPending(ifActive: false, using: artistLoader)
        XCTAssertEqual(artistReads, 0)
        await artists.loadPending(ifActive: true, using: artistLoader)
        await albums.loadPending(ifActive: true, using: albumLoader)
        await artists.loadPending(ifActive: true, using: artistLoader)
        XCTAssertEqual(albumReads, 1)
        XCTAssertEqual(artistReads, 1)
    }

    func testEmptyLoadedPageDoesNotReloadOnReentry() async {
        let model = FoundationBrowseModel()
        var reads = 0
        let loader: (Int) async throws -> FoundationPage = { _ in
            reads += 1
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        await model.load(.initial, using: loader)
        await model.load(.initial, using: loader)
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(model.loaded)
        await model.load(.refresh, using: loader)
        XCTAssertEqual(reads, 2)
    }

    func testConsumedPageAndRefreshActionsDoNotReplayOnAppearance() async {
        let model = FoundationBrowseModel()
        var offsets: [Int] = []
        let loader: (Int) async throws -> FoundationPage = { offset in
            offsets.append(offset)
            return FoundationPage(items: [], nextStartIndex: offset + 50)
        }
        await model.loadPending(using: loader)
        model.request(.more)
        await model.loadPending(using: loader)
        await model.loadPending(using: loader)
        XCTAssertEqual(offsets, [0, 50])
        model.request(.refresh)
        await model.loadPending(using: loader)
        await model.loadPending(using: loader)
        XCTAssertEqual(offsets, [0, 50, 0])
        model.request(.more)
        await model.loadPending(using: loader)
        XCTAssertEqual(offsets, [0, 50, 0, 50])
    }

    func testCancelledAppearanceDoesNotConsumePendingPage() async {
        let model = FoundationBrowseModel()
        await model.loadPending { _ in FoundationPage(items: [], nextStartIndex: 50) }
        model.request(.more)
        let cancelled = Task {
            await model.loadPending { _ in
                XCTFail("Cancelled appearance started a read")
                return FoundationPage(items: [], nextStartIndex: nil)
            }
        }
        cancelled.cancel()
        await cancelled.value
        var offsets: [Int] = []
        await model.loadPending {
            offsets.append($0)
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(offsets, [50])
    }

    func testInitialFailureWaitsForExplicitRetryAfterReappearance() async {
        let model = FoundationBrowseModel()
        var reads = 0
        await model.loadPending { _ in
            reads += 1
            throw URLError(.timedOut)
        }
        await model.loadPending { _ in
            reads += 1
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertNotNil(model.errorMessage)
        model.request(model.retryRequest)
        await model.loadPending { _ in
            reads += 1
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testFailedRefreshKeepsPageAndExplicitRefreshRecovers() async {
        let model = FoundationBrowseModel()
        let item = FoundationItem(
            id: "synthetic", title: "Album", subtitle: "", kind: .album, duration: nil)
        await model.load(.initial) { _ in FoundationPage(items: [item], nextStartIndex: nil) }
        await model.load(.refresh) { _ in throw URLError(.timedOut) }
        XCTAssertEqual(model.items, [item])
        XCTAssertNotNil(model.errorMessage)
        await model.load(.refresh) { _ in FoundationPage(items: [], nextStartIndex: nil) }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func testCancellationIgnoringOldPageCannotReplaceNewPage() async {
        let model = FoundationBrowseModel()
        let started = expectation(description: "Old load held")
        var release: CheckedContinuation<FoundationPage, Never>?
        let old = Task {
            await model.load(.initial) { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        let new = FoundationItem(id: "new", title: "New", subtitle: "", kind: .album, duration: nil)
        await model.load(.refresh) { _ in FoundationPage(items: [new], nextStartIndex: nil) }
        release?.resume(returning: FoundationPage(items: [], nextStartIndex: 50))
        await old.value
        XCTAssertEqual(model.items, [new])
        XCTAssertNil(model.nextStartIndex)
        XCTAssertFalse(model.isLoading)
    }

    func testNewAlbumsCompleteWhileTracksStallAndCancelledTrackResultStaysUnpublished() async {
        let tracks = FoundationBrowseModel()
        let albums = FoundationBrowseModel()
        let trackStarted = expectation(description: "Track section request is suspended")
        var releaseTrack: CheckedContinuation<FoundationPage, Never>?
        var trackOffsets: [Int] = []
        var albumOffsets: [Int] = []
        let album = FoundationItem(
            id: "recent-album", title: "Album", subtitle: "", kind: .album, duration: nil)
        let track = FoundationItem(
            id: "recent-track", title: "Track", subtitle: "", kind: .track, duration: nil)
        let trackLoad = Task {
            await tracks.loadPending { offset in
                trackOffsets.append(offset)
                return await withCheckedContinuation { continuation in
                    releaseTrack = continuation
                    trackStarted.fulfill()
                }
            }
        }
        await fulfillment(of: [trackStarted], timeout: 2)
        await albums.loadPending { offset in
            albumOffsets.append(offset)
            return FoundationPage(items: [album], nextStartIndex: 50)
        }
        XCTAssertTrue(tracks.isLoading)
        XCTAssertFalse(tracks.loaded)
        XCTAssertEqual(albums.items, [album])
        XCTAssertFalse(albums.isLoading)
        XCTAssertEqual(trackOffsets, [0])
        XCTAssertEqual(albumOffsets, [0])

        // Leaving New cancels the owner, even if its loader finishes afterward.
        trackLoad.cancel()
        releaseTrack?.resume(returning: FoundationPage(items: [track], nextStartIndex: 100))
        await trackLoad.value
        XCTAssertTrue(tracks.items.isEmpty)
        XCTAssertFalse(tracks.loaded)
        XCTAssertNil(tracks.nextStartIndex)
        XCTAssertNil(tracks.errorMessage)
        XCTAssertFalse(tracks.isLoading)
        XCTAssertEqual(albums.items, [album])
        XCTAssertEqual(albums.nextStartIndex, 50)
    }

    func testNewSharedPagesEnterSeeAllWithoutReadsAndContinueOnlyOnExplicitLoadMore() async {
        let tracks = FoundationBrowseModel()
        let albums = FoundationBrowseModel()
        let first = FoundationItem(
            id: "first-track", title: "Track", subtitle: "", kind: .track, duration: nil)
        let next = FoundationItem(
            id: "next-track", title: "Track", subtitle: "", kind: .track, duration: nil)
        var trackOffsets: [Int] = []
        var albumOffsets: [Int] = []
        let loadTracks: (Int) async throws -> FoundationPage = { offset in
            trackOffsets.append(offset)
            return offset == 0
                ? FoundationPage(items: [first], nextStartIndex: 100)
                : FoundationPage(items: [next], nextStartIndex: nil)
        }
        let loadAlbums: (Int) async throws -> FoundationPage = { offset in
            albumOffsets.append(offset)
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        await tracks.loadPending(using: loadTracks)
        await albums.loadPending(using: loadAlbums)

        // See All and its source shelf reuse the same owners, including empty content.
        let seeAllTracks = tracks
        let seeAllAlbums = albums
        await seeAllTracks.loadPending(using: loadTracks)
        await seeAllAlbums.loadPending(using: loadAlbums)
        XCTAssertEqual(trackOffsets, [0])
        XCTAssertEqual(albumOffsets, [0])
        XCTAssertEqual(seeAllTracks.items, [first])
        XCTAssertEqual(seeAllTracks.nextStartIndex, 100)
        XCTAssertTrue(seeAllAlbums.loaded)
        XCTAssertTrue(seeAllAlbums.items.isEmpty)

        seeAllTracks.request(.more)
        await seeAllTracks.loadPending(using: loadTracks)
        await tracks.loadPending(using: loadTracks)
        await albums.loadPending(using: loadAlbums)
        XCTAssertEqual(trackOffsets, [0, 100])
        XCTAssertEqual(albumOffsets, [0])
        XCTAssertEqual(tracks.items, [first, next])
        XCTAssertNil(tracks.nextStartIndex)
    }

}
