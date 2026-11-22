import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testAlbumDuplicatePreferenceRestoresRowsNumbersAndPlaybackQueue() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, queuePresentation: true, duplicateAlbumTracks: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        XCTAssertTrue(app.buttons["collection-track-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["collection-track-2"].exists)
        XCTAssertEqual(app.staticTexts["album-track-number-0"].label, "1")
        XCTAssertEqual(app.staticTexts["album-track-number-1"].label, "2")
        tapVisibleCenter(app.buttons["Play"], in: app)
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 10))
        openNowPlaying(app)
        XCTAssertEqual((queueSnapshot(app)["queue"] as? [String])?.count, 2)
        dismissNowPlaying(app)
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Home", in: app)
        tapNativeChrome(app.buttons["Profile and settings"], in: app)
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["FoundationShowDuplicateAlbumTracks"].firstMatch
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        tapNativeChrome(app.navigationBars["Profile & Settings"].buttons["Done"], in: app)
        selectTab("Library", in: app)
        // Library retains the album index when returning from another tab.
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        let album = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@", "View Fixture Album", "Fixture Album")
        ).firstMatch
        tapVisible(album, in: app)
        XCTAssertTrue(app.buttons["collection-track-2"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["album-track-number-0"].label, "1")
        XCTAssertEqual(app.staticTexts["album-track-number-1"].label, "1")
        XCTAssertEqual(app.staticTexts["album-track-number-2"].label, "2")
        tapVisibleCenter(app.buttons["Play"], in: app)
        openNowPlaying(app)
        XCTAssertEqual((queueSnapshot(app)["queue"] as? [String])?.count, 3)
        capture("Album duplicate preference preserves actual track numbers and full queue", in: app)
    }

    @objc func testColdPlaylistLoadsWithoutEditorAndCancelledFirstEntryReloads() {
        continueAfterFailure = false
        // No canonical-download setup: this begins with an empty account-owned model.
        let cold = launch(.init(productionShell: true))
        selectTab("Library", in: cold)
        openCanonicalCollection("playlist", fromDownloads: false, in: cold)
        XCTAssertTrue(cold.buttons["collection-track-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            cold.buttons["collection-track-1"].exists,
            "Initial detail load preserves duplicate occurrences without opening Edit")
        cold.terminate()

        let app = launch(.init(heldFirstPlaylistTracks: true, productionShell: true))
        selectTab("Library", in: app)
        openCanonicalCollection("playlist", fromDownloads: false, in: app)
        tapNativeChrome(app.buttons["Read catalog counts"], in: app)
        let firstRead = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "playlist-tracks 1"),
            object: app.staticTexts["fixture-catalog-counts"])
        XCTAssertEqual(XCTWaiter.wait(for: [firstRead], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["collection-track-0"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "View Fixture Playlist", "Fixture Playlist")
        ).firstMatch
        tapVisible(playlist, in: app)
        XCTAssertTrue(app.buttons["collection-track-0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["collection-track-1"].exists)
        tapNativeChrome(app.buttons["Read catalog counts"], in: app)
        let secondRead = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "playlist-tracks 2"),
            object: app.staticTexts["fixture-catalog-counts"])
        XCTAssertEqual(
            XCTWaiter.wait(for: [secondRead], timeout: 3), .completed,
            "A cancelled first owner must not strand or duplicate its replacement load")
    }

    @objc func testArtistPlaybackPreparationPreservesHeroWithoutLoadingBanner() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, heldArtistTracks: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app, useVerifiedCenter: true)
        tapVisibleCenter(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "label CONTAINS %@", "state playing"),
                        object: identity)
                ], timeout: 10), .completed)
        let originalIdentity = identity.label
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        tapVisibleCenter(app.buttons["library-category-artists"], in: app)
        let artist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
        ).firstMatch
        tapVisibleCenter(artist, in: app)
        let shuffle = app.buttons["Shuffle"]
        reveal(shuffle, in: app)
        // The scroll hero is distinct from the native bar's retained fading title.
        let title = app.scrollViews.staticTexts["Fixture Artist"].firstMatch
        if !title.exists || !title.isHittable {
            capture("Quiet artist title precondition", in: app)
            XCTContext.runActivity(named: "Quiet artist title accessibility precondition") {
                activity in
                let attachment = XCTAttachment(string: app.debugDescription)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        XCTAssertTrue(title.exists && title.isHittable)
        let originalTitleY = title.frame.minY
        capture("Artist hero before collection loading", in: app)

        for attempt in 0..<2 {
            let control = attempt == 0 ? app.buttons["Shuffle"] : app.buttons["Play"]
            tapVisibleCenter(control, in: app)
            let busy = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "isEnabled == false"), object: control)
            XCTAssertEqual(XCTWaiter.wait(for: [busy], timeout: 5), .completed)
            XCTAssertFalse(app.buttons["Cancel collection loading"].exists)
            XCTAssertFalse(
                app.progressIndicators.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Loading songs")
                ).firstMatch.exists)
            XCTAssertEqual(title.frame.minY, originalTitleY, accuracy: 2)
            let playerControl = app.buttons["foundation-mini-playback-toggle"]
            XCTAssertTrue(playerControl.exists && playerControl.isHittable)
            XCTAssertEqual(identity.label, originalIdentity)
            capture("Quiet artist playback preparation attempt \(attempt)", in: app)

            // Leaving the destination cancels the held preparation and preserves playback.
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["library-index-artist"]
                    .waitForExistence(timeout: 5))
            XCTAssertEqual(identity.label, originalIdentity)
            let dismiss = app.buttons["Dismiss"]
            if dismiss.waitForExistence(timeout: 3) { tapVisibleCenter(dismiss, in: app) }
            let nextArtist = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
            ).firstMatch
            tapVisibleCenter(nextArtist, in: app)
            XCTAssertTrue(app.buttons["Shuffle"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Shuffle"].isEnabled)
        }
    }

    @objc func testCollectionFailureNativeRetryPreservesPlaybackUntilSuccess() {
        checkCollectionOutcome("fail-once", related: false)
    }

    @objc func testEmptyCollectionNativeDismissPreservesPlayback() {
        checkCollectionOutcome("empty", related: false)
    }

    func checkCollectionOutcome(_ outcome: String, related: Bool) {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, collectionOutcome: outcome))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app, useVerifiedCenter: true)
        tapVisibleCenter(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"), evaluatedWith: identity)
        wait(for: [playing], timeout: 10)
        let originalIdentity = identity.label

        let context: XCUIElement
        let outcomeIdentity: XCUIElement
        if related {
            openNowPlaying(app)
            tapNativeChrome(app.buttons["More playback options"], in: app)
            tapVisible(app.buttons["View Artist"], in: app)
            assertRelatedDetent("medium", in: app)
            expandRelatedSheet(app)
            context = relatedSheet(app)
            outcomeIdentity = app.staticTexts["fixture-related-playback-identity"]
        } else {
            app.navigationBars.buttons.firstMatch.tap()
            app.navigationBars.buttons.firstMatch.tap()
            tapVisibleCenter(app.buttons["library-category-artists"], in: app)
            let artist = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
            ).firstMatch
            tapVisibleCenter(artist, in: app)
            context = app
            outcomeIdentity = identity
        }
        XCTAssertEqual(outcomeIdentity.label, originalIdentity)
        let command = outcome == "empty" ? "Shuffle" : "Play"
        tapVisibleCenter(context.buttons[command], in: app)
        let actionIdentity = related && outcomeIdentity.exists ? outcomeIdentity : identity
        let expectedModelState =
            outcome == "empty"
            ? "notice This collection has no songs." : "error The network request failed."
        let completed = expectation(
            for: NSPredicate(format: "value CONTAINS %@", expectedModelState),
            evaluatedWith: actionIdentity)
        wait(for: [completed], timeout: 5)
        XCTContext.runActivity(named: "Collection model outcome before native alert lookup") {
            activity in
            let attachment = XCTAttachment(
                string: actionIdentity.value as? String ?? "missing status")
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        capture("Collection model completed before alert, related \(related)", in: app)
        let title = outcome == "empty" ? "Music" : "Unable to Complete Action"
        let matchingAlerts = app.alerts.matching(NSPredicate(format: "label == %@", title))
        let alert = matchingAlerts.element
        XCTAssertTrue(
            alert.waitForExistence(timeout: 5), "Collection outcome must be presented natively")
        let alertCount = matchingAlerts.count
        if alertCount != 1 {
            XCTContext.runActivity(named: "Native alert accessibility containers") { activity in
                let containers = app.alerts.allElementsBoundByIndex.map { candidate in
                    "label \(candidate.label); identifier \(candidate.identifier); frame \(candidate.frame); "
                        + "buttons \(candidate.buttons.allElementsBoundByIndex.map(\.label))"
                }.joined(separator: "\n")
                let attachment = XCTAttachment(
                    string: containers + "\n\n" + app.debugDescription)
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
        }
        XCTAssertEqual(alertCount, 1)
        let message =
            outcome == "empty"
            ? "This collection has no songs." : "The network request failed. Try again explicitly."
        XCTAssertTrue(alert.staticTexts[message].exists)
        XCTAssertEqual(
            alert.buttons.matching(NSPredicate(format: "label == %@", "Dismiss")).count, 1)
        XCTAssertTrue(alert.buttons["Dismiss"].isHittable)
        XCTAssertEqual(outcomeIdentity.label, originalIdentity)
        if related { XCTAssertTrue(relatedSheet(app).exists) }
        XCTAssertFalse(app.buttons["Cancel collection loading"].exists)
        capture("Native \(outcome) collection outcome, related \(related)", in: app)

        if outcome == "empty" {
            XCTAssertFalse(alert.buttons["Retry"].exists)
            alert.buttons["Dismiss"].tap()
            let dismissed = expectation(
                for: NSPredicate(format: "exists == false"), evaluatedWith: alert)
            wait(for: [dismissed], timeout: 5)
            XCTAssertEqual(outcomeIdentity.label, originalIdentity)
            XCTAssertTrue(context.buttons["Shuffle"].isEnabled)
        } else {
            let retry = alert.buttons["Retry"]
            XCTAssertEqual(
                alert.buttons.matching(NSPredicate(format: "label == %@", "Retry")).count, 1)
            XCTAssertTrue(retry.isEnabled && retry.isHittable)
            retry.tap()
            let retried = expectation(
                for: NSPredicate(
                    format: "label != %@ AND label CONTAINS %@", originalIdentity, "state playing"),
                evaluatedWith: outcomeIdentity)
            wait(for: [retried], timeout: 10)
            XCTAssertFalse(alert.exists)
            XCTAssertTrue(context.buttons["Play"].isEnabled)
        }
        if related { XCTAssertTrue(relatedSheet(app).exists) }
    }

    @objc func testAlbumOverviewSheetUsesLightWindowAppearance() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "none", colorScheme: "light",
                compactFixtureControls: true, overview: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app, useVerifiedCenter: true)
        let more = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Overview: Synthetic album")
        ).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        tapVisibleCenter(more, in: app)
        let navigation = app.navigationBars["About Fixture Album"]
        XCTAssertTrue(navigation.waitForExistence(timeout: 5))
        let body = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Synthetic album overview")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertTrue(body.label.contains("overview paragraph 8."))
        let mediumTitleY = navigation.frame.minY
        XCTAssertGreaterThan(mediumTitleY, app.frame.height * 0.25)
        XCTAssertFalse(navigation.buttons["Done"].exists)
        capture("Album overview native glass at medium detent with system light colors", in: app)
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(
                forDuration: 0.1,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
        XCTAssertLessThan(navigation.frame.minY, mediumTitleY - app.frame.height * 0.15)
        capture("Album overview native sheet expanded with system light colors", in: app)
        XCTAssertFalse(navigation.buttons["Done"].exists)
        for _ in 0..<2 where navigation.exists {
            navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(
                    forDuration: 0.1,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertFalse(navigation.exists)
        let counts = app.buttons["Read catalog counts"]
        counts.tap()
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "value == %@", "overview-album 1"),
                        object: counts)
                ], timeout: 5), .completed)
    }

    @objc func testLoadedAlbumAndArtistOverviewSheetsInLightAppearance() {
        checkLoadedOverviewSheets(colorScheme: "light")
    }

    @objc func testAlbumAndArtistOverviewContentDragExpandsBeforeScrolling() {
        checkLoadedOverviewSheets(colorScheme: "light", verifyContentInteraction: true)
    }

    @objc func testLoadedAlbumAndArtistOverviewSheetsInDarkAppearance() {
        checkLoadedOverviewSheets(colorScheme: "dark")
    }

    @objc func testLoadedOverviewSheetsWithAccessibilityTextAndReducedEffects() {
        checkLoadedOverviewSheets(
            colorScheme: "light", largeText: true, reducedAccessibilityEffects: true)
    }

    private func checkLoadedOverviewSheets(
        colorScheme: String, largeText: Bool = false,
        reducedAccessibilityEffects: Bool = false, verifyContentInteraction: Bool = false
    ) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let appearance = colorScheme + (largeText ? " accessibility text" : "")
        for kind in ["album", "artist"] {
            let app = launch(
                .init(
                    productionShell: true, largeText: largeText, canonicalDownloadState: "none",
                    reducedAccessibilityEffects: reducedAccessibilityEffects,
                    colorScheme: colorScheme,
                    compactFixtureControls: true, overview: true))
            selectTab("Library", in: app)
            if kind == "album" {
                openCanonicalCollection(
                    kind, fromDownloads: false, in: app, useVerifiedCenter: true)
            } else {
                tapVisibleCenter(
                    app.descendants(matching: .any)["library-category-artists"], in: app)
                XCTAssertTrue(app.navigationBars["Artists"].waitForExistence(timeout: 5))
                tapVisibleCenter(
                    app.buttons.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
                    ).firstMatch, in: app)
            }
            let more = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Overview: Synthetic " + kind)
            ).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            let title = "About Fixture " + (kind == "album" ? "Album" : "Artist")
            let navigation = app.navigationBars[title]
            for reopening in 0..<(verifyContentInteraction ? 1 : 2) {
                tapVisibleCenter(more, in: app)
                XCTAssertTrue(navigation.waitForExistence(timeout: 5))
                XCTAssertFalse(
                    navigation.buttons["Done"].exists,
                    "The native-grabber flyout uses swipe dismissal without a duplicate Done button"
                )
                let body = app.staticTexts.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Synthetic " + kind + " overview")
                ).firstMatch
                XCTAssertTrue(body.waitForExistence(timeout: 5))
                XCTAssertTrue(body.isHittable)
                XCTAssertTrue(body.label.contains("overview paragraph 8."))
                capture("Overview \(kind) \(appearance) medium reopen \(reopening)", in: app)
                if reopening == 0 {
                    let mediumTitleY = navigation.frame.minY
                    if verifyContentInteraction {
                        let mediumTextOffset = body.frame.minY - navigation.frame.minY
                        let shortStart = app.coordinate(
                            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                        shortStart.press(
                            forDuration: 0.1,
                            thenDragTo: shortStart.withOffset(CGVector(dx: 0, dy: -12)),
                            withVelocity: .slow, thenHoldForDuration: 0.2)
                        XCTAssertEqual(
                            body.frame.minY - navigation.frame.minY, mediumTextOffset, accuracy: 2,
                            "A short medium-height drag must not scroll the reading text")
                        // Start on the reading content, leaving the native grabber untouched.
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82))
                            .press(
                                forDuration: 0.1,
                                thenDragTo: app.coordinate(
                                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.14)))
                        let expanded = XCTNSPredicateExpectation(
                            predicate: NSPredicate { _, _ in
                                MainActor.assumeIsolated {
                                    navigation.frame.minY < mediumTitleY - app.frame.height * 0.15
                                }
                            }, object: nil)
                        XCTAssertEqual(
                            XCTWaiter.wait(for: [expanded], timeout: 5), .completed,
                            "Dragging medium content must expand the sheet before scrolling")
                    } else {
                        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                            .press(
                                forDuration: 0.1,
                                thenDragTo: app.coordinate(
                                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
                    }
                    capture("Overview \(kind) \(appearance) expanded", in: app)
                    let expandedTextY = body.frame.minY
                    body.swipeUp()
                    if verifyContentInteraction {
                        XCTAssertLessThan(
                            body.frame.minY, expandedTextY - 24,
                            "Expanded reading content remains scrollable")
                    }
                    capture("Overview \(kind) \(appearance) scrolled", in: app)
                }
                for _ in 0..<2 where navigation.exists {
                    navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                        .press(
                            forDuration: 0.1,
                            thenDragTo: app.coordinate(
                                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
                }
                XCTAssertFalse(navigation.exists)
                let counts = app.buttons["Read catalog counts"]
                counts.tap()
                XCTAssertEqual(
                    XCTWaiter.wait(
                        for: [
                            XCTNSPredicateExpectation(
                                predicate: NSPredicate(
                                    format: "value == %@", "overview-" + kind + " 1"),
                                object: counts)
                        ], timeout: 5), .completed)
            }
            app.terminate()
        }
    }

    private func chooseCollectionAction(_ title: String, in app: XCUIApplication) {
        app.buttons["More actions"].tap()
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
    }

    private enum DownloadSmokeDestination {
        case root, downloads, playlists

        var title: String {
            switch self {
            case .root: "Download Test Library"
            case .downloads: "Downloads"
            case .playlists: "Playlists"
            }
        }
    }

    /// These two smoke flows use the observed application-level native back control.

    private func backInDownloadSmoke(
        to destination: DownloadSmokeDestination, in app: XCUIApplication
    ) async {
        func controls() -> [XCUIElement] {
            app.buttons.matching(identifier: "BackButton").allElementsBoundByIndex.filter {
                $0.exists && $0.isEnabled && $0.isHittable
            }
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        var uniqueAvailable = false
        repeat {
            if controls().count == 1 {
                uniqueAvailable = true
                break
            }
            guard clock.now < deadline else { break }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                XCTFail("Download smoke back polling was cancelled")
                return
            }
        } while clock.now < deadline
        guard uniqueAvailable else {
            capture("Download smoke back unavailable", in: app)
            captureDiagnosticText("Download smoke back hierarchy", app.debugDescription)
            XCTFail("Download smoke requires a unique hittable BackButton")
            return
        }
        let matches = controls()
        guard matches.count == 1, let back = matches.first else {
            XCTFail("Download smoke back control changed before tapping")
            return
        }
        let frame = back.frame
        guard frame.width > 0, frame.height > 0,
            app.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        else {
            XCTFail("Download smoke back control is outside the application")
            return
        }
        back.tap()
        XCTAssertTrue(app.navigationBars[destination.title].waitForExistence(timeout: 5))
        switch destination {
        case .root:
            XCTAssertTrue(app.buttons["Queue fixture playlist"].waitForExistence(timeout: 5))
        case .downloads:
            XCTAssertTrue(app.buttons["downloads-category-track"].waitForExistence(timeout: 5))
        case .playlists:
            let playlist = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
            ).firstMatch
            XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        }
    }

    private func openManagement(_ app: XCUIApplication) {
        let link = app.buttons["Downloaded Music"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
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

    @objc func testAccessibilitySizedStorageRowsSupportSelectionAndCancel() {
        continueAfterFailure = false
        let app = launch(.init(largeText: true))
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

    @objc func testArtistLoadingShimmerKeepsGridGeometryUntilCanonicalCardsLoad() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", heldArtistAlbums: true))
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

    @objc func testPullRefreshShowsRemoteFavoriteWithoutLeavingFullSongsView() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true, favoritesCatalog: true, remoteFavoriteRefresh: true))
        selectTab("Library", in: app)
        tapVisibleCenter(app.buttons["Favorites"], in: app)
        let catalog = app.descendants(matching: .any)["favorites-catalog"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 5))
        // Fail a blank initial destination promptly instead of cycling through scroll discovery.
        let initialShelf = catalog.buttons.matching(
            NSPredicate(format: "label == %@", "Playlists")
        ).firstMatch
        guard initialShelf.waitForExistence(timeout: 10) else {
            capture("Favorites missing initial loading shell", in: app)
            XCTFail("Favorites must mount its initial shelf owners")
            return
        }
        let songs = catalog.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Songs"))
            .firstMatch
        tapVisibleCenter(songs, in: app)
        XCTAssertTrue(app.navigationBars["Favorite Songs"].waitForExistence(timeout: 5))
        let changed = app.buttons["fixture-change-remote-favorite"]
        tapNativeChrome(changed, in: app)
        let acknowledged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "changed"), object: changed)
        XCTAssertEqual(XCTWaiter.wait(for: [acknowledged], timeout: 5), .completed)
        let remoteSong = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Remote Favorite")
        ).firstMatch
        XCTAssertFalse(
            remoteSong.exists, "The fixture changes only server data, not local favorite state")
        scrollContent(in: app, upward: false)
        XCTAssertTrue(remoteSong.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Favorite Songs"].exists)
        capture(
            "Native pull refresh discovers remote favorite in the current Songs destination",
            in: app)
    }

    @objc func testSmallSongsAlphabetRangesHandleMissingLettersWithoutOpeningCollections() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, canonicalDownloadState: "full"))
        selectTab("Library", in: app)
        for category in ["albums", "artists"] {
            tapVisible(app.buttons["library-category-" + category], in: app)
            XCTAssertFalse(app.descendants(matching: .any)["library-alphabet-rail"].exists)
            app.navigationBars.buttons.firstMatch.tap()
        }
        tapVisible(app.buttons["library-category-songs"], in: app)
        XCTAssertTrue(app.tables["library-index-track"].waitForExistence(timeout: 5))
        tapNativeAlphabet("F", in: app)
        let tone = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
            .firstMatch
        XCTAssertTrue(tone.waitForExistence(timeout: 5))
        tapNativeAlphabet("Z", in: app)
        XCTAssertTrue(app.staticTexts["No songs found."].waitForExistence(timeout: 5))
        tapNativeAlphabet("#", in: app)
        XCTAssertTrue(tone.waitForExistence(timeout: 5))
        XCTAssertTrue(app.tables["library-index-track"].exists)
        capture("Small Songs title ranges remain in the native track list", in: app)
    }

    @objc func testLibraryCoverGridsCanonicalArtworkColumnsAndPartialLastRow() {
        continueAfterFailure = false
        for largeText in [false, true] {
            let app = launch(
                .init(
                    productionShell: true, largeText: largeText, canonicalDownloadState: "full",
                    artworkCache: true, pagedCatalog: true, partialGridRow: true))
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

    func readAlphabetCounts(_ app: XCUIApplication, containing expected: String? = nil)
        -> String
    {
        let read = app.buttons["Read catalog counts"]
        tapNativeChrome(read, in: app)
        if let expected {
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", expected), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        return read.value as? String ?? ""
    }

    @objc func testTracksAlphabetFetchesColdZRangeAndPreservesCanonicalFSelection() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                alphabetCatalog: true, compactFixtureControls: true, extendedSongsCatalog: true))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        let table = app.tables["library-index-track"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        XCTAssertFalse(
            readAlphabetCounts(app, containing: "track-all-0 1").contains("track-all-100"))
        tapNativeAlphabet("Z", in: app)
        XCTAssertTrue(app.buttons["Actions for Z Fixture track 260"].waitForExistence(timeout: 10))
        var counts = readAlphabetCounts(app, containing: "track-Z-0 1")
        XCTAssertTrue(counts.contains("track-Z-0 1"))
        XCTAssertFalse(
            counts.contains("track-all-100"), "Cold letter selection must not walk earlier pages")
        XCTAssertFalse(counts.contains("track-all-200"))
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(app.buttons["Actions for F Fixture track 100"].waitForExistence(timeout: 10))
        table.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: table.frame.width * 0.5, dy: 60)).tap()
        let identity = app.staticTexts["fixture-playback-identity"]
        let selection = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "item alphabet-track-100;"),
            evaluatedWith: identity)
        wait(for: [selection], timeout: 10)
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].waitForExistence(timeout: 10))
        counts = readAlphabetCounts(app, containing: "track-A-0 1")
        XCTAssertTrue(counts.contains("track-F-0 1"))
        XCTAssertTrue(counts.contains("track-A-0 1"))
        XCTAssertFalse(counts.contains("track-all-100"))
        capture("Cold Z and F title ranges avoid prefix scans and retain queue identity", in: app)
    }

    @objc func testTracksAlphabetRangeFailureRetriesTheSelectedLetter() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", alphabetCatalog: true,
                alphabetFailOnce: true, compactFixtureControls: true))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        tapNativeAlphabet("F", in: app)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["library-alphabet-rail"].exists)
        tapNativeChrome(app.buttons["Retry"], in: app)
        XCTAssertTrue(app.buttons["Actions for F Fixture track 100"].waitForExistence(timeout: 10))
        let counts = readAlphabetCounts(app, containing: "track-F-0 2")
        XCTAssertTrue(counts.contains("track-F-0 2"))
        XCTAssertFalse(counts.contains("track-all-100"))
        capture("Failed F title range retries without loading the catalog prefix", in: app)
    }

    @objc func testTracksAlphabetSupersedesHeldRangeAndRejectsItsLateResult() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", alphabetCatalog: true,
                compactFixtureControls: true, heldAlphabetRange: true))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        XCTAssertTrue(app.buttons["Actions for A Fixture track 0"].waitForExistence(timeout: 5))
        tapNativeAlphabet("A", in: app)
        XCTAssertTrue(readAlphabetCounts(app, containing: "track-A-0 1").contains("track-A-0 1"))
        tapNativeAlphabet("G", in: app)
        XCTAssertTrue(app.buttons["Actions for G Fixture track 150"].waitForExistence(timeout: 10))
        let counts = readAlphabetCounts(app, containing: "cancelled 1")
        XCTAssertTrue(counts.contains("cancelled 1"))
        XCTAssertTrue(counts.contains("track-G-0 1"))
        XCTAssertFalse(counts.contains("track-all-100"))
        XCTAssertFalse(app.buttons["Actions for A Fixture track 0"].exists)
        capture("Latest explicit title range wins after cancelling held A", in: app)
    }

    @objc func testLibraryCollectionNativeBackCancellationRestoresSourceAndPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, canonicalDownloadState: "full", longPlayback: true))
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

    @objc func testWaitingCancellationFailureRetryAndRemoval() async {
        continueAfterFailure = false
        let app = launch(.downloadFailures)
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        XCTAssertTrue(app.buttons["downloads-category-track"].exists)
        XCTAssertTrue(app.buttons["downloads-category-album"].exists)
        XCTAssertTrue(app.buttons["downloads-category-playlist"].exists)
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5))
        tapVisible(app.buttons["downloads-category-playlist"], in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No playlists found."].waitForExistence(timeout: 5))
        await backInDownloadSmoke(to: .downloads, in: app)
        await backInDownloadSmoke(to: .root, in: app)
        let tracked = app.buttons["Open tracked fixture playlist"]
        XCTAssertTrue(tracked.waitForExistence(timeout: 5))
        tapVisible(tracked, in: app)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
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
        await backInDownloadSmoke(to: .root, in: app)
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
        await backInDownloadSmoke(to: .root, in: app)
        openDownloads(app)
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
    }

    @objc func testRelaunchDuplicateTracksLocalPlaybackAndRemoveAll() async {
        continueAfterFailure = false
        let app = launch(.downloads)
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
        tapVisible(app.buttons["downloads-category-track"], in: app)
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
            ).count, 1)
        await backInDownloadSmoke(to: .downloads, in: app)
        tapVisible(app.buttons["downloads-category-playlist"], in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        let occurrences = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertTrue(occurrences.element(boundBy: 0).isEnabled)
        XCTAssertTrue(occurrences.element(boundBy: 1).isEnabled)
        capture("Downloaded playlist preserves duplicate occurrences", in: app)
        app.buttons["Play"].tap()
        await backInDownloadSmoke(to: .playlists, in: app)
        await backInDownloadSmoke(to: .downloads, in: app)
        await backInDownloadSmoke(to: .root, in: app)
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
        await backInDownloadSmoke(to: .root, in: app)
        openDownloads(app)
        XCTAssertTrue(app.staticTexts["No Downloads"].waitForExistence(timeout: 5))
        app.terminate()
    }

    @objc func testSongRemovalWarnsForPlaylistAndStaysExcludedAfterRelaunch() {
        continueAfterFailure = false
        let app = launch(.downloads)
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
                format: "label CONTAINS %@", "Downloaded playlists may be incomplete.")
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
