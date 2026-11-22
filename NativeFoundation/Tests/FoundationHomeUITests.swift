import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testNewTracksLoadsDateAddedAscendingSongsAndStartsPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true))
        selectTab("New", in: app)
        let missingTone = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Missing Tone")
        ).firstMatch
        XCTAssertTrue(
            missingTone.waitForExistence(timeout: 10),
            "Date Added feed includes the first synthetic provider-ordered song")
        let tone = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
        ).firstMatch
        XCTAssertTrue(tone.waitForExistence(timeout: 10))
        XCTAssertLessThan(missingTone.frame.minY, tone.frame.minY)
        tapVisibleCenter(tone, in: app)
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "state playing"),
            object: app.staticTexts["fixture-playback-identity"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        capture("New tracks in Date Added ascending order", in: app)
    }

    @objc func testSharedArtworkHomeToLibraryTrackAndOfflineNavigation() {
        let app = launch(.init(productionShell: true, artworkCache: true))
        func counts(_ expected: String) {
            app.buttons["Read artwork counts"].tap()
            let label = app.staticTexts["fixture-artwork-counts"]
            let predicate = NSPredicate(format: "label CONTAINS %@", expected)
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: label)],
                    timeout: 5), .completed)
        }
        XCTAssertTrue(app.buttons["Home"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Album"))
                .firstMatch.waitForExistence(timeout: 10))
        counts("Album 1")
        capture("Shared artwork Home album", in: app)
        app.buttons["Library"].firstMatch.tap()
        tapVisible(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Songs")).firstMatch,
            in: app)
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
                .firstMatch.waitForExistence(timeout: 5))
        counts("Album 1")
        capture("Shared artwork Library track no second album fetch", in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        app.buttons["Home"].firstMatch.tap()
        app.buttons["Library"].firstMatch.tap()
        counts("Album 1")
        capture("Shared artwork retained across offline navigation", in: app)
    }

    @objc func testHomeEmptyFavoritesHeadingStillOpensCompleteFavorites() {
        let app = launch(
            .init(productionShell: true, favoritesCatalog: true, emptyFavoritePreview: true))
        selectTab("Home", in: app)
        let heading = app.buttons["home-favorites"]
        reveal(heading, in: app)
        tapVisible(heading, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["favorites-catalog"].waitForExistence(timeout: 5))
    }

    @objc func testHomeMixedFavoritesHeadingOpensAllFavoriteCategories() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                compactFixtureControls: true, favoritesCatalog: true))
        selectTab("Home", in: app)
        let allFavorites = app.buttons["home-favorites"]
        reveal(allFavorites, in: app)
        XCTAssertTrue(app.buttons["View Fixture Album"].exists)
        XCTAssertTrue(app.buttons["View Fixture Playlist"].exists)
        XCTAssertFalse(app.buttons["home-all-favorites"].exists)
        tapVisibleCenter(allFavorites, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["favorites-catalog"].waitForExistence(timeout: 5))
        let playlist = app.buttons["View Fixture Playlist"].firstMatch
        reveal(playlist, in: app)
        tapVisibleCenter(playlist, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["collection-detail-playlist-playlist"]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertTrue(app.buttons["Unfavorite"].exists)
    }

    @objc func testFavoritesUsesLibraryCardsAndRowsAndKeepsSongPlaybackIdentity() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, compactFixtureControls: true, favoritesCatalog: true))
        selectTab("Library", in: app)
        tapVisibleCenter(app.buttons["Favorites"], in: app)
        let catalog = app.descendants(matching: .any)["favorites-catalog"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        for (kind, label) in [
            ("track", "Fixture Tone"), ("album", "View Fixture Album"),
            ("artist", "Fixture Artist"), ("playlist", "View Fixture Playlist"),
        ] {
            let content = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", label)
            ).firstMatch
            reveal(content, in: app)
            XCTAssertTrue(content.isHittable)
            XCTAssertTrue(
                app.descendants(matching: .any)["favorites-section-" + kind].firstMatch.exists)
        }
        let playlistHeading = catalog.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Playlists")
        ).firstMatch
        XCTAssertTrue(playlistHeading.waitForExistence(timeout: 5))
        tapVisibleCenter(playlistHeading, in: app)
        XCTAssertTrue(app.navigationBars["Favorite Playlists"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Load more"].exists)
        let finalPlaylist = app.buttons["View Fixture Playlist 7"].firstMatch
        reveal(finalPlaylist, in: app)
        XCTAssertTrue(finalPlaylist.isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        // Return to the first shelf before looking for its lazy header.
        for _ in 0..<3 { app.swipeDown() }
        let songsHeading = catalog.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Songs")
        ).firstMatch
        XCTAssertTrue(songsHeading.waitForExistence(timeout: 5))
        tapVisibleCenter(songsHeading, in: app)
        XCTAssertTrue(app.navigationBars["Favorite Songs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Load more"].exists)
        let finalSong = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone 7")
        ).firstMatch
        reveal(finalSong, in: app)
        XCTAssertTrue(finalSong.isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        capture(
            "Four independently paged favorite shelves and complete Songs destination", in: app)
        let album = app.buttons["View Fixture Album"].firstMatch
        for _ in 0..<6 {
            if album.exists && album.isHittable { break }
            app.swipeDown()
        }
        tapVisibleCenter(album, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["collection-detail-album-album"]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertTrue(app.buttons["Unfavorite"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        let song = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
        ).firstMatch
        tapVisibleCenter(song, in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@", "item tone;", "state playing"),
            evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        XCTAssertTrue(app.buttons["Show Now Playing"].exists)
        capture("Favorites grouped song row starts its original canonical track", in: app)
    }

    @objc func testHomeIdleEndPreserverDoesNotFollowLateContentOrOverrideUpwardBrowsing() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, colorScheme: "dark", compactFixtureControls: true,
                homeScrollBoundary: true, homeNativeViewportDiagnostic: true, heldHomeGenres: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let player = app.buttons["Show Now Playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        assertMiniPlayerValue("Playing", in: player)
        if !app.tabBars.buttons["Home"].exists {
            tapNativeChrome(app.tabBars.buttons["Library"], in: app)
        }
        selectTab("Home", in: app)
        let scroll = app.scrollViews["foundation-home-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeUp()
        scroll.swipeUp()
        if app.buttons["foundation-mini-player-minimized"].exists {
            tapNativeChrome(app.tabBars.buttons["Home"], in: app)
        }
        XCTAssertTrue(app.buttons["foundation-mini-player-normal"].waitForExistence(timeout: 5))
        captureHomeBoundary("Held genre index at old visible end", in: app)
        let clearance = app.staticTexts["foundation-home-chrome-clearance"]
        let bound = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "nativeAtEnd=true"),
            object: clearance)
        XCTAssertEqual(XCTWaiter.wait(for: [bound], timeout: 5), .completed)
        let before = clearance.value as? String ?? ""
        let height = homeBoundaryNumber("naturalHeight", in: before)
        let oldHeightToken = "naturalHeight=\(height)"
        let stableHeight = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT(value CONTAINS %@)", oldHeightToken),
            object: clearance)
        stableHeight.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [stableHeight], timeout: 1), .completed)
        let probe = app.staticTexts["foundation-home-scroll-boundary"]
        let beforeOffset = homeBoundaryOffset(probe.value as? String ?? "")
        openAlphabetFixtureControls(app)
        tapVisible(app.buttons["Release Home genres"], in: app)
        closeAlphabetFixtureControls(app)
        let published = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "NOT(value CONTAINS %@)", oldHeightToken),
            object: clearance)
        XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 5), .completed)
        captureHomeBoundary("Independent late Home genre publication", in: app)
        let after = clearance.value as? String ?? ""
        XCTAssertGreaterThan(homeBoundaryNumber("naturalHeight", in: after), height + 100)
        XCTAssertEqual(homeBoundaryOffset(probe.value as? String ?? ""), beforeOffset, accuracy: 1)
        XCTAssertTrue(after.contains("nativeAtEnd=false"))
        XCTAssertTrue(app.buttons["foundation-mini-player-normal"].exists)

        scroll.swipeUp(velocity: .slow)
        let beforeUp = homeBoundaryOffset(probe.value as? String ?? "")
        scroll.swipeDown(velocity: .slow)
        captureHomeBoundary("Deliberate upward reading after publication", in: app)
        XCTAssertLessThan(homeBoundaryOffset(probe.value as? String ?? ""), beforeUp - 1)
        XCTAssertTrue((clearance.value as? String ?? "").contains("nativeAtEnd=false"))
        let noFollow = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "nativeAtEnd=true"),
            object: clearance)
        noFollow.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noFollow], timeout: 1), .completed)
        // A new native end is reached again only through a real user scroll.
        for _ in 0..<5 { scroll.swipeUp() }
        captureHomeBoundary("New natural end reached explicitly", in: app)
        let rebound = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "nativeAtEnd=true"),
            object: clearance)
        XCTAssertEqual(XCTWaiter.wait(for: [rebound], timeout: 5), .completed)
        assertFinalHomeCardClearsPlayer(player, in: app)
        let newEndOffset = homeBoundaryOffset(probe.value as? String ?? "")
        scroll.swipeDown(velocity: .slow)
        captureHomeBoundary("Reading away from the new native end", in: app)
        XCTAssertLessThan(homeBoundaryOffset(probe.value as? String ?? ""), newEndOffset - 100)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(
            forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -50)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
        let middleOffset = homeBoundaryOffset(probe.value as? String ?? "")
        XCTAssertLessThan(middleOffset, newEndOffset - 100)
        if app.buttons["foundation-mini-player-minimized"].exists {
            tapNativeChrome(app.tabBars.buttons["Home"], in: app)
        }
        captureHomeBoundary("Native chrome resize while reading the middle", in: app)
        XCTAssertEqual(homeBoundaryOffset(probe.value as? String ?? ""), middleOffset, accuracy: 1)
        // Binding storage alone is not an acceptance surrogate: the physical
        // viewport must remain at the user's reading position through resizing.
    }

    @objc func testHomeHardFlingReboundsKeepFinalShelfReachable() {
        continueAfterFailure = false
        // Opt-in diagnostic for a runtime that automatically expands its bar on rebound.
        // The retained 27.0 simulator overshoots and rebounds with its bar minimized.
        let requiresAutomaticExpansion =
            ProcessInfo.processInfo.environment["VELACANTO_REQUIRE_REBOUND_EXPANSION"] == "1"
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, colorScheme: "dark", compactFixtureControls: true,
                homeScrollBoundary: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let player = app.buttons["Show Now Playing"]
        XCTAssertTrue(player.waitForExistence(timeout: 5))
        if !app.tabBars.buttons["Home"].exists {
            tapNativeChrome(app.tabBars.buttons["Library"], in: app)
        }
        selectTab("Home", in: app)
        let scroll = app.scrollViews["foundation-home-scroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scrollHomeToFinalShelf(scroll, in: app)

        for iteration in 0..<3 {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            start.press(
                forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 100)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            let decisions = app.staticTexts["foundation-home-scroll-phases"]
            let priorGesture = homeTraceGesture(decisions.value as? String ?? "")
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).press(
                forDuration: 0.05,
                thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)),
                withVelocity: .fast, thenHoldForDuration: 0)
            captureHomeBoundary("Hard fling rebound \(iteration + 1)", in: app)
            let trace = decisions.value as? String ?? ""
            let gesture = homeTraceGesture(trace)
            XCTAssertGreaterThan(gesture, priorGesture)
            let current = trace.split(separator: "\n").filter {
                $0.hasPrefix("gesture=\(gesture) ")
            }.joined(separator: "\n")
            XCTAssertTrue(current.contains("beyondEnd=true"), "The fling must overshoot the end")
            XCTAssertTrue(current.contains("interacting->decelerating"))
            XCTAssertTrue(current.contains("decelerating->idle"))
            let expanded = app.buttons["foundation-mini-player-normal"].exists
            let minimized = app.buttons["foundation-mini-player-minimized"].exists
            XCTAssertTrue(expanded != minimized, "The settled native placement must be unambiguous")
            if requiresAutomaticExpansion {
                XCTAssertTrue(
                    expanded,
                    "Rebound must automatically expand native chrome; never tap Home to simulate it"
                )
            }
            assertFinalHomeCardClearsPlayer(player, in: app)
            let stable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"),
                object: app.buttons[
                    expanded ? "foundation-mini-player-minimized" : "foundation-mini-player-normal"]
            )
            stable.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 1), .completed)
        }

        let probe = app.staticTexts["foundation-home-scroll-boundary"]
        let endOffset = homeBoundaryOffset(probe.value as? String ?? "")
        scroll.swipeDown(velocity: .slow)
        captureHomeBoundary("Deliberate upward browsing after hard flings", in: app)
        XCTAssertLessThan(homeBoundaryOffset(probe.value as? String ?? ""), endOffset - 1)
    }

    private func homeTraceGesture(_ trace: String) -> Int {
        trace.split(separator: "\n").compactMap {
            Int($0.split(separator: " ").first?.dropFirst("gesture=".count) ?? "")
        }.max() ?? 0
    }

    func homeBoundaryNumber(_ name: String, in value: String) -> Double {
        guard let field = value.split(separator: " ").first(where: { $0.hasPrefix(name + "=") }),
            let number = Double(field.dropFirst(name.count + 1)), number.isFinite
        else {
            XCTFail("Missing finite \(name) field in controlled Home geometry")
            return .nan
        }
        return number
    }

    private func homeBoundaryOffset(_ value: String) -> Double {
        guard let field = value.split(separator: " ").first, field.hasPrefix("offsetY="),
            let offset = Double(field.dropFirst("offsetY=".count))
        else {
            XCTFail("The synthetic Home geometry probe must publish its offsetY field")
            return .nan
        }
        return offset
    }

    func captureHomeBoundary(_ name: String, in app: XCUIApplication) {
        capture(name, in: app)
        let probe = app.staticTexts["foundation-home-scroll-boundary"]
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        let geometry = XCTAttachment(string: probe.value as? String ?? "Missing scroll geometry")
        geometry.name = name + " scroll geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let decisions = app.staticTexts["foundation-home-scroll-phases"]
        XCTAssertTrue(decisions.waitForExistence(timeout: 5))
        let trace = XCTAttachment(string: decisions.value as? String ?? "Missing scroll phases")
        trace.name = name + " native scroll phases"
        trace.lifetime = .keepAlways
        add(trace)
        let clearance = app.staticTexts["foundation-home-chrome-clearance"]
        XCTAssertTrue(clearance.waitForExistence(timeout: 5))
        let layout = XCTAttachment(string: clearance.value as? String ?? "Missing chrome geometry")
        layout.name = name + " measured chrome and reserve"
        layout.lifetime = .keepAlways
        add(layout)
    }

    func scrollHomeToFinalShelf(_ scroll: XCUIElement, in app: XCUIApplication) {
        let genre = app.buttons["home-shelf-Fixture Genre"]
        for _ in 0..<8 {
            scroll.swipeUp()
            if genre.exists && genre.isHittable {
                break
            }
        }
        XCTAssertTrue(genre.exists && genre.isHittable)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Final Home Album"))
                .firstMatch.waitForExistence(timeout: 5))
        // Finish scrolling after the final async shelf has actually published.
        scroll.swipeUp()
        scroll.swipeUp()
    }

    func assertFinalHomeCardClearsPlayer(
        _ player: XCUIElement, in app: XCUIApplication
    ) {
        let cards = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Final Home Album")
        ).allElementsBoundByIndex.filter { $0.exists && $0.frame.minY < app.frame.maxY }
        guard let last = cards.max(by: { $0.frame.maxY < $1.frame.maxY }) else {
            XCTFail("The final loaded Home shelf must contain a synthetic album card")
            return
        }
        let toggle = app.buttons["foundation-mini-playback-toggle"]
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(toggle.exists && tabBar.exists)
        let clearance = app.staticTexts["foundation-home-chrome-clearance"]
        XCTAssertTrue(clearance.waitForExistence(timeout: 5))
        let measured = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "measured=true"), object: clearance)
        XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 5), .completed)
        let evidence = clearance.value as? String ?? ""
        guard
            let field = evidence.split(separator: " ").first(where: {
                $0.hasPrefix("accessoryTop=")
            }), let accessoryTop = Double(field.dropFirst("accessoryTop=".count)),
            accessoryTop.isFinite
        else {
            XCTFail("The native accessory frame must be measured before asserting final clearance")
            return
        }
        let chromeTop = min(
            player.frame.minY, toggle.frame.minY, tabBar.frame.minY, CGFloat(accessoryTop))
        let geometry = XCTAttachment(
            string:
                "Final card: \(last.frame)\nOpen player: \(player.frame)"
                + "\nPlayback toggle: \(toggle.frame)\nTab bar: \(tabBar.frame)"
                + "\nExpanded player: \(app.buttons["foundation-mini-player-normal"].exists)"
                + "\nMinimized player: \(app.buttons["foundation-mini-player-minimized"].exists)"
                + "\nMeasured chrome: " + evidence)
        geometry.name = "Home final card and native mini-player bounds"
        geometry.lifetime = .keepAlways
        add(geometry)
        XCTAssertTrue(last.isHittable)
        XCTAssertLessThanOrEqual(
            last.frame.maxY, chromeTop,
            "The complete final card, including its subtitle, must clear native playback/tab controls"
        )
    }
}
