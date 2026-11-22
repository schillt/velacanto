#if os(macOS)
    import AppKit
    import XCTest

    /// Runs outside the app so the actual SwiftUI Scene owns accessibility discovery.
    @MainActor
    final class FoundationRootLyricsRetirementUITests: XCTestCase {
        func testActualRootSignOutRetiresHeldLyricsWithoutChangingSelectedOccurrence() {
            continueAfterFailure = false
            guard
                let expectedPath = ProcessInfo.processInfo.environment[
                    "FOUNDATION_ROOT_LYRICS_EXPECTED_APP_PATH"], !expectedPath.isEmpty
            else { return XCTFail("Use the qualified driver to identify the exact isolated app") }
            let expectedApp = URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath()
                .standardizedFileURL
            let app = XCUIApplication()
            app.launchArguments = ["-foundationTesting", "-foundationRootLyricsRetirement"]
            addTeardownBlock { @MainActor in
                if self.testRun?.failureCount ?? 0 > 0 {
                    let capture = XCTAttachment(screenshot: app.screenshot())
                    capture.name = "Actual isolated root failure"
                    capture.lifetime = .keepAlways
                    self.add(capture)
                    let tree = XCTAttachment(string: app.debugDescription)
                    tree.name = "Actual isolated Scene accessibility"
                    tree.lifetime = .keepAlways
                    self.add(tree)
                }
                let abort = app.buttons["root-retirement-abort"]
                if abort.exists { abort.click() }
                app.terminate()
            }
            app.launch()
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.chameleonenterprise.velacanto.isolationtesting"
            ).filter { !$0.isTerminated }
            let identity = XCTAttachment(
                string: "Expected app: \(expectedApp.path)\nRunning instances: "
                    + running.map {
                        "pid=\($0.processIdentifier);bundle=\($0.bundleURL?.path ?? "missing");"
                            + "executable=\($0.executableURL?.path ?? "missing")"
                    }.joined(separator: "\n"))
            identity.name = "Actual launched isolated binary identity"
            identity.lifetime = .keepAlways
            add(identity)
            guard running.count == 1, let launched = running.first else {
                return XCTFail("Expected exactly one running isolated application")
            }
            guard launched.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == expectedApp,
                launched.executableURL?.resolvingSymlinksInPath().standardizedFileURL
                    == expectedApp.appendingPathComponent("Contents/MacOS/VelacantoIsolation")
            else { return XCTFail("The launched app is not the verified isolated build") }
            if app.windows.count == 0 {
                // Open the declared real Scene through its public native command.
                // Never substitute private RootView state or a guessed coordinate.
                app.activate()
                let file = app.menuBars.menuBarItems["File"]
                XCTAssertTrue(file.exists)
                file.click()
                let newWindow = file.menus.menuItems["New Window"]
                XCTAssertTrue(newWindow.exists)
                XCTAssertTrue(newWindow.isEnabled)
                newWindow.click()
            }
            let phase = app.staticTexts["root-retirement-phase"]
            let facts = app.staticTexts["root-retirement-facts"]
            func waitForPhase(_ value: String, timeout: TimeInterval = 5) {
                let matches = NSPredicate(format: "value == %@", value)
                XCTAssertEqual(
                    XCTWaiter.wait(
                        for: [XCTNSPredicateExpectation(predicate: matches, object: phase)],
                        timeout: timeout), .completed)
            }
            func assertFacts(_ expected: [String]) {
                let observedValue = facts.value as? String ?? ""
                let observed = observedValue.split(separator: ";").map(String.init)
                for fact in expected {
                    XCTAssertTrue(observed.contains(fact), "Missing \(fact) in \(observedValue)")
                }
            }
            func clickFixtureControl(_ identifier: String) {
                let control = app.buttons[identifier]
                XCTAssertTrue(control.exists)
                XCTAssertTrue(control.isEnabled)
                let frame = control.frame
                XCTAssertTrue(
                    app.windows.firstMatch.frame.contains(frame),
                    "Fixture control lies outside its actual app window: \(identifier) \(frame)")
                guard let primary = NSScreen.screens.first else {
                    return XCTFail("No desktop screen is available for the fixture control")
                }
                // XCTest uses top-left desktop coordinates; AppKit screen frames use bottom-left.
                let inWorkArea = NSScreen.screens.contains { screen in
                    let visible = screen.visibleFrame
                    let workArea = CGRect(
                        x: visible.minX, y: primary.frame.maxY - visible.maxY,
                        width: visible.width, height: visible.height)
                    return workArea.contains(frame)
                }
                XCTAssertTrue(
                    inWorkArea,
                    "Fixture control overlaps the Dock/menu bar or lies offscreen: \(identifier) \(frame)"
                )
                XCTAssertTrue(control.isHittable, "Fixture control is obscured: \(identifier)")
                control.click()
            }
            waitForPhase("ready")
            let lyrics = app.buttons["Show lyrics"]
            XCTAssertTrue(lyrics.waitForExistence(timeout: 3))
            XCTAssertTrue(lyrics.isEnabled)
            let negativeControl = ProcessInfo.processInfo.environment[
                "FOUNDATION_ROOT_LYRICS_NEGATIVE_CONTROL"]
            XCTAssertTrue(
                negativeControl == nil || negativeControl == "omit-press",
                "Unknown runner-only root lyrics negative control")
            if negativeControl == "omit-press" {
                assertFacts(["requests=0"])
                let control = XCTAttachment(
                    string:
                        "Runner-only negative control: omitted the actual Show lyrics press. "
                        + "The unchanged provider-entry wait must fail. Actual fixture facts: "
                        + (facts.value as? String ?? "unavailable"))
                control.name = "Missing actual lyrics press failure control"
                control.lifetime = .keepAlways
                add(control)
            } else {
                lyrics.click()
            }
            waitForPhase("provider-entered")
            let inspector = app.descendants(matching: .any)["mac-playback-sidebar"]
            XCTAssertTrue(inspector.waitForExistence(timeout: 3))
            assertFacts(["requests=1", "held=true", "selection=true", "unrelated=true"])
            clickFixtureControl("root-retirement-signout")
            assertFacts(["signout-invoked=true"])
            waitForPhase("provider-cancelled")
            let removed = NSPredicate(format: "exists == false")
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: removed, object: inspector)],
                    timeout: 3), .completed)
            let rootRemoved = NSPredicate(format: "value CONTAINS %@", "root-gone=true")
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: rootRemoved, object: facts)],
                    timeout: 3), .completed)
            XCTAssertFalse(lyrics.exists)
            assertFacts(["held=true", "cancelled=true", "selection=true", "root-gone=true"])
            clickFixtureControl("root-retirement-release")
            waitForPhase("provider-returned")
            clickFixtureControl("root-retirement-inspect")
            waitForPhase("inspected")
            XCTAssertTrue(app.staticTexts["Sign in to VelaCanto"].waitForExistence(timeout: 3))
            XCTAssertFalse(lyrics.exists)
            XCTAssertFalse(inspector.exists)
            XCTAssertFalse(app.staticTexts["Retired account lyrics must never appear"].exists)
            assertFacts([
                "requests=1", "held=false", "cancelled=true", "returned=true", "selection=true",
                "unrelated=true", "root-gone=true", "permits=0", "cleanup-error=false",
                "cleaning=false",
            ])
            if app.sheets.count > 0 {
                XCTAssertEqual(app.sheets.count, 1)
                let notice = app.sheets.firstMatch
                XCTAssertTrue(
                    notice.staticTexts.matching(NSPredicate(format: "value == %@", "Sign-out"))
                        .firstMatch.exists,
                    "Only the actual production Sign-out notice may be acknowledged")
                let acknowledge = notice.buttons["OK"]
                XCTAssertTrue(acknowledge.exists)
                XCTAssertTrue(acknowledge.isEnabled)
                acknowledge.click()
                XCTAssertEqual(
                    XCTWaiter.wait(
                        for: [XCTNSPredicateExpectation(predicate: removed, object: notice)],
                        timeout: 3), .completed)
            }
            clickFixtureControl("root-retirement-clean")
            waitForPhase("cleaned")
        }
    }
#endif
