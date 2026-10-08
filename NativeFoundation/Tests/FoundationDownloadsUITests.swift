import UIKit
import Vision
import XCTest

@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    private func launch(
        failOnce: Bool = false, account: Bool = false, delayedAuth: Bool = false,
        productionShell: Bool = false, largeText: Bool = false,
        canonicalDownloadState: String? = nil, artworkCache: Bool = false,
        membership: String? = nil, slowTransfer: Bool = false, longPlayback: Bool = false,
        unknownRelatedItems: Bool = false, missingArtwork: Bool = false,
        reducedAccessibilityEffects: Bool = false, signInFailure: String? = nil,
        colorScheme: String? = nil, pagedCatalog: Bool = false,
        catalogPageFailOnce: Bool = false, playlistPresentation: Bool = false,
        librarySelection: Bool = false, alphabetCatalog: Bool = false,
        alphabetFailOnce: Bool = false, delayedAlphabetCapability: Bool = false,
        heldArtistAlbums: Bool = false, partialGridRow: Bool = false
    )
        -> XCUIApplication
    {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if productionShell { app.launchArguments.append("-fixtureProductionShell") }
        if heldArtistAlbums { app.launchArguments.append("-fixtureHoldArtistAlbums") }
        if partialGridRow { app.launchArguments.append("-fixtureGridPartialRow") }
        if artworkCache { app.launchArguments.append("-fixtureArtworkCache") }
        if pagedCatalog {
            app.launchArguments += ["-fixturePagedCatalog", "-fixtureHoldInitialCatalog"]
        }
        if catalogPageFailOnce { app.launchArguments.append("-fixtureCatalogPageFailOnce") }
        if playlistPresentation { app.launchArguments.append("-fixturePlaylistPresentation") }
        if librarySelection { app.launchArguments.append("-fixtureLibrarySelection") }
        if alphabetCatalog {
            app.launchArguments += ["-fixtureAlphabetCatalog", "-fixtureHoldAlphabetA"]
        }
        if alphabetFailOnce { app.launchArguments.append("-fixtureAlphabetFailOnce") }
        if delayedAlphabetCapability {
            app.launchArguments.append("-fixtureDelayedAlphabetCapability")
        }
        if let canonicalDownloadState {
            app.launchArguments += [
                "-fixtureCanonicalCollections", "-fixtureDownloadState", canonicalDownloadState,
            ]
        }
        if failOnce { app.launchArguments.append("-fixtureFailOnce") }
        if slowTransfer { app.launchArguments.append("-fixtureSlowTransfer") }
        if longPlayback { app.launchArguments.append("-fixtureLongPlayback") }
        if unknownRelatedItems { app.launchArguments.append("-fixtureUnknownRelatedItems") }
        if missingArtwork { app.launchArguments.append("-fixtureMissingArtwork") }
        if reducedAccessibilityEffects {
            app.launchEnvironment["FOUNDATION_UI_REDUCE_MOTION"] = "1"
            app.launchEnvironment["FOUNDATION_UI_REDUCE_TRANSPARENCY"] = "1"
        }
        if let membership { app.launchArguments += ["-fixtureMembership", membership] }
        if account { app.launchArguments.append("-fixtureAccount") }
        if let signInFailure { app.launchArguments.append(signInFailure) }
        if let colorScheme { app.launchEnvironment["FOUNDATION_UI_COLOR_SCHEME"] = colorScheme }
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
        if membership != nil {
            XCTAssertTrue(app.staticTexts["Membership fixture ready"].waitForExistence(timeout: 20))
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
        func tab(_ title: String) { selectTab(title, in: app) }
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

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let button = app.tabBars.buttons[title].firstMatch
        if !button.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.14, dy: 0.95)).tap()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    /// Native bars are intentionally outside the scrolling content viewport.
    private func tapNativeChrome(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        XCTAssertTrue(app.frame.contains(center))
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertFalse(keyboard.frame.contains(center)) }
        element.tap()
    }

    private func tapVisible(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) {
        reveal(element, in: app, context: context)
        element.tap()
    }

    private func reveal(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) {
        let root = context ?? app
        for step in 0..<32 {
            if element.exists && element.frame.width > 0 && element.frame.height > 0
                && tapCenterIsVisible(element, in: app, context: context) && element.isHittable
            {
                break
            }
            let scroll = [
                root.collectionViews.firstMatch, root.scrollViews.firstMatch,
                root.tables.firstMatch,
            ]
            .first { $0.exists }
            let viewport = scroll.map { uncoveredViewport($0, in: app, context: context) }
            let upward =
                element.exists && element.frame.height > 0 && viewport != nil
                ? element.frame.midY >= viewport!.midY : step < 24
            scrollContent(in: app, upward: upward, context: context)
        }
        if !element.exists || element.frame.width <= 0 || element.frame.height <= 0
            || !tapCenterIsVisible(element, in: app, context: context) || !element.isHittable
        {
            capture("Unreachable navigation target", in: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic unreachable navigation hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(
            element.exists && element.frame.width > 0 && element.frame.height > 0
                && tapCenterIsVisible(element, in: app, context: context) && element.isHittable)
    }

    // XCTest can report a clipped offscreen link as hittable and tap the adjacent row.
    // Scroll the actual target's center into the viewport before using its native tap.
    private func tapCenterIsVisible(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) -> Bool {
        let root = context ?? app
        let scroll = [
            root.collectionViews.firstMatch, root.scrollViews.firstMatch, root.tables.firstMatch,
        ]
        .first { $0.exists }
        guard let scroll else { return true }
        let viewport = uncoveredViewport(scroll, in: app, context: context)
        return viewport.height > 20
            && viewport.contains(
                CGPoint(x: element.frame.midX, y: element.frame.midY))
    }

    /// Reported scroll frames include native bars; gestures must start in actual content.
    private func uncoveredViewport(
        _ scroll: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) -> CGRect {
        let root = context ?? app
        let original = scroll.frame.intersection(app.frame)
        var top = original.minY
        var bottom = original.maxY
        for bar in root.navigationBars.allElementsBoundByIndex {
            let frame = bar.frame
            if frame.intersects(original), frame.maxY < original.maxY { top = max(top, frame.maxY) }
        }
        let profile = root.descendants(matching: .any)["Profile and settings"].firstMatch
        if profile.exists && profile.frame.height > 0 && profile.frame.intersects(original)
            && profile.frame.minY < original.midY && profile.isHittable
        {
            top = max(top, profile.frame.maxY + 12)
        }
        let search = root.textFields["Search music"]
        if search.exists && search.frame.height > 0 && search.frame.intersects(original)
            && search.frame.minY < original.midY && search.isHittable
        {
            top = max(top, search.frame.maxY + 8)
        }
        let tabBar = root.tabBars.firstMatch
        if tabBar.exists && tabBar.frame.intersects(original) {
            bottom = min(bottom, tabBar.frame.minY)
        }
        let miniPlayer = root.buttons["Show Now Playing"]
        if miniPlayer.exists && miniPlayer.frame.height > 0 && miniPlayer.frame.intersects(original)
            && miniPlayer.frame.minY > original.midY && miniPlayer.isHittable
        {
            bottom = min(bottom, miniPlayer.frame.minY)
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists && keyboard.frame.intersects(original) {
            bottom = min(bottom, keyboard.frame.minY)
        }
        let height = max(0, bottom - top)
        let margin = min(12, height * 0.05)
        return CGRect(
            x: original.minX, y: top + margin, width: original.width,
            height: max(0, height - 2 * margin))
    }

    private func scrollContent(
        in app: XCUIApplication, upward: Bool = true, context: XCUIElement? = nil
    ) {
        let root = context ?? app
        let scroll = [
            root.collectionViews.firstMatch, root.scrollViews.firstMatch, root.tables.firstMatch,
        ]
        .first { $0.exists && $0.frame.height > 0 }
        if let scroll {
            let viewport = uncoveredViewport(scroll, in: app, context: context)
            guard viewport.height > 20 else { return }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(
                    dx: viewport.midX - app.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.8 : 0.2) - app.frame.minY))
            let end = origin.withOffset(
                CGVector(
                    dx: viewport.midX - app.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.2 : 0.8) - app.frame.minY))
            start.press(
                forDuration: 0.1, thenDragTo: end, withVelocity: .slow,
                thenHoldForDuration: 0.2)
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
        tapVisible(address, in: app)
        address.typeText("https://example.invalid")
        let username = app.textFields["Username"]
        let next = app.keyboards.firstMatch.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "next")
        ).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5) && next.isHittable)
        next.tap()
        username.typeText("synthetic-ui")
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(next.exists && next.isHittable)
        next.tap()
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
        _ app: XCUIApplication, state: String, offline: Bool, captureName: String,
        context: XCUIElement? = nil
    ) -> CollectionPresentation {
        let root = context ?? app
        let expectedTitles = ["Fixture Tone", "Fixture Missing Tone", "Fixture Tone"]
        var labels: [String] = []
        var enabled: [Bool] = []
        var actions: [String] = []
        var values: [String] = []
        let headerEnabled = !offline || state != "none"
        for title in ["Play", "Shuffle"] {
            let settled = expectation(
                for: NSPredicate(format: "enabled == %@", NSNumber(value: headerEnabled)),
                evaluatedWith: root.buttons[title])
            wait(for: [settled], timeout: 5)
        }
        let playEnabled = root.buttons["Play"].isEnabled
        let shuffleEnabled = root.buttons["Shuffle"].isEnabled
        capture(captureName + " header", in: app)
        for index in expectedTitles.indices {
            let row = root.buttons["collection-track-\(index)"]
            for _ in 0..<12 {
                if row.exists { break }
                scrollContent(in: app, context: context)
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
            let action = root.buttons["collection-track-actions-\(index)"]
            XCTAssertTrue(action.exists)
            XCTAssertEqual(action.label, "Actions for " + expectedTitles[index])
            let badge = root.images["collection-track-download-\(index)"]
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
            XCTAssertFalse(root.buttons[title].exists)
        }
        capture(captureName, in: app)
        return CollectionPresentation(
            rowLabels: labels, rowEnabled: enabled, rowValues: values, actionLabels: actions,
            playEnabled: playEnabled, shuffleEnabled: shuffleEnabled)
    }

    private func verifyCanonicalEntryPoints(state: String, largeText: Bool = false) {
        let app = launch(
            productionShell: true, largeText: largeText, canonicalDownloadState: state)
        selectTab("Library", in: app)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.waitForExistence(timeout: 5))
        if largeText {
            XCTAssertEqual(
                app.staticTexts["fixture-dynamic-type-size"].label,
                "Synthetic Dynamic Type: accessibility3")
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
            let landscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { element, _ in
                    MainActor.assumeIsolated {
                        guard let app = element as? XCUIApplication else { return false }
                        return app.frame.width > app.frame.height
                    }
                }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
            XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.isSelected)
            XCTAssertTrue(app.staticTexts["Library"].firstMatch.exists)
            capture("Accessibility-sized landscape Library navigation", in: app)
        }
        for offline in [false, true] {
            if offline {
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
            let status = app.descendants(matching: .any)["browsing-offline-status"]
            if offline {
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(
                    status.frame.maxY,
                    app.buttons["Profile and settings"].firstMatch.frame.minY + 1
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
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Search"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Offline. Downloaded music is in Library."].exists)
        XCTAssertTrue(app.buttons["Open Library"].exists)
        let search = app.textFields["Search music"]
        if search.exists { XCTAssertTrue(search.isEnabled) }
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
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
        app.buttons["offline-retry"].tap()
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
        selectTab("Home", in: app)
        XCTAssertTrue(app.staticTexts["Home"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
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

    func testMobileSignInBrandingSecureFieldsAndServerErrorsLightAndDark() {
        continueAfterFailure = false
        for (scheme, failure) in [
            ("light", "-fixtureInvalidServer"), ("dark", "-fixtureUnreachableServer"),
        ] {
            let app = launch(account: true, signInFailure: failure, colorScheme: scheme)
            XCTAssertTrue(app.navigationBars["Velacanto"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["sign-in-introduction"].exists)
            XCTAssertFalse(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Foundation")
                ).firstMatch.exists)
            XCTAssertTrue(app.secureTextFields["Password"].exists)
            XCTAssertFalse(app.textFields["Password"].exists)
            XCTAssertFalse(app.buttons["Sign in"].isEnabled)
            capture("Mature mobile sign in " + scheme, in: app)
            fillSyntheticSignIn(app)
            XCTAssertTrue(app.buttons["Sign in"].isEnabled)
            let go = app.keyboards.firstMatch.buttons.matching(
                NSPredicate(format: "label ==[c] %@", "go")
            ).firstMatch
            XCTAssertTrue(go.waitForExistence(timeout: 5) && go.isHittable)
            go.tap()
            let error = app.descendants(matching: .any)["sign-in-error"]
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.staticTexts["The network request failed. Try again explicitly."].exists)
            XCTAssertTrue(app.buttons["Sign in"].isEnabled)
            XCTAssertEqual(app.textFields["Username"].value as? String, "synthetic-ui")
            XCTAssertTrue(app.secureTextFields["Password"].exists)
            XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
            capture("Actionable synthetic server error " + scheme, in: app)
            app.terminate()
        }
    }

    func testMobileSignInLargeTextKeyboardFocusAndInProgressCancellation() {
        continueAfterFailure = false
        let app = launch(account: true, delayedAuth: true, largeText: true, colorScheme: "dark")
        let address = app.textFields["Jellyfin HTTPS address"]
        tapVisible(address, in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        address.typeText("https://example.invalid")
        let next = app.keyboards.firstMatch.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "next")
        ).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5) && next.isHittable)
        next.tap()
        app.textFields["Username"].typeText("synthetic-ui")
        XCTAssertTrue(next.exists && next.isHittable)
        next.tap()
        app.secureTextFields["Password"].typeText("synthetic-not-a-password")
        capture("Large text sign in secure keyboard focus", in: app)
        let go = app.keyboards.firstMatch.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "go")
        ).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5) && go.isHittable)
        go.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["sign-in-progress"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Signing in…"].isEnabled)
        capture("Large text connecting state prevents duplicate submission", in: app)
        tapVisible(app.buttons["Cancel"], in: app)
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
        XCTAssertEqual(app.textFields["Username"].value as? String, "synthetic-ui")
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
        capture("Large text cancelled sign in preserves entered state", in: app)
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
            let savePassword = app.sheets["Save Password?"]
            let systemNotNow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[
                "Not Now"]
            if systemNotNow.waitForExistence(timeout: 5) { systemNotNow.tap() }
            if savePassword.waitForExistence(timeout: 5) {
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

    private func openSyntheticLibrarySelector(_ app: XCUIApplication) {
        tapNativeChrome(app.buttons["Profile and settings"], in: app)
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["FoundationSettingsAccount"], in: app)
        XCTAssertTrue(app.navigationBars["Server & Account"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["FoundationSettingsMusicLibraries"], in: app)
        XCTAssertTrue(app.navigationBars["Music Libraries"].waitForExistence(timeout: 5))
    }

    private func closeSyntheticLibrarySettings(_ app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Server & Account"].waitForExistence(timeout: 5))
        app.navigationBars["Server & Account"].buttons.firstMatch.tap()
        tapNativeChrome(app.navigationBars["Profile & Settings"].buttons["Done"], in: app)
    }

    private func selectSyntheticLibrary(_ name: String, in app: XCUIApplication) {
        let choice = app.buttons.matching(identifier: "FoundationMusicLibraryChoice").matching(
            NSPredicate(format: "label CONTAINS %@", name)
        ).firstMatch
        tapVisible(choice, in: app)
        let save = app.buttons["FoundationMusicLibrarySave"]
        XCTAssertTrue(save.isEnabled)
        tapNativeChrome(save, in: app)
        closeSyntheticLibrarySettings(app)
    }

    func testSyntheticLibrarySelectionCancelSaveIsolationRelaunchAndUnavailableFolder() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            librarySelection: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let original = identity.label
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        openSyntheticLibrarySelector(app)
        let cedar = app.buttons.matching(identifier: "FoundationMusicLibraryChoice").matching(
            NSPredicate(format: "label CONTAINS %@", "Fixture Cedar Library")
        ).firstMatch
        tapVisible(cedar, in: app)
        XCTAssertTrue(app.buttons["FoundationMusicLibrarySave"].isEnabled)
        tapNativeChrome(app.navigationBars["Music Libraries"].buttons["Cancel"], in: app)
        closeSyntheticLibrarySettings(app)
        XCTAssertEqual(identity.label, original)
        openSyntheticLibrarySelector(app)
        XCTAssertFalse(
            app.buttons["FoundationMusicLibrarySave"].isEnabled,
            "Cancel must leave the original All selection unchanged")
        selectSyntheticLibrary("Fixture Cedar Library", in: app)
        XCTAssertEqual(identity.label, original)
        selectTab("Home", in: app)
        let cedarAlbum = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Cedar Album")
        ).firstMatch
        XCTAssertTrue(cedarAlbum.waitForExistence(timeout: 10))
        capture("Selected synthetic Cedar catalog and uninterrupted mini player", in: app)
        openSyntheticLibrarySelector(app)
        selectSyntheticLibrary("Fixture Silver Library", in: app)
        let silverAlbum = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Silver Album")
        ).firstMatch
        XCTAssertTrue(silverAlbum.waitForExistence(timeout: 10))
        XCTAssertFalse(cedarAlbum.exists, "New selection must not expose the old cached shelf")
        XCTAssertEqual(identity.label, original)
        capture("Selected synthetic Silver catalog isolates cached Cedar shelf", in: app)
        openSyntheticLibrarySelector(app)
        selectSyntheticLibrary("Fixture Cedar Library", in: app)
        XCTAssertTrue(cedarAlbum.waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments.append("-fixtureStartOffline")
        app.launch()
        XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        selectTab("Home", in: app)
        XCTAssertTrue(cedarAlbum.waitForExistence(timeout: 10))
        openSyntheticLibrarySelector(app)
        XCTAssertTrue(
            app.staticTexts["Connect to choose a music library."].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["FoundationMusicLibrarySave"].isEnabled)
        XCTAssertFalse(app.buttons["FoundationMusicLibraryChoice"].exists)
        capture("Retained library choice offline with account wide download explanation", in: app)
        tapNativeChrome(app.navigationBars["Music Libraries"].buttons["Cancel"], in: app)
        closeSyntheticLibrarySettings(app)
        app.terminate()
        app.launchArguments.removeAll { $0 == "-fixtureStartOffline" }
        app.launchArguments.append("-fixtureSelectedLibraryUnavailable")
        app.launch()
        XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        openSyntheticLibrarySelector(app)
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label BEGINSWITH %@", "Your selected library is no longer available")
            )
            .firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["FoundationMusicLibrarySave"].isEnabled)
        capture(
            "Unavailable saved library requires explicit replacement without broad fallback",
            in: app)
    }

    func testProfileSettingsFullPageAccountStorageAndDiagnosticsPresentation() {
        continueAfterFailure = false
        let app = launch(productionShell: true, largeText: true, canonicalDownloadState: "full")
        selectTab("Library", in: app)
        let profile = app.buttons["Profile and settings"]
        XCTAssertTrue(profile.exists && profile.isHittable)
        profile.tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show Now Playing"].isHittable)
        capture("Full page accessible Profile and Settings", in: app)
        tapVisible(app.buttons["FoundationSettingsAccount"], in: app)
        XCTAssertTrue(app.navigationBars["Server & Account"].waitForExistence(timeout: 5))
        let accountForm = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@ AND (label CONTAINS %@ OR value CONTAINS %@)",
                "Provider", "Jellyfin", "Jellyfin")
        ).firstMatch
        let providerLeaf = app.staticTexts["Jellyfin"]
        if !accountForm.exists && !providerLeaf.exists {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic current account provider accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(accountForm.exists || providerLeaf.exists)
        XCTAssertFalse(app.secureTextFields.firstMatch.exists)
        XCTAssertFalse(app.textFields.firstMatch.exists)
        reveal(app.staticTexts["All music available to this Jellyfin account"], in: app)
        XCTAssertTrue(app.staticTexts["All music available to this Jellyfin account"].exists)
        capture("Account details explain library access without credentials", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        for label in [
            "Downloaded audio", "Download-owned artwork", "Download metadata & other files",
            "Cached artwork", "Cached catalog pages", "Artwork cache memory cost",
        ] {
            let row = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", label + ",")
            ).firstMatch
            reveal(row, in: app)
            XCTAssertTrue(app.staticTexts[label].exists)
        }
        capture("Separate account scoped storage and cache metrics", in: app)
        reveal(app.staticTexts["Diagnostics"], in: app)
        XCTAssertTrue(app.staticTexts["Diagnostics"].exists)
        XCTAssertFalse(app.staticTexts["Internal"].exists)
        XCTAssertTrue(app.buttons["Local diagnostic snapshot"].exists)
        capture("Settings diagnostics section and native Done", in: app)
        tapNativeChrome(app.buttons["Done"], in: app)
        XCTAssertTrue(app.buttons["library-category-albums"].waitForExistence(timeout: 5))
    }

    func testArtistLoadingShimmerKeepsGridGeometryUntilCanonicalCardsLoad() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", heldArtistAlbums: true)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-artists"], in: app)
        let artist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
        ).firstMatch
        tapVisible(artist, in: app)
        let skeleton = app.descendants(matching: .any)["loading-placeholder-albumGrid"]
        XCTAssertTrue(skeleton.waitForExistence(timeout: 5))
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        for _ in 0..<12 {
            if skeleton.frame.intersection(uncoveredViewport(scroll, in: app)).height > 100 {
                break
            }
            scrollContent(in: app)
        }
        XCTAssertGreaterThan(
            skeleton.frame.intersection(uncoveredViewport(scroll, in: app)).height, 100)
        let frame = skeleton.frame
        XCTAssertGreaterThan(frame.width, 140)
        XCTAssertGreaterThan(frame.height, 140)
        // Compare only the visible skeleton interior, excluding clocks, chrome and controls.
        let textureFrame = frame.intersection(uncoveredViewport(scroll, in: app))
            .insetBy(dx: 4, dy: 4)
        func skeletonTexture() -> Data? {
            guard let screen = XCUIScreen.main.screenshot().image.cgImage else { return nil }
            let scaleX = CGFloat(screen.width) / app.frame.width
            let scaleY = CGFloat(screen.height) / app.frame.height
            let pixels = CGRect(
                x: textureFrame.minX * scaleX, y: textureFrame.minY * scaleY,
                width: textureFrame.width * scaleX, height: textureFrame.height * scaleY
            ).integral
            guard let crop = screen.cropping(to: pixels) else { return nil }
            var bytes = Data(count: crop.width * crop.height * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard
                    let context = CGContext(
                        data: buffer.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(
                    crop,
                    in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height))
                )
                return true
            }
            return rendered ? bytes : nil
        }
        let firstTexture = skeletonTexture()
        XCTAssertNotNil(firstTexture)
        capture("Artist initial fixed album grid shimmer", in: app)
        let phaseStart = Date()
        let oneCycle = expectation(
            for: NSPredicate { _, _ in Date().timeIntervalSince(phaseStart) >= 1.5 },
            evaluatedWith: nil)
        wait(for: [oneCycle], timeout: 3)
        XCTAssertEqual(skeleton.frame.minY, frame.minY, accuracy: 1)
        XCTAssertEqual(skeleton.frame.width, frame.width, accuracy: 1)
        XCTAssertEqual(skeleton.frame.height, frame.height, accuracy: 1)
        let secondTexture = skeletonTexture()
        XCTAssertNotNil(secondTexture)
        XCTAssertNotEqual(
            firstTexture, secondTexture, "Default shimmer must change skeleton pixels")
        capture("Artist shimmer second phase same reserved geometry", in: app)
        tapNativeChrome(app.buttons["Release artist albums"], in: app)
        let gone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: skeleton)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.buttons["View Fixture Album"].waitForExistence(timeout: 5))
        capture("Artist loaded canonical grid replaces shimmer", in: app)
    }

    func testSearchLiquidGlassReducedEffectsLargeTextKeepsQueryAndFocus() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, largeText: true, canonicalDownloadState: "full",
            reducedAccessibilityEffects: true)
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["Search music"]
        field.typeText("Fixture")
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertEqual(
            app.staticTexts["fixture-accessibility-effects"].label,
            "Synthetic accessibility: reduced motion, reduced transparency")
        capture("Accessible opaque Search bubble active with large text", in: app)
        dismiss.tap()
        let hidden = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 5)
        XCTAssertEqual(field.value as? String, "Fixture")
        XCTAssertFalse(dismiss.exists)
        capture("Accessible Search dismissal preserves query without glass morph", in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
    }

    func testSearchKeyboardAutofocusCancelManualFocusAndReentryPreserveQuery() {
        continueAfterFailure = false
        let app = launch(productionShell: true, canonicalDownloadState: "full")
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.exists)
        field.typeText("Fixture")
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        capture("Active Search bar and separate 44 point Liquid Glass bubble", in: app)
        dismiss.tap()
        let hidden = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 5)
        XCTAssertEqual(field.value as? String, "Fixture")
        XCTAssertFalse(app.buttons["search-dismiss-keyboard"].exists)
        capture("Inactive Search bar after bubble merges query preserved", in: app)
        scrollContent(in: app)
        XCTAssertFalse(
            app.keyboards.firstMatch.exists, "Cancelled visit must not refocus on redraw")
        for _ in 0..<8 {
            if field.exists && field.isHittable { break }
            scrollContent(in: app, upward: false)
        }
        XCTAssertTrue(field.exists && field.isHittable)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
        app.buttons["search-dismiss-keyboard"].tap()
        selectTab("Library", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
        capture("Search native focus reentry keeps query", in: app)
    }

    func testLibraryCoverGridsCanonicalArtworkColumnsAndPartialLastRow() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launch(
                productionShell: true, largeText: largeText, canonicalDownloadState: "full",
                artworkCache: true, pagedCatalog: true, partialGridRow: true)
            selectTab("Library", in: app)
            for kind in ["album", "playlist"] {
                tapVisible(app.buttons["library-category-" + kind + "s"], in: app)
                XCTAssertTrue(
                    app.descendants(matching: .any)["library-index-" + kind]
                        .waitForExistence(timeout: 5))
                tapNativeChrome(app.buttons["Release initial catalog page"], in: app)
                let first = app.buttons["View Paged " + kind + " 0"]
                XCTAssertTrue(first.waitForExistence(timeout: 10))
                let firstFrame = first.frame
                let firstRowFrames = (0..<6).compactMap { index -> CGRect? in
                    let cover = app.buttons["View Paged " + kind + " " + String(index)]
                    guard cover.exists else { return nil }
                    let frame = cover.frame
                    return abs(frame.minY - firstFrame.minY) <= 2 ? frame : nil
                }
                XCTAssertFalse(firstRowFrames.isEmpty)
                if largeText {
                    XCTAssertGreaterThanOrEqual(firstFrame.width, 240)
                } else {
                    let second = app.buttons["View Paged " + kind + " 1"]
                    XCTAssertTrue(second.exists)
                    XCTAssertEqual(firstFrame.minY, second.frame.minY, accuracy: 2)
                    XCTAssertLessThan(firstFrame.maxX, second.frame.minX)
                }
                capture(
                    "Canonical Library cover grid " + kind
                        + (largeText ? " large text" : " regular columns"), in: app)
                let last = app.buttons["View Paged " + kind + " 6"]
                reveal(last, in: app)
                XCTAssertEqual(
                    last.frame.minX, firstRowFrames[6 % firstRowFrames.count].minX, accuracy: 2)
                XCTAssertFalse(app.buttons["View Paged " + kind + " 7"].exists)
                capture("Partial last cover grid row " + kind, in: app)
                // The known first cover is above this last row and may be absent from lazy AX.
                for _ in 0..<32 {
                    if first.exists && first.frame.width > 0 && first.frame.height > 0
                        && first.isHittable && tapCenterIsVisible(first, in: app)
                    {
                        break
                    }
                    scrollContent(in: app, upward: false)
                }
                XCTAssertTrue(
                    first.exists && first.frame.width > 0 && first.frame.height > 0
                        && first.isHittable && tapCenterIsVisible(first, in: app))
                tapVisible(first, in: app)
                let detail = app.descendants(matching: .any)[
                    "collection-detail-" + kind + "-paged-" + kind + "-0"]
                XCTAssertTrue(detail.waitForExistence(timeout: 5))
                capture("Library cover opens canonical " + kind + " destination", in: app)
                app.navigationBars.buttons.firstMatch.tap()
                XCTAssertTrue(first.waitForExistence(timeout: 5))
                tapVisible(first, in: app)
                XCTAssertTrue(detail.waitForExistence(timeout: 5))
                app.navigationBars.buttons.firstMatch.tap()
                app.navigationBars.buttons.firstMatch.tap()
            }
            tapNativeChrome(app.buttons["Read catalog counts"], in: app)
            let counts = app.staticTexts["fixture-catalog-counts"].label
            for kind in ["album", "playlist"] {
                XCTAssertTrue(counts.contains(kind + "-browse-0 1"), counts)
                XCTAssertTrue(counts.contains(kind + "-browse-6 1"), counts)
                XCTAssertFalse(counts.contains(kind + "-browse-12"), counts)
            }
        }
    }

    func testLibraryTypedListsPagedDedupRetryEndAndScopedSearch() {
        continueAfterFailure = false
        let app = launch(productionShell: true, pagedCatalog: true, catalogPageFailOnce: true)
        selectTab("Library", in: app)
        for (category, kind) in [
            ("Albums", "album"), ("Artists", "artist"), ("Songs", "track"),
            ("Playlists", "playlist"), ("Genres", "genre"),
        ] {
            tapVisible(app.buttons["library-category-" + category.lowercased()], in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["library-index-" + kind]
                    .waitForExistence(timeout: 5))
            let skeleton = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Loading")
            ).firstMatch
            XCTAssertTrue(skeleton.waitForExistence(timeout: 5))
            capture("Native typed Library index " + kind + " viewport skeleton", in: app)
            let release = app.buttons["Release initial catalog page"]
            XCTAssertTrue(release.exists && release.isHittable)
            release.tap()
            let last = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Paged " + kind + " 11")
            ).firstMatch
            for _ in 0..<12 {
                if app.buttons["Retry"].exists || last.exists { break }
                scrollContent(in: app)
            }
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
            capture("Typed Library page error retains first page " + kind, in: app)
            tapVisible(app.buttons["Retry"], in: app)
            reveal(last, in: app)
            XCTAssertTrue(last.exists)
            XCTAssertFalse(app.buttons["Load more"].exists)
            let duplicate = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Paged " + kind + " 5"))
            reveal(duplicate.firstMatch, in: app)
            XCTAssertEqual(
                duplicate.count, 1, "Overlapping provider page must deduplicate item identity")
            capture("Typed Library complete paged list " + kind, in: app)
            if kind == "album" {
                let field = app.searchFields["Search albums"]
                for _ in 0..<16 {
                    if field.exists && field.isHittable { break }
                    scrollContent(in: app, upward: false)
                }
                tapNativeChrome(field, in: app)
                field.typeText("Paged album 10")
                let result = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Paged album 10")
                ).firstMatch
                XCTAssertTrue(result.waitForExistence(timeout: 10))
                XCTAssertFalse(
                    app.buttons.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "Paged album 0")
                    ).firstMatch.exists)
                capture("Scoped Library search finds item beyond first browse page", in: app)
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
                field.typeText("slow")
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
                let clearedValue = field.value as? String ?? ""
                XCTAssertTrue(clearedValue.isEmpty || clearedValue == "Search albums")
                tapNativeChrome(app.navigationBars["Albums"].buttons["Close"], in: app)
                let keyboardDismissed = expectation(
                    for: NSPredicate(format: "exists == false"),
                    evaluatedWith: app.keyboards.firstMatch)
                wait(for: [keyboardDismissed], timeout: 5)
                reveal(last, in: app)
                XCTAssertTrue(
                    last.exists, "Clearing pending scoped query restores complete baseline")
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
        tapNativeChrome(app.buttons["Read catalog counts"], in: app)
        let counts = app.staticTexts["fixture-catalog-counts"].label
        for kind in ["album", "artist", "track", "playlist", "genre"] {
            XCTAssertTrue(counts.contains(kind + "-browse-6 2"), counts)
            XCTAssertFalse(counts.contains(kind + "-browse-12"), counts)
        }
        XCTAssertTrue(counts.contains("album-Paged album 10-0 1"), counts)
        capture("Bounded typed catalog requests after page end", in: app)
    }

    private func tapNativeAlphabet(_ letter: String, in app: XCUIApplication) {
        if letter == "All" {
            tapNativeChrome(app.buttons["library-alphabet-all-album"], in: app)
            return
        }
        let table = app.tables["library-index-album"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        // UIKit exposes one native Section index AX control, rather than letter children.
        let index = table.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Section index")
        ).firstMatch
        if !index.waitForExistence(timeout: 5) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic native alphabet index accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(index.exists && index.isHittable)
        XCTAssertGreaterThan(index.frame.width, 0)
        XCTAssertGreaterThan(index.frame.height, 0)
        let offline =
            app.switches["Simulate unavailable network"].switches.firstMatch.value as? String == "1"
        let titles =
            ["All"] + (offline ? ["#"] : [])
            + (65...90).map { String(UnicodeScalar($0)!) }
        guard let position = titles.firstIndex(of: letter) else {
            XCTFail("Requested letter must belong to the approved native index order")
            return
        }
        guard
            let fraction = nativeAlphabetGlyphPosition(
                position, titles: titles, image: index.screenshot().image)
        else { return }
        // UIKit receives the actual gesture; window/retry/count assertions prove its selection.
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fraction)).tap()
    }

    private func nativeAlphabetGlyphPosition(
        _ position: Int, titles: [String], image: UIImage
    ) -> CGFloat? {
        guard let pixels = image.cgImage, pixels.width > 0, pixels.height > 0 else {
            XCTFail("Native index screenshot must contain pixels")
            return nil
        }
        let width = pixels.width
        let height = pixels.height
        var rgba = Data(count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(
                pixels, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard rendered else {
            XCTFail("Native index screenshot must normalize to RGBA")
            return nil
        }
        func isBlue(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            let red = Int(rgba[offset])
            let green = Int(rgba[offset + 1])
            let blue = Int(rgba[offset + 2])
            return blue > 180 && blue - red > 100 && blue - green > 40
        }
        var runs: [ClosedRange<Int>] = []
        for y in 0..<height where (0..<width).contains(where: { isBlue($0, y) }) {
            if let last = runs.last, last.upperBound + 1 == y {
                runs[runs.count - 1] = last.lowerBound...y
            } else {
                runs.append(y...y)
            }
        }
        guard (3...64).contains(runs.count) else {
            XCTFail("Native index must have a bounded set of distinct rendered glyph rows")
            return nil
        }
        var anchors: [Int?] = []
        for run in runs {
            let bluePoints = run.flatMap { y in
                (0..<width).filter { isBlue($0, y) }.map { CGPoint(x: CGFloat($0), y: CGFloat(y)) }
            }
            guard let minX = bluePoints.map(\.x).min(),
                let maxX = bluePoints.map(\.x).max()
            else { return nil }
            let glyphWidth = maxX - minX + 1
            let glyphHeight = CGFloat(run.count)
            let aspect = glyphWidth / glyphHeight
            let fill = CGFloat(bluePoints.count) / (glyphWidth * glyphHeight)
            // A filled circular bullet represents omitted ordered titles, never a letter anchor.
            if (0.85...1.15).contains(aspect), fill > 0.65 {
                anchors.append(nil)
                continue
            }
            let cropRect = CGRect(
                x: 0, y: CGFloat(max(0, run.lowerBound - 6)), width: CGFloat(width),
                height: CGFloat(min(height - max(0, run.lowerBound - 6), run.count + 12)))
            guard let crop = pixels.cropping(to: cropRect) else { return nil }
            let ocrWidth = crop.width * 4 + 64
            let ocrHeight = crop.height * 4 + 64
            guard ocrWidth <= 2048, ocrHeight <= 2048,
                let ocrContext = CGContext(
                    data: nil, width: ocrWidth, height: ocrHeight, bitsPerComponent: 8,
                    bytesPerRow: ocrWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                XCTFail("Native glyph OCR preprocessing must fit its bounded pixel budget")
                return nil
            }
            ocrContext.setFillColor(CGColor(gray: 1, alpha: 1))
            ocrContext.fill(
                CGRect(x: 0, y: 0, width: CGFloat(ocrWidth), height: CGFloat(ocrHeight)))
            ocrContext.interpolationQuality = .high
            ocrContext.draw(
                crop,
                in: CGRect(
                    x: 32, y: 32, width: CGFloat(crop.width * 4), height: CGFloat(crop.height * 4)))
            guard let ocrImage = ocrContext.makeImage() else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = anchors.isEmpty ? .accurate : .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: ocrImage, options: [:]).perform([request])
            } catch {
                XCTFail("Public native index glyph recognition failed: \(error)")
                return nil
            }
            let recognized =
                request.results?.compactMap { $0.topCandidates(1).first?.string }
                ?? []
            let firstGlyphAll =
                anchors.isEmpty && recognized.count == 1
                && recognized[0].uppercased().range(of: "^A[IL][IL]$", options: .regularExpression)
                    != nil
            guard recognized.count == 1,
                let title = firstGlyphAll ? "All" : recognized.first,
                let anchor = titles.firstIndex(where: {
                    $0.caseInsensitiveCompare(title) == .orderedSame
                })
            else {
                XCTFail(
                    "Native index glyph must unambiguously match an approved title: \(recognized)")
                return nil
            }
            anchors.append(anchor)
        }
        guard anchors.first! == 0, anchors.last! == titles.count - 1 else {
            XCTFail("Rendered native index must expose its complete All-to-Z range")
            return nil
        }
        var covered: [Int] = []
        var targetY: CGFloat?
        for row in runs.indices {
            let center = CGFloat(runs[row].lowerBound + runs[row].upperBound) / 2
            if let anchor = anchors[row] {
                covered.append(anchor)
                if anchor == position { targetY = center }
            } else {
                guard row > 0, row + 1 < runs.count,
                    let before = anchors[row - 1], let after = anchors[row + 1],
                    after > before + 1
                else {
                    XCTFail("Native compressed bullet must have ordered recognized neighbors")
                    return nil
                }
                let hidden = Array((before + 1)..<after)
                covered.append(contentsOf: hidden)
                if let offset = hidden.firstIndex(of: position) {
                    let previous = CGFloat(runs[row - 1].lowerBound + runs[row - 1].upperBound) / 2
                    let next = CGFloat(runs[row + 1].lowerBound + runs[row + 1].upperBound) / 2
                    let top = (previous + center) / 2
                    let bottom = (center + next) / 2
                    targetY = top + (CGFloat(offset) + 0.5) / CGFloat(hidden.count) * (bottom - top)
                }
            }
        }
        guard covered == Array(titles.indices), let targetY else {
            XCTFail("Native rendered glyphs must account for each approved title exactly once")
            return nil
        }
        return targetY / CGFloat(height)
    }

    private func readAlphabetCounts(_ app: XCUIApplication) -> String {
        tapNativeChrome(app.buttons["Read catalog counts"], in: app)
        return app.staticTexts["fixture-catalog-counts"].label
    }

    func testNativeAlphabetServerWindowRelativePagingAllRestoreAndPlayback() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            alphabetCatalog: true, alphabetFailOnce: true)
        // Start a genuinely downloaded fixture occurrence through the unchanged Home row.
        selectTab("Home", in: app)
        let tone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
            .firstMatch
        tapVisible(tone, in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let original = identity.label
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-albums"], in: app)
        XCTAssertTrue(app.tables["library-index-album"].waitForExistence(timeout: 5))
        let a = app.buttons["View A Fixture album 0"]
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "F Fixture album 50"))
                .firstMatch.exists)
        let before = readAlphabetCounts(app)
        XCTAssertTrue(before.contains("album-all-0 1"))
        XCTAssertFalse(before.contains("album-all-50"))
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["Retry"], in: app)
        let f = app.buttons["View F Fixture album 50"]
        XCTAssertTrue(f.waitForExistence(timeout: 10))
        capture("Native alphabet F loads beyond initial server page", in: app)
        let g = app.buttons["View G Fixture album 119"]
        // This known later item is beyond the initial fifty-item server window.
        for _ in 0..<80 {
            if g.exists && g.frame.width > 0 && g.frame.height > 0
                && g.isHittable && tapCenterIsVisible(g, in: app)
            {
                break
            }
            scrollContent(in: app, upward: true)
        }
        XCTAssertTrue(
            g.exists && g.frame.width > 0 && g.frame.height > 0
                && g.isHittable && tapCenterIsVisible(g, in: app))
        XCTAssertTrue(g.exists)
        XCTAssertEqual(identity.label, original)
        let paged = readAlphabetCounts(app)
        XCTAssertTrue(paged.contains("album-F-0 2"))
        XCTAssertTrue(paged.contains("album-F-50 1"))
        XCTAssertFalse(paged.contains("album-all-50"))
        tapNativeAlphabet("All", in: app)
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        XCTAssertEqual(
            readAlphabetCounts(app), paged, "All restores retained browsing without a catalog fetch"
        )
        tapNativeAlphabet("A", in: app)
        var startedCounts = ""
        for _ in 0..<5 {
            startedCounts = readAlphabetCounts(app)
            if startedCounts.contains("album-A-0 1") { break }
        }
        XCTAssertTrue(
            startedCounts.contains("album-A-0 1"),
            "Cancellation coverage requires the held provider request to actually start")
        tapNativeAlphabet("G", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "G Fixture album 100"))
                .firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(a.exists, "Cancelled letter response cannot replace the latest window")
        XCTAssertTrue(
            readAlphabetCounts(app).contains("cancelled 1"),
            "Switching letters must actually cancel the held provider task")
        XCTAssertEqual(identity.label, original)
        capture("Rapid native alphabet selection retains latest server window", in: app)
        tapNativeAlphabet("All", in: app)
        tapVisible(a, in: app)
        let detail = app.descendants(matching: .any)["collection-detail-album-alphabet-album-0"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(
            forDuration: 0.1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(detail.exists, "Cancelled native back keeps alphabet-source collection open")
        XCTAssertEqual(identity.label, original)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tables["library-index-album"].waitForExistence(timeout: 5))
        XCTAssertEqual(identity.label, original)
        let field = app.searchFields["Search albums"]
        for _ in 0..<12 {
            if field.exists && field.isHittable { break }
            scrollContent(in: app, upward: false)
        }
        tapNativeChrome(field, in: app)
        field.typeText("G Fixture album 119")
        XCTAssertTrue(g.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.tables["library-index-album"].descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Section index")).firstMatch.exists,
            "Typed search must hide the native alphabet index")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 19))
        tapNativeChrome(app.navigationBars["Albums"].buttons["Close"], in: app)
        XCTAssertTrue(a.waitForExistence(timeout: 5))
        let beforeOffline = readAlphabetCounts(app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        tapNativeAlphabet("#", in: app)
        XCTAssertTrue(
            app.tables["library-index-album"].staticTexts["Other downloaded names"]
                .waitForExistence(timeout: 5))
        let numbered = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "# Fixture Album")
        ).firstMatch
        XCTAssertTrue(numbered.waitForExistence(timeout: 5))
        XCTAssertEqual(
            readAlphabetCounts(app), beforeOffline,
            "Offline alphabet operates only on complete known downloaded membership")
        capture("Native offline number index uses complete known collections", in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(f.waitForExistence(timeout: 10))
        XCTAssertEqual(identity.label, original)
        capture("Reconnect reuses server alphabet without playback replacement", in: app)
    }

    func testDelayedAlphabetCapabilityKeepsOpenCollectionSourceUntilBack() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full",
            alphabetCatalog: true, delayedAlphabetCapability: true)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-albums"], in: app)
        let row = app.buttons["View A Fixture album 0"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(app.tables["library-index-album"].exists)
        tapVisible(row, in: app)
        let detail = app.descendants(matching: .any)["collection-detail-album-alphabet-album-0"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5))
        tapNativeChrome(app.buttons["Release alphabet capability"], in: app)
        XCTAssertTrue(detail.exists)
        XCTAssertFalse(
            app.tables["library-index-album"].exists,
            "Capability completion must not replace the source renderer under an active destination"
        )
        capture("Delayed alphabet capability preserves canonical open collection", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.tables["library-index-album"].waitForExistence(timeout: 10))
        XCTAssertTrue(row.exists)
        capture("Native alphabet renderer adopts capability only after Back", in: app)
    }

    private func openNowPlaying(_ app: XCUIApplication) {
        let button = app.buttons["Show Now Playing"]
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
    }

    private func relatedSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["now-playing-related-sheet"]
    }

    private func assertRelatedDetent(_ detent: String, in app: XCUIApplication) {
        let sheet = relatedSheet(app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let settled = expectation(
            for: NSPredicate(format: "value == %@", detent), evaluatedWith: sheet)
        wait(for: [settled], timeout: 5)
    }

    private func dragRelatedSheet(_ app: XCUIApplication, verticalDistance: CGFloat) {
        let sheet = relatedSheet(app)
        XCTAssertTrue(sheet.exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(
                dx: sheet.frame.midX - app.frame.minX,
                dy: sheet.frame.minY + 12 - app.frame.minY))
        let startY = sheet.frame.minY + 12
        let endY = min(app.frame.maxY - 12, max(app.frame.minY + 12, startY + verticalDistance))
        let end = start.withOffset(CGVector(dx: 0, dy: endY - startY))
        start.press(
            forDuration: 0.1, thenDragTo: end, withVelocity: .slow,
            thenHoldForDuration: 0.2)
    }

    private func expandRelatedSheet(_ app: XCUIApplication) {
        dragRelatedSheet(app, verticalDistance: -app.frame.height * 0.4)
        assertRelatedDetent("large", in: app)
    }

    private func closeRelatedSheet(_ app: XCUIApplication) {
        XCTAssertFalse(relatedSheet(app).buttons["now-playing-related-close"].exists)
        dragRelatedSheet(app, verticalDistance: app.frame.height * 0.85)
        let gone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: relatedSheet(app))
        wait(for: [gone], timeout: 5)
    }

    private func dragExpandedPlayerArtwork(_ app: XCUIApplication, distance: CGFloat) {
        let artwork = app.descendants(matching: .any)["fixture-player-expanded-artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(artwork.frame.width, 0)
        XCTAssertGreaterThan(artwork.frame.height, 0)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(
                dx: artwork.frame.midX - app.frame.minX,
                dy: artwork.frame.midY - app.frame.minY))
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func dismissNowPlaying(_ app: XCUIApplication) {
        dragExpandedPlayerArtwork(app, distance: app.frame.height * 0.5)
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
    }

    private func artworkTransitionCount(_ key: String, in app: XCUIApplication) -> Int {
        let metrics = app.staticTexts["fixture-player-artwork-transition"]
        XCTAssertTrue(metrics.waitForExistence(timeout: 5))
        let fields = metrics.label.split(separator: ";").map {
            $0.trimmingCharacters(in: .whitespaces).split(separator: " ")
        }
        guard let field = fields.first(where: { $0.first == Substring(key) }),
            field.count == 2, let count = Int(field[1])
        else {
            XCTFail("Missing bounded artwork transition counter: " + key)
            return -1
        }
        return count
    }

    func testMiniPlayerCohesiveGlassMorphReverseAndCancelledDismissalKeepsPlayback() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", artworkCache: true,
            longPlayback: true)
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
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("morph", in: app), 1)
        XCTAssertEqual(artworkTransitionCount("fade", in: app), 0)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("glass", in: app), 1)
        capture("Cohesive glass mini bar expands into player surface", in: app)
        dragExpandedPlayerArtwork(app, distance: 28)
        XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertEqual(artwork.frame.minX, expandedFrame.minX, accuracy: 2)
        XCTAssertEqual(artwork.frame.minY, expandedFrame.minY, accuracy: 2)
        XCTAssertEqual(artwork.frame.width, expandedFrame.width, accuracy: 2)
        XCTAssertEqual(artwork.frame.height, expandedFrame.height, accuracy: 2)
        XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, originalIdentity)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("cancelled", in: app), 1)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("morph", in: app), 2)
        capture("Artwork native interactive cancellation restores expanded snapshot", in: app)
        dismissNowPlaying(app)
        XCTAssertTrue(app.descendants(matching: .any)["collection-detail-album-album"].exists)
        XCTAssertEqual(identity.label, originalIdentity)
        capture("Artwork reverse morph restores same canonical mini player", in: app)
        openNowPlaying(app)
        XCTAssertTrue(app.buttons["Pause"].exists)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("morph", in: app), 4)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("glass", in: app), 4)
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("completed", in: app), 3)
        XCTAssertEqual(artworkTransitionCount("fade", in: app), 0)
        dismissNowPlaying(app)
        XCTAssertEqual(identity.label, originalIdentity)
    }

    func testNowPlayingAlbumAndArtistUseCanonicalRoutesOnlineAndOffline() {
        verifyNowPlayingCanonicalRoutes(state: "full", offlineOnly: false)
    }

    func testNowPlayingPartialOfflineAlbumAndArtistPreserveKnownTracksAndPlayback() {
        verifyNowPlayingCanonicalRoutes(state: "partial", offlineOnly: true)
    }

    func testRelatedSheetCanonicalActionPresentersStayInPlayer() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            playlistPresentation: true)
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
        let baselineAdd = app.buttons["Add to Playlist"]
        XCTAssertTrue(baselineAdd.waitForExistence(timeout: 5))
        XCTAssertTrue(baselineAdd.isEnabled)
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
        let add = app.buttons["Add to Playlist"]
        XCTAssertTrue(add.waitForExistence(timeout: 5) && add.isHittable)
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
        let remove = app.buttons["Remove Downloads"]
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
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isHittable)
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

    func testNowPlayingRelatedSheetNativeDetentsCancellationAndScrollKeepPlayback() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "partial", longPlayback: true)
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

    func testRelatedSheetLargeTextReducedEffectsAndMissingArtworkKeepsCanonicalContent() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, largeText: true, canonicalDownloadState: "partial",
            longPlayback: true, missingArtwork: true, reducedAccessibilityEffects: true)
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

    func testLibraryCollectionNativeBackCancellationRestoresSourceAndPlayback() {
        continueAfterFailure = false
        let app = launch(productionShell: true, canonicalDownloadState: "full", longPlayback: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        for kind in ["album", "playlist"] {
            openCanonicalCollection(kind, fromDownloads: false, in: app)
            let detail = app.descendants(matching: .any)["collection-detail-" + kind + "-" + kind]
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
            start.press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertTrue(detail.exists, "Cancelled native back must retain collection detail")
            XCTAssertEqual(identity.label, originalIdentity)
            capture("Canonical " + kind + " native back cancelled", in: app)
            start.press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            let category = kind == "album" ? "Albums" : "Playlists"
            XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 5))
            XCTAssertFalse(detail.exists)
            XCTAssertEqual(identity.label, originalIdentity)
            capture("Canonical " + kind + " native back restores cover source", in: app)
            app.navigationBars.buttons.firstMatch.tap()
        }
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
        let app = launch(productionShell: true, canonicalDownloadState: state, longPlayback: true)
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

    func testNowPlayingUnknownAlbumAndArtistStayDisabledWithoutInterruptingPlayback() {
        continueAfterFailure = false
        let app = launch(productionShell: true, longPlayback: true, unknownRelatedItems: true)
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

    func testPartialTrackDiscoversAlbumArtistPlaylistAndOfflineSearchAfterColdLaunch() {
        assertPartialMembership(mode: "track")
    }

    func testPartialAlbumDiscoversUnownedPlaylistAndOfflineSearchAfterColdLaunch() {
        assertPartialMembership(mode: "album")
    }

    private func assertPartialMembership(mode: String) {
        continueAfterFailure = false
        let app = launch(productionShell: true, membership: mode)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        app.terminate()
        app.launchArguments.append("-fixtureStartOffline")
        app.launch()
        XCTAssertTrue(app.staticTexts["Membership fixture ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["browsing-offline-status"].waitForExistence(timeout: 5))
        app.buttons["Library"].firstMatch.tap()
        for (category, title) in [
            ("albums", "Fixture Album"), ("artists", "Fixture Artist"),
            ("playlists", "Fixture Playlist"),
        ] {
            tapVisible(app.buttons["library-category-" + category], in: app)
            let match = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                .firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            match.tap()
            if category == "artists" {
                let album = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Fixture Album")
                ).firstMatch
                tapVisible(album, in: app)
            }
            let playable = app.buttons["collection-track-0"]
            let missing = app.buttons["collection-track-1"]
            XCTAssertTrue(playable.waitForExistence(timeout: 5))
            XCTAssertTrue(playable.isEnabled)
            XCTAssertTrue(missing.exists)
            XCTAssertFalse(missing.isEnabled)
            XCTAssertTrue((missing.value as? String ?? "").contains("unavailable offline"))
            XCTAssertTrue(app.buttons["Play"].isEnabled)
            capture("Cold offline partial " + mode + " discovers " + category, in: app)
            app.navigationBars.buttons.firstMatch.tap()
            if category == "artists" { app.navigationBars.buttons.firstMatch.tap() }
            app.navigationBars.buttons.firstMatch.tap()
        }
        selectTab("Home", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["offline-notice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
        selectTab("Search", in: app)
        let search = app.textFields["Search music"]
        XCTAssertTrue(search.waitForExistence(timeout: 5) && search.isEnabled)
        search.tap()
        search.typeText("Fixture")
        // The keyboard obscures lower native result sections; dismiss through normal scrolling.
        scrollContent(in: app)
        XCTAssertTrue(
            app.staticTexts["Searching downloaded music and saved collections."].waitForExistence(
                timeout: 5))
        for title in ["Fixture Tone", "Fixture Album", "Fixture Artist", "Fixture Playlist"] {
            let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                .firstMatch
            for _ in 0..<8 {
                if result.exists { break }
                scrollContent(in: app)
            }
            XCTAssertTrue(result.exists, "Missing local search result: " + title)
        }
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Missing Tone"))
                .firstMatch.exists)
        capture("Offline local search includes playable track and related collections", in: app)
        app.buttons["offline-status-retry"].tap()
        XCTAssertTrue(app.switches["Simulate unavailable network"].waitForExistence(timeout: 5))
        let online = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"),
            object: app.switches["Simulate unavailable network"])
        XCTAssertEqual(XCTWaiter.wait(for: [online], timeout: 5), .completed)
        XCTAssertTrue(search.isEnabled)
        let onlineMissing = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Missing Tone")
        ).firstMatch
        for _ in 0..<8 {
            if onlineMissing.exists { break }
            scrollContent(in: app, upward: false)
        }
        XCTAssertTrue(onlineMissing.waitForExistence(timeout: 5))
        XCTAssertTrue(onlineMissing.isEnabled)
        capture("Explicit Retry restores online search without losing navigation", in: app)
    }

    func testMeasuredTrackAndIndeterminateCollectionFeedback() {
        continueAfterFailure = false
        let app = launch(productionShell: true, canonicalDownloadState: nil, slowTransfer: true)
        app.buttons["Queue fixture playlist"].tap()
        app.buttons["Library"].firstMatch.tap()
        tapVisible(app.buttons["library-category-songs"], in: app)
        let progress = app.descendants(matching: .any)["collection-track-download-0"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertEqual(progress.label, "Downloading")
        XCTAssertEqual(progress.value as? String, "50 percent")
        let queued = app.descendants(matching: .any)["collection-track-download-1"].firstMatch
        XCTAssertTrue(queued.exists)
        XCTAssertEqual(queued.label, "Download queued")
        capture("Measured track uses accessible determinate circular progress", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["library-category-playlists"], in: app)
        let aggregate = app.descendants(matching: .any)["download-state-active-indeterminate"]
            .firstMatch
        XCTAssertTrue(aggregate.waitForExistence(timeout: 5))
        XCTAssertFalse((aggregate.value as? String ?? "").contains("percent"))
        capture("Collection feedback does not invent aggregate percentages", in: app)
        XCTAssertTrue(app.staticTexts["Fixture download ready"].waitForExistence(timeout: 65))
        assertOfflineIconIsAccessible(in: app)
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
        XCTAssertTrue(app.descendants(matching: .any)["download-state-waiting"].firstMatch.exists)
        chooseCollectionAction("Cancel Download", in: app)
        XCTAssertTrue(
            app.staticTexts["Cancelled — downloaded tracks are retained"]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["download-state-cancelled"].firstMatch.exists)
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
        reveal(app.buttons["Remove Selected"], in: app)
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
        reveal(app.buttons["Remove Selected"], in: app)
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
