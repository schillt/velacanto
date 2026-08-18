import XCTest

@MainActor
final class VelacantoUITests: XCTestCase {
    private let app = XCUIApplication()

    private func launchApplication() {
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    func testSignedOutPrimaryNavigation() throws {
        #if os(macOS)
            throw XCTSkip("iOS tab navigation coverage")
        #else
            continueAfterFailure = false
            launchApplication()
            XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))

            app.tabBars.buttons["Library"].tap()
            XCTAssertTrue(
                app.staticTexts["Connect Your Music Library"].waitForExistence(timeout: 2)
            )

            app.tabBars.buttons["Search"].tap()
            XCTAssertTrue(
                app.staticTexts["Search Needs a Music Server"].waitForExistence(timeout: 2)
            )
        #endif
    }

    func testSignedOutLibraryCanOpenProfile() throws {
        #if os(macOS)
            throw XCTSkip("iOS tab and profile-sheet coverage")
        #else
            continueAfterFailure = false
            launchApplication()
            app.tabBars.buttons["Library"].tap()
            app.buttons["Open Profile"].tap()

            XCTAssertTrue(
                app.navigationBars["Profile & Settings"].waitForExistence(timeout: 2)
            )
        #endif
    }
}
