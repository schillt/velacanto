import UIKit
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
        heldArtistAlbums: Bool = false, partialGridRow: Bool = false,
        compactFixtureControls: Bool = false, queuePresentation: Bool = false,
        alphabetCapabilityFailOnce: Bool = false, detachedPlayerArtwork: Bool = false,
        holdPlayerGlass: Bool = false, heldAlphabetPage: Bool = false
    )
        -> XCUIApplication
    {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if productionShell { app.launchArguments.append("-fixtureProductionShell") }
        if queuePresentation { app.launchArguments.append("-fixtureQueuePresentation") }
        if detachedPlayerArtwork { app.launchArguments.append("-fixtureDetachedPlayerArtwork") }
        if holdPlayerGlass { app.launchArguments.append("-fixtureHoldPlayerGlass") }
        if heldAlphabetPage { app.launchArguments.append("-fixtureHoldOrdinaryAlphabetPage") }
        if compactFixtureControls { app.launchArguments.append("-fixtureCompactControls") }
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
        if alphabetCapabilityFailOnce {
            app.launchArguments.append("-fixtureAlphabetCapabilityFailOnce")
        }
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
        if compactFixtureControls { openAlphabetFixtureControls(app) }
        if account && largeText {
            XCTAssertTrue(app.textFields["Jellyfin HTTPS address"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["Velacanto"].exists)
        } else {
            let entry = account ? "Sign in" : "Queue fixture playlist"
            XCTAssertTrue(app.buttons[entry].waitForExistence(timeout: 10))
        }
        if canonicalDownloadState != nil {
            XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        }
        if membership != nil {
            XCTAssertTrue(app.staticTexts["Membership fixture ready"].waitForExistence(timeout: 20))
        }
        if compactFixtureControls { closeAlphabetFixtureControls(app) }
        return app
    }

    private func queueSnapshot(_ app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["fixture-player-queue-snapshot"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        guard let data = element.label.data(using: .utf8),
            let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Synthetic queue snapshot must contain JSON")
            return [:]
        }
        return snapshot
    }

    private func revealQueueControl(
        _ control: XCUIElement, entryID: String, in app: XCUIApplication
    ) {
        let list = app.descendants(matching: .any)["fixture-queue-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let viewport = list.frame.intersection(app.frame).insetBy(dx: 8, dy: 16)
        XCTAssertGreaterThan(viewport.height, 44)
        for _ in 0..<16 {
            if control.exists && control.frame.width > 0 && control.frame.height > 0,
                control.isHittable,
                viewport.contains(CGPoint(x: control.frame.midX, y: control.frame.midY))
            {
                break
            }
            let order = queueSnapshot(app)["queue"] as? [String] ?? []
            guard let target = order.firstIndex(of: entryID) else {
                XCTFail("The target queue occurrence must remain in the real queue")
                return
            }
            let visible = order.enumerated().compactMap { index, id -> Int? in
                let row = app.buttons["fixture-queue-select-" + id]
                guard row.exists, row.frame.width > 0, row.frame.height > 0,
                    row.isHittable,
                    viewport.contains(CGPoint(x: row.frame.midX, y: row.frame.midY))
                else { return nil }
                return index
            }
            let upward = visible.min().map { target >= $0 } ?? (target > 0)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(
                    dx: viewport.midX, dy: viewport.minY + viewport.height * (upward ? 0.8 : 0.2)))
            let end = origin.withOffset(
                CGVector(
                    dx: viewport.midX, dy: viewport.minY + viewport.height * (upward ? 0.2 : 0.8)))
            start.press(
                forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(control.exists && control.frame.width > 0 && control.frame.height > 0)
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(viewport.contains(CGPoint(x: control.frame.midX, y: control.frame.midY)))
    }

    func testNativeQueueAppearanceLightDarkAndReducedTransparency() {
        continueAfterFailure = false
        for (scheme, reduced) in [("light", false), ("dark", false), ("dark", true)] {
            let app = launch(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                reducedAccessibilityEffects: reduced, colorScheme: scheme, queuePresentation: true)
            selectTab("Library", in: app)
            openCanonicalCollection("album", fromDownloads: false, in: app)
            tapVisible(app.buttons["collection-track-0"], in: app)
            let identity = app.staticTexts["fixture-playback-identity"]
            let playing = expectation(
                for: NSPredicate(format: "label CONTAINS %@", "state playing"),
                evaluatedWith: identity)
            wait(for: [playing], timeout: 10)
            let baseline = identity.label
            openNowPlaying(app)
            app.buttons["Show queue"].tap()
            XCTAssertEqual((queueSnapshot(app)["queue"] as? [String])?.count, 5)
            XCTAssertEqual((queueSnapshot(app)["upcoming"] as? [String])?.count, 4)
            XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, baseline)
            capture(
                "Native Queue appearance " + scheme + (reduced ? " reduced transparency" : ""),
                in: app)
            app.buttons["Show artwork"].tap()
            XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
            app.buttons["Show queue"].tap()
            XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, baseline)
            capture("Native Queue repeated appearance " + scheme, in: app)
            app.terminate()
        }
    }

    private func dragQueueEntry(
        _ source: XCUIElement, to target: XCUIElement, in app: XCUIApplication
    ) {
        let list = app.descendants(matching: .any)["fixture-queue-list"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = list.frame.maxX - app.frame.minX - 24
        let handle = origin.withOffset(CGVector(dx: x, dy: source.frame.midY - app.frame.minY))
        let destination = origin.withOffset(CGVector(dx: x, dy: target.frame.midY - app.frame.minY))
        handle.press(
            forDuration: 0.8, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3
        )
    }

    func testQueueRepeatedDragReordersOccurrencesAndKeepsCurrentPlayback() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            queuePresentation: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        app.buttons["Show queue"].tap()
        let selected = queueSnapshot(app)["selected"] as? String
        capture("Native Queue reorder handles preserve row styling", in: app)
        for _ in 0..<3 {
            let before = queueSnapshot(app)["upcoming"] as? [String] ?? []
            XCTAssertGreaterThanOrEqual(before.count, 2)
            guard before.count >= 2 else { return }
            let source = app.buttons["fixture-queue-select-" + before[1]]
            let target = app.buttons["fixture-queue-select-" + before[0]]
            XCTAssertTrue(source.isHittable && target.isHittable)
            dragQueueEntry(source, to: target, in: app)
            let after = queueSnapshot(app)
            XCTAssertEqual(
                after["upcoming"] as? [String], [before[1], before[0]] + Array(before.dropFirst(2)))
            XCTAssertEqual(after["selected"] as? String, selected)
            XCTAssertEqual(after["history"] as? [String], [])
            XCTAssertTrue(app.buttons["Pause"].exists)
        }
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        capture("Repeated occurrence drag keeps current playback and dismissal", in: app)
    }

    func testMiniPlayerControlsRemainInteractiveAboveAlbumNavigation() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true)
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

    func testNativeQueuePresentationActionsReorderAndPlaybackContinuity() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            colorScheme: "light", queuePresentation: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let rootIdentity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"),
            evaluatedWith: rootIdentity)
        wait(for: [playing], timeout: 10)
        let startingIdentity = rootIdentity.label
        openNowPlaying(app)
        let identity = app.staticTexts["fixture-player-playback-identity"]
        XCTAssertEqual(identity.label, startingIdentity)
        // Check menu semantics with a paused clock; advancing playback is covered
        // separately by repeated handle reorder and interrupted dismissal tests.
        app.buttons["Pause"].tap()
        let paused = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state paused"),
            evaluatedWith: identity)
        wait(for: [paused], timeout: 5)
        let originalIdentity = identity.label
        app.buttons["Show queue"].tap()
        let snapshot = queueSnapshot(app)
        guard let queue = snapshot["queue"] as? [String],
            let initial = snapshot["upcoming"] as? [String]
        else {
            XCTFail("Queue occurrence arrays are required")
            return
        }
        XCTAssertEqual(queue.count, 5)
        XCTAssertEqual(Set(queue).count, 5)
        XCTAssertEqual(initial.count, 4)
        XCTAssertEqual(snapshot["selected"] as? String, queue.first)
        XCTAssertEqual(identity.label, originalIdentity)
        let current = app.buttons["fixture-queue-select-" + queue[0]]
        XCTAssertEqual(current.value as? String, "Current track")
        XCTAssertTrue(current.isSelected)
        XCTAssertEqual(snapshot["history"] as? [String], [])
        capture("Native Queue baseline light", in: app)
        func action(_ title: String, entry: String) {
            let row = app.buttons["fixture-queue-select-" + entry]
            revealQueueControl(row, entryID: entry, in: app)
            row.press(forDuration: 1)
            let button = app.cells.buttons.matching(
                NSPredicate(format: "label == %@", title))
            XCTAssertEqual(button.count, 1)
            XCTAssertTrue(button.element.isHittable)
            button.element.tap()
        }
        action("Play Last", entry: initial[0])
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String],
            Array(initial.dropFirst()) + [initial[0]])
        action("Play Next", entry: initial[0])
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], initial)
        XCTAssertEqual(identity.label, originalIdentity)
        // Cancel a real native menu without selecting any queue action.
        let menu = app.buttons["fixture-queue-select-" + initial[1]]
        menu.press(forDuration: 1)
        let lastAction = app.cells.buttons["Play Last"]
        XCTAssertTrue(lastAction.waitForExistence(timeout: 5))
        let artworkToggle = app.buttons["Show artwork"]
        XCTAssertTrue(artworkToggle.frame.width > 0)
        let outside = artworkToggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        XCTAssertFalse(
            lastAction.frame.contains(
                CGPoint(x: artworkToggle.frame.midX, y: artworkToggle.frame.midY)))
        outside.tap()
        let gone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: lastAction)
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], initial)
        let cancellationOutcome = XCTAttachment(
            string:
                "Outside native menu tap: Show artwork exists \(app.buttons["Show artwork"].exists); Show queue exists \(app.buttons["Show queue"].exists)"
        )
        cancellationOutcome.name = "Synthetic Queue cancellation gesture consumption"
        cancellationOutcome.lifetime = .keepAlways
        add(cancellationOutcome)
        XCTAssertTrue(
            app.buttons["Show artwork"].exists,
            "Native menu cancellation must retain the visible Queue")
        XCTAssertFalse(app.buttons["Show queue"].exists)
        let source = app.buttons["fixture-queue-select-" + initial[3]]
        let destination = app.buttons["fixture-queue-select-" + initial[0]]
        reveal(source, in: app)
        XCTAssertTrue(source.isHittable && destination.isHittable)
        dragQueueEntry(source, to: destination, in: app)
        let reordered = [initial[3]] + Array(initial.prefix(3))
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], reordered)
        action("Remove from Up Next", entry: initial[2])
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String],
            reordered.filter { $0 != initial[2] })
        XCTAssertEqual(identity.label, originalIdentity)
        app.buttons["Shuffle"].tap()
        XCTAssertEqual(queueSnapshot(app)["shuffle"] as? Bool, true)
        XCTAssertEqual(
            Set(queueSnapshot(app)["upcoming"] as? [String] ?? []),
            Set(reordered.filter { $0 != initial[2] }))
        app.buttons["Shuffle"].tap()
        XCTAssertEqual(queueSnapshot(app)["shuffle"] as? Bool, false)
        app.buttons["Repeat"].tap()
        app.cells.buttons["One"].tap()
        XCTAssertEqual(queueSnapshot(app)["repeat"] as? String, "one")
        app.buttons["Repeat"].tap()
        app.cells.buttons["Off"].tap()
        XCTAssertEqual(queueSnapshot(app)["repeat"] as? String, "off")
        XCTAssertEqual(identity.label, originalIdentity)
        capture(
            "Native Queue edited upcoming occurrences preserve active playback", in: app)
        for _ in 0..<2 {
            app.buttons["Show artwork"].tap()
            XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
            app.buttons["Show queue"].tap()
            XCTAssertEqual(identity.label, originalIdentity)
        }
        capture("Native Queue repeated presentation light", in: app)
        let beforeSelection = queueSnapshot(app)
        guard let beforeOrder = beforeSelection["queue"] as? [String],
            let selectedIndex = beforeOrder.firstIndex(of: initial[1])
        else {
            XCTFail("The chosen duplicate occurrence must remain queued")
            return
        }
        let selection = app.buttons["fixture-queue-select-" + initial[1]]
        tapVisible(selection, in: app)
        let selectedIdentity =
            "Fixture identity: \(initial[1]); item tone; intent true; state playing"
        let selectedPlaying = expectation(
            for: NSPredicate(format: "label == %@", selectedIdentity), evaluatedWith: identity)
        wait(for: [selectedPlaying], timeout: 10)
        XCTAssertNotEqual(identity.label, originalIdentity)
        XCTAssertEqual(identity.label, selectedIdentity)
        let afterSelection = queueSnapshot(app)
        XCTAssertEqual(afterSelection["selected"] as? String, initial[1])
        XCTAssertEqual(afterSelection["queue"] as? [String], beforeOrder)
        XCTAssertEqual(
            afterSelection["history"] as? [String], Array(beforeOrder.prefix(selectedIndex)))
        XCTAssertEqual(
            afterSelection["upcoming"] as? [String], Array(beforeOrder.dropFirst(selectedIndex + 1))
        )
        XCTAssertEqual(selection.value as? String, "Current track")
        XCTAssertTrue(selection.isSelected)
        XCTAssertFalse(current.isSelected)
        capture("Native Queue selects the exact duplicate occurrence", in: app)
        app.terminate()
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
        var button = app.tabBars.buttons[title].firstMatch
        if !button.exists {
            // iPad's native top tab controls are buttons outside a TabBar AX container.
            let symbol: String? =
                switch title {
                case "New": "square.grid.2x2"
                case "Library": "music.pages"
                case "Search": "magnifyingglass"
                default: nil
                }
            if let symbol {
                button =
                    app.buttons.matching(
                        NSPredicate(format: "label == %@ AND identifier == %@", title, symbol)
                    ).firstMatch
            } else {
                button =
                    app.buttons.matching(
                        NSPredicate(format: "label == %@ AND identifier != %@", title, "BackButton")
                    ).firstMatch
            }
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
        XCTAssertTrue(app.buttons["Playback Settings"].exists)
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
        XCTAssertFalse(app.staticTexts["Downloaded audio"].exists)
        XCTAssertFalse(app.staticTexts["Cached artwork"].exists)
        tapVisible(app.buttons["Downloaded Music"], in: app)
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Audio")
            ).firstMatch.exists)
        capture("Download storage details remain in Downloaded Music", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["Cached Media"], in: app)
        XCTAssertTrue(app.navigationBars["Cached Media"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cached artwork"].waitForExistence(timeout: 5))
        let memory = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Artwork cache memory cost")
        ).firstMatch
        XCTAssertTrue(memory.exists)

        capture("Cache disk and memory details have their own page", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        let profileForm = app.collectionViews["foundation-profile-form"]
        profileForm.swipeUp()
        XCTAssertTrue(app.switches["Record local diagnostics"].exists)
        XCTAssertTrue(app.buttons["Refresh snapshot"].exists)
        XCTAssertTrue(app.buttons["Share diagnostic snapshot"].exists)
        XCTAssertFalse(app.buttons["Local diagnostic snapshot"].exists)
        capture("Diagnostic options directly on Profile", in: app)
        tapVisible(app.buttons["Open-source licenses"], in: app, context: profileForm)
        XCTAssertTrue(app.navigationBars["Open-source licenses"].waitForExistence(timeout: 5))
        let titles = [
            "Get", "Jellyfin Swift SDK", "Swift Atomics", "Swift Collections", "Swift NIO",
            "Swift NIO Transport Services", "Swift System",
        ]
        for title in titles {
            let row = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", title)
            ).firstMatch
            XCTAssertTrue(row.exists)
        }
        capture("Alphabetical dependency license list", in: app)
        let sdk = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Jellyfin Swift SDK")
        ).firstMatch
        tapNativeChrome(sdk, in: app)
        XCTAssertTrue(app.navigationBars["Jellyfin Swift SDK"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Mozilla Public License Version 2.0")
            ).firstMatch.exists)
        capture("Individual full license text", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
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

    func testSearchRepeatedOpeningAndFocusReentryKeepsDismissalResponsive() {
        continueAfterFailure = false
        let app = launch(productionShell: true, canonicalDownloadState: "full")
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        field.typeText("Fixture")
        for _ in 0..<5 {
            dismiss.tap()
            XCTAssertTrue(dismiss.waitForNonExistence(timeout: 3))
            field.tap()
            XCTAssertTrue(dismiss.waitForExistence(timeout: 1))
            XCTAssertTrue(dismiss.isHittable)
            XCTAssertEqual(field.value as? String, "Fixture")
        }
        dismiss.tap()
        field.tap()
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        selectTab("Library", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 1) && dismiss.isHittable)
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Fixture")
        capture("Repeated Search split merge and tab reentry preserves query", in: app)
    }

    func testCompleteLoadedSongsAlphabetTapAndDragStayInTracks() {
        continueAfterFailure = false
        // This fixture has no server alphabet capability and complete two-song membership.
        let app = launch(productionShell: true, canonicalDownloadState: "full")
        selectTab("Library", in: app)
        for category in ["albums", "artists"] {
            tapVisible(app.buttons["library-category-" + category], in: app)
            XCTAssertFalse(
                app.descendants(matching: .any).matching(
                    NSPredicate(format: "label == %@", "Section index")
                ).firstMatch.exists)
            app.navigationBars.buttons.firstMatch.tap()
        }
        tapVisible(app.buttons["library-category-songs"], in: app)
        let table = app.tables["library-index-track"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        let index = table.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Section index")
        ).firstMatch
        XCTAssertTrue(index.waitForExistence(timeout: 5) && index.isHittable)
        let first = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
        ).firstMatch
        XCTAssertTrue(first.exists)
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).tap()
        XCTAssertTrue(first.exists)
        XCTAssertFalse(app.staticTexts["Z and following"].exists)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let start = index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05))
        let end = index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(
            forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(first.exists)
        XCTAssertFalse(app.staticTexts["Z and following"].exists)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        capture("Complete loaded Songs alphabet tap drag without server seek", in: app)
    }

    func testQueueSkipPauseCollapseAndReopenRepeatedly() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            queuePresentation: true, detachedPlayerArtwork: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        for iteration in 0..<3 {
            if app.buttons["Show queue"].exists { app.buttons["Show queue"].tap() }
            XCTAssertTrue(app.descendants(matching: .any)["fixture-queue-list"].exists)
            app.buttons["Next"].tap()
            let pause = app.buttons["Pause"]
            XCTAssertTrue(pause.waitForExistence(timeout: 5))
            pause.tap()
            app.buttons["Play"].tap()
            let collapse = app.buttons["Collapse Now Playing"]
            XCTAssertTrue(collapse.exists && collapse.isHittable)
            let grabber = collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grabber.press(
                forDuration: 0.1, thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: 15)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertTrue(collapse.exists && collapse.isHittable)
            XCTAssertTrue(app.buttons["Show artwork"].exists)
            if iteration == 1 {
                grabber.press(
                    forDuration: 0.1,
                    thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: app.frame.height * 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                collapse.tap()
            }
            XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Show Now Playing"].isHittable)
            openNowPlaying(app)
            // Previous may first restart a track after three seconds. Two taps guarantee
            // return to the first occurrence, including when the controls took time to settle.
            app.buttons["Previous"].tap()
            app.buttons["Previous"].tap()
        }
        app.buttons["Collapse Now Playing"].tap()
        selectTab("Search", in: app)
        XCTAssertTrue(app.textFields["Search music"].waitForExistence(timeout: 5))
        capture(
            "Repeated queue skips and playback controls retain collapse and navigation", in: app)
    }

    func testPlayerPlaybackInteractionsDismissWithoutAnArtworkAnchor() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            queuePresentation: true, detachedPlayerArtwork: true)
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

    func testNativeMiniPlayerMinimizesExpandsAndReturnsToNormal() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", artworkCache: true,
            longPlayback: true, alphabetCatalog: true, compactFixtureControls: true)
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

    func testMiniPlayerGlassRendersIntermediateGeometry() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", artworkCache: true,
            longPlayback: true, holdPlayerGlass: true)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        capture("Owned compact glass source above navigation", in: app)
        app.buttons["Show Now Playing"].tap()
        XCTAssertTrue(app.buttons["More playback options"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(artworkTransitionCount("intermediate", in: app), 1)
        capture("Player after measured intermediate glass expansion", in: app)
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        capture("Owned compact glass restored after reverse transition", in: app)
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
                XCTAssertFalse(app.tables["library-index-" + kind].exists)
                XCTAssertFalse(
                    app.descendants(matching: .any).matching(
                        NSPredicate(format: "label == %@", "Section index")
                    ).firstMatch.exists)
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
            if kind != "track" {
                XCTAssertFalse(
                    app.descendants(matching: .any).matching(
                        NSPredicate(format: "label == %@", "Section index")
                    ).firstMatch.exists)
            }
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
        let table = app.tables["library-index-track"]
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
        let titles = (65...90).map { String(UnicodeScalar($0)!) }
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
        guard titles.indices.contains(position) else {
            XCTFail("Requested title must belong to the native index")
            return nil
        }
        if runs.count == titles.count {
            let target = runs[position]
            let center = CGFloat(target.lowerBound + target.upperBound) / 2
            return center / CGFloat(height)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Observed native alphabet index glyph mismatch"
        attachment.lifetime = .keepAlways
        add(attachment)
        // UIKit can compress the offline title array to fewer glyph rows with dots.
        // Infer only the hidden # touch slot; the real window and zero-network assertions
        // remain the oracle for UIKit's selection. Online full-glyph checks stay strict.
        if titles.count == 28, titles[1] == "#", position == 1,
            runs.count >= 3, runs.count < titles.count,
            let first = runs.first, let last = runs.last
        {
            let firstCenter = CGFloat(first.lowerBound + first.upperBound) / 2
            let lastCenter = CGFloat(last.lowerBound + last.upperBound) / 2
            guard lastCenter > firstCenter else {
                XCTFail("Compressed native index must have distinct endpoint glyphs")
                return nil
            }
            let center =
                firstCenter + (lastCenter - firstCenter)
                * CGFloat(position) / CGFloat(titles.count - 1)
            return center / CGFloat(height)
        }
        XCTFail(
            "Native index must render the full approved title order or observed offline # compression: "
                + "expected \(titles.count), observed \(runs.count)")
        return nil
    }

    private func openAlphabetFixtureControls(_ app: XCUIApplication) {
        let button = app.buttons["Fixture controls"]
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        XCTAssertTrue(app.buttons["Close fixture controls"].waitForExistence(timeout: 5))
    }

    private func closeAlphabetFixtureControls(_ app: XCUIApplication) {
        let close = app.buttons["Close fixture controls"]
        XCTAssertTrue(close.exists && close.isHittable)
        close.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Fixture controls"].isHittable)
    }

    private func readAlphabetCounts(_ app: XCUIApplication) -> String {
        let read = app.buttons["Read catalog counts"]
        tapNativeChrome(read, in: app)
        return read.value as? String ?? ""
    }

    private func toggleAlphabetNetwork(_ app: XCUIApplication, offline: Bool) {
        openAlphabetFixtureControls(app)
        let toggle = app.switches["Simulate unavailable network"].switches.firstMatch
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, offline ? "1" : "0")
        closeAlphabetFixtureControls(app)
        XCTAssertEqual(
            app.buttons["Fixture controls"].value as? String, offline ? "offline" : "online")
    }

    func testTracksAlphabetJumpsRetainEarlierRowsAndUseOrdinaryPages() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            alphabetCatalog: true, compactFixtureControls: true)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        let table = app.tables["library-index-track"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        // The simulator gives hosted buttons stale zero-sized accessibility frames
        // after an index jump. Touch the rendered first row instead, and verify the
        // selected canonical item. This exercises hit testing as well as scrolling.
        func touchFirstRenderedRow() {
            table.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: table.frame.width * 0.5, dy: 60)).tap()
        }
        func expectSelection(_ index: Int) {
            let identity = app.staticTexts["fixture-playback-identity"]
            let observed = XCTAttachment(string: identity.label)
            observed.name = "Synthetic rendered-row selection"
            observed.lifetime = .keepAlways
            add(observed)
            let selected = expectation(
                for: NSPredicate(format: "label CONTAINS %@", "item alphabet-track-\(index);"),
                evaluatedWith: identity)
            wait(for: [selected], timeout: 5)
        }
        XCTAssertTrue(app.buttons["Actions for G Fixture track 150"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["library-alphabet-all-track"].exists)
        let before = readAlphabetCounts(app)
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(app.buttons["Actions for F Fixture track 100"].waitForExistence(timeout: 10))
        capture("F anchor within retained full Tracks list", in: app)
        touchFirstRenderedRow()
        expectSelection(100)
        // Scroll backwards across F without All and touch an earlier retained A row.
        table.swipeDown()
        touchFirstRenderedRow()
        let identity = app.staticTexts["fixture-playback-identity"].label
        let prefix = "item alphabet-track-"
        let value = identity.components(separatedBy: prefix).last?
            .components(separatedBy: ";").first
        let earlier = value.flatMap(Int.init)
        XCTAssertNotNil(earlier)
        XCTAssertLessThan(earlier ?? 100, 100)
        tapNativeAlphabet("A", in: app)
        touchFirstRenderedRow()
        expectSelection(0)
        tapNativeAlphabet("G", in: app)
        touchFirstRenderedRow()
        expectSelection(150)
        tapNativeAlphabet("A", in: app)
        touchFirstRenderedRow()
        expectSelection(0)
        let counts = readAlphabetCounts(app)
        XCTAssertEqual(counts, before, "Rail gestures must not request pages")
        XCTAssertFalse(app.progressIndicators["Jumping to F…"].exists)
        XCTAssertTrue(counts.contains("track-all-0 1"))
        XCTAssertTrue(counts.contains("track-all-100 1"))
        XCTAssertFalse(counts.contains("track-F-"))
        XCTAssertFalse(counts.contains("track-G-"))
        capture("A returns to retained first row with no filtered requests", in: app)
    }

    func testTracksAlphabetOfflineAndRelatedNavigationRetainPlayback() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", longPlayback: true,
            alphabetCatalog: true, compactFixtureControls: true)
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

    func testTracksOrdinaryPageFailureRetryKeepsEarlierRowsAndRail() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", alphabetCatalog: true,
            alphabetFailOnce: true, compactFixtureControls: true)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tables["library-index-track"].exists)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].exists)
        tapNativeChrome(app.buttons["Retry"], in: app)
        tapNativeAlphabet("F", in: app)
        let f = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "F Fixture track 100")
        ).firstMatch
        XCTAssertTrue(f.waitForExistence(timeout: 10))
        capture("Loaded F anchor after ordinary page retry", in: app)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].isHittable)
        let before = readAlphabetCounts(app)
        tapNativeAlphabet("F", in: app)
        tapNativeAlphabet("A", in: app)
        XCTAssertEqual(readAlphabetCounts(app), before)
        capture("Ordinary page retry preserves prior rows and loaded anchors", in: app)
    }

    func testTracksActivationLoadCancelsOnExitAndRailDoesNotRetargetLoading() {
        continueAfterFailure = false
        let app = launch(
            productionShell: true, canonicalDownloadState: "full", alphabetCatalog: true,
            compactFixtureControls: true, heldAlphabetPage: true)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].waitForExistence(timeout: 5))
        let before = readAlphabetCounts(app)
        tapNativeAlphabet("F", in: app)
        tapNativeAlphabet("G", in: app)
        tapNativeAlphabet("A", in: app)
        XCTAssertFalse(app.buttons["library-alphabet-cancel-track"].exists)
        XCTAssertFalse(app.buttons["library-alphabet-all-track"].exists)
        XCTAssertEqual(readAlphabetCounts(app), before)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["library-category-songs"], in: app)
        XCTAssertTrue(app.buttons["Actions for G Fixture track 150"].waitForExistence(timeout: 10))
        tapNativeAlphabet("G", in: app)
        XCTAssertTrue(app.buttons["Actions for G Fixture track 150"].isHittable)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].isHittable)
        XCTAssertTrue(readAlphabetCounts(app).contains("cancelled 1"))
        capture(
            "Activation load resumes after exit; rail never starts or retargets requests", in: app)
    }

    private func openNowPlaying(_ app: XCUIApplication) {
        let button = app.buttons["Show Now Playing"]
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        let opened = app.buttons["More playback options"].waitForExistence(timeout: 5)
        if !opened { capture("Player failed opening controls", in: app) }
        XCTAssertTrue(opened)
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
