import Security
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import SwiftUI
    import UIKit
#else
    import AppKit
    import SwiftUI
#endif

@MainActor
final class FoundationPresentationTests: XCTestCase {
    func testAlbumReadingProfileUsesContentAnchorsAcrossNarrowAndWideViewports() {
        let phone = FoundationAlbumBackdropProfile(
            imageSide: 430, height: 850, controlsBottom: 280, readingTop: 430)
        let wide = FoundationAlbumBackdropProfile(
            imageSide: 951, height: 669, controlsBottom: 280, readingTop: 430)
        // The same visible controls and text need the same support, regardless of art width.
        for y in stride(from: CGFloat.zero, through: 660, by: 10) {
            XCTAssertEqual(phone.readingAmount(at: y), wide.readingAmount(at: y))
        }
        for profile in [phone, wide] {
            XCTAssertEqual(profile.readingAmount(at: 280), 0)
            XCTAssertEqual(profile.readingAmount(at: 430), 1)
            XCTAssertGreaterThan(profile.readingAmount(at: 355), 0)
            XCTAssertLessThan(profile.readingAmount(at: 355), 1)
            XCTAssertEqual(profile.readingAmount(at: 660), 1)
            let amounts = stride(from: CGFloat.zero, through: 660, by: 5).map {
                profile.readingAmount(at: $0)
            }
            XCTAssertEqual(amounts, amounts.sorted())
            // Reading support must never form a darker stripe before the final track tint.
            let neutral = profile.neutralStops.map(\.opacity)
            XCTAssertEqual(neutral, neutral.sorted())
            XCTAssertLessThanOrEqual(neutral.max() ?? .infinity, neutral.last ?? -.infinity)
            XCTAssertGreaterThan(neutral.last ?? 0, neutral.first ?? 1)
        }
    }

    func testAlbumImageFeatherJoinsTintContinuouslyAtSquareBoundary() {
        for side: CGFloat in [430, 951] {
            let profile = FoundationAlbumBackdropProfile(
                imageSide: side, height: 900, controlsBottom: 280, readingTop: 430)
            let amounts = (0...100).map { profile.imageOpacity(at: side * CGFloat($0) / 100) }
            XCTAssertTrue(amounts.allSatisfy { $0.isFinite && (0...1).contains($0) })
            XCTAssertEqual(amounts, amounts.sorted(by: >))
            XCTAssertEqual(profile.imageOpacity(at: side), 0)
            XCTAssertEqual(profile.imageOpacity(at: side + 1), 0)
            // A smooth feather approaches the join continuously with a vanishing slope.
            let nearEdge = profile.imageOpacity(at: side - 0.1)
            let fartherFromEdge = profile.imageOpacity(at: side - 0.2)
            XCTAssertGreaterThan(nearEdge, 0)
            XCTAssertLessThan(nearEdge, 0.001)
            XCTAssertLessThan(nearEdge, fartherFromEdge * 0.3)
            XCTAssertEqual(profile.readingAmount(at: max(side, 430) + 1), 1)
            XCTAssertEqual(profile.imageStops.last?.opacity, 0)
        }
    }

    func testAlbumBackdropProfileKeepsScrolledAndMissingHeadersReadableWithFiniteStops() {
        let profiles = [
            // A still-visible first track must not defer support after controls leave the top.
            FoundationAlbumBackdropProfile(
                imageSide: 951, height: 669, controlsBottom: -40, readingTop: 250),
            FoundationAlbumBackdropProfile(
                imageSide: 430, height: 850, controlsBottom: nil, readingTop: 400),
            FoundationAlbumBackdropProfile(
                imageSide: .nan, height: .infinity, controlsBottom: .nan, readingTop: -.infinity),
        ]
        for profile in profiles {
            XCTAssertEqual(profile.readingAmount(at: 0), 1)
            XCTAssertEqual(profile.readingAmount(at: profile.height), 1)
            // Scrolling the header away retains uniform support, without a residual dark band.
            let neutral = profile.neutralStops.map(\.opacity)
            XCTAssertEqual(Set(neutral).count, 1)
            for stops in [profile.readingStops, profile.imageStops, profile.neutralStops] {
                let positions = stops.map(\.location)
                XCTAssertEqual(positions, positions.sorted())
                XCTAssertEqual(positions.first, 0)
                XCTAssertEqual(positions.last, 1)
                XCTAssertTrue(positions.allSatisfy { $0.isFinite && (0...1).contains($0) })
                XCTAssertTrue(
                    stops.allSatisfy { $0.opacity.isFinite && (0...1).contains($0.opacity) })
            }
        }
        // A visible control row with a virtualized track still gets a finite reading ramp.
        let awaitingTracks = FoundationAlbumBackdropProfile(
            imageSide: 951, height: 669, controlsBottom: 280, readingTop: nil)
        XCTAssertEqual(awaitingTracks.readingAmount(at: 280), 0)
        XCTAssertEqual(awaitingTracks.readingAmount(at: 669), 1)
    }

