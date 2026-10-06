import XCTest

@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    private func launch(
        failOnce: Bool = false, account: Bool = false, delayedAuth: Bool = false,
        productionShell: Bool = false, largeText: Bool = false
    )
        -> XCUIApplication
    {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if productionShell { app.launchArguments.append("-fixtureProductionShell") }
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
        return app
    }

    private func openDownloads(_ app: XCUIApplication) {
        app.buttons["Downloads"].tap()
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForSavedDownload(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Saved download"].waitForExistence(timeout: 10))
    }

    private func openFixturePlaylist(_ app: XCUIApplication) {
        app.buttons["Playlists"].tap()
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.tap()
        XCTAssertTrue(app.buttons["Play Available Tracks"].waitForExistence(timeout: 5))
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
        for _ in 0..<5 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
        element.tap()
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
        XCTAssertTrue(app.buttons["Retry Online"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Network connection unavailable. Showing downloaded music."
            ].exists)
        capture("Limited offline production shell", in: app)
        app.buttons["Search"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Retry Online"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["Albums, artists, and songs"].exists)
        app.buttons["Profile and settings"].tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        capture("Offline Profile and Settings", in: app)
        app.buttons["Downloaded Music"].tap()
        XCTAssertTrue(app.navigationBars["Downloaded Music"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Retry Online"].waitForExistence(timeout: 5))
        app.buttons["Retry Online"].tap()
        XCTAssertTrue(app.textFields["Albums, artists, and songs"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Simulate unavailable network"].value as? String, "0")
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
            app.buttons["Play Available Tracks"].tap()
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
        app.buttons["Cancel"].tap()
        enableCellular(app)
        XCTAssertTrue(
            app.staticTexts["Cancelled — downloaded tracks are retained"].exists)
        app.buttons["Retry Download"].tap()
        XCTAssertTrue(app.progressIndicators.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Download incomplete — retry when ready"].waitForExistence(timeout: 10))
        app.buttons["Retry Download"].tap()
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
        app.buttons["Play Available Tracks"].tap()
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
        let unavailable = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ AND label CONTAINS %@",
                "Fixture Tone", "Not available offline"))
        XCTAssertTrue(unavailable.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(unavailable.count, 2)
        XCTAssertFalse(app.buttons["Play Available Tracks"].isEnabled)
        XCTAssertTrue(app.buttons["Download Again"].exists)
        capture("Removed song stays unavailable in saved playlist after relaunch", in: app)
    }
}
