import UIKit
import XCTest

/// Stable XCTest class identity; feature files extend this same owner.
@MainActor
final class FoundationDownloadsUITests: XCTestCase {
    func launch(_ scenario: FoundationUITestScenario = .downloads) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.chameleonenterprise.velacanto.uitesting")
        do {
            let configuration = try scenario.configuration()
            app.launchArguments = configuration.arguments
            app.launchEnvironment = configuration.environment
        } catch {
            XCTFail("Invalid UI scenario: \(error)")
            return app
        }
        let account = scenario.account
        let largeText = scenario.largeText
        let canonicalDownloadState = scenario.canonicalDownloadState
        let membership = scenario.membership
        let compactFixtureControls = scenario.compactFixtureControls
        let homeScrollBoundary = scenario.homeScrollBoundary
        let heldHomeGenres = scenario.heldHomeGenres
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments.append("-fixtureCleanup")
            app.launch()
            XCTAssertTrue(app.staticTexts["Fixture cleanup complete"].waitForExistence(timeout: 10))
            app.terminate()
        }
        captureFailureOnTeardown(app)
        app.launch()
        if compactFixtureControls { openAlphabetFixtureControls(app) }
        if account && largeText {
            XCTAssertTrue(app.navigationBars["VelaCanto"].waitForExistence(timeout: 10))
            let form = app.collectionViews.firstMatch
            guard form.waitForExistence(timeout: 5), app.collectionViews.count == 1 else {
                XCTFail("Expected one sign-in form collection")
                return app
            }
            let address = app.textFields["Jellyfin HTTPS address"]
            reveal(address, in: app)
            XCTAssertTrue(address.waitForExistence(timeout: 5) && address.isHittable)
        } else {
            if account {
                XCTAssertTrue(
                    app.textFields["Jellyfin HTTPS address"].waitForExistence(timeout: 10))
            } else {
                XCTAssertTrue(app.buttons["Queue fixture playlist"].waitForExistence(timeout: 10))
            }
        }
        if canonicalDownloadState != nil {
            XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        }
        if membership != nil {
            XCTAssertTrue(app.staticTexts["Membership fixture ready"].waitForExistence(timeout: 20))
        }
        if homeScrollBoundary {
            tapNativeChrome(app.buttons["fixture-build-primary-genres"], in: app)
            app.buttons["Read primary genre counts"].tap()
            let census = XCTNSPredicateExpectation(
                predicate: NSPredicate(
                    format: "label == %@",
                    heldHomeGenres ? "metadata 1 returned 0" : "metadata 1 returned 1"),
                object: app.staticTexts["fixture-primary-genre-counts"])
            XCTAssertEqual(XCTWaiter.wait(for: [census], timeout: 5), .completed)
        }
        if compactFixtureControls { closeAlphabetFixtureControls(app) }
        return app
    }

    func openDownloads(_ app: XCUIApplication) {
        tapVisible(app.buttons["Downloads"], in: app)
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
    }

    func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func captureFailureOnTeardown(_ app: XCUIApplication) {
        addTeardownBlock { @MainActor in
            guard (self.testRun?.failureCount ?? 0) > 0 else { return }
            self.capture("Failure screen", in: app)
            self.captureDiagnosticText("Failure accessibility hierarchy", app.debugDescription)
        }
    }

    func captureDiagnosticText(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func waitForSavedDownload(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Fixture download ready"].waitForExistence(timeout: 10))
    }

    func openFixturePlaylist(_ app: XCUIApplication) {
        app.buttons["Playlists"].tap()
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        playlist.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
    }

    func returnToFixtureRoot(_ app: XCUIApplication) {
        for _ in 0..<4 {
            if app.navigationBars["Download Test Library"].exists { return }
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(app.navigationBars["Download Test Library"].waitForExistence(timeout: 5))
    }

    func selectTab(_ title: String, in app: XCUIApplication) {
        var button = app.tabBars.buttons[title].firstMatch
        if title == "Library", !button.exists {
            // On Duo the native vertical bar exposes a labelled Button with
            // the symbol on its child Image, not on the button itself.
            func libraryControls() -> [XCUIElement] {
                app.buttons.matching(NSPredicate(format: "label == %@", title))
                    .allElementsBoundByIndex.filter { control in
                        control.exists && control.isHittable
                            && (control.images["music.pages.fill"].exists
                                || control.images["music.pages"].exists)
                    }
            }
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated { libraryControls().count == 1 }
                }, object: nil)
            guard XCTWaiter.wait(for: [available], timeout: 5) == .completed else {
                captureDiagnosticText(
                    "Adaptive Library accessibility hierarchy", app.debugDescription)
                XCTFail("Adaptive Library requires one hittable native bar button")
                return
            }
            let matches = libraryControls()
            guard matches.count == 1, let control = matches.first else {
                XCTFail("Adaptive Library button changed before tapping")
                return
            }
            button = control
        }
        if title == "Search", !button.exists {
            // Adaptive Search may replace its action with an image after selection;
            // query a control explicitly, then verify the destination itself.
            let match = NSPredicate(format: "label == %@", title)
            func hittableControls() -> [XCUIElement] {
                (app.buttons.matching(match).allElementsBoundByIndex
                    + app.popUpButtons.matching(match).allElementsBoundByIndex)
                    .filter {
                        $0.exists && $0.isHittable
                            && $0.images.matching(identifier: "magnifyingglass").firstMatch.exists
                    }
            }
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        hittableControls().count == 1
                    }
                }, object: nil)
            guard XCTWaiter.wait(for: [available], timeout: 5) == .completed else {
                capture("Adaptive Search unavailable", in: app)
                captureDiagnosticText(
                    "Adaptive Search accessibility hierarchy", app.debugDescription)
                XCTFail("Adaptive Search has no hittable button or pop-up action")
                return
            }
            let controls = hittableControls()
            guard controls.count == 1, let control = controls.first,
                control.exists, control.isHittable
            else {
                capture("Adaptive Search became unavailable", in: app)
                captureDiagnosticText(
                    "Adaptive Search accessibility hierarchy", app.debugDescription)
                XCTFail("Adaptive Search control became unavailable before tapping")
                return
            }
            control.tap()
            let field = app.textFields["Search music"]
            let usableField = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND hittable == true"), object: field
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [usableField], timeout: 5), .completed,
                "Adaptive Search did not expose a usable search field")
            return
        }
        if !button.exists {
            // Native adaptive navigation can expose buttons outside a TabBar.
            // A same-named static page heading is never a selectable control.
            let window = mainWindow(in: app)
            let match = NSPredicate(format: "label == %@ AND identifier != %@", title, "BackButton")
            func nativeControls() -> [XCUIElement] {
                (app.buttons.matching(match).allElementsBoundByIndex
                    + app.popUpButtons.matching(match).allElementsBoundByIndex).filter {
                        $0.exists && $0.isHittable
                            && window.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                    }
            }
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated { nativeControls().count == 1 }
                }, object: nil)
            guard XCTWaiter.wait(for: [available], timeout: 5) == .completed else {
                captureDiagnosticText("Adaptive navigation controls", app.debugDescription)
                XCTFail("Adaptive navigation requires one hittable native " + title + " control")
                return
            }
            let controls = nativeControls()
            guard controls.count == 1, let control = controls.first else {
                XCTFail("Adaptive navigation control changed before tapping")
                return
            }
            button = control
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }

    /// XCUIApplication can retain portrait bounds while its MainWindow is
    /// landscape. Keep both frame calculations and injected input on that window.
    func mainWindow(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.element(boundBy: 0)
        let frame = window.frame
        XCTAssertTrue(
            window.exists && !frame.isNull && !frame.isInfinite
                && frame.width > 0 && frame.height > 0,
            "An actual application window is required for UI coordinates")
        return window
    }

    /// Native bars are intentionally outside the scrolling content viewport.

    func tapNativeChrome(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
        XCTAssertTrue(mainWindow(in: app).frame.contains(center))
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertFalse(keyboard.frame.contains(center)) }
        element.tap()
    }

    func tapVisible(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) {
        reveal(element, in: app, context: context)
        element.tap()
    }

    // On this runtime native tap() can choose {-1, -1} for a visible SwiftUI button.
    // Use the verified on-screen center without bypassing reachability or hit testing.

    func tapVisibleCenter(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        let frame = element.frame
        let window = mainWindow(in: app)
        let applicationFrame = window.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertTrue(element.isHittable && applicationFrame.contains(center))
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(
                CGVector(dx: center.x - applicationFrame.minX, dy: center.y - applicationFrame.minY)
            )
            .tap()
    }

    func reveal(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil
    ) {
        let root = context ?? app
        for step in 0..<32 {
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists && frame.width > 0 && frame.height > 0
                && tapCenterIsVisible(element, in: app, context: context, frame: frame)
                && element.isHittable
            {
                return
            }
            let scroll = [
                root.collectionViews.firstMatch, root.scrollViews.firstMatch,
                root.tables.firstMatch,
            ]
            .first { $0.exists }
            let viewport = scroll.map { uncoveredViewport($0, in: app, context: context) }
            let upward =
                exists && frame.height > 0 && viewport != nil
                ? frame.midY >= viewport!.midY : step < 24
            scrollContent(in: app, upward: upward, context: context)
        }
        let exists = element.exists
        let frame = exists ? element.frame : .zero
        let reachable =
            exists && frame.width > 0 && frame.height > 0
            && tapCenterIsVisible(element, in: app, context: context, frame: frame)
            && element.isHittable
        if !reachable {
            capture("Unreachable navigation target", in: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic unreachable navigation hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(reachable)
    }

    // XCTest can report a clipped offscreen link as hittable and tap the adjacent row.
    // Scroll the actual target's center into the viewport before using its native tap.

    func tapCenterIsVisible(
        _ element: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil,
        frame: CGRect? = nil
    ) -> Bool {
        let root = context ?? app
        let scroll = [
            root.collectionViews.firstMatch, root.scrollViews.firstMatch, root.tables.firstMatch,
        ]
        .first { $0.exists }
        guard let scroll else { return true }
        let viewport = uncoveredViewport(scroll, in: app, context: context, gestureInset: false)
        let targetFrame = frame ?? element.frame
        return viewport.height > 20
            && viewport.contains(
                CGPoint(x: targetFrame.midX, y: targetFrame.midY))
    }

    /// Reported scroll frames include native bars; gestures must start in actual content.

    func uncoveredViewport(
        _ scroll: XCUIElement, in app: XCUIApplication, context: XCUIElement? = nil,
        gestureInset: Bool = true
    ) -> CGRect {
        let root = context ?? app
        let original = scroll.frame.intersection(mainWindow(in: app).frame)
        var top = original.minY
        var bottom = original.maxY
        for bar in root.navigationBars.allElementsBoundByIndex {
            let frame = bar.frame
            if frame.intersects(original), frame.maxY < original.maxY { top = max(top, frame.maxY) }
        }
        let profile = root.descendants(matching: .any)["Profile and settings"].firstMatch
        if profile.exists {
            let frame = profile.frame
            if frame.height > 0 && frame.intersects(original)
                && frame.minY < original.midY && profile.isHittable
            {
                top = max(top, frame.maxY + 12)
            }
        }
        let search = root.textFields["Search music"]
        if search.exists {
            let frame = search.frame
            if frame.height > 0 && frame.intersects(original)
                && frame.minY < original.midY && search.isHittable
            {
                top = max(top, frame.maxY + 8)
            }
        }
        let tabBar = root.tabBars.firstMatch
        if tabBar.exists {
            let frame = tabBar.frame
            if frame.intersects(original) { bottom = min(bottom, frame.minY) }
        }
        let miniPlayer = root.buttons["Show Now Playing"]
        if miniPlayer.exists {
            let frame = miniPlayer.frame
            if frame.height > 0 && frame.intersects(original)
                && frame.minY > original.midY && miniPlayer.isHittable
            {
                bottom = min(bottom, frame.minY)
            }
        }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            let frame = keyboard.frame
            if frame.intersects(original) { bottom = min(bottom, frame.minY) }
        }
        let height = max(0, bottom - top)
        // Keep drags away from chrome, but a visible button may validly sit closer to it.
        let margin = gestureInset ? min(12, height * 0.05) : 0
        return CGRect(
            x: original.minX, y: top + margin, width: original.width,
            height: max(0, height - 2 * margin))
    }

    func scrollContent(
        in app: XCUIApplication, upward: Bool = true, context: XCUIElement? = nil
    ) {
        let root = context ?? app
        let scroll = [
            root.collectionViews.firstMatch, root.scrollViews.firstMatch, root.tables.firstMatch,
        ]
        .first { $0.exists && $0.frame.height > 0 }
        if let scroll {
            let viewport = uncoveredViewport(scroll, in: app, context: context)
            guard viewport.height > 20 else { return }
            let window = mainWindow(in: app)
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(
                    dx: viewport.midX - window.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.8 : 0.2) - window.frame.minY))
            let end = origin.withOffset(
                CGVector(
                    dx: viewport.midX - window.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.2 : 0.8) - window.frame.minY))
            start.press(
                forDuration: 0.1, thenDragTo: end, withVelocity: .slow,
                thenHoldForDuration: 0.2)
        } else if upward {
            app.swipeUp()
        } else {
            app.swipeDown()
        }
    }

    func enableCellular(_ app: XCUIApplication) {
        let toggle = app.switches["Use Cellular Data"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        let enabled = expectation(
            for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        wait(for: [enabled], timeout: 5)
    }

    func openCanonicalCollection(
        _ kind: String, fromDownloads: Bool, in app: XCUIApplication,
        useVerifiedCenter: Bool = false
    ) {
        if fromDownloads {
            let downloads = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Downloads")
            ).firstMatch
            tapVisible(downloads, in: app)
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        }
        let category = kind == "album" ? "Albums" : "Playlists"
        let link =
            fromDownloads
            ? app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", category)).firstMatch
            : app.descendants(matching: .any).matching(
                identifier: "library-category-" + category.lowercased()
            ).firstMatch
        if useVerifiedCenter { tapVisibleCenter(link, in: app) } else { tapVisible(link, in: app) }
        XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 5))
        let title = kind == "album" ? "Fixture Album" : "Fixture Playlist"
        let collection = app.buttons.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "View " + title, title)
        ).firstMatch
        if useVerifiedCenter {
            tapVisibleCenter(collection, in: app)
        } else {
            tapVisible(collection, in: app)
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["collection-detail-" + kind + "-" + kind]
                .waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[title].firstMatch.exists)
        XCTAssertTrue(app.buttons["Play"].exists)
        XCTAssertTrue(app.buttons["Shuffle"].exists)
    }

    func tapNativeAlphabet(_ letter: String, in app: XCUIApplication) {
        let table = app.tables["library-index-track"]
        XCTAssertTrue(table.waitForExistence(timeout: 5))
        // Use the complete rail frame so tap coordinates match its equal letter regions.
        let index = app.descendants(matching: .any)["library-alphabet-rail"]
        if !index.waitForExistence(timeout: 5) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Synthetic native alphabet index accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(index.exists && index.isHittable)
        XCTAssertGreaterThan(index.frame.width, 0)
        XCTAssertGreaterThan(index.frame.height, 0)
        let titles = ["#"] + (65...90).map { String(UnicodeScalar($0)!) }
        guard let position = titles.firstIndex(of: letter) else {
            XCTFail("Requested letter must belong to the approved native index order")
            return
        }
        let fraction = (CGFloat(position) + 0.5) / CGFloat(titles.count)
        index.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: fraction)).tap()
    }

    func openAlphabetFixtureControls(_ app: XCUIApplication) {
        let button = app.buttons["Fixture controls"]
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        XCTAssertTrue(app.buttons["Close fixture controls"].waitForExistence(timeout: 5))
    }

    func closeAlphabetFixtureControls(_ app: XCUIApplication) {
        let close = app.buttons["Close fixture controls"]
        XCTAssertTrue(close.exists && close.isHittable)
        close.tap()
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["Fixture controls"].isHittable)
    }

    func toggleAlphabetNetwork(_ app: XCUIApplication, offline: Bool) {
        openAlphabetFixtureControls(app)
        let toggle = app.switches["Simulate unavailable network"].switches.firstMatch
        XCTAssertTrue(toggle.exists && toggle.isHittable)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, offline ? "1" : "0")
        closeAlphabetFixtureControls(app)
        XCTAssertEqual(
            app.buttons["Fixture controls"].value as? String, offline ? "offline" : "online")
    }

    func openNowPlaying(_ app: XCUIApplication) {
        let button = app.buttons["Show Now Playing"]
        XCTAssertTrue(button.waitForExistence(timeout: 5) && button.isHittable)
        button.tap()
        let opened = app.buttons["More playback options"].waitForExistence(timeout: 5)
        if !opened { capture("Player failed opening controls", in: app) }
        XCTAssertTrue(opened)
    }

    func relatedSheet(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["now-playing-related-sheet"]
    }

    func assertRelatedDetent(_ detent: String, in app: XCUIApplication) {
        let sheet = relatedSheet(app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        let settled = expectation(
            for: NSPredicate(format: "value == %@", detent), evaluatedWith: sheet)
        wait(for: [settled], timeout: 5)
    }

    func dragRelatedSheet(_ app: XCUIApplication, verticalDistance: CGFloat) {
        let sheet = relatedSheet(app)
        XCTAssertTrue(sheet.exists)
        let window = mainWindow(in: app)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(
                dx: sheet.frame.midX - window.frame.minX,
                dy: sheet.frame.minY + 12 - window.frame.minY))
        let startY = sheet.frame.minY + 12
        let endY = min(
            window.frame.maxY - 12, max(window.frame.minY + 12, startY + verticalDistance))
        let end = start.withOffset(CGVector(dx: 0, dy: endY - startY))
        start.press(
            forDuration: 0.1, thenDragTo: end, withVelocity: .slow,
            thenHoldForDuration: 0.2)
    }

    func expandRelatedSheet(_ app: XCUIApplication) {
        dragRelatedSheet(app, verticalDistance: -mainWindow(in: app).frame.height * 0.4)
        assertRelatedDetent("large", in: app)
    }

    func dragExpandedPlayerArtwork(_ app: XCUIApplication, distance: CGFloat) {
        let artwork = app.descendants(matching: .any)["fixture-player-expanded-artwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(artwork.frame.width, 0)
        XCTAssertGreaterThan(artwork.frame.height, 0)
        let window = mainWindow(in: app)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(
            CGVector(
                dx: artwork.frame.midX - window.frame.minX,
                dy: artwork.frame.midY - window.frame.minY))
        start.press(
            forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
            withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    func dismissNowPlaying(_ app: XCUIApplication) {
        dragExpandedPlayerArtwork(app, distance: mainWindow(in: app).frame.height * 0.5)
        let restored = expectation(
            for: NSPredicate(format: "exists == true AND hittable == true"),
            evaluatedWith: app.buttons["Show Now Playing"])
        wait(for: [restored], timeout: 5)
    }
}
