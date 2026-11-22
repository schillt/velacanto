import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
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

    @objc func testSyntheticLibrarySelectionCancelSaveIsolationRelaunchAndUnavailableFolder() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                librarySelection: true))
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

    @objc func testProfileSettingsFullPageAccountStorageAndDiagnosticsPresentation() {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, largeText: true, canonicalDownloadState: "full"))
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
        let snapshotButton = app.buttons["diagnostic-snapshot-open"]
        XCTAssertTrue(snapshotButton.exists)
        if snapshotButton.isEnabled {
            tapVisible(snapshotButton, in: app, context: profileForm)
            XCTAssertTrue(
                app.textViews["diagnostic-snapshot-content"].firstMatch.waitForExistence(
                    timeout: 5))
            tapNativeChrome(app.navigationBars["Diagnostic snapshot"].buttons["Done"], in: app)
            XCTAssertTrue(profileForm.waitForExistence(timeout: 5))
        }
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
}
