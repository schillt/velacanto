import XCTest

@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    private func launch(
        failOnce: Bool = false, account: Bool = false, delayedAuth: Bool = false,
        productionShell: Bool = false, largeText: Bool = false,
        canonicalDownloadState: String? = nil, artworkCache: Bool = false
    )
        -> XCUIApplication
    {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if productionShell { app.launchArguments.append("-fixtureProductionShell") }
        if artworkCache { app.launchArguments.append("-fixtureArtworkCache") }
        if let canonicalDownloadState {
            app.launchArguments += [
                "-fixtureCanonicalCollections", "-fixtureDownloadState", canonicalDownloadState,
            ]
        }
        if failOnce { app.launchArguments.append("-fixtureFailOnce") }
        if account { app.launchArguments.append("-fixtureAccount") }
        if delayedAuth { app.launchArguments.append("-fixtureDelayedAuth") }
        app.launchEnvironment["FOUNDATION_UI_RUN_ID"] = UUID().uuidString
        if largeText { app.launchEnvironment["FOUNDATION_UI_LARGE_TEXT"] = "1" }
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments.append("-fixtureCleanup")
            app.launch()
            XCTAssertTrue(app.staticTexts["Fixture cleanup complete"].waitForExistence(timeout: 10))
            app.terminate()
        }
        app.launch()
        let entry = account ? "Sign in" : "Queue fixture playlist"
        XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 10))
        if canonicalDownloadState != nil {
            XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        }
        return app
    }

    func testSharedArtworkHomeToLibraryTrackAndOfflineNavigation() {
        let app = launch(productionShell: true, artworkCache: true)
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

    func testSharedArtistPlaylistAndDistinctGenreArtworkSources() {
        let app = launch(productionShell: true, artworkCache: true)
        func counts(_ expected: String) {
            app.buttons["Read artwork counts"].tap()
            let label = app.staticTexts["fixture-artwork-counts"]
            let predicate = NSPredicate(format: "label CONTAINS %@", expected)
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: label)],
                    timeout: 5), .completed)
        }
        func tab(_ title: String) {
            let button = app.buttons[title].firstMatch
            if !button.exists {
                // Native scroll minimization leaves the current-tab bubble at the lower left.
                // Expand that visible system control, then require the named destination.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.95)).tap()
            }
            XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
            button.tap()
        }
        tab("Home")
        counts("Album 1")
        let genre = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Genre")
        ).firstMatch
        tab("New")
        for _ in 0..<12 {
            if genre.exists && genre.isHittable { break }
            scrollContent(in: app)
        }
        XCTAssertTrue(genre.exists && genre.isHittable)
        counts("Album 1")
        counts("Genre 0")
        capture("New genre representative reuses album without aliasing genre Primary", in: app)
        tab("Library")
        tapVisible(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Artists")).firstMatch,
            in: app)
        XCTAssertTrue(app.navigationBars["Artists"].waitForExistence(timeout: 5))
        counts("Artist 1")
        capture("Shared artist artwork", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playlists"))
                .firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        counts("Playlist 1")
        capture("Shared playlist artwork", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tab("Search")
        counts("Genre 1")
        capture("Search genre Primary shares its identity independently of New", in: app)
    }

    private func openDownloads(_ app: XCUIApplication) {
        tapVisible(app.buttons["Downloads"], in: app)
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertOfflineIconIsAccessible(in app: XCUIApplication) {
        let badge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Available offline")
        ).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Downloaded"].exists)
    }

    private func waitForSavedDownload(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Fixture download ready"].waitForExistence(timeout: 10))
    }

    private func chooseCollectionAction(_ title: String, in app: XCUIApplication) {
        app.buttons["More actions"].tap()
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private func openFixturePlaylist(_ app: XCUIApplication) {
        app.buttons["Playlists"].tap()
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
    }

    private func returnToFixtureRoot(_ app: XCUIApplication) {
        for _ in 0..<4 {
            if app.navigationBars["Download Test Library"].exists { return }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Download Test Library"].waitForExistence(timeout: 5))
    }

    private func openManagement(_ app: XCUIApplication) {
        let link = app.buttons["Downloaded Music"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        for step in 0..<24 {
            if element.exists && element.isHittable && tapCenterIsVisible(element, in: app) {
                break
            }
            scrollContent(in: app, upward: step < 12)
        }
        if !element.exists || !element.isHittable || !tapCenterIsVisible(element, in: app) {
            capture("Unreachable navigation target", in: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic unreachable navigation hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(element.exists && element.isHittable && tapCenterIsVisible(element, in: app))
        element.tap()
    }

    // XCTest can report a clipped offscreen link as hittable and tap the adjacent row.
    // Scroll the actual target's center into the viewport before using its native tap.
    private func tapCenterIsVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let scroll = [
            app.collectionViews.firstMatch, app.scrollViews.firstMatch, app.tables.firstMatch,
        ]
        .first { $0.exists }
        guard let scroll else { return true }
        return element.frame.midY > scroll.frame.minY + 48
            && element.frame.midY < scroll.frame.maxY - 24
    }

    private func scrollContent(in app: XCUIApplication, upward: Bool = true) {
        let scroll = [
            app.collectionViews.firstMatch, app.scrollViews.firstMatch, app.tables.firstMatch,
        ]
        .first { $0.exists && $0.frame.height > 0 }
        if let scroll {
            // The native header overlays part of the scroll frame. Move within its visible lower
            // portion, in small steps, so accessibility-sized rows cannot be skipped between probes.
            let start = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.85 : 0.55))
            let end = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.55 : 0.85))
            start.press(
                forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        } else if upward {
            app.swipeUp()
        } else {
            app.swipeDown()
        }
    }

    private func confirmRemoval(_ title: String, in app: XCUIApplication) {
        let sheetButton = app.sheets.buttons[title]
        if sheetButton.exists {
            sheetButton.tap()
        } else {
            let alertButton = app.alerts.buttons[title]
            if alertButton.exists {
                alertButton.tap()
            } else {
                // On iPad, a native confirmation dialog can be a popover rather than a sheet.
                let matches = app.buttons.matching(identifier: title)
                XCTAssertGreaterThan(matches.count, 0)
                matches.element(boundBy: matches.count - 1).tap()
            }
        }
    }

    private func enableCellular(_ app: XCUIApplication) {
        let toggle = app.switches["Use Cellular Data"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        let enabled = expectation(
            for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        wait(for: [enabled], timeout: 5)
    }

    private func fillSyntheticSignIn(_ app: XCUIApplication) {
        let address = app.textFields["Jellyfin HTTPS address"]
        address.tap()
        address.typeText("https://example.invalid")
        let username = app.textFields["Username"]
        username.tap()
        username.typeText("synthetic-ui")
        let password = app.secureTextFields["Password"]
        password.tap()
        password.typeText("synthetic-not-a-password")
        // Use the public native keyboard affordance when this keyboard exposes it.
        for title in ["Hide keyboard", "Hide Keyboard"] {
            let hideKeyboard = app.keyboards.buttons[title].firstMatch
            if hideKeyboard.exists && hideKeyboard.isHittable {
                hideKeyboard.tap()
                break
            }
        }
    }

    private struct CollectionPresentation: Equatable {
        let rowLabels: [String]
        let rowEnabled: [Bool]
        let rowValues: [String]
        let actionLabels: [String]
        let playEnabled: Bool
        let shuffleEnabled: Bool
    }

    private func openCanonicalCollection(
        _ kind: String, fromDownloads: Bool, in app: XCUIApplication
    ) {
        if fromDownloads {
            let downloads = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Downloads")
            ).firstMatch
            tapVisible(downloads, in: app)
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        }
        let category = kind == "album" ? "Albums" : "Playlists"
        let link =
            fromDownloads
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", category)).firstMatch
            : app.descendants(matching: .any).matching(
                identifier: "library-category-" + category.lowercased()
            ).firstMatch
        tapVisible(link, in: app)
        XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 5))
        let title = kind == "album" ? "Fixture Album" : "Fixture Playlist"
        let collection = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "View " + title, title)
        ).firstMatch
        tapVisible(collection, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["collection-detail-" + kind + "-" + kind]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].firstMatch.exists)
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertTrue(app.buttons["Shuffle"].exists)
    }

    private func canonicalPresentation(
        _ app: XCUIApplication, state: String, offline: Bool, captureName: String
    ) -> CollectionPresentation {
        let expectedTitles = ["Fixture Tone", "Fixture Missing Tone", "Fixture Tone"]
        var labels: [String] = []
        var enabled: [Bool] = []
        var actions: [String] = []
        var values: [String] = []
        let headerEnabled = !offline || state != "none"
        for title in ["Play", "Shuffle"] {
            let settled = expectation(
                for: NSPredicate(format: "enabled == %@", NSNumber(value: headerEnabled)),
                evaluatedWith: app.buttons[title])
            wait(for: [settled], timeout: 5)
        }
        let playEnabled = app.buttons["Play"].isEnabled
        let shuffleEnabled = app.buttons["Shuffle"].isEnabled
        capture(captureName + " header", in: app)
        for index in expectedTitles.indices {
            let row = app.buttons["collection-track-\(index)"]
            for _ in 0..<12 {
                if row.exists { break }
                scrollContent(in: app)
            }
            XCTAssertTrue(row.exists, "Known occurrence \(index) must remain in the collection")
            XCTAssertTrue(row.label.contains(expectedTitles[index]))
            let ready = state == "full" || (state == "partial" && index != 1)
            let playable = !offline || ready
            let settled = expectation(
                for: NSPredicate(format: "enabled == %@", NSNumber(value: playable)),
                evaluatedWith: row)
            wait(for: [settled], timeout: 5)
            if offline && !ready {
                XCTAssertTrue((row.value as? String ?? "").contains("unavailable offline"))
            }
            let action = app.buttons["collection-track-actions-\(index)"]
            XCTAssertTrue(action.exists)
            XCTAssertEqual(action.label, "Actions for " + expectedTitles[index])
            let badge = app.images["collection-track-download-\(index)"]
            if ready {
                XCTAssertTrue(badge.exists)
                XCTAssertEqual(badge.label, "Available offline")
                if badge.isHittable && action.isHittable {
                    XCTAssertLessThan(badge.frame.maxX, action.frame.midX)
                    XCTAssertEqual(badge.frame.midY, action.frame.midY, accuracy: 12)
                }
            } else {
                XCTAssertFalse(badge.exists)
            }
            labels.append(row.label)
            enabled.append(row.isEnabled)
            values.append(row.value as? String ?? "")
            actions.append(action.label)
        }
        for title in [
            "Play All", "Play All Songs", "Play Available Tracks", "Saved download",
            "2 of 3 available", "3 saved tracks", "Downloaded",
        ] {
            XCTAssertFalse(app.staticTexts[title].exists)
            XCTAssertFalse(app.buttons[title].exists)
        }
        capture(captureName, in: app)
        return CollectionPresentation(
            rowLabels: labels, rowEnabled: enabled, rowValues: values, actionLabels: actions,
            playEnabled: playEnabled, shuffleEnabled: shuffleEnabled)
    }

    private func verifyCanonicalEntryPoints(state: String, largeText: Bool = false) {
        let app = launch(
            productionShell: true, largeText: largeText, canonicalDownloadState: state)
        if largeText {
            XCTAssertEqual(
                app.staticTexts["fixture-dynamic-type-size"].label,
                "Synthetic Dynamic Type: accessibility3")
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        }
        app.buttons["Library"].firstMatch.tap()
        if largeText { capture("Accessibility-sized landscape Library navigation", in: app) }
        for offline in [false, true] {
            if offline {
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
            let status = app.descendants(matching: .any)["browsing-offline-status"]
            if offline {
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(
                    status.frame.maxY, app.buttons["Profile and settings"].firstMatch.frame.minY + 1
                )
            } else {
                XCTAssertFalse(status.exists)
            }
            for kind in ["playlist", "album"] {
                var baseline: CollectionPresentation?
                for downloadedEntry in [false, true] {
                    openCanonicalCollection(kind, fromDownloads: downloadedEntry, in: app)
                    let presentation = canonicalPresentation(
                        app, state: state, offline: offline,
                        captureName:
                            "Canonical \(kind) \(state) \(offline ? "offline" : "online") via \(downloadedEntry ? "Downloads" : "Library")"
                    )
                    if let baseline {
                        XCTAssertEqual(
                            presentation, baseline,
                            "Entry point must not change known occurrences or available actions")
                    } else {
                        baseline = presentation
                    }
                    XCTAssertEqual(presentation.playEnabled, !offline || state != "none")
                    XCTAssertEqual(presentation.shuffleEnabled, !offline || state != "none")
                    for _ in 0..<(downloadedEntry ? 3 : 2) {
                        app.navigationBars.buttons.firstMatch.tap()
                    }
                }
            }
        }
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        let status = app.descendants(matching: .any)["browsing-offline-status"]
        let online = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: status)
        wait(for: [online], timeout: 5)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.exists)
    }

    func testOfflineLandscapeHeaderAndInlineActionsRemainReachable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(productionShell: true, largeText: true, canonicalDownloadState: "full")
        app.buttons["Library"].firstMatch.tap()
        openCanonicalCollection("playlist", fromDownloads: false, in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browsing-offline-status"].exists)
        capture("Full-screen offline landscape canonical playlist header", in: app)
        XCTAssertTrue(app.buttons["More actions"].isHittable)
        app.buttons["More actions"].tap()
        XCTAssertTrue(app.buttons["Edit Playlist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit Playlist"].isEnabled)
        capture("Full-screen offline landscape reachable playlist actions", in: app)
        app.staticTexts["Canonical fixture ready"].tap()
        _ = canonicalPresentation(
            app, state: "full", offline: true,
            captureName: "Full-screen offline landscape canonical playlist rows")
        tapVisible(app.buttons["collection-track-actions-2"], in: app)
        let removalActions = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Downloads")
        ).allElementsBoundByIndex
        XCTAssertTrue(removalActions.contains(where: { $0.isHittable }))
        capture("Full-screen offline landscape reachable inline track actions", in: app)
    }

    func testPartialCollectionsHaveIdenticalLibraryAndDownloadsEntryPoints() {
        continueAfterFailure = false
        verifyCanonicalEntryPoints(state: "partial")
    }

    func testFullCollectionsHaveIdenticalEntryPointsAtAccessibilityTextSize() {
        continueAfterFailure = false
        verifyCanonicalEntryPoints(state: "full", largeText: true)
    }

    func testKnownUndownloadedCollectionsKeepAllOccurrencesAcrossEntryPoints() {
        continueAfterFailure = false
        let app = launch(productionShell: true, canonicalDownloadState: "none")
        app.buttons["Library"].firstMatch.tap()
        for kind in ["playlist", "album"] {
            var onlineBaseline: CollectionPresentation?
            var offlineBaseline: CollectionPresentation?
            for downloadedEntry in [false, true] {
                openCanonicalCollection(kind, fromDownloads: downloadedEntry, in: app)
                let online = canonicalPresentation(
                    app, state: "none", offline: false,
                    captureName:
                        "Known undownloaded \(kind) online via \(downloadedEntry ? "Downloads" : "Library")"
                )
                if let onlineBaseline { XCTAssertEqual(online, onlineBaseline) }
                onlineBaseline = online
                XCTAssertTrue(online.playEnabled)
                XCTAssertTrue(online.shuffleEnabled)
                // Zero-ready cards are intentionally filtered from offline catalog lists.
                // An already-open canonical detail must nevertheless retain all occurrences.
                for _ in 0..<4 { app.swipeDown() }
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
                let strip = app.descendants(matching: .any)["browsing-offline-status"]
                XCTAssertTrue(strip.waitForExistence(timeout: 5))
                XCTAssertTrue(
                    app.descendants(matching: .any)["collection-detail-" + kind + "-" + kind].exists
                )
                let offline = canonicalPresentation(
                    app, state: "none", offline: true,
                    captureName:
                        "Known undownloaded \(kind) preserved offline via \(downloadedEntry ? "Downloads" : "Library")"
                )
                if let offlineBaseline { XCTAssertEqual(offline, offlineBaseline) }
                offlineBaseline = offline
                XCTAssertFalse(offline.playEnabled)
                XCTAssertFalse(offline.shuffleEnabled)
                for _ in 0..<(downloadedEntry ? 3 : 2) {
                    app.navigationBars.buttons.firstMatch.tap()
                }
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
        }
    }

    func testLimitedOfflineProductionShellKeepsSettingsAndExplicitRetry() {
        continueAfterFailure = false
        let app = launch(productionShell: true)
        app.buttons["Queue fixture playlist"].tap()
        app.buttons["Library"].firstMatch.tap()
        let downloads = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Downloads")
        ).firstMatch
        tapVisible(downloads, in: app)
        waitForSavedDownload(app)
        capture("Downloads in Your Music production navigation", in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Downloads"].exists)
        XCTAssertFalse(app.buttons["Retry Online"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["browsing-offline-status"].waitForExistence(timeout: 5))
        capture("Offline preserves Downloads beneath the compact status strip", in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        let rotatedStatus = app.descendants(matching: .any)["browsing-offline-status"]
        XCTAssertTrue(rotatedStatus.exists)
        XCTAssertLessThanOrEqual(
            rotatedStatus.frame.maxY, app.navigationBars["Downloads"].frame.minY + 1)
        capture("Offline Downloads landscape keeps navigation below the status strip", in: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Retry Online"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Search"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Offline. Downloaded music is in Library."].exists)
        XCTAssertTrue(app.buttons["Open Library"].exists)
        let search = app.textFields["Search music"]
        if search.exists { XCTAssertFalse(search.isEnabled) }
        capture("Offline preserves Search and explains unavailable content", in: app)
        app.buttons["Profile and settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        capture("Offline Profile and Settings", in: app)
        XCTAssertFalse(app.staticTexts["Streaming Quality"].exists)
        XCTAssertFalse(app.staticTexts["Download Quality"].exists)
        XCTAssertTrue(app.staticTexts["Playback & Downloads"].exists)
        XCTAssertTrue(app.buttons["Playback & Download Settings"].exists)
        app.buttons["Downloaded Music"].tap()
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Retry Online"].waitForExistence(timeout: 5))
        app.buttons["Retry Online"].tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertTrue(search.isEnabled)
        XCTAssertTrue(app.staticTexts["Search"].firstMatch.exists)
        XCTAssertEqual(app.switches["Simulate unavailable network"].value as? String, "0")
    }

    func testOfflinePreservesAlbumHomeAndPlayerWithoutPlaybackBadges() {
        continueAfterFailure = false
        let app = launch(productionShell: true)
        app.buttons["Queue fixture playlist"].tap()
        app.buttons["Library"].firstMatch.tap()
        let downloads = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Downloads")
        ).firstMatch
        tapVisible(downloads, in: app)
        waitForSavedDownload(app)
        app.navigationBars.buttons.firstMatch.tap()
        let albums = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Albums")
        ).firstMatch
        tapVisible(albums, in: app)
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        let album = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Album")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        XCTAssertTrue(app.buttons["Shuffle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Album"].firstMatch.exists)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Album"].firstMatch.exists)
        XCTAssertFalse(app.navigationBars["Downloads"].exists)
        capture("Offline preserves the open album detail", in: app)
        app.buttons["Play"].tap()
        let backToAlbums = app.navigationBars.buttons["Albums"].firstMatch
        XCTAssertTrue(backToAlbums.waitForExistence(timeout: 5))
        backToAlbums.tap()
        capture("Offline album grid retained after playback", in: app)
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Home"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Retry Online"].exists)
        let resume = app.buttons["Open Now Playing"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertFalse(resume.label.contains("Available offline"))
        XCTAssertFalse((resume.value as? String ?? "").contains("Available offline"))
        XCTAssertFalse(resume.images["Available offline"].exists)
        capture("Offline Home retains Continue Listening without a download badge", in: app)
        resume.tap()
        XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
        capture("Now Playing excludes download badges", in: app)
        // The hierarchy may retain background catalog elements during the native zoom transition.
        XCTAssertTrue(
            app.images.matching(identifier: "Available offline")
                .allElementsBoundByIndex.allSatisfy { !$0.isHittable })
        XCTAssertFalse(app.staticTexts["Downloaded"].exists)
    }

    func testDownloadedPlaylistGridDetailAndSongsUseAccessibleIconBadges() {
        continueAfterFailure = false
        let app = launch(largeText: true)
        XCTAssertEqual(
            app.staticTexts["fixture-dynamic-type-size"].label,
            "Synthetic Dynamic Type: accessibility3")
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        waitForSavedDownload(app)
        tapVisible(app.buttons["Playlists"], in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        assertOfflineIconIsAccessible(in: app)
        capture("Accessibility-sized shared downloaded playlist grid", in: app)
        tapVisible(playlist, in: app)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Shuffle"].exists)
        capture("Accessibility-sized shared downloaded playlist hero", in: app)
        app.swipeUp()
        let track = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
        ).firstMatch
        for _ in 0..<5 {
            if track.exists && track.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(track.exists && track.isHittable)
        assertOfflineIconIsAccessible(in: app)
        capture("Accessibility-sized shared downloaded playlist song rows", in: app)
        returnToFixtureRoot(app)
        openDownloads(app)
        app.buttons["Songs"].tap()
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        assertOfflineIconIsAccessible(in: app)
        XCTAssertFalse(app.buttons["Play All"].exists)
        XCTAssertFalse(app.buttons["Play All Songs"].exists)
        capture("Accessibility-sized downloaded Songs icon badge", in: app)
    }

    func testAccessibilitySizedStorageRowsSupportSelectionAndCancel() {
        continueAfterFailure = false
        let app = launch(largeText: true)
        let size = app.staticTexts["fixture-dynamic-type-size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.label, "Synthetic Dynamic Type: accessibility3")
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        waitForSavedDownload(app)
        returnToFixtureRoot(app)
        openManagement(app)
        app.buttons["Edit"].tap()
        let song = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone,")
        ).firstMatch
        tapVisible(song, in: app)
        XCTAssertEqual(song.value as? String, "Selected")
        capture("Accessibility-sized Downloaded Music selection", in: app)
        tapVisible(app.buttons["Remove Selected"], in: app)
        XCTAssertTrue(app.alerts["Remove selected downloads?"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.buttons["Cancel"].isHittable)
        capture("Accessibility-sized playlist removal warning", in: app)
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(song.exists)
        XCTAssertEqual(song.value as? String, "Selected")
    }

    func testCancelledSyntheticSignInCannotOpenAccount() async {
        continueAfterFailure = false
        let app = launch(account: true, delayedAuth: true)
        fillSyntheticSignIn(app)
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
        let complete = app.buttons["Complete delayed authentication"]
        XCTAssertTrue(complete.exists && complete.isEnabled)
        complete.tap()
        XCTAssertTrue(
            app.staticTexts["Delayed authentication response delivered"]
                .waitForExistence(timeout: 5))
        let opened = expectation(
            for: NSPredicate(format: "exists == true"),
            evaluatedWith: app.buttons["Queue fixture playlist"])
        opened.isInverted = true
        await fulfillment(of: [opened], timeout: 4)
        XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
    }

    func testSyntheticSignInFailureRetryAndRepeatedSignOutWithLocalPlayback() async {
        continueAfterFailure = false
        let app = launch(account: true)
        fillSyntheticSignIn(app)
        app.buttons["Sign in"].tap()
        XCTAssertTrue(
            app.staticTexts["Sign in again or check your account permissions."]
                .waitForExistence(timeout: 10))
        app.buttons["Sign in"].tap()
        for cycle in 0..<2 {
            let queue = app.buttons["Queue fixture playlist"]
            XCTAssertTrue(queue.waitForExistence(timeout: 10))
            let savePassword = app.alerts["Save Password?"]
            if savePassword.waitForExistence(timeout: 2) {
                savePassword.buttons["Not Now"].tap()
                let dismissed = expectation(
                    for: NSPredicate(format: "exists == false"), evaluatedWith: savePassword)
                await fulfillment(of: [dismissed], timeout: 5)
            }
            let hittable = expectation(
                for: NSPredicate(format: "hittable == true"), evaluatedWith: queue)
            await fulfillment(of: [hittable], timeout: 5)
            queue.tap()
            openDownloads(app)
            XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5))
            enableCellular(app)
            waitForSavedDownload(app)
            openFixturePlaylist(app)
            app.buttons["Play"].tap()
            returnToFixtureRoot(app)
            let playing = expectation(
                for: NSPredicate(format: "label == %@", "Fixture playback: playing"),
                evaluatedWith: app.staticTexts["fixture-playback-state"])
            await fulfillment(of: [playing], timeout: 10)
            app.buttons["Sign out fixture"].tap()
            XCTAssertTrue(
                app.staticTexts["Fixture account cleanup complete"]
                    .waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Sign in"].exists)
            XCTAssertEqual(app.textFields["Username"].value as? String, "Username")
            XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
            if cycle == 0 {
                fillSyntheticSignIn(app)
                app.buttons["Sign in"].tap()
            }
        }
    }

    func testWaitingCancellationFailureRetryAndRemoval() {
        continueAfterFailure = false
        let app = launch(failOnce: true)
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        XCTAssertTrue(app.buttons["Songs"].exists)
        XCTAssertTrue(app.buttons["Albums"].exists)
        XCTAssertTrue(app.buttons["Playlists"].exists)
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5))
        openFixturePlaylist(app)
        chooseCollectionAction("Cancel Download", in: app)
        XCTAssertTrue(
            app.staticTexts["Cancelled — downloaded tracks are retained"]
                .waitForExistence(timeout: 5))
        enableCellular(app)
        chooseCollectionAction("Retry Download", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["fixture-download-progress"]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Download incomplete — retry when ready"].waitForExistence(timeout: 10))
        chooseCollectionAction("Retry Download", in: app)
        waitForSavedDownload(app)
        returnToFixtureRoot(app)
        openManagement(app)
        app.buttons["Edit"].tap()
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist,")
        ).firstMatch
        tapVisible(playlist, in: app)
        XCTAssertEqual(playlist.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Remove Selected"].isEnabled)
        tapVisible(app.buttons["Remove Selected"], in: app)
        confirmRemoval("Remove", in: app)
        returnToFixtureRoot(app)
        openDownloads(app)
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
    }

    func testRelaunchDuplicateTracksLocalPlaybackAndRemoveAll() async {
        continueAfterFailure = false
        let app = launch()
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        waitForSavedDownload(app)
        // Disallow the injected cellular path before cold process relaunch.
        app.switches["Use Cellular Data"].switches.firstMatch.tap()
        app.terminate()
        app.launch()
        openDownloads(app)
        waitForSavedDownload(app)
        capture("Downloads ready after cold relaunch", in: app)
        XCTAssertEqual(app.switches["Use Cellular Data"].value as? String, "0")
        app.buttons["Songs"].tap()
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
            ).count, 1)
        app.navigationBars.buttons.firstMatch.tap()
        openFixturePlaylist(app)
        let occurrences = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertTrue(occurrences.element(boundBy: 0).isEnabled)
        XCTAssertTrue(occurrences.element(boundBy: 1).isEnabled)
        capture("Downloaded playlist preserves duplicate occurrences", in: app)
        app.buttons["Play"].tap()
        returnToFixtureRoot(app)
        let state = app.staticTexts["fixture-playback-state"]
        let playing = expectation(
            for: NSPredicate(format: "label == %@", "Fixture playback: playing"),
            evaluatedWith: state)
        await fulfillment(of: [playing], timeout: 10)
        openManagement(app)
        tapVisible(app.buttons["Remove All Downloads"], in: app)
        confirmRemoval("Remove All Downloads", in: app)
        XCTAssertTrue(app.staticTexts["No downloaded songs."].waitForExistence(timeout: 10))
        capture("Downloaded Music empty after Remove All", in: app)
        returnToFixtureRoot(app)
        openDownloads(app)
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testSongRemovalWarnsForPlaylistAndStaysExcludedAfterRelaunch() {
        continueAfterFailure = false
        let app = launch()
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        waitForSavedDownload(app)
        returnToFixtureRoot(app)
        openManagement(app)
        app.buttons["Edit"].tap()
        capture("Downloaded Music Edit", in: app)
        let song = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone,")
        ).firstMatch
        tapVisible(song, in: app)
        XCTAssertEqual(song.value as? String, "Selected")
        XCTAssertTrue(app.buttons["Remove Selected"].isEnabled)
        tapVisible(app.buttons["Remove Selected"], in: app)
        let warning = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@", "Some selected songs belong to downloaded playlists.")
        )
        .firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        capture("Song removal warns about retained playlist", in: app)
        confirmRemoval("Cancel", in: app)
        XCTAssertTrue(song.exists)
        tapVisible(app.buttons["Remove Selected"], in: app)
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        confirmRemoval("Remove", in: app)
        XCTAssertTrue(app.staticTexts["No downloaded songs."].waitForExistence(timeout: 5))
        capture("Downloaded Music empty songs after removal", in: app)
        app.terminate()
        app.launch()
        openDownloads(app)
        openFixturePlaylist(app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        for index in 0..<2 {
            let occurrence = app.buttons["collection-track-\(index)"]
            XCTAssertTrue(occurrence.waitForExistence(timeout: 5))
            XCTAssertEqual(occurrence.label, "Fixture Tone")
            let unavailable = expectation(
                for: NSPredicate(
                    format: "enabled == false AND value CONTAINS %@", "unavailable offline"),
                evaluatedWith: occurrence)
            wait(for: [unavailable], timeout: 5)
        }
        XCTAssertFalse(app.buttons["Play"].isEnabled)
        capture("Removed song stays unavailable in saved playlist after relaunch", in: app)
        app.buttons["More actions"].tap()
        XCTAssertTrue(app.buttons["Remove Downloads"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Download Again"].exists)
    }
}
