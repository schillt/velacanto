import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    private func fillSyntheticSignIn(_ app: XCUIApplication, keepKeyboardVisible: Bool = false) {
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
        if !keepKeyboardVisible {
            for title in ["Hide keyboard", "Hide Keyboard"] {
                let hideKeyboard = app.keyboards.buttons[title].firstMatch
                if hideKeyboard.exists && hideKeyboard.isHittable {
                    hideKeyboard.tap()
                    break
                }
            }
        }
    }

    @objc func testMobileSignInBrandingSecureFieldsAndServerErrorsLightAndDark() {
        continueAfterFailure = false
        for (scheme, failure) in [
            ("light", "-fixtureInvalidServer"), ("dark", "-fixtureUnreachableServer"),
        ] {
            let app = launch(.init(account: true, signInFailure: failure, colorScheme: scheme))
            XCTAssertTrue(app.navigationBars["VelaCanto"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["sign-in-introduction"].exists)
            XCTAssertFalse(
                app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS[c] %@", "Foundation")
                ).firstMatch.exists)
            XCTAssertTrue(app.secureTextFields["Password"].exists)
            XCTAssertFalse(app.textFields["Password"].exists)
            app.collectionViews.firstMatch.swipeUp()
            XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["Sign in"].isEnabled)
            capture("Mature mobile sign in " + scheme, in: app)
            fillSyntheticSignIn(app, keepKeyboardVisible: true)
            let submit = app.buttons["Sign in"]
            // Submit through the visible keyboard Go control. The form button
            // can validly remain covered while the password field is focused.
            XCTAssertTrue(submit.exists)
            XCTAssertTrue(submit.isEnabled)
            let go = app.keyboards.firstMatch.buttons.matching(
                NSPredicate(format: "label ==[c] %@", "go")
            ).firstMatch
            if !go.exists || !go.isHittable {
                tapVisible(app.secureTextFields["Password"], in: app)
            }
            XCTAssertTrue(go.waitForExistence(timeout: 5) && go.isHittable)
            XCTAssertTrue(mainWindow(in: app).frame.contains(go.frame))
            go.tap()
            let error = app.descendants(matching: .any)["sign-in-error"].firstMatch
            reveal(app.buttons["Sign in"], in: app)
            XCTAssertTrue(error.waitForExistence(timeout: 10))
            XCTAssertTrue(
                app.staticTexts["The network request failed. Try again explicitly."].exists)
            XCTAssertTrue(app.buttons["Sign in"].isEnabled)
            reveal(app.textFields["Username"], in: app)
            XCTAssertEqual(app.textFields["Username"].value as? String, "synthetic-ui")
            XCTAssertTrue(app.secureTextFields["Password"].exists)
            XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
            capture("Actionable synthetic server error " + scheme, in: app)
            app.terminate()
        }
    }

    @objc func testMobileSignInLargeTextKeyboardFocusAndInProgressCancellation() {
        continueAfterFailure = false
        let app = launch(
            .init(account: true, delayedAuth: true, largeText: true, colorScheme: "dark"))
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
        guard next.exists && next.isHittable else {
            capture("Sign-in second Next unavailable", in: app)
            captureDiagnosticText("Sign-in second Next hierarchy", app.debugDescription)
            XCTFail("Keyboard Next must remain hittable after username entry")
            return
        }
        next.tap()
        app.secureTextFields["Password"].typeText("synthetic-not-a-password")
        capture("Large text sign in secure keyboard focus", in: app)
        let go = app.keyboards.firstMatch.buttons.matching(
            NSPredicate(format: "label ==[c] %@", "go")
        ).firstMatch
        XCTAssertTrue(go.waitForExistence(timeout: 5) && go.isHittable)
        go.tap()
        let cancel = app.buttons["Cancel"]
        reveal(cancel, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["sign-in-progress"].firstMatch
                .waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Signing in…"].isEnabled)
        capture("Large text connecting state prevents duplicate submission", in: app)
        cancel.tap()
        reveal(app.buttons["Sign in"], in: app)
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
        reveal(app.textFields["Username"], in: app)
        XCTAssertEqual(app.textFields["Username"].value as? String, "synthetic-ui")
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
        capture("Large text cancelled sign in preserves entered state", in: app)
    }

    @objc func testCancelledSyntheticSignInCannotOpenAccount() async {
        continueAfterFailure = false
        let app = launch(.delayedSignIn)
        fillSyntheticSignIn(app)
        app.buttons["Sign in"].tap()
        let cancel = app.buttons["Cancel"]
        reveal(cancel, in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        reveal(app.buttons["Sign in"], in: app)
        XCTAssertTrue(app.buttons["Sign in"].isEnabled)
        let complete = app.buttons["Complete delayed authentication"]
        XCTAssertTrue(complete.exists && complete.isEnabled)
        // The fixture completion band is native safe-area chrome, outside the Form.
        tapNativeChrome(complete, in: app)
        XCTAssertTrue(
            app.staticTexts["Delayed authentication response delivered"]
                .waitForExistence(timeout: 5))
        XCTAssertEqual(complete.value as? String, "invocations 1")
        let opened = expectation(
            for: NSPredicate(format: "exists == true"),
            evaluatedWith: app.buttons["Queue fixture playlist"])
        opened.isInverted = true
        await fulfillment(of: [opened], timeout: 4)
        XCTAssertFalse(app.buttons["Queue fixture playlist"].exists)
    }

    @objc func testSyntheticSignInFailureRetryAndRepeatedSignOutWithLocalPlayback() async {
        continueAfterFailure = false
        let app = launch(.signIn)
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
}
