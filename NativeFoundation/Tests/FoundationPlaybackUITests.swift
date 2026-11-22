import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testSongCreditsGrabberDismissesWithoutDuplicateDone() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["Play"], in: app)
        openNowPlaying(app)
        tapVisible(app.buttons["More playback options"], in: app)
        tapNativeChrome(app.buttons["Song Credits"], in: app)
        let navigation = app.navigationBars["Song Credits"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        XCTAssertFalse(navigation.buttons["Done"].exists)
        capture("Song Credits retains native grabber without duplicate dismissal button", in: app)
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertFalse(navigation.exists)
        XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
    }

    @objc func testMissingLyricsShowsUnavailableControlAfterClosingPane() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                longPlayback: true, lyricsPresentation: true, missingLyrics: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["Play"], in: app)
        openNowPlaying(app)
        app.buttons["Show lyrics"].tap()
        XCTAssertTrue(app.staticTexts["Lyrics unavailable"].waitForExistence(timeout: 5))
        app.buttons["Show artwork"].tap()
        let unavailable = app.buttons["Lyrics unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 5))
        XCTAssertFalse(unavailable.isEnabled)
        capture("Confirmed missing lyrics has dimmed slashed control", in: app)
    }

    @objc func testLyricsFollowTrackChangesWithoutClosingPane() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                longPlayback: true, queuePresentation: true, lyricsPresentation: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["Play"], in: app)
        openNowPlaying(app)
        app.buttons["Show lyrics"].tap()
        XCTAssertTrue(app.buttons["Fixture lyric tone"].waitForExistence(timeout: 5))
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        modal.buttons["Next"].tap()
        XCTAssertTrue(
            app.buttons["Fixture lyric missing-tone"].waitForExistence(timeout: 5),
            "A new occurrence must load its own lyrics while the pane stays open")
        modal.buttons["Next"].tap()
        XCTAssertTrue(app.buttons["Fixture lyric tone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Fixture lyric missing-tone"].exists)
        capture("Lyrics follow consecutive track changes", in: app)
    }

    @objc func testFirstCollectionPlaybackStartsFromEmptyQueue() {
        continueAfterFailure = false
        for kind in ["album", "artist"] {
            for command in ["Play", "Shuffle"] {
                let app = launch(
                    .init(
                        productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                        compactFixtureControls: true))
                selectTab("Library", in: app)
                if kind == "album" {
                    openCanonicalCollection(
                        "album", fromDownloads: false, in: app,
                        useVerifiedCenter: true)
                } else {
                    tapVisibleCenter(app.buttons["library-category-artists"], in: app)
                    let artist = app.buttons.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
                    ).firstMatch
                    tapVisibleCenter(artist, in: app)
                }
                XCTAssertFalse(app.buttons["foundation-mini-playback-toggle"].exists)
                tapVisibleCenter(app.buttons[command], in: app)
                let playing = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label CONTAINS %@", "state playing"),
                    object: app.staticTexts["fixture-playback-identity"])
                let playbackResult = XCTWaiter.wait(for: [playing], timeout: 10)
                capture("First tap \(kind) \(command) state", in: app)
                XCTAssertEqual(
                    playbackResult, .completed,
                    "The first \(kind) \(command) request must start playback")
                XCTAssertFalse(app.staticTexts["Collection loading cancelled."].exists)
                XCTAssertFalse(app.buttons["Cancel collection loading"].exists)
                capture("Cold \(kind) \(command)", in: app)
                app.terminate()
            }
        }
    }

    @objc func testRelatedCollectionFailureNativeRetryPreservesPlaybackUntilSuccess() {
        checkCollectionOutcome("fail-once", related: true)
    }

    @objc func testRelatedEmptyCollectionNativeDismissPreservesPlayback() {
        checkCollectionOutcome("empty", related: true)
    }

    @objc func testMiniPlayerControlsRemainInteractiveAboveAlbumNavigation() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let selected = identity.label.components(separatedBy: ";").first
        app.buttons["foundation-mini-playback-toggle"].tap()
        let paused = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "intent false"), evaluatedWith: identity)
        wait(for: [paused], timeout: 5)
        XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
        app.buttons["foundation-mini-playback-toggle"].tap()
        let resumed = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "intent true"), evaluatedWith: identity)
        wait(for: [resumed], timeout: 5)
        XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
        openNowPlaying(app)
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        capture("Owned mini-player controls retain their occurrence above album content", in: app)
    }

    @objc func testAdaptivePlayerControlsAndQueuePreservePlaybackContext() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launch(
                .init(
                    productionShell: true, largeText: largeText,
                    canonicalDownloadState: "full", longPlayback: true,
                    compactFixtureControls: true, queuePresentation: true))
            selectTab("Library", in: app)
            if largeText {
                // Keep the natural Library starting position. Its compact Favorites
                // row no longer requires a preparatory swipe past the Albums link.
                let scroll = app.scrollViews.firstMatch
                XCTAssertTrue(scroll.waitForExistence(timeout: 5) && scroll.isHittable)
            }
            openCanonicalCollection("album", fromDownloads: false, in: app)
            tapVisible(app.buttons["collection-track-0"], in: app)
            let rootIdentity = app.staticTexts["fixture-playback-identity"]
            let playing = expectation(
                for: NSPredicate(format: "label CONTAINS %@", "state playing"),
                evaluatedWith: rootIdentity)
            wait(for: [playing], timeout: 10)
            let selected = rootIdentity.label.components(separatedBy: ";").first
            openNowPlaying(app)
            let modal = app.descendants(matching: .any)["foundation-now-playing"]
            XCTAssertTrue(modal.waitForExistence(timeout: 5))
            let viewport = app.windows.element(boundBy: 0).frame
            func captureAdaptiveGeometry(_ state: String) {
                let name = "Duo \(largeText ? "large" : "standard") \(state)"
                capture(name, in: app)
                let appCapture = XCTAttachment(screenshot: app.screenshot())
                appCapture.name = name + " app surface"
                appCapture.lifetime = .keepAlways
                add(appCapture)
                captureDiagnosticText(name + " hierarchy", app.debugDescription)
                let fields: [(String, XCUIElement)] = [
                    (
                        "artwork",
                        modal.descendants(matching: .any)["fixture-player-expanded-artwork"]
                    ),
                    ("previous", modal.buttons["Previous"]),
                    ("pause", modal.buttons["Pause"]),
                    ("play", modal.buttons["Play"]),
                    ("next", modal.buttons["Next"]),
                    ("queue", modal.buttons["Show queue"]),
                    ("showArtwork", modal.buttons["Show artwork"]),
                    ("collapse", modal.buttons["Collapse Now Playing"]),
                    ("position", modal.sliders["Playback position"]),
                    ("queueList", modal.descendants(matching: .any)["fixture-queue-list"]),
                ]
                let rows = fields.map { name, element in
                    element.exists
                        ? "\(name): \(element.frame), hittable=\(element.isHittable)"
                        : "\(name): absent"
                }
                let description = (["window: \(viewport)"] + rows).joined(separator: "\n")
                captureDiagnosticText(name + " frames", description)
            }
            captureAdaptiveGeometry("player before assertions")
            if viewport.height > viewport.width {
                let artwork = modal.descendants(matching: .any)["fixture-player-expanded-artwork"]
                XCTAssertTrue(artwork.waitForExistence(timeout: 5))
                XCTAssertTrue(viewport.contains(artwork.frame))
                XCTAssertEqual(artwork.frame.width, artwork.frame.height, accuracy: 1)
                XCTAssertEqual(artwork.frame.midX, viewport.midX, accuracy: 3)
                XCTAssertGreaterThan(artwork.frame.minX, viewport.minX)
                XCTAssertLessThan(artwork.frame.maxX, viewport.maxX)
            }
            for label in ["Previous", "Pause", "Next", "Show queue", "Collapse Now Playing"] {
                let control = modal.buttons[label].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), "Missing \(label)")
                XCTAssertTrue(viewport.contains(control.frame), "Outside viewport: \(label)")
                if control.isEnabled { XCTAssertTrue(control.isHittable, "Not hittable: \(label)") }
            }
            let position = modal.sliders["Playback position"].firstMatch
            XCTAssertTrue(position.waitForExistence(timeout: 5))
            XCTAssertTrue(viewport.contains(position.frame), "Playback position outside viewport")
            if position.isEnabled { XCTAssertTrue(position.isHittable) }
            let lyrics = modal.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@", "Show lyrics", "Lyrics unavailable")
            ).firstMatch
            XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
            XCTAssertTrue(viewport.contains(lyrics.frame), "Lyrics control outside viewport")
            if lyrics.isEnabled { XCTAssertTrue(lyrics.isHittable) }
            modal.buttons["Pause"].tap()
            let identity = app.staticTexts["fixture-player-playback-identity"]
            let paused = expectation(
                for: NSPredicate(format: "label CONTAINS %@", "state paused"),
                evaluatedWith: identity)
            wait(for: [paused], timeout: 5)
            XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
            modal.buttons["Show queue"].tap()
            captureAdaptiveGeometry("queue after opening")
            let snapshot = queueSnapshot(app)
            XCTAssertEqual((snapshot["queue"] as? [String])?.count, 5)
            XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
            XCTAssertTrue(modal.buttons["Show artwork"].isHittable)
            modal.buttons["Show artwork"].tap()
            XCTAssertTrue(modal.buttons["Collapse Now Playing"].isHittable)
            capture(
                largeText ? "Adaptive player large text" : "Adaptive player standard text", in: app)
            modal.buttons["Collapse Now Playing"].tap()
            XCTAssertEqual(rootIdentity.label.components(separatedBy: ";").first, selected)
            XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    @objc func testOpenedLandscapePlayerShowsLyricsAndQueueBesideArtwork() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, queuePresentation: true, lyricsPresentation: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let window = app.windows.element(boundBy: 0).frame
        guard window.width > window.height else {
            throw XCTSkip("Requires the opened landscape Duo presentation")
        }
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        let artwork = modal.descendants(matching: .any)["fixture-player-expanded-artwork"]
        let identity = app.staticTexts["fixture-player-playback-identity"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let title = modal.staticTexts["Fixture Tone"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let position = modal.sliders["Playback position"]
        XCTAssertTrue(position.exists)
        XCTAssertEqual(artwork.frame.width, artwork.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(artwork.frame.maxX, position.frame.minX + 1)
        XCTAssertTrue(window.contains(artwork.frame) && window.contains(position.frame))
        let controlColumnX = position.frame.midX
        let fullArtworkWidth = artwork.frame.width
        let selected = identity.label.components(separatedBy: ";").first
        modal.buttons["Show lyrics"].tap()
        let lyric = modal.buttons["Fixture lyric tone"]
        XCTAssertTrue(lyric.waitForExistence(timeout: 5))
        XCTAssertTrue(artwork.isHittable && lyric.isHittable)
        XCTAssertEqual(artwork.frame.width, artwork.frame.height, accuracy: 1)
        XCTAssertEqual(artwork.frame.midX, position.frame.midX, accuracy: 3)
        XCTAssertLessThanOrEqual(lyric.frame.maxX, artwork.frame.minX + 1)
        XCTAssertEqual(position.frame.midX, controlColumnX, accuracy: 3)
        XCTAssertLessThan(artwork.frame.width, fullArtworkWidth)
        XCTAssertLessThanOrEqual(artwork.frame.maxY, title.frame.minY + 1)
        XCTAssertGreaterThan(modal.buttons["Pause"].frame.midX, lyric.frame.maxX)
        XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
        capture("Opened Duo lyrics beside artwork", in: app)
        let lyricsCapture = XCTAttachment(screenshot: app.screenshot())
        lyricsCapture.name = "Opened Duo lyrics beside artwork app surface"
        lyricsCapture.lifetime = .keepAlways
        add(lyricsCapture)
        modal.buttons["Show queue"].tap()
        let queue = modal.descendants(matching: .any)["fixture-queue-list"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        XCTAssertTrue(artwork.isHittable && queue.isHittable)
        XCTAssertLessThanOrEqual(queue.frame.maxX, artwork.frame.minX + 1)
        XCTAssertGreaterThan(modal.buttons["Pause"].frame.midX, queue.frame.maxX)
        XCTAssertEqual(position.frame.midX, controlColumnX, accuracy: 3)
        XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)
        XCTAssertEqual((queueSnapshot(app)["queue"] as? [String])?.count, 5)
        capture("Opened Duo queue beside artwork", in: app)
        let queueCapture = XCTAttachment(screenshot: app.screenshot())
        queueCapture.name = "Opened Duo queue beside artwork app surface"
        queueCapture.lifetime = .keepAlways
        add(queueCapture)
        modal.buttons["Show artwork"].tap()
        XCTAssertTrue(artwork.isHittable)
        XCTAssertLessThanOrEqual(artwork.frame.maxX, position.frame.minX + 1)
        XCTAssertEqual(position.frame.midX, controlColumnX, accuracy: 3)
        XCTAssertEqual(artwork.frame.width, fullArtworkWidth, accuracy: 3)
        XCTAssertEqual(identity.label.components(separatedBy: ";").first, selected)

        // Rotation requires separate review on the exact candidate and device.

    }

    @objc func testNativeZoomQueueScrollKeepsPlayerAndReturnsToBar() {
        continueAfterFailure = false
        let app = launch(.playbackQueue)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        app.buttons["Show queue"].tap()
        let queue = app.descendants(matching: .any)["fixture-queue-list"]
        XCTAssertTrue(queue.waitForExistence(timeout: 5))
        queue.swipeUp()
        XCTAssertTrue(app.buttons["Show artwork"].exists)
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        XCTAssertTrue(modal.exists)
        XCTAssertFalse(app.buttons["Show Now Playing"].isHittable)
        modal.buttons["Next"].tap()
        modal.buttons["Pause"].tap()
        modal.buttons["Play"].tap()
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        openNowPlaying(app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].isHittable)
        capture("Native zoom preserves queue scrolling and playback controls", in: app)
    }

    @objc func testPlayerPlaybackInteractionsDismissWithoutAnArtworkAnchor() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                queuePresentation: true, detachedPlayerArtwork: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        for iteration in 0..<3 {
            openNowPlaying(app)
            app.buttons["Next"].tap()
            app.buttons["Pause"].tap()
            app.buttons["Play"].tap()
            if iteration == 0 {
                let grabber = app.buttons["Collapse Now Playing"].coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                grabber.press(
                    forDuration: 0.1,
                    thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: app.frame.height * 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            } else if iteration == 1 {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.3))
                start.press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.3)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                app.buttons["Collapse Now Playing"].tap()
            }
            XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Show Now Playing"].isHittable)
        }
        capture(
            "Playback controls retain header edge and button dismissal without artwork", in: app)
    }

    @objc func testHomeFinalShelfStaysClearOfNativeMiniPlayer() {
        assertHomeFinalShelfClearsMiniPlayer(largeText: false)
    }

    @objc func testHomeFinalShelfStaysClearOfNativeMiniPlayerAtAccessibilitySize() {
        assertHomeFinalShelfClearsMiniPlayer(largeText: true)
    }

    private func assertHomeFinalShelfClearsMiniPlayer(largeText: Bool) {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, largeText: largeText, canonicalDownloadState: "full",
                artworkCache: true, longPlayback: true, colorScheme: largeText ? "light" : "dark",
                compactFixtureControls: true,
                homeScrollBoundary: true, homeNativeViewportDiagnostic: !largeText))
        selectTab("Home", in: app)
        let scroll = app.scrollViews["foundation-home-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show Now Playing"].exists)
        captureHomeBoundary("Initial Home remains at its top", in: app)
        let initial = app.staticTexts["foundation-home-scroll-boundary"].value as? String ?? ""
        XCTAssertEqual(
            homeBoundaryNumber("offsetY", in: initial)
                + homeBoundaryNumber("insetTop", in: initial), 0, accuracy: 1)
        let initialOffsetToken = String(initial.split(separator: " ").first ?? "") + " "
        let remainsAtTop = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT(value BEGINSWITH %@)", initialOffsetToken),
            object: app.staticTexts["foundation-home-scroll-boundary"])
        remainsAtTop.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [remainsAtTop], timeout: 1), .completed)
        scrollHomeToFinalShelf(scroll, in: app)
        captureHomeBoundary("Final Home shelf without a mini-player", in: app)

        if !app.tabBars.buttons["Library"].exists {
            // A native scroll-minimized bar shows only its selected tab and Search.
            // Tapping the collapsed selected tab reveals the other destinations.
            tapNativeChrome(app.tabBars.buttons["Home"], in: app)
        }
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let player = app.buttons["Show Now Playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        if largeText {
            assertMiniPlayerValue("Playing", in: player)
        }
        if !app.tabBars.buttons["Home"].exists {
            tapNativeChrome(app.tabBars.buttons["Library"], in: app)
        }
        selectTab("Home", in: app)
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        captureHomeBoundary(
            "Retained Home scroll position when the first mini-player appears", in: app)
        scrollHomeToFinalShelf(scroll, in: app)
        captureHomeBoundary("Final Home shelf above the native mini-player", in: app)
        assertFinalHomeCardClearsPlayer(player, in: app)

        let toggle = app.buttons["foundation-mini-playback-toggle"]
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        toggle.tap()
        if largeText {
            assertMiniPlayerValue("Paused", in: player)
        }
        captureHomeBoundary(
            "Final Home shelf remains reachable after playback state change", in: app)
        assertFinalHomeCardClearsPlayer(player, in: app)

        XCTAssertTrue(app.buttons["foundation-mini-player-minimized"].exists)
        tapNativeChrome(app.tabBars.buttons["Home"], in: app)
        XCTAssertTrue(
            app.buttons["foundation-mini-player-normal"].waitForExistence(timeout: 5))
        captureHomeBoundary(
            "Final Home shelf when the native tab bar expands at the scroll end", in: app)
        assertFinalHomeCardClearsPlayer(player, in: app)
        XCTAssertTrue(app.buttons["foundation-mini-player-normal"].exists)
        let staysExpanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"),
            object: app.buttons["foundation-mini-player-minimized"])
        staysExpanded.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [staysExpanded], timeout: 1), .completed)
        scrollHomeToFinalShelf(scroll, in: app)
        captureHomeBoundary(
            "Final Home shelf after scrolling again from the expanded native tab bar", in: app)
        assertFinalHomeCardClearsPlayer(player, in: app)
    }

    func assertMiniPlayerValue(_ state: String, in player: XCUIElement) {
        let published = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", state), object: player)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 5), .completed)
        let value = player.value as? String ?? ""
        XCTAssertTrue(value.contains("Fixture Tone") && value.contains("Generated silent PCM"))
        XCTAssertTrue(value.contains(state))
    }

    @objc func testNativeMiniPlayerMinimizesExpandsAndReturnsToNormal() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, alphabetCatalog: true, compactFixtureControls: true))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        let table = app.tables["library-index-track"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        table.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: table.frame.width * 0.5, dy: 60)).tap()
        let open = app.buttons["Show Now Playing"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        let normal = app.buttons["foundation-mini-player-normal"]
        let minimized = app.buttons["foundation-mini-player-minimized"]
        XCTAssertTrue(normal.waitForExistence(timeout: 5) && normal.isHittable)
        table.swipeUp()
        XCTAssertTrue(minimized.waitForExistence(timeout: 5) && minimized.isHittable)
        capture("Native scroll-minimized player", in: app)
        openNowPlaying(app)
        dismissNowPlaying(app)
        XCTAssertTrue(open.isHittable)
        // Scroll back to the top, where UIKit restores the normal tab accessory.
        for _ in 0..<5 {
            if normal.exists && normal.isHittable { break }
            table.swipeDown()
        }
        XCTAssertTrue(normal.waitForExistence(timeout: 5) && normal.isHittable)
        openNowPlaying(app)
        dismissNowPlaying(app)
        XCTAssertTrue(open.isHittable)
        capture("Native player restored to normal placement", in: app)
    }

    @objc func testTracksAlphabetOfflineAndRelatedNavigationRetainPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                alphabetCatalog: true, compactFixtureControls: true))
        selectTab("Home", in: app)
        let tone = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "# Fixture Tone")
        ).firstMatch
        tapVisible(tone, in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let original = identity.label
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        tapNativeAlphabet("F", in: app)
        tapNativeAlphabet("A", in: app)
        tapVisible(app.buttons["Actions for A Fixture track 0"], in: app)
        app.cells.buttons["View Album"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["collection-detail-album-album"]
                .waitForExistence(timeout: 5))
        XCTAssertEqual(identity.label, original)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tables["library-index-track"].waitForExistence(timeout: 5))
        toggleAlphabetNetwork(app, offline: true)
        let before = readAlphabetCounts(app)
        tapNativeAlphabet("F", in: app)
        tapNativeAlphabet("Z", in: app)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(tone.waitForExistence(timeout: 5))
        XCTAssertEqual(readAlphabetCounts(app), before)
        XCTAssertEqual(identity.label, original)
        toggleAlphabetNetwork(app, offline: false)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].waitForExistence(timeout: 5))
        XCTAssertEqual(identity.label, original)
        capture("Full-list anchors offline and related navigation retain playback", in: app)
    }

    private func closeRelatedSheet(_ app: XCUIApplication) {
        XCTAssertFalse(relatedSheet(app).buttons["now-playing-related-close"].exists)
        dragRelatedSheet(app, verticalDistance: app.frame.height * 0.85)
        let gone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: relatedSheet(app))
        wait(for: [gone], timeout: 5)
    }

    @objc func testNativeZoomBoundedPerformance() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(
            metrics: [
                XCTClockMetric(), XCTCPUMetric(application: app), XCTMemoryMetric(application: app),
            ],
            options: options
        ) {
            openNowPlaying(app)
            XCTAssertTrue(app.descendants(matching: .any)["foundation-now-playing"].exists)
            dismissNowPlaying(app)
        }
    }

    @objc func testMiniPlayerNativeZoomReverseAndCancelledDismissalKeepsPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true))
        for tab in ["Home", "New", "Library"] {
            selectTab(tab, in: app)
            capture("Native rounded glyphs selected " + tab, in: app)
        }
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label
        capture("Mini player artwork morph canonical source", in: app)
        openNowPlaying(app)
        let artwork = app.descendants(matching: .any)["fixture-player-expanded-artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        let expandedFrame = artwork.frame
        capture("Cohesive glass mini bar expands into player surface", in: app)
        dragExpandedPlayerArtwork(app, distance: 28)
        XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertEqual(artwork.frame.minX, expandedFrame.minX, accuracy: 2)
        XCTAssertEqual(artwork.frame.minY, expandedFrame.minY, accuracy: 2)
        XCTAssertEqual(artwork.frame.width, expandedFrame.width, accuracy: 2)
        XCTAssertEqual(artwork.frame.height, expandedFrame.height, accuracy: 2)
        XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, originalIdentity)
        capture("Artwork native interactive cancellation restores expanded snapshot", in: app)
        dismissNowPlaying(app)
        XCTAssertTrue(app.descendants(matching: .any)["collection-detail-album-album"].exists)
        XCTAssertEqual(identity.label, originalIdentity)
        capture("Artwork reverse morph restores same canonical mini player", in: app)
        openNowPlaying(app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        dismissNowPlaying(app)
        XCTAssertEqual(identity.label, originalIdentity)
    }

    @objc func testNowPlayingAlbumAndArtistUseCanonicalRoutesOnlineAndOffline() {
        verifyNowPlayingCanonicalRoutes(state: "full", offlineOnly: false)
    }

    @objc func testNowPlayingPartialOfflineAlbumAndArtistPreserveKnownTracksAndPlayback() {
        verifyNowPlayingCanonicalRoutes(state: "partial", offlineOnly: true)
    }

    @objc func testRelatedAlbumAndArtistContentDragExpandsMediumSheet() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch(
            .init(
                productionShell: true, largeText: true, canonicalDownloadState: "full",
                longPlayback: true,
                compactFixtureControls: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        for kind in ["Album", "Artist"] {
            tapNativeChrome(app.buttons["More playback options"], in: app)
            tapVisible(app.buttons["View " + kind], in: app)
            assertRelatedDetent("medium", in: app)
            capture("Related \(kind) content at medium detent", in: app)
            let sheet = relatedSheet(app)
            let title = sheet.staticTexts["Fixture " + kind].firstMatch
            XCTAssertTrue(title.exists && title.frame.height > 0)
            let mediumTitleOffset = title.frame.minY - sheet.frame.minY
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(
                    dx: sheet.frame.midX - app.frame.minX,
                    dy: sheet.frame.minY + sheet.frame.height * 0.75 - app.frame.minY))
            start.press(
                forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -12)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            assertRelatedDetent("medium", in: app)
            XCTAssertEqual(
                title.frame.minY - sheet.frame.minY, mediumTitleOffset, accuracy: 2,
                "Medium-height detail content must stay fixed relative to its sheet")
            start.press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)))
            assertRelatedDetent("large", in: app)
            capture("Related \(kind) body drag expands before content scrolling", in: app)
            let expandedTitleOffset = title.frame.minY - sheet.frame.minY
            sheet.swipeUp()
            XCTAssertLessThan(
                title.frame.minY - sheet.frame.minY, expandedTitleOffset - 20,
                "Large-height detail content must remain scrollable")
            // Dismiss from the content, not the grabber, so a refresh control cannot consume the drag.
            for _ in 0..<3 where relatedSheet(app).exists {
                let current = relatedSheet(app)
                let contentStart = current.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                contentStart.press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(
                        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            }
            let dismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: relatedSheet(app))
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        }
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
    }

    @objc func testRelatedSheetRefinedControlsRemainUsable() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        app.buttons["Pause"].tap()
        app.buttons["More playback options"].tap()
        app.buttons["View Artist"].tap()
        let pin = relatedSheet(app).buttons["related-artist-pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5) && pin.isHittable)
        let initialLabel = pin.label
        XCTAssertGreaterThanOrEqual(pin.frame.width, 44)
        XCTAssertGreaterThanOrEqual(pin.frame.height, 44)
        XCTAssertLessThanOrEqual(pin.frame.width, 46)
        XCTAssertLessThanOrEqual(pin.frame.height, 46)
        pin.tap()
        XCTAssertNotEqual(pin.label, initialLabel)
        pin.tap()
        XCTAssertEqual(pin.label, initialLabel)
        XCTAssertFalse(relatedSheet(app).buttons["More actions"].exists)
        capture("Artist sheet direct pin and contrast", in: app)
        closeRelatedSheet(app)
        app.buttons["More playback options"].tap()
        app.buttons["View Album"].tap()
        let more = relatedSheet(app).buttons["More actions"]
        XCTAssertTrue(more.waitForExistence(timeout: 5) && more.isHittable)
        XCTAssertGreaterThanOrEqual(more.frame.width, 44)
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        capture("Album sheet larger glass controls and contrast", in: app)
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Play"].exists)
    }

    @objc func testRelatedSheetCanonicalActionPresentersStayInPlayer() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                playlistPresentation: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        let detail = app.descendants(matching: .any)["collection-detail-album-album"]
        let toolbar = app.buttons["More actions"]
        let detailFrame = detail.frame
        let toolbarFrame = toolbar.frame
        let toolbarDownload = app.navigationBars.buttons.matching(
            identifier: "download-state-complete"
        ).firstMatch
        XCTAssertTrue(toolbarDownload.exists && toolbarDownload.isHittable)
        let downloadFrame = toolbarDownload.frame
        let downloadLabel = toolbarDownload.label
        let downloadEnabled = toolbarDownload.isEnabled
        XCTAssertGreaterThan(detailFrame.width, 0)
        XCTAssertGreaterThan(detailFrame.height, 0)
        XCTAssertGreaterThan(toolbarFrame.width, 0)
        XCTAssertGreaterThan(toolbarFrame.height, 0)
        tapNativeChrome(toolbar, in: app)
        let baselineAddMatches = app.cells.buttons.matching(
            NSPredicate(format: "label == %@", "Add to Playlist"))
        XCTAssertEqual(baselineAddMatches.count, 1)
        let baselineAdd = baselineAddMatches.element
        XCTAssertTrue(baselineAdd.waitForExistence(timeout: 5) && baselineAdd.isHittable)
        XCTAssertTrue(baselineAdd.isEnabled)
        XCTAssertGreaterThan(baselineAdd.frame.width, 0)
        XCTAssertGreaterThan(baselineAdd.frame.height, 0)
        XCTAssertTrue(app.frame.contains(baselineAdd.frame))
        let baselineAddEnabled = baselineAdd.isEnabled
        let menuRemoval = app.buttons["Remove Downloads"]
        XCTAssertTrue(menuRemoval.exists)
        let menuRemovalFrame = menuRemoval.frame
        XCTAssertFalse(
            menuRemovalFrame.intersects(downloadFrame),
            "The native menu row and canonical download toolbar have distinct geometry")
        let point = CGPoint(
            x: detailFrame.minX + detailFrame.width * 0.06,
            y: toolbarFrame.maxY + 32)
        XCTAssertTrue(app.frame.contains(point) && detailFrame.contains(point))
        XCTAssertFalse(toolbarFrame.insetBy(dx: -12, dy: -12).contains(point))
        XCTAssertFalse(baselineAdd.frame.insetBy(dx: -12, dy: -12).contains(point))
        XCTAssertFalse(menuRemovalFrame.insetBy(dx: -12, dy: -12).contains(point))
        XCTAssertFalse(downloadFrame.insetBy(dx: -12, dy: -12).contains(point))
        app.coordinate(withNormalizedOffset: .zero).withOffset(
            CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)
        ).tap()
        for overlay in [baselineAdd, app.buttons["Remove"]] {
            let closed = expectation(
                for: NSPredicate(format: "exists == false"), evaluatedWith: overlay)
            wait(for: [closed], timeout: 5)
        }
        // The menu and toolbar share this download identifier. Query the native bar anew:
        // global Remove Downloads legitimately resolves to the restored canonical control.
        let restoredMore = app.buttons["More actions"]
        XCTAssertTrue(restoredMore.exists && restoredMore.isHittable)
        let restoredDownload = app.navigationBars.buttons.matching(
            identifier: "download-state-complete"
        ).firstMatch
        XCTAssertTrue(restoredDownload.exists && restoredDownload.isHittable)
        XCTAssertEqual(restoredDownload.label, downloadLabel)
        XCTAssertEqual(restoredDownload.isEnabled, downloadEnabled)
        XCTAssertEqual(restoredDownload.frame.minX, downloadFrame.minX, accuracy: 2)
        XCTAssertEqual(restoredDownload.frame.minY, downloadFrame.minY, accuracy: 2)
        XCTAssertEqual(restoredDownload.frame.width, downloadFrame.width, accuracy: 2)
        XCTAssertEqual(restoredDownload.frame.height, downloadFrame.height, accuracy: 2)
        XCTAssertFalse(restoredDownload.frame.intersects(menuRemovalFrame))
        XCTAssertFalse(app.staticTexts["Remove downloads?"].exists)
        let baseline = canonicalPresentation(
            app, state: "full", offline: false,
            captureName: "Canonical album before related sheet action presenters")
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label
        openNowPlaying(app)
        app.buttons["More playback options"].tap()
        app.buttons["View Album"].tap()
        assertRelatedDetent("medium", in: app)
        expandRelatedSheet(app)
        let sheet = relatedSheet(app)
        let more = sheet.buttons["More actions"]
        tapNativeChrome(more, in: app)
        let globalAddCandidates = app.buttons.matching(
            NSPredicate(format: "label == %@", "Add to Playlist"))
        let globalAddCount = globalAddCandidates.count
        var addCandidateRows = ["Synthetic Add to Playlist candidates: \(globalAddCount)"]
        for index in 0..<min(globalAddCount, 16) {
            let candidate = globalAddCandidates.element(boundBy: index)
            addCandidateRows.append(
                "\(index): identifier=\(candidate.identifier); frame=\(candidate.frame); enabled=\(candidate.isEnabled); hittable=\(candidate.isHittable)"
            )
        }
        if globalAddCount > 16 {
            addCandidateRows.append("Additional candidates omitted: \(globalAddCount - 16)")
        }
        let addCandidateEvidence = XCTAttachment(string: addCandidateRows.joined(separator: "\n"))
        addCandidateEvidence.name = "Synthetic related menu Add to Playlist candidates"
        addCandidateEvidence.lifetime = .keepAlways
        self.add(addCandidateEvidence)
        capture("Synthetic related native menu before Add to Playlist", in: app)
        let addMatches = app.cells.buttons.matching(
            NSPredicate(format: "label == %@", "Add to Playlist"))
        XCTAssertEqual(addMatches.count, 1)
        let add = addMatches.element
        XCTAssertTrue(add.waitForExistence(timeout: 5) && add.isHittable)
        XCTAssertGreaterThan(add.frame.width, 0)
        XCTAssertGreaterThan(add.frame.height, 0)
        XCTAssertTrue(app.frame.contains(add.frame))
        XCTAssertEqual(add.isEnabled, baselineAddEnabled)
        add.tap()
        let picker = app.navigationBars["Add to Playlist"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fixture Playlist"].waitForExistence(timeout: 10))
        capture("Canonical Add to Playlist picker presented above related player sheet", in: app)
        // The existing picker cancels selection through native Done; never select a playlist.
        tapNativeChrome(picker.buttons["Done"], in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["fixture-related-playback-identity"].label, originalIdentity)
        tapNativeChrome(more, in: app)
        let removalHierarchy = XCTAttachment(string: String(app.debugDescription.prefix(120_000)))
        removalHierarchy.name = "Synthetic related removal menu hierarchy (120000 character cap)"
        removalHierarchy.lifetime = .keepAlways
        self.add(removalHierarchy)
        capture("Synthetic related removal menu before unchanged hit assertion", in: app)
        let removalCandidates = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Downloads"))
        let removalCandidateCount = removalCandidates.count
        var removalDiagnostics = [
            "Synthetic Remove Downloads candidates: \(removalCandidateCount)",
            "Candidate cap: 16; overflow: \(max(0, removalCandidateCount - 16))",
        ]
        for candidateIndex in 0..<min(16, removalCandidateCount) {
            let candidate = removalCandidates.element(boundBy: candidateIndex)
            removalDiagnostics.append(
                "index \(candidateIndex); identifier \(candidate.identifier); "
                    + "frame \(String(describing: candidate.frame)); enabled \(candidate.isEnabled); "
                    + "hittable \(candidate.isHittable)")
        }
        let removalEvidence = XCTAttachment(string: removalDiagnostics.joined(separator: "\n"))
        removalEvidence.name = "Synthetic related removal menu matching controls (16 candidate cap)"
        removalEvidence.lifetime = .keepAlways
        self.add(removalEvidence)
        let menuRemovals = app.cells.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Downloads"))
        XCTAssertEqual(menuRemovals.count, 1, "The native menu must expose one removal action")
        let remove = menuRemovals.element
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isHittable)
        XCTAssertGreaterThan(remove.frame.width, 0)
        XCTAssertGreaterThan(remove.frame.height, 0)
        XCTAssertTrue(app.frame.contains(remove.frame))
        remove.tap()
        let destructive = app.buttons["Remove"]
        XCTAssertTrue(destructive.waitForExistence(timeout: 5))
        capture("Canonical download removal confirmation above related player sheet", in: app)
        let cancel = app.buttons["Cancel"]
        if cancel.exists && cancel.isHittable {
            cancel.tap()
        } else {
            // Native toolbar confirmation popovers omit Cancel and dismiss on outside taps.
            // The retained screenshot places this point on the inert left artwork header,
            // above and left of the confirmation content, away from native toolbar controls.
            let point = CGPoint(
                x: sheet.frame.minX + sheet.frame.width * 0.06,
                y: sheet.frame.minY + sheet.frame.height * 0.25)
            XCTAssertTrue(app.frame.contains(point))
            XCTAssertFalse(destructive.frame.insetBy(dx: -24, dy: -24).contains(point))
            let title = app.staticTexts["Remove downloads?"]
            if title.exists {
                XCTAssertFalse(title.frame.insetBy(dx: -24, dy: -24).contains(point))
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)
            ).tap()
        }
        let confirmationClosed = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: destructive)
        wait(for: [confirmationClosed], timeout: 5)
        XCTAssertTrue(sheet.exists)
        let after = canonicalPresentation(
            app, state: "full", offline: false,
            captureName: "Cancelled canonical actions preserve downloaded related album rows",
            context: sheet)
        XCTAssertEqual(after, baseline)
        XCTAssertEqual(app.staticTexts["fixture-related-playback-identity"].label, originalIdentity)
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        dismissNowPlaying(app)
        XCTAssertEqual(identity.label, originalIdentity)
    }

    @objc func testNowPlayingRelatedAlbumUsesSystemLightAppearance() {
        verifyNowPlayingRelatedAlbumAppearance("light")
    }

    @objc func testNowPlayingRelatedAlbumUsesSystemDarkAppearance() {
        verifyNowPlayingRelatedAlbumAppearance("dark")
    }

    /// The serialized host sets the retained simulator to Light before launch, then changes
    /// real system appearance at these log markers. No fixture appearance override is used.

    @objc func testNowPlayingRelatedSheetFollowsLiveSystemAppearanceAndKeepsPlayerContrast() throws
    {
        guard ProcessInfo.processInfo.environment["VELACANTO_SHEET206_LIVE_APPEARANCE"] == "1"
        else {
            throw XCTSkip("Requires serialized host orchestration of real simulator appearance")
        }
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        capture("System Light full player retains artwork status contrast", in: app)
        app.buttons["More playback options"].tap()
        app.buttons["View Album"].tap()
        assertRelatedDetent("medium", in: app)
        let context = relatedSheet(app).staticTexts["fixture-detail-context-album-album"]
        XCTAssertTrue(context.waitForExistence(timeout: 5))
        XCTAssertEqual(context.label, "Detail context: related; appearance light")
        capture("Live system Light medium details with artwork status contrast", in: app)
        NSLog("VELACANTO_SHEET206_READY_DARK")
        waitForRelatedAppearance("dark", context: context)
        capture("Live system Dark medium details with artwork status contrast", in: app)
        expandRelatedSheet(app)
        XCTAssertEqual(context.label, "Detail context: related; appearance dark")
        NSLog("VELACANTO_SHEET206_READY_LIGHT")
        waitForRelatedAppearance("light", context: context)
        capture("Live system Light large details with artwork status contrast", in: app)
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        capture("Full player retains artwork status contrast after live changes", in: app)
        app.buttons["More playback options"].tap()
        app.buttons["View Album"].tap()
        assertRelatedDetent("medium", in: app)
        XCTAssertEqual(context.label, "Detail context: related; appearance light")
        capture("Live system Light details reopened with artwork status contrast", in: app)
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
    }

    private func waitForRelatedAppearance(_ scheme: String, context: XCUIElement) {
        let changed = expectation(
            for: NSPredicate(
                format: "label == %@", "Detail context: related; appearance \(scheme)"),
            evaluatedWith: context)
        // This new orchestration boundary allows the host to issue the real OS change.
        wait(for: [changed], timeout: 30)
    }

    private func verifyNowPlayingRelatedAlbumAppearance(_ scheme: String) {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                colorScheme: scheme))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        for cycle in 0..<2 {
            app.buttons["More playback options"].tap()
            app.buttons["View Album"].tap()
            assertRelatedDetent("medium", in: app)
            let context = relatedSheet(app).staticTexts["fixture-detail-context-album-album"]
            XCTAssertTrue(context.waitForExistence(timeout: 5))
            capture("Now Playing album \(scheme) medium cycle \(cycle)", in: app)
            XCTAssertEqual(context.label, "Detail context: related; appearance \(scheme)")
            expandRelatedSheet(app)
            XCTAssertEqual(context.label, "Detail context: related; appearance \(scheme)")
            capture("Now Playing album \(scheme) large cycle \(cycle)", in: app)
            closeRelatedSheet(app)
            XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        }
    }

    @objc func testNowPlayingArtistAlbumNavigationKeepsSheetContextAndPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                colorScheme: "dark"))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let identity = app.staticTexts["fixture-player-playback-identity"].label
        app.buttons["More playback options"].tap()
        app.buttons["View Artist"].tap()
        assertRelatedDetent("medium", in: app)
        expandRelatedSheet(app)
        let rootContext = relatedSheet(app).staticTexts["fixture-detail-context-artist-artist"]
        XCTAssertTrue(rootContext.waitForExistence(timeout: 5))
        XCTAssertEqual(rootContext.label, "Detail context: related; appearance dark")
        let album = relatedSheet(app).buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", "View Fixture Album", "Fixture Album")
        ).firstMatch
        for cycle in 0..<3 {
            tapVisible(album, in: app, context: relatedSheet(app))
            let albumContext = relatedSheet(app).staticTexts["fixture-detail-context-album-album"]
            XCTAssertTrue(albumContext.waitForExistence(timeout: 5))
            capture("Nested album retains Now Playing context cycle \(cycle)", in: app)
            XCTAssertEqual(albumContext.label, "Detail context: related; appearance dark")
            XCTAssertEqual(app.staticTexts["fixture-related-playback-identity"].label, identity)
            relatedSheet(app).navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(rootContext.waitForExistence(timeout: 5))
        }
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
    }

    @objc func testNowPlayingDetailsOmitRecommendationsWithoutLoadingThem() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, relatedRecommendations: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        let recommendation = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Recommended Fixture Album")
        ).firstMatch
        reveal(recommendation, in: app)
        XCTAssertTrue(app.staticTexts["More Like This"].exists)
        let before = recommendationCounts(
            readAlphabetCounts(app, containing: "recommendations-album 1"))
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let identity = app.staticTexts["fixture-player-playback-identity"].label
        for route in ["View Album", "View Artist"] {
            app.buttons["More playback options"].tap()
            app.buttons[route].tap()
            assertRelatedDetent("medium", in: app)
            expandRelatedSheet(app)
            for _ in 0..<3 { scrollContent(in: app, upward: true, context: relatedSheet(app)) }
            XCTAssertFalse(relatedSheet(app).staticTexts["More Like This"].exists)
            XCTAssertFalse(relatedSheet(app).staticTexts["Appears On"].exists)
            XCTAssertFalse(relatedSheet(app).buttons["Recommended Fixture Album"].exists)
            XCTAssertEqual(app.staticTexts["fixture-related-playback-identity"].label, identity)
            capture("Now Playing \(route) omits optional recommendations", in: app)
            closeRelatedSheet(app)
            XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        }
        dismissNowPlaying(app)
        XCTAssertEqual(
            recommendationCounts(readAlphabetCounts(app, containing: "recommendations-album 1")),
            before)
        reveal(recommendation, in: app)
        XCTAssertTrue(recommendation.exists, "Normal album recommendations remain available")
    }

    private func recommendationCounts(_ summary: String) -> [String: Int] {
        let keys = ["recommendations-album", "recommendations-artist", "artist-appearances"]
        var result = Dictionary(uniqueKeysWithValues: keys.map { ($0, 0) })
        for entry in summary.components(separatedBy: ", ") {
            let parts = entry.split(separator: " ")
            guard parts.count == 2, keys.contains(String(parts[0])), let count = Int(parts[1])
            else {
                continue
            }
            result[String(parts[0])] = count
        }
        return result
    }

    @objc func testNowPlayingRelatedSheetNativeDetentsCancellationAndScrollKeepPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "partial", longPlayback: true))
        selectTab("Library", in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label
        openNowPlaying(app)
        for cycle in 0..<2 {
            app.buttons["More playback options"].tap()
            app.buttons["View Album"].tap()
            assertRelatedDetent("medium", in: app)
            capture("Related sheet partial offline medium cycle \(cycle)", in: app)
            dragRelatedSheet(app, verticalDistance: 28)
            assertRelatedDetent("medium", in: app)
            capture("Related sheet cancelled native dismissal", in: app)
            expandRelatedSheet(app)
            capture("Immersive related sheet large retains native grabber", in: app)
            XCTAssertFalse(relatedSheet(app).buttons["now-playing-related-close"].exists)
            XCTAssertFalse(relatedSheet(app).navigationBars.firstMatch.exists)
            XCTAssertTrue(relatedSheet(app).staticTexts["Fixture Album"].firstMatch.exists)
            let row = relatedSheet(app).buttons["collection-track-2"]
            reveal(row, in: app, context: relatedSheet(app))
            XCTAssertTrue(row.exists)
            XCTAssertTrue(relatedSheet(app).exists)
            assertRelatedDetent("large", in: app)
            XCTAssertEqual(
                app.staticTexts["fixture-related-playback-identity"].label, originalIdentity)
            dragRelatedSheet(app, verticalDistance: app.frame.height * 0.35)
            assertRelatedDetent("medium", in: app)
            capture("Related sheet collapsed to medium", in: app)
            if cycle == 0 {
                dragRelatedSheet(app, verticalDistance: app.frame.height * 0.65)
                let gone = expectation(
                    for: NSPredicate(format: "exists == false"), evaluatedWith: relatedSheet(app))
                wait(for: [gone], timeout: 5)
            } else {
                closeRelatedSheet(app)
            }
            XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Pause"].exists)
            XCTAssertEqual(
                app.staticTexts["fixture-player-playback-identity"].label, originalIdentity)
        }
        dismissNowPlaying(app)
        XCTAssertTrue(app.descendants(matching: .any)["collection-detail-album-album"].exists)
        XCTAssertEqual(identity.label, originalIdentity)
    }

    @objc func testRelatedSheetLargeTextReducedEffectsAndMissingArtworkKeepsCanonicalContent() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, largeText: true, canonicalDownloadState: "partial",
                longPlayback: true, missingArtwork: true, reducedAccessibilityEffects: true))
        XCTAssertTrue(app.staticTexts["fixture-accessibility-effects"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["fixture-accessibility-effects"].label,
            "Synthetic accessibility: reduced motion, reduced transparency")
        XCTAssertEqual(
            app.staticTexts["fixture-dynamic-type-size"].label,
            "Synthetic Dynamic Type: accessibility3")
        selectTab("Library", in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        openCanonicalCollection("album", fromDownloads: false, in: app)
        let baseline = canonicalPresentation(
            app, state: "partial", offline: true,
            captureName: "Accessible missing artwork canonical Library album")
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label
        openNowPlaying(app)
        app.buttons["More playback options"].tap()
        app.buttons["View Album"].tap()
        assertRelatedDetent("medium", in: app)
        capture("Accessible missing artwork medium native sheet", in: app)
        expandRelatedSheet(app)
        let routed = canonicalPresentation(
            app, state: "partial", offline: true,
            captureName: "Accessible missing artwork large canonical sheet",
            context: relatedSheet(app))
        XCTAssertEqual(routed, baseline)
        XCTAssertEqual(app.staticTexts["fixture-related-playback-identity"].label, originalIdentity)
        closeRelatedSheet(app)
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 5))
        dismissNowPlaying(app)
        XCTAssertEqual(identity.label, originalIdentity)
    }

    private struct ArtistPresentation: Equatable {
        let title: String
        let playEnabled: Bool
        let shuffleEnabled: Bool
        let albumLabel: String
    }

    private func canonicalArtistPresentation(
        _ app: XCUIApplication, captureName: String, context: XCUIElement? = nil
    ) -> ArtistPresentation {
        let root = context ?? app
        let title = root.staticTexts["Fixture Artist"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(root.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(root.buttons["Shuffle"].exists)
        let titleLabel = title.label
        let playEnabled = root.buttons["Play"].isEnabled
        let shuffleEnabled = root.buttons["Shuffle"].isEnabled
        let album = root.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", "View Fixture Album", "Fixture Album")
        )
        .firstMatch
        reveal(album, in: app, context: context)
        let presentation = ArtistPresentation(
            title: titleLabel, playEnabled: playEnabled,
            shuffleEnabled: shuffleEnabled, albumLabel: album.label)
        capture(captureName, in: app)
        return presentation
    }

    private func verifyNowPlayingCanonicalRoutes(state: String, offlineOnly: Bool) {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, canonicalDownloadState: state, longPlayback: true))
        selectTab("Library", in: app)
        if offlineOnly { app.switches["Simulate unavailable network"].switches.firstMatch.tap() }
        tapVisible(app.buttons["library-category-artists"], in: app)
        XCTAssertTrue(app.navigationBars["Artists"].waitForExistence(timeout: 5))
        let libraryArtist = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@", "Fixture Artist")
        ).firstMatch
        tapVisible(libraryArtist, in: app)
        let artistBaseline = canonicalArtistPresentation(
            app,
            captureName: "Canonical Library artist baseline for Now Playing routes")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        openCanonicalCollection("album", fromDownloads: false, in: app)
        let baseline = canonicalPresentation(
            app, state: state, offline: offlineOnly,
            captureName: "Canonical Library album baseline for Now Playing routes")
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "state playing"), object: identity)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let originalIdentity = identity.label
        for offline in (offlineOnly ? [true] : [false, true]) {
            if offline && !offlineOnly {
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
            for route in ["View Album", "View Artist", "View Album"] {
                openNowPlaying(app)
                XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Pause"].exists)
                app.buttons["More playback options"].tap()
                XCTAssertTrue(app.buttons[route].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons[route].isEnabled)
                app.buttons[route].tap()
                assertRelatedDetent("medium", in: app)
                capture("Now Playing " + route + " native medium sheet", in: app)
                expandRelatedSheet(app)
                if route == "View Artist" {
                    let routedArtist = canonicalArtistPresentation(
                        app,
                        captureName: "Now Playing canonical artist route "
                            + (offline ? "offline" : "online"), context: relatedSheet(app))
                    XCTAssertEqual(routedArtist, artistBaseline)
                    let album = relatedSheet(app).buttons.matching(
                        NSPredicate(
                            format: "label == %@ OR label BEGINSWITH %@", "View Fixture Album",
                            "Fixture Album")
                    ).firstMatch
                    tapVisible(album, in: app, context: relatedSheet(app))
                }
                XCTAssertTrue(
                    relatedSheet(app).descendants(matching: .any)["collection-detail-album-album"]
                        .waitForExistence(timeout: 5))
                let routed = canonicalPresentation(
                    app, state: state, offline: offline,
                    captureName: "Now Playing " + route + " canonical album "
                        + (offline ? "offline" : "online"), context: relatedSheet(app))
                XCTAssertEqual(routed, baseline)
                XCTAssertEqual(
                    app.staticTexts["fixture-related-playback-identity"].label, originalIdentity,
                    "Navigation must retain exact occurrence and playing state")
                if route == "View Artist" {
                    relatedSheet(app).navigationBars.buttons.firstMatch.tap()
                    XCTAssertTrue(
                        relatedSheet(app).staticTexts["Fixture Artist"].firstMatch.waitForExistence(
                            timeout: 5))
                }
                closeRelatedSheet(app)
                XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Pause"].exists)
                dismissNowPlaying(app)
                XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
                XCTAssertTrue(
                    app.descendants(matching: .any)["collection-detail-album-album"].exists,
                    "Related sheet must return to the original Library album")
                XCTAssertEqual(identity.label, originalIdentity)
            }
        }
    }

    @objc func testNowPlayingUnknownAlbumAndArtistStayDisabledWithoutInterruptingPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, longPlayback: true, unknownRelatedItems: true))
        app.buttons["Queue fixture playlist"].tap()
        waitForSavedDownload(app)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "state playing"), object: identity)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let originalIdentity = identity.label
        for offline in [false, true] {
            if offline { app.switches["Simulate unavailable network"].switches.firstMatch.tap() }
            openNowPlaying(app)
            XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
            app.buttons["More playback options"].tap()
            for title in ["View Album", "View Artist"] {
                XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
                XCTAssertFalse(app.buttons[title].isEnabled)
            }
            capture("Now Playing missing related metadata has disabled native actions", in: app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            dismissNowPlaying(app)
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            XCTAssertEqual(identity.label, originalIdentity)
        }
    }

    @objc func testRemoteContinueListeningHomePullRefreshReadsUpdatedActivity() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, compactFixtureControls: true, remoteListening: true))
        selectTab("Home", in: app)
        let media = app.buttons["Continue listening instructions"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        XCTAssertTrue((media.value as? String ?? "").contains("Remote Fixture Track 0"))
        openAlphabetFixtureControls(app)
        tapNativeChrome(app.buttons["Next remote fixture track"], in: app)
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Remote generation 1"),
            object: app.staticTexts["fixture-remote-generation"])
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        closeAlphabetFixtureControls(app)
        let read = app.buttons["Read catalog counts"]
        func remoteReads() -> Int {
            let value = read.value as? String ?? ""
            let entry = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.first { $0.hasPrefix("remote-listening ") }
            return entry.flatMap { Int($0.dropFirst("remote-listening ".count)) } ?? -1
        }
        _ = readAlphabetCounts(app, containing: "remote-listening ")
        let before = remoteReads()
        XCTAssertGreaterThan(before, 0)
        let home = chromeScroll(app, "home")
        XCTAssertTrue(home.exists && home.isHittable)
        let heading = app.staticTexts["continue-listening-heading"]
        XCTAssertTrue(heading.exists && heading.isHittable)
        capture("Home top immediately before the single refresh gesture", in: app)
        // The previous synthesized swipe was only200pt/0.2s over inner content.
        // Pull slowly in the observed outer gutter so a nested carousel cannot win it.
        let pullStart = home.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.15))
        let pullEnd = home.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.80))
        XCTAssertTrue(home.frame.contains(pullStart.screenPoint))
        XCTAssertTrue(home.frame.contains(pullEnd.screenPoint))
        let gesture = XCTAttachment(
            string:
                "outer gutter native drag \(pullStart.screenPoint) -> \(pullEnd.screenPoint); slow")
        gesture.name = "Home deliberate native pull geometry"
        gesture.lifetime = .keepAlways
        add(gesture)
        pullStart.press(
            forDuration: 0.05, thenDragTo: pullEnd,
            withVelocity: .slow, thenHoldForDuration: 0.2)
        // Poll only the existing read-only diagnostic control. Never resend the
        // gesture, mutate the remote actor, or invoke refresh through fixture code.
        for _ in 0..<3 {
            tapNativeChrome(read, in: app)
            if remoteReads() > before { break }
        }
        let after = remoteReads()
        let attachment = XCTAttachment(
            string: "remote reads before \(before), after \(after); "
                + "card \(media.value as? String ?? "")")
        attachment.name = "Home refresh actual read and rendered card"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture("Home after the single refresh gesture and bounded counter reads", in: app)
        XCTAssertGreaterThan(after, before, "The Home gesture must actually read remote activity")
        XCTAssertTrue((media.value as? String ?? "").contains("Remote Fixture Track 1"))
    }

    @objc func testRemoteContinueListeningMetadataGuideAndPlaybackIsolation() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, compactFixtureControls: true, favoritesCatalog: true,
                remoteListening: true))
        try startSyntheticChromePlayback(app)
        selectTab("Home", in: app)
        let identity = app.staticTexts["fixture-playback-identity"].label
        let media = app.buttons["Continue listening instructions"]
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        let value = media.value as? String ?? ""
        for text in [
            "Remote Fixture Track 0", "Remote Fixture Artist", "Remote Fixture Album", "1:30",
            "3:00",
        ] {
            XCTAssertTrue(value.contains(text), value)
        }
        media.tap()
        XCTAssertTrue(app.staticTexts["Continue listening here"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["fixture-playback-identity"].label, identity)
        media.tap()
        let suppress = app.switches["Don’t show this guide again"].firstMatch
        XCTAssertTrue(suppress.waitForExistence(timeout: 5))
        XCTAssertEqual(suppress.value as? String, "0")
        suppress.switches.firstMatch.tap()
        let suppressed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: suppress)
        XCTAssertEqual(XCTWaiter.wait(for: [suppressed], timeout: 5), .completed)
        app.buttons["Done"].firstMatch.tap()
        media.tap()
        XCTAssertTrue(app.buttons["Handoff Help"].waitForExistence(timeout: 5))
        app.buttons["Handoff Help"].tap()
        XCTAssertTrue(app.staticTexts["Continue listening here"].waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertEqual(app.staticTexts["fixture-playback-identity"].label, identity)
        capture("Remote card metadata artwork and half-progress ring", in: app)
    }

    @objc func testRemoteContinueListeningCardDismissRefreshAndFixedHeadingNativeSwipe() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, compactFixtureControls: true, favoritesCatalog: true,
                remoteListening: true))
        try startSyntheticChromePlayback(app)
        selectTab("Home", in: app)
        let card = app.descendants(matching: .any)["continue-listening-remote-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let before = app.staticTexts["fixture-playback-identity"].label
        XCTAssertFalse(app.buttons["continue-listening-dismiss"].exists)
        card.press(forDuration: 1)
        let dismissMenuItem = app.buttons["Dismiss"].firstMatch
        XCTAssertTrue(dismissMenuItem.waitForExistence(timeout: 5))
        dismissMenuItem.tap()
        XCTAssertFalse(card.exists)
        chromeScroll(app, "home").swipeDown()
        XCTAssertFalse(card.exists)
        selectTab("Library", in: app)
        selectTab("Home", in: app)
        XCTAssertFalse(card.exists)
        openAlphabetFixtureControls(app)
        tapVisible(app.buttons["Next remote fixture track"], in: app)
        XCTAssertTrue(app.staticTexts["fixture-remote-generation"].waitForExistence(timeout: 5))
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Remote generation 1"),
            object: app.staticTexts["fixture-remote-generation"])
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 5), .completed)
        closeAlphabetFixtureControls(app)
        chromeScroll(app, "home").swipeDown()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let heading = app.staticTexts["continue-listening-heading"]
        XCTAssertTrue(heading.exists)
        let headingX = heading.frame.minX
        let partialStart = card.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        partialStart.press(
            forDuration: 0.05,
            thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0)
        let nativeDismiss = app.buttons["Dismiss"].firstMatch
        XCTAssertTrue(nativeDismiss.waitForExistence(timeout: 5))
        XCTAssertEqual(heading.frame.minX, headingX, accuracy: 1, "Only the card should slide")
        nativeDismiss.tap()
        XCTAssertFalse(card.exists)
        XCTAssertEqual(app.staticTexts["fixture-playback-identity"].label, before)
        capture("Card-only native swipe keeps heading fixed and dismisses remote hint", in: app)
        advanceRemoteFixture(app, generation: 2)
        chromeScroll(app, "home").swipeDown()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).press(
            forDuration: 0.05,
            thenDragTo: card.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
            withVelocity: .fast, thenHoldForDuration: 0)
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: card)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        let carousel = app.scrollViews["fixture-favorites-carousel"]
        reveal(app.buttons["home-favorites"], in: app)
        reveal(carousel, in: app)
        let first = carousel.buttons.firstMatch
        XCTAssertTrue(first.exists && first.isHittable)
        let oldX = first.frame.minX
        carousel.swipeLeft()
        XCTAssertTrue(
            !first.exists || first.frame.minX < oldX - 1,
            "Horizontal shelf scrolling must remain native after row swipe dismissal")
        carousel.swipeRight()
        XCTAssertEqual(app.staticTexts["fixture-playback-identity"].label, before)
        capture("Full swipe keeps horizontal shelf interaction and playback", in: app)
    }

    private func advanceRemoteFixture(_ app: XCUIApplication, generation: Int) {
        openAlphabetFixtureControls(app)
        tapVisible(app.buttons["Next remote fixture track"], in: app)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Remote generation \(generation)"),
            object: app.staticTexts["fixture-remote-generation"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        closeAlphabetFixtureControls(app)
    }

    @objc func testContinueListeningLocalPlaybackNeverCreatesRemoteCard() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true))
        try startSyntheticChromePlayback(app)
        selectTab("Home", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["continue-listening-remote-card"].exists)
        XCTAssertTrue(app.buttons["Show Now Playing"].exists)
    }
}