    func testFoldedPlayerRegionsKeepContentAboveControlsAndClearFoldMargins() throws {
        // Different viewport shapes and an off-center fold must preserve on-screen
        // roles without relying on device orientation or native primary-slot order.
        for (size, foldY) in [
            (CGSize(width: 669, height: 951), CGFloat(462)),
            (CGSize(width: 951, height: 669), CGFloat(290)),
        ] {
            let fold = CGRect(x: 0, y: foldY, width: size.width, height: 3)
            let regions = try XCTUnwrap(
                FoundationPlayerRegionLayout.regions(
                    size: size, divider: fold,
                    margins: EdgeInsets(top: 7, leading: 0, bottom: 11, trailing: 0)))
            XCTAssertTrue(regions.stacksVertically)
            XCTAssertLessThan(regions.content.midY, regions.controls.midY)
            XCTAssertLessThanOrEqual(regions.content.maxY, fold.minY - 7)
            XCTAssertGreaterThanOrEqual(regions.controls.minY, fold.maxY + 11)
            XCTAssertFalse(regions.controls.intersects(regions.content))
            let viewport = CGRect(origin: .zero, size: size)
            XCTAssertTrue(viewport.contains(regions.controls))
            XCTAssertTrue(viewport.contains(regions.content))
            XCTAssertGreaterThan(regions.controls.height, 0)
            XCTAssertGreaterThan(regions.content.height, 0)
        }
    }

