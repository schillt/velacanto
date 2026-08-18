import XCTest

@MainActor
final class VelacantoUITests: XCTestCase {
    private let app = XCUIApplication()

    private func launchApplication() {
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    private func assertPlaybackAccessoryIsHidden() {
        XCTAssertFalse(app.buttons["Show Now Playing"].exists)
        XCTAssertFalse(app.staticTexts["Nothing Playing"].exists)
    }

    func testSignedOutPrimaryNavigation() throws {
        continueAfterFailure = false
        launchApplication()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        assertPlaybackAccessoryIsHidden()

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(
            app.staticTexts["Connect Your Music Library"].waitForExistence(timeout: 2)
        )
        assertPlaybackAccessoryIsHidden()

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            app.staticTexts["Search Needs a Music Server"].waitForExistence(timeout: 2)
        )
        assertPlaybackAccessoryIsHidden()
    }

    func testSignedOutLibraryCanOpenProfile() throws {
        continueAfterFailure = false
        launchApplication()
        app.tabBars.buttons["Library"].tap()
        app.buttons["Open Profile"].tap()

        XCTAssertTrue(
            app.navigationBars["Profile & Settings"].waitForExistence(timeout: 2)
        )
    }
}
