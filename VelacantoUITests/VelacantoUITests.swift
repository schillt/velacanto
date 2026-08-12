import XCTest

final class VelacantoUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    func testSignedOutPrimaryNavigation() {
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(
            app.staticTexts["Connect Your Music Library"].waitForExistence(timeout: 2)
        )

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(
            app.staticTexts["Search Needs a Music Server"].waitForExistence(timeout: 2)
        )
    }

    func testSignedOutLibraryCanOpenProfile() {
        app.tabBars.buttons["Library"].tap()
        app.buttons["Open Profile"].tap()

        XCTAssertTrue(
            app.navigationBars["Profile & Settings"].waitForExistence(timeout: 2)
        )
    }
}
