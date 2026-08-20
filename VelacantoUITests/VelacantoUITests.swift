import XCTest

@MainActor
final class VelacantoUITests: XCTestCase {
    private let app = XCUIApplication()

    private func launchApplication() {
        app.launchArguments = ["-uiTesting"]
        app.launch()
    }

    private func launchSignedInFixture() {
        app.launchArguments = ["-uiTesting", "-uiTestingSignedIn"]
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
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["Connect Your Music Library"].waitForExistence(timeout: 2)
        )
        assertPlaybackAccessoryIsHidden()

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 2))
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

    func testSignedInLibraryAndSearchNavigation() throws {
        continueAfterFailure = false
        launchSignedInFixture()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Favorites"].waitForExistence(timeout: 3))

        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["Your Music"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Albums"].exists)
        XCTAssertTrue(app.staticTexts["Genres"].exists)
        XCTAssertTrue(app.staticTexts["Open Audio File"].exists)

        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.staticTexts["Browse Genres"].waitForExistence(timeout: 3))
    }

    func testSignedInSearchRetainsKeyboardFocusWhileTyping() throws {
        continueAfterFailure = false
        launchSignedInFixture()

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 5))
        searchTab.tap()
        XCTAssertTrue(app.staticTexts["Browse Genres"].waitForExistence(timeout: 3))
        let searchField = app.textFields["Search music"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()

        searchField.typeText("t")
        XCTAssertEqual(searchField.value as? String, "t")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["Enter at least two characters to find music."].exists
        )

        searchField.typeText("e")
        XCTAssertEqual(searchField.value as? String, "te")
        XCTAssertTrue(app.keyboards.firstMatch.exists)

        searchField.typeText("s")
        XCTAssertEqual(searchField.value as? String, "tes")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Test Album"].waitForExistence(timeout: 3))
    }

    func testSignedInPlaybackSurfaceExposesLyricsQueueAndFavorite() throws {
        continueAfterFailure = false
        launchSignedInFixture()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        let compactMetadata = app.buttons["Now Playing"]
        XCTAssertTrue(compactMetadata.waitForExistence(timeout: 2))
        XCTAssertEqual(compactMetadata.value as? String, "Test Track, Test Artist")
        app.buttons["Show Now Playing"].tap()

        XCTAssertTrue(app.buttons["Show Lyrics"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Show Queue"].exists)
        XCTAssertTrue(app.buttons["Favorite"].exists)
        app.buttons["Show Lyrics"].tap()
        XCTAssertTrue(app.buttons["Hide Lyrics"].waitForExistence(timeout: 3))
        app.buttons["Hide Lyrics"].tap()
        app.buttons["Show Queue"].tap()
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Shuffle Up Next"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Repeat Off"].exists)
        app.buttons["Hide Queue"].tap()
        XCTAssertTrue(app.buttons["Show Queue"].waitForExistence(timeout: 3))
        app.buttons["Show Queue"].tap()
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 3))
    }
}
