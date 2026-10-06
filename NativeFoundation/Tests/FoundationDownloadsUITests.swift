import XCTest

@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    private func launch(failOnce: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        app.launchArguments = ["-foundationDownloadsUITesting", "-foundationTesting"]
        if failOnce { app.launchArguments.append("-fixtureFailOnce") }
        app.launchEnvironment["FOUNDATION_UI_RUN_ID"] = UUID().uuidString
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments.append("-fixtureCleanup")
            app.launch()
            XCTAssertTrue(app.staticTexts["Fixture cleanup complete"].waitForExistence(timeout: 10))
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["Queue fixture playlist"].waitForExistence(timeout: 10))
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
