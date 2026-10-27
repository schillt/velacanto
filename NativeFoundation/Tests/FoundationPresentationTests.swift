import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPresentationTests: XCTestCase {
    #if os(macOS)
        func testHandoffBrowseRoutesWithoutAMountedRootCollectionBinding() async throws {
            let audio = FoundationMacHandoffAudioProbe()
            let player = FoundationPlayer(
                resolve: { item in try await audio.resolve(item) },
                activateSession: {}, deactivateSession: {})
            let original = FoundationQueueEntry(
                item: .init(
                    id: "current", title: "Current", subtitle: "", kind: .track, duration: 30))
            player.restoreSession(
                .init(
                    entries: [original], selectedEntryID: original.id,
                    shuffleEnabled: false, repeatMode: .off))
            let controller = FoundationHandoffController(publish: { _ in })
            controller.configure(
                scope: String(repeating: "a", count: 64), player: player,
                resolve: { $0 }, navigate: { _ in })
            defer {
                controller.invalidate()
                player.stop()
            }
            let navigation = FoundationMacNavigation()
            // No SwiftUI collection-binding observer is mounted in this seam.
            // Native continuation has already resolved the item for this account.
            for kind in [FoundationItem.Kind.album, .artist, .playlist] {
                let item = FoundationItem(
                    id: "incoming", title: "Incoming", subtitle: "", kind: kind, duration: nil)
                controller.requestBrowse(item)
                navigation.continueBrowsing(try XCTUnwrap(controller.takeBrowseRequest()))
                XCTAssertEqual(navigation.path.map(\.item), [item])
                XCTAssertNil(controller.takeBrowseRequest(), "A browse delivery is consumed once")
                XCTAssertEqual(player.persistedQueue, [original])
                XCTAssertEqual(player.selectedEntryID, original.id)
                XCTAssertFalse(player.wantsPlayback)
                XCTAssertEqual(player.state, .paused)
            }
            let resolutions = await audio.count
            XCTAssertEqual(resolutions, 0, "Browsing must not request an audio resource")
        }

        func testHandoffBrowseReplacesExistingMacDetailPath() {
            let navigation = FoundationMacNavigation()
            let album = FoundationItem(
                id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
            let artist = FoundationItem(
                id: "artist", title: "Artist", subtitle: "", kind: .artist, duration: nil)
            let playlist = FoundationItem(
                id: "playlist", title: "Playlist", subtitle: "", kind: .playlist, duration: nil)
            navigation.open(album)
            navigation.open(artist)
            let previousOwners = Set(navigation.path.map(\.headerOwnerID))

            navigation.continueBrowsing(playlist)

            XCTAssertEqual(navigation.path.map(\.item), [playlist])
            XCTAssertFalse(previousOwners.contains(navigation.path[0].headerOwnerID))
        }

        func testPlaylistTitleChangePreservesSidebarDestinationIdentity() {
            let before = FoundationItem(
                id: "playlist", title: "Before", subtitle: "", kind: .playlist, duration: nil)
            var after = before
            after.title = "After"
            let oldRoute = FoundationMacLibraryRoute.playlist(before)
            let renamedRoute = FoundationMacLibraryRoute.playlist(after)
            XCTAssertNotEqual(oldRoute, renamedRoute)
            XCTAssertEqual(oldRoute.identity, renamedRoute.identity)
            XCTAssertNotEqual(oldRoute.identity, FoundationMacLibraryRoute.playlists.identity)
        }

        func testConfirmedPlaylistRenameUpdatesAllOpenCopiesWithoutChangingNavigationIdentity() {
            let navigation = FoundationMacNavigation()
            let playlist = FoundationItem(
                id: "playlist", title: "Before", subtitle: "", kind: .playlist, duration: nil)
            navigation.open(playlist)
            navigation.open(playlist)
            let owners = navigation.path.map(\.headerOwnerID)
            let before = Set(navigation.path)
            XCTAssertEqual(before.count, 2, "Repeated destinations retain distinct header owners")

            navigation.updatePlaylistTitle(id: playlist.id, name: "After")

            XCTAssertEqual(navigation.path.map(\.item.title), ["After", "After"])
            XCTAssertEqual(navigation.path.map(\.headerOwnerID), owners)
            XCTAssertEqual(
                Set(navigation.path), before, "Changing a title must not replace a route")
            XCTAssertTrue(
                navigation.path.allSatisfy {
                    $0.item.id == playlist.id && $0.item.kind == .playlist
                })
        }

        func testPlaylistRenameLeavesUnrelatedAndSameIDOtherKindDestinationsUntouched() {
            let navigation = FoundationMacNavigation()
            let playlist = FoundationItem(
                id: "same", title: "Playlist", subtitle: "", kind: .playlist, duration: nil)
            let album = FoundationItem(
                id: "same", title: "Album", subtitle: "Artist", kind: .album, duration: nil)
            let other = FoundationItem(
                id: "other", title: "Other Playlist", subtitle: "", kind: .playlist, duration: nil)
            for item in [playlist, album, other] { navigation.open(item) }
            let owners = navigation.path.map(\.headerOwnerID)

            navigation.updatePlaylistTitle(id: playlist.id, name: "Renamed")

            XCTAssertEqual(
                navigation.path.map(\.item.title), ["Renamed", "Album", "Other Playlist"])
            XCTAssertEqual(navigation.path[1].item, album)
            XCTAssertEqual(navigation.path[2].item, other)
            XCTAssertEqual(navigation.path.map(\.headerOwnerID), owners)
            navigation.updatePlaylistTitle(id: "missing", name: "Must Not Appear")
            XCTAssertEqual(
                navigation.path.map(\.item.title), ["Renamed", "Album", "Other Playlist"])
        }
    #endif

    func testSongAlphabetSeeksUnloadedFarLetterWithoutWalkingCatalogPages() async throws {
        let source = SongAlphabetFixture(total: 1_000_000, split: 750_000)
        let offset = try await FoundationSongAlphabetSeek.lowerBound(letter: "Z") {
            await source.read($0)
        }
        XCTAssertEqual(offset, 750_000)
        let reads = await source.reads
        XCTAssertLessThanOrEqual(reads.count, 24)
        XCTAssertTrue(reads.contains(749_999))
        XCTAssertTrue(reads.contains(750_000))
    }

    func testSongAlphabetEmptyCatalogAndRepeatedTitlesHaveValidBoundaries() async throws {
        let empty = SongAlphabetFixture(names: [])
        let emptyOffset = try await FoundationSongAlphabetSeek.lowerBound(letter: "M") {
            await empty.read($0)
        }
        XCTAssertEqual(emptyOffset, 0)
        let duplicateTitles = SongAlphabetFixture(names: ["Alpha", "Bravo", "Bravo", "Zulu"])
        let first = try await FoundationSongAlphabetSeek.lowerBound(letter: "B") {
            await duplicateTitles.read($0)
        }
        XCTAssertEqual(first, 1)
        let missing = try await FoundationSongAlphabetSeek.lowerBound(letter: "M") {
            await duplicateTitles.read($0)
        }
        XCTAssertEqual(missing, 3)
    }

    func testSongAlphabetCleanNamePreservesArticlesAndNormalizesPunctuationAndDiacritics() {
        func item(_ title: String) -> FoundationItem {
            .init(id: title, title: title, subtitle: "", kind: .track, duration: nil)
        }
        XCTAssertEqual(FoundationSongAlphabetSeek.key(item(" !Éclair—Live ")), "eclair live")
        XCTAssertEqual(FoundationSongAlphabetSeek.letter(item("!Éclair")), "E")
        XCTAssertEqual(FoundationSongAlphabetSeek.letter(item("The Apple")), "T")
        XCTAssertEqual(FoundationSongAlphabetSeek.letter(item("42 Songs")), "#")
    }

    func testSongAlphabetRejectsOversizedCatalogAndIgnoredOffsets() async throws {
        do {
            _ = try await FoundationSongAlphabetSeek.lowerBound(letter: "Z") { offset in
                .init(
                    startIndex: offset, totalCount: 1_000_001,
                    items: [
                        .init(id: "one", title: "Alpha", subtitle: "", kind: .track, duration: nil)
                    ])
            }
            XCTFail("Oversized catalog should fail without walking it")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await FoundationSongAlphabetSeek.lowerBound(letter: "Z") { offset in
                .init(
                    startIndex: offset, totalCount: 100,
                    items: [
                        .init(id: "one", title: "Alpha", subtitle: "", kind: .track, duration: nil)
                    ])
            }
            XCTFail("Ignored offset must not appear to be a valid title range")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
    }

    func testSongAlphabetCancellationCannotPublishATarget() async throws {
        let source = SongAlphabetFixture(names: ["Alpha", "Zulu"])
        do {
            _ = try await FoundationSongAlphabetSeek.lowerBound(letter: "Z") { offset in
                if offset != 0 { throw CancellationError() }
                return await source.read(offset)
            }
            XCTFail("Cancelled seek returned a target")
        } catch is CancellationError {}
    }

    func testPlayerSurfaceExpandsOnlyMeasuredVisibleBarIntoFinalPlayerBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let bar = CGRect(x: 12, y: 720, width: 366, height: 56)
        XCTAssertEqual(
            FoundationPlayerSurfaceTransitionDecision.resolve(
                compact: bar, expanded: bounds, reduceMotion: false),
            .expand(compact: bar, expanded: bounds))
        for invalid in [
            CGRect.zero, CGRect(x: 12, y: 830, width: 366, height: 56),
            CGRect(x: 12, y: 720, width: CGFloat.infinity, height: 56),
        ] {
            XCTAssertEqual(
                FoundationPlayerSurfaceTransitionDecision.resolve(
                    compact: invalid, expanded: bounds, reduceMotion: false), .fade)
        }
    }

    func testPlayerSurfaceHonorsReducedMotionAndDoesNotInventMissingBarGeometry() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let bar = CGRect(x: 12, y: 720, width: 366, height: 56)
        XCTAssertEqual(
            FoundationPlayerSurfaceTransitionDecision.resolve(
                compact: bar, expanded: bounds, reduceMotion: true), .fade)
        XCTAssertEqual(
            FoundationPlayerSurfaceTransitionDecision.resolve(
                compact: nil, expanded: bounds, reduceMotion: false), .fade)
        XCTAssertEqual(
            FoundationPlayerSurfaceTransitionDecision.resolve(
                compact: bar, expanded: .zero, reduceMotion: false), .fade)
    }

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
                compact: CGRect(x: 18, y: 730, width: CGFloat.infinity, height: 34),
                expanded: expanded),
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

private actor SongAlphabetFixture {
    let total: Int
    let split: Int
    let names: [String]?
    private(set) var reads: [Int] = []

    init(total: Int, split: Int) {
        self.total = total
        self.split = split
        names = nil
    }
    init(names: [String]) {
        self.names = names
        total = names.count
        split = 0
    }

    func read(_ offset: Int) -> FoundationSongAlphabetSeek.Probe {
        reads.append(offset)
        guard offset < total else { return .init(startIndex: offset, totalCount: total, items: []) }
        let title = names.map { $0[offset] } ?? (offset < split ? "Alpha" : "Zulu")
        return .init(
            startIndex: offset, totalCount: total,
            items: [
                .init(id: "song-\(offset)", title: title, subtitle: "", kind: .track, duration: nil)
            ])
    }
}

#if os(macOS)
    private actor FoundationMacHandoffAudioProbe {
        private(set) var count = 0
        func resolve(_ item: FoundationItem) throws -> URL {
            count += 1
            throw FoundationLibraryError.unavailable
        }
    }
#endif