    func testFoldedPlayerRegionsKeepContentPhysicallyLeftAndControlsRight() throws {
        let size = CGSize(width: 951, height: 669)
        // A zero-width division is a legitimate hinge, not missing geometry.
        let fold = CGRect(x: 447, y: 0, width: 0, height: size.height)
        let regions = try XCTUnwrap(
            FoundationPlayerRegionLayout.regions(
                size: size, divider: fold,
                margins: EdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 13)))
        XCTAssertFalse(regions.stacksVertically)
        XCTAssertLessThan(regions.content.midX, regions.controls.midX)
        XCTAssertLessThanOrEqual(regions.content.maxX, fold.minX - 9)
        XCTAssertGreaterThanOrEqual(regions.controls.minX, fold.maxX + 13)
        XCTAssertFalse(regions.controls.intersects(regions.content))
        let viewport = CGRect(origin: .zero, size: size)
        XCTAssertTrue(viewport.contains(regions.controls))
        XCTAssertTrue(viewport.contains(regions.content))
    }

    func testFoldedPlayerRegionsRejectInvalidOrUnusableGeometry() {
        let size = CGSize(width: 669, height: 951)
        let fold = CGRect(x: 0, y: 470, width: size.width, height: 0)
        XCTAssertNil(
            FoundationPlayerRegionLayout.regions(
                size: .zero, divider: fold, margins: EdgeInsets()))
        for invalid in [
            CGRect.null, CGRect.infinite, CGRect.zero,
            CGRect(x: 0, y: -20, width: size.width, height: 2),
            CGRect(x: 0, y: size.height + 10, width: size.width, height: 2),
        ] {
            XCTAssertNil(
                FoundationPlayerRegionLayout.regions(
                    size: size, divider: invalid, margins: EdgeInsets()))
        }
        XCTAssertNil(
            FoundationPlayerRegionLayout.regions(
                size: size, divider: fold,
                margins: EdgeInsets(top: .infinity, leading: 0, bottom: 0, trailing: 0)))
        XCTAssertNil(
            FoundationPlayerRegionLayout.regions(
                size: size, divider: fold,
                margins: EdgeInsets(top: size.height, leading: 0, bottom: 0, trailing: 0)))
    }

    #if os(iOS)
        func testQueueNativeSwipesProtectHistoryAndRejectRetiredOccurrenceActions() throws {
            let item = FoundationItem(
                id: "same-track", title: "Song", subtitle: "Artist", kind: .track, duration: 60)
            let history = FoundationQueueEntry(item: item)
            let current = FoundationQueueEntry(item: item)
            let upcoming = [FoundationQueueEntry(item: item), FoundationQueueEntry(item: item)]
            var played: [UUID] = []
            var positions: [String] = []
            var removed: [UUID] = []
            func list(_ entries: [FoundationQueueEntry]) -> FoundationQueueReorderList<
                Text, Text, Text
            > {
                .init(
                    history: [history], current: current, upcoming: entries,
                    dynamicTypeSize: .large, shuffleEnabled: false, repeatMode: .off,
                    play: { id, position in
                        played.append(id)
                        positions.append(position == .next ? "next" : "last")
                    }, remove: { removed.append($0) }, geometryReady: {}, move: { _, _ in },
                    header: { Text("Current") }, historyHeader: { Text("History") },
                    row: { _, _ in Text("Song") })
            }
            let coordinator = FoundationQueueReorderList<Text, Text, Text>.Coordinator(
                parent: list(upcoming))
            XCTAssertNil(
                coordinator.swipeActions(at: IndexPath(item: 0, section: 0), leading: true))
            XCTAssertNil(
                coordinator.swipeActions(at: IndexPath(item: 0, section: 1), leading: false))
            XCTAssertNil(
                coordinator.swipeActions(at: IndexPath(item: 3, section: 2), leading: true))
            let leading = try XCTUnwrap(
                coordinator.swipeActions(at: IndexPath(item: 0, section: 2), leading: true))
            XCTAssertEqual(leading.actions.map(\.accessibilityLabel), ["Play Next", "Play Last"])
            XCTAssertTrue(leading.actions.allSatisfy { $0.title == nil && $0.image != nil })
            XCTAssertTrue(leading.performsFirstActionWithFullSwipe)
            var completed: [Bool] = []
            for action in leading.actions {
                action.handler(action, UIView()) { completed.append($0) }
            }
            XCTAssertEqual(played, [upcoming[0].id, upcoming[0].id])
            XCTAssertEqual(positions, ["next", "last"])
            XCTAssertEqual(completed, [true, true])
            let trailing = try XCTUnwrap(
                coordinator.swipeActions(at: IndexPath(item: 1, section: 2), leading: false))
            XCTAssertTrue(trailing.performsFirstActionWithFullSwipe)
            let remove = try XCTUnwrap(trailing.actions.first)
            XCTAssertEqual(remove.style, .destructive)
            XCTAssertNotNil(remove.image)
            remove.handler(remove, UIView()) { completed.append($0) }
            XCTAssertEqual(removed, [upcoming[1].id])
            // A captured action must not mutate an occurrence that is no longer upcoming.
            coordinator.parent = list([])
            let oldPlay = leading.actions[0]
            oldPlay.handler(oldPlay, UIView()) { completed.append($0) }
            remove.handler(remove, UIView()) { completed.append($0) }
            XCTAssertEqual(played.count, 2)
            XCTAssertEqual(removed.count, 1)
            XCTAssertEqual(Array(completed.suffix(2)), [false, false])
        }
    #endif

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
        let suite = "FoundationPresentationTests." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated presentation preferences")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FoundationCredentials.Operations(
            update: { _, _ in errSecItemNotFound }, add: { _ in errSecItemNotFound },
            copy: { _ in (errSecItemNotFound, nil) }, delete: { _ in errSecItemNotFound })
        let model = FoundationAppModel(
            credentialOperations: credentials, credentialDefaults: defaults,
            playbackPreferences: FoundationPlaybackPreferences(defaults: defaults))
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

    @MainActor
    private final class HeldBrowsePage {
        let entered = XCTestExpectation(description: "browse page entered hold")
        private var continuation: CheckedContinuation<FoundationPage, Never>?
        private var released: FoundationPage?
        func hold() async -> FoundationPage {
            entered.fulfill()
            if let released { return released }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release(_ page: FoundationPage) {
            released = page
            continuation?.resume(returning: page)
            continuation = nil
        }
    }

    private func requireBrowseOperation(
        _ task: Task<Void, Never>, gate: HeldBrowsePage, held: Task<Void, Never>, name: String
    ) async -> Bool {
        let finished = XCTestExpectation(description: name)
        let observer = Task {
            await task.value
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            task.cancel()
            held.cancel()
            gate.release(.init(items: [], nextStartIndex: nil))
            observer.cancel()
            XCTFail("\(name) did not finish within 5 seconds")
            return false
        }
        return true
    }

    func testCancellationIgnoringOldPageCannotReplaceNewPage() async {
        let model = FoundationBrowseModel()
        let gate = HeldBrowsePage()
        let old = Task {
            await model.load(.initial) { _ in await gate.hold() }
        }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            old.cancel()
            gate.release(.init(items: [], nextStartIndex: nil))
            XCTFail("Old browse load did not enter within 2 seconds")
            return
        }
        old.cancel()
        let new = FoundationItem(id: "new", title: "New", subtitle: "", kind: .album, duration: nil)
        let replacement = Task {
            await model.load(.refresh) { _ in FoundationPage(items: [new], nextStartIndex: nil) }
        }
        guard
            await requireBrowseOperation(
                replacement, gate: gate, held: old, name: "replacement browse page")
        else { return }
        gate.release(FoundationPage(items: [], nextStartIndex: 50))
        guard
            await requireBrowseOperation(
                old, gate: gate, held: old, name: "retired browse page")
        else { return }
        XCTAssertEqual(model.items, [new])
        XCTAssertNil(model.nextStartIndex)
        XCTAssertFalse(model.isLoading)
    }

    func testNewAlbumsCompleteWhileTracksStallAndCancelledTrackResultStaysUnpublished() async {
        let tracks = FoundationBrowseModel()
        let albums = FoundationBrowseModel()
        let gate = HeldBrowsePage()
        var trackOffsets: [Int] = []
        var albumOffsets: [Int] = []
        let album = FoundationItem(
            id: "recent-album", title: "Album", subtitle: "", kind: .album, duration: nil)
        let track = FoundationItem(
            id: "recent-track", title: "Track", subtitle: "", kind: .track, duration: nil)
        let trackLoad = Task {
            await tracks.loadPending { offset in
                trackOffsets.append(offset)
                return await gate.hold()
            }
        }
        guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
            trackLoad.cancel()
            gate.release(.init(items: [], nextStartIndex: nil))
            XCTFail("Track section did not enter within 2 seconds")
            return
        }
        let albumLoad = Task {
            await albums.loadPending { offset in
                albumOffsets.append(offset)
                return FoundationPage(items: [album], nextStartIndex: 50)
            }
        }
        guard
            await requireBrowseOperation(
                albumLoad, gate: gate, held: trackLoad, name: "independent album page")
        else { return }
        XCTAssertTrue(tracks.isLoading)
        XCTAssertFalse(tracks.loaded)
        XCTAssertEqual(albums.items, [album])
        XCTAssertFalse(albums.isLoading)
        XCTAssertEqual(trackOffsets, [0])
        XCTAssertEqual(albumOffsets, [0])

        // Leaving New cancels the owner, even if its loader finishes afterward.
        trackLoad.cancel()
        gate.release(FoundationPage(items: [track], nextStartIndex: 100))
        guard
            await requireBrowseOperation(
                trackLoad, gate: gate, held: trackLoad, name: "retired track page")
        else { return }
        XCTAssertTrue(tracks.items.isEmpty)
        XCTAssertFalse(tracks.loaded)
        XCTAssertNil(tracks.nextStartIndex)
        XCTAssertNil(tracks.errorMessage)
        XCTAssertFalse(tracks.isLoading)
        XCTAssertEqual(albums.items, [album])
        XCTAssertEqual(albums.nextStartIndex, 50)
    }

    func testNewSharedPagesReuseSeedAndContinueOnVisibleEndDemand() async {
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

        await seeAllTracks.loadNextVisiblePage(using: loadTracks)
        await tracks.loadPending(using: loadTracks)
        await albums.loadPending(using: loadAlbums)
        XCTAssertEqual(trackOffsets, [0, 100])
        XCTAssertEqual(albumOffsets, [0])
        XCTAssertEqual(tracks.items, [first, next])
        XCTAssertNil(tracks.nextStartIndex)
    }

    func testPlaylistAddVisibleDemandRevealsBufferedRowsBeforeOneProviderPage() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let buffered = (0..<30).map {
            FoundationItem(
                id: "buffered-\($0)", title: "Song \($0)", subtitle: "", kind: .track, duration: nil
            )
        }
        await model.load(.initial) { _ in .init(items: buffered, nextStartIndex: 30) }
        var reads: [Int] = []
        let more = (30..<42).map {
            FoundationItem(
                id: "next-\($0)", title: "Song \($0)", subtitle: "", kind: .track, duration: nil)
        }
        func next(_ count: Int) async -> Int {
            await FoundationPlaylistAddContinuation.advance(
                visibleCount: count, model: model, ifActive: { true }, allowsNetwork: { true },
                using: { offset in
                    reads.append(offset)
                    return .init(items: more, nextStartIndex: nil)
                })
        }
        var visible = await next(12)
        XCTAssertEqual(visible, 24)
        XCTAssertTrue(reads.isEmpty, "Buffered rows must not request another provider page")
        visible = await next(visible)
        XCTAssertEqual(visible, 36)
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(Array(model.items.prefix(visible)), buffered)
        visible = await next(visible)
        XCTAssertEqual(visible, 48)
        XCTAssertEqual(reads, [30])
        XCTAssertEqual(model.items, buffered + more, "Visible row identity and order stay stable")
        let exhaustedCount = await next(visible)
        XCTAssertEqual(exhaustedCount, visible)
        XCTAssertEqual(reads, [30], "An exhausted result must not read again")
    }

    func testPlaylistAddVisibleDemandStopsAtEmptyContinuationAndRetiredContext() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let seed = (0..<12).map {
            FoundationItem(
                id: "seed-\($0)", title: "Seed \($0)", subtitle: "", kind: .track, duration: nil)
        }
        await model.load(.initial) { _ in .init(items: seed, nextStartIndex: 12) }
        var reads: [Int] = []
        let visible = await FoundationPlaylistAddContinuation.advance(
            visibleCount: 12, model: model, ifActive: { true }, allowsNetwork: { true },
            using: { offset in
                reads.append(offset)
                return .init(items: [], nextStartIndex: 24)
            })
        XCTAssertEqual(visible, 12)
        XCTAssertEqual(reads, [12], "An empty page must not walk its successor cursor")
        // Catalog validation rejects an empty page that claims another offset.
        // Preserve the last accepted cursor and require explicit recovery, never drain it.
        XCTAssertEqual(model.nextStartIndex, 12)
        XCTAssertEqual(model.items, seed)
        XCTAssertNotNil(model.errorMessage)
        let blocked = await FoundationPlaylistAddContinuation.advance(
            visibleCount: visible, model: model, ifActive: { true }, allowsNetwork: { true },
            using: { offset in
                reads.append(offset)
                XCTFail("A failed empty continuation must not retry automatically")
                return .init(items: seed, nextStartIndex: nil)
            })
        XCTAssertEqual(blocked, visible)
        XCTAssertEqual(reads, [12])
        XCTAssertEqual(model.nextStartIndex, 12)
        XCTAssertEqual(model.items, seed)

        // A new query owns a clean model epoch; retire that epoch during its actual read.
        model.clearRetainedData()
        await model.load(.initial) { _ in .init(items: seed, nextStartIndex: 12) }
        XCTAssertNil(model.errorMessage)
        let retired = await FoundationPlaylistAddContinuation.advance(
            visibleCount: visible, model: model, ifActive: { true }, allowsNetwork: { true },
            using: { offset in
                reads.append(offset)
                model.clearRetainedData()
                return .init(items: seed, nextStartIndex: 36)
            })
        XCTAssertEqual(retired, visible, "An obsolete query cannot advance the new view window")
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.nextStartIndex)
        XCTAssertEqual(reads, [12, 12])
    }

    func testPlaylistAddVisibleDemandHonorsOperationOfflineAndCancellation() async {
        let model = FoundationBrowseModel()
        await model.load(.initial) { _ in
            .init(
                items: [
                    .init(id: "seed", title: "Seed", subtitle: "", kind: .track, duration: nil)
                ],
                nextStartIndex: 12)
        }
        var reads = 0
        for (active, online) in [(false, true), (true, false)] {
            let count = await FoundationPlaylistAddContinuation.advance(
                visibleCount: 12, model: model, ifActive: { active }, allowsNetwork: { online },
                using: { _ in
                    reads += 1
                    return .init(items: [], nextStartIndex: nil)
                })
            XCTAssertEqual(count, 12)
        }
        var active = true
        let count = await FoundationPlaylistAddContinuation.advance(
            visibleCount: 12, model: model, ifActive: { active }, allowsNetwork: { true },
            using: { _ in
                reads += 1
                active = false
                return .init(
                    items: [
                        .init(id: "late", title: "Late", subtitle: "", kind: .track, duration: nil)
                    ],
                    nextStartIndex: nil)
            })
        XCTAssertEqual(count, 12, "An operation or dismissed editor cannot advance after a page")
        XCTAssertEqual(reads, 1)
        model.clearRetainedData()
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: 12) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await FoundationPlaylistAddContinuation.advance(
                visibleCount: 12, model: model, ifActive: { true }, allowsNetwork: { true },
                using: { _ in
                    reads += 1
                    return .init(items: [], nextStartIndex: nil)
                })
        }
        let cancelledCount = await cancelled.value
        XCTAssertEqual(cancelledCount, 12)
        XCTAssertEqual(reads, 1)
    }

    func testVisibleSearchContinuationSettlesItsSeedBeforeOneAutomaticPage() async throws {
        let seed = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(
                .init(items: [], nextStartIndex: nil), kind: .track))
        let lease = FoundationSearchSeedLease(page: seed.page)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        var reads: [Int] = []
        let match = FoundationItem(
            id: "match", title: "Garden", subtitle: "", kind: .track, duration: nil)
        model.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "synthetic",
            fallback: .init(term: "gar", nextStartIndex: 50), seed: seed, seedLease: lease
        ) { term, kind, offset in
            XCTAssertEqual(term, "gar")
            XCTAssertEqual(kind, .track)
            reads.append(offset)
            return .init(items: [match], nextStartIndex: nil)
        }
        XCTAssertTrue(lease.pending)
        await model.loadNextVisiblePage { _ in
            XCTFail("The scoped overview seed must not be reread from the provider")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertFalse(lease.pending)
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(reads, [50])
        XCTAssertEqual(model.items, [match])
        XCTAssertFalse(model.hasMorePages)
        await model.loadNextVisiblePage { _ in
            XCTFail("An exhausted category must not read again")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, [50])
    }

    func testMountedPaginationFooterDoesNotDrainAnEmptyPageOnCursorPublication() async {
        let first = FoundationItem(
            id: "first", title: "First", subtitle: "", kind: .track, duration: nil)
        let last = FoundationItem(
            id: "last", title: "Last", subtitle: "", kind: .track, duration: nil)
        weak var publishedOwner: PaginationFooterOwner?
        let model = FoundationBrowseModel(onLoadSettled: { publishedOwner?.publicationSettled() })
        await model.load(.initial) { _ in .init(items: [first], nextStartIndex: 50) }
        let owner = PaginationFooterOwner(model: model, last: last)
        publishedOwner = owner
        let root = PaginationFooterHarness(owner: owner, model: model)
        #if os(iOS)
            guard
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }
                ).first
            else {
                XCTFail("A connected test-host window scene is required to mount the real footer")
                return
            }
            let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 120)
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                oldKeyWindow?.makeKey()
            }
        #else
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 120),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: root)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
        #endif
        guard await XCTWaiter.fulfillment(of: [owner.firstPage], timeout: 5) == .completed else {
            XCTFail("Visible footer did not request its page")
            return
        }
        let unsolicited = await XCTWaiter.fulfillment(
            of: [owner.unexpectedContinuation], timeout: 1)
        XCTAssertEqual(
            unsolicited, .completed,
            "A cursor publication alone must not restart the footer task")
        XCTAssertTrue(owner.demand.footerVisible)
        XCTAssertEqual(owner.offsets, [50])
        XCTAssertEqual(model.nextStartIndex, 100)
        owner.continuationAllowed = true
        owner.demand.request(active: true, allowsNetwork: true, isLoading: false, hasError: false)
        guard await XCTWaiter.fulfillment(of: [owner.lastPage], timeout: 5) == .completed else {
            XCTFail("New user demand did not request the next page")
            return
        }
        XCTAssertEqual(owner.offsets, [50, 100])
        XCTAssertEqual(model.items.map(\.id), [first.id, last.id])
        XCTAssertNil(model.nextStartIndex)
    }

    func testVisiblePaginationRechecksOfflineAndCancellationAfterBusyPublication() async {
        for cancels in [false, true] {
            let model = FoundationBrowseModel()
            let first = FoundationItem(
                id: "first", title: "First", subtitle: "", kind: .track, duration: nil)
            await model.load(.initial) { _ in .init(items: [first], nextStartIndex: 50) }
            let gate = HeldBrowsePage()
            let refresh = Task { await model.load(.refresh) { _ in await gate.hold() } }
            guard await XCTWaiter.fulfillment(of: [gate.entered], timeout: 2) == .completed else {
                refresh.cancel()
                gate.release(.init(items: [], nextStartIndex: nil))
                XCTFail("Refresh did not enter its hold")
                return
            }
            var online = true
            var reads: [Int] = []
            let waiting = XCTestExpectation(description: "pagination entered wait")
            var checks = 0
            let pending = Task {
                await model.loadNextVisiblePage(
                    ifActive: {
                        checks += 1
                        if checks == 1 { waiting.fulfill() }
                        return true
                    },
                    allowsNetwork: { online }
                ) { offset in
                    reads.append(offset)
                    return .init(items: [], nextStartIndex: nil)
                }
            }
            guard await XCTWaiter.fulfillment(of: [waiting], timeout: 2) == .completed else {
                pending.cancel()
                refresh.cancel()
                gate.release(.init(items: [], nextStartIndex: nil))
                XCTFail("Pagination did not wait for the in-flight page")
                return
            }
            if cancels { pending.cancel() } else { online = false }
            gate.release(.init(items: [first], nextStartIndex: 50))
            guard await requireBrowseOperation(refresh, gate: gate, held: refresh, name: "refresh")
            else {
                pending.cancel()
                return
            }
            guard
                await requireBrowseOperation(
                    pending, gate: gate, held: refresh, name: "retired pagination")
            else { return }
            XCTAssertEqual(reads, [], "Retired or offline demand cannot start another read")
            XCTAssertEqual(model.items, [first])
            XCTAssertEqual(model.nextStartIndex, 50)
        }
    }

}

