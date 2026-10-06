import XCTest

@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    private func launch(failOnce: Bool = false, account: Bool = false, delayedAuth: Bool = false)
        -> XCUIApplication
    {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if failOnce { app.launchArguments.append("-fixtureFailOnce") }
        if account { app.launchArguments.append("-fixtureAccount") }
        if delayedAuth { app.launchArguments.append("-fixtureDelayedAuth") }
        app.launchEnvironment["FOUNDATION_UI_RUN_ID"] = UUID().uuidString
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
        app.buttons["On Device"].tap()
        XCTAssertTrue(app.navigationBars["On Device"].waitForExistence(timeout: 5))
    }

    private func enableCellular(_ app: XCUIApplication) {
        let toggle = app.switches["Use Cellular Data"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
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
    }

    func testCancelledSyntheticSignInCannotOpenAccount() async {
        continueAfterFailure = false
        let app = launch(account: true, delayedAuth: true)
        fillSyntheticSignIn(app)
        app.buttons["Sign in"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
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
                XCTAssertFalse(savePassword.exists)
            }
            let hittable = expectation(
                for: NSPredicate(format: "hittable == true"), evaluatedWith: queue)
            await fulfillment(of: [hittable], timeout: 5)
            queue.tap()
            openDownloads(app)
            XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5))
            enableCellular(app)
            XCTAssertTrue(
                app.staticTexts["2 of 2 tracks available offline"]
                    .waitForExistence(timeout: 10))
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Playlist"))
                .firstMatch.tap()
            app.buttons["Play Available Tracks"].tap()
            app.navigationBars.buttons.firstMatch.tap()
            app.navigationBars.buttons.firstMatch.tap()
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
        XCTAssertTrue(app.staticTexts["Waiting for Wi-Fi"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        enableCellular(app)
        XCTAssertTrue(
            app.staticTexts["Cancelled — downloaded tracks are retained"].exists)
        app.buttons["Retry"].tap()
        XCTAssertTrue(app.progressIndicators.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Download incomplete — retry when ready"].waitForExistence(timeout: 10))
        app.buttons["Retry"].tap()
        XCTAssertTrue(
            app.staticTexts["2 of 2 tracks available offline"].waitForExistence(timeout: 10))
        app.buttons["Remove Download"].tap()
        app.sheets.buttons["Remove Download"].tap()
        XCTAssertTrue(
            app.staticTexts["Choose Download from a song, album, or playlist’s Actions menu."]
                .waitForExistence(timeout: 5))
    }

    func testRelaunchDuplicateTracksLocalPlaybackAndRemoveAll() async {
        continueAfterFailure = false
        let app = launch()
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        XCTAssertTrue(
            app.staticTexts["2 of 2 tracks available offline"].waitForExistence(timeout: 10))
        // Disallow the injected cellular path before cold process relaunch.
        app.switches["Use Cellular Data"].switches.firstMatch.tap()
        app.terminate()
        app.launch()
        openDownloads(app)
        XCTAssertTrue(
            app.staticTexts["2 of 2 tracks available offline"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["Use Cellular Data"].value as? String, "0")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture Playlist"))
            .firstMatch.tap()
        XCTAssertTrue(app.buttons["Play Available Tracks"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Available offline").count, 2)
        app.buttons["Play Available Tracks"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        let state = app.staticTexts["fixture-playback-state"]
        let playing = expectation(
            for: NSPredicate(format: "label == %@", "Fixture playback: playing"),
            evaluatedWith: state)
        await fulfillment(of: [playing], timeout: 10)
        openDownloads(app)
        app.buttons["Remove All Downloads"].tap()
        app.sheets.buttons["Remove All Downloads"].tap()
        XCTAssertTrue(
            app.staticTexts["Choose Download from a song, album, or playlist’s Actions menu."]
                .waitForExistence(timeout: 5))
        app.terminate()
    }
}