@MainActor
private final class PaginationFooterOwner: ObservableObject {
    @Published var demand = FoundationCatalogPageDemand()
    let model: FoundationBrowseModel
    let last: FoundationItem
    let firstPage = XCTestExpectation(description: "first visible-end page")
    let unexpectedContinuation: XCTestExpectation = {
        let value = XCTestExpectation(description: "unwanted cursor-driven page")
        value.isInverted = true
        return value
    }()
    let lastPage = XCTestExpectation(description: "explicit new scroll demand")
    var continuationAllowed = false
    var offsets: [Int] = []

    init(model: FoundationBrowseModel, last: FoundationItem) {
        self.model = model
        self.last = last
    }

    func page(_ offset: Int) async throws -> FoundationPage {
        offsets.append(offset)
        if offset == 50 { return .init(items: [], nextStartIndex: 100) }
        if !continuationAllowed { unexpectedContinuation.fulfill() }
        return .init(items: [last], nextStartIndex: nil)
    }

    func publicationSettled() {
        if offsets.last == 50 { firstPage.fulfill() }
        if offsets.last == 100, continuationAllowed { lastPage.fulfill() }
    }
}

private struct PaginationFooterHarness: View {
    @ObservedObject var owner: PaginationFooterOwner
    @ObservedObject var model: FoundationBrowseModel
    var body: some View {
        FoundationPaginationFooter(
            demand: $owner.demand, isLoading: model.isLoading, isEnabled: true,
            hasError: model.errorMessage != nil, showsScrollHint: model.items.isEmpty
        ) {
            await model.loadNextVisiblePage(using: owner.page)
        }
        .id(model.catalogIdentityContext)
        .frame(width: 300, height: 100)
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
