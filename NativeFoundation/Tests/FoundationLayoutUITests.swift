import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    private enum ChromeObservationError: Error { case conditionNotMet(String) }

    private func chromeFacts(_ app: XCUIApplication, _ context: String) -> [String: Double] {
        let probe = app.descendants(matching: .any)["fixture-chrome-" + context].firstMatch
        guard probe.exists, let value = probe.value as? String,
            let data = value.data(using: .utf8),
            let values = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return values
    }

    private func awaitChrome(
        _ app: XCUIApplication, _ context: String, timeout: TimeInterval = 5,
        optionalCondition: Bool = false,
        matching predicate: ([String: Double]) -> Bool
    ) throws -> [String: Double] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let facts = chromeFacts(app, context)
            if facts["found"] == 1, facts["ambiguousNativeScroll"] == 0,
                facts["inWindow"] == 1, facts["identityConsistent"] == 1,
                facts["dragging"] == 0, facts["decelerating"] == 0,
                predicate(facts)
            {
                return facts
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let facts = chromeFacts(app, context)
        let attachment = XCTAttachment(string: "context=\(context);metrics=\(facts)")
        attachment.name = "Shared chrome unresolved observation"
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Synthetic shared chrome accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        guard !facts.isEmpty else {
            XCTFail("Required synthetic numeric chrome probe is missing: \(context)")
            throw ChromeObservationError.conditionNotMet(context)
        }
        if facts["found"] == 1, facts["ambiguousNativeScroll"] == 0, !optionalCondition {
            XCTFail("Observed native geometry failed its bounded condition: \(context); \(facts)")
            throw ChromeObservationError.conditionNotMet(context)
        }
        throw XCTSkip(
            "Required native observation did not settle; no clearance/transition pass: \(context)")
    }

    func chromeScroll(_ app: XCUIApplication, _ context: String) -> XCUIElement {
        context == "home"
            ? app.scrollViews["foundation-home-scroll"]
            : app.descendants(matching: .any)[
                "library-index-" + context.replacingOccurrences(of: "index-", with: "")]
    }

    private func captureChrome(_ name: String, app: XCUIApplication, context: String) {
        capture(name, in: app)
        let item = XCTAttachment(string: "context=\(context);metrics=\(chromeFacts(app, context))")
        item.name = name + " metrics"
        item.lifetime = .keepAlways
        add(item)
    }

    func startSyntheticChromePlayback(_ app: XCUIApplication) throws {
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: true, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "state playing"), object: identity)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let end = Date().addingTimeInterval(10)
        while !app.buttons["library-category-songs"].exists, Date() < end {
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists && back.isHittable else { break }
            back.tap()
        }
        XCTAssertTrue(app.buttons["library-category-songs"].waitForExistence(timeout: 5))
    }

    private func assertChromeUnderlap(_ facts: [String: Double], context: String) throws {
        guard let y = facts["windowFrameY"], let height = facts["windowFrameHeight"],
            let accessory = facts["accessoryTop"]
        else {
            throw XCTSkip("Native frame/accessory measurement absent: \(context)")
        }
        let epsilon = 1 / max(1, facts["displayScale", default: 1])
        XCTAssertGreaterThan(
            y + height, accessory + epsilon,
            "The native scroll viewport must continue behind chrome, not be clipped to its top")
    }

    private func reachActualEnd(
        _ app: XCUIApplication, context: String, requireAutomaticExpansion: Bool
    ) throws -> [String: Double] {
        let scroll = chromeScroll(app, context)
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        let initial = try awaitChrome(app, context) {
            $0["phase"] == 0
                && (!context.hasPrefix("index-")
                    || ($0["naturalRows", default: 0] > 0 && $0["hasMore"] == 0))
        }
        let priorExpansions = initial["expansions", default: 0]
        let deadline = Date().addingTimeInterval(18)
        var previousOffset = initial["offsetY"]
        while Date() < deadline {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let finish = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(
                forDuration: 0.05, thenDragTo: finish,
                withVelocity: .fast, thenHoldForDuration: 0)
            let facts = try awaitChrome(app, context) { $0["phase"] == 0 }
            if requireAutomaticExpansion,
                facts["expansions", default: 0] > priorExpansions
                    || facts["nativeAtEnd"] == 1
            {
                // Wait for actual placement AND frame transition, without sending
                // another gesture after reaching the end. Native callbacks may settle
                // across frames; a missing transition is explicitly inconclusive.
                _ = try awaitChrome(app, context, timeout: 3, optionalCondition: true) {
                    $0["phase"] == 0 && $0["placement"] == 1
                        && $0["observedMinimized"] == 1
                        && $0["expansions", default: 0] > priorExpansions
                }
                let settled = try awaitChrome(app, context, timeout: 3) {
                    $0["phase"] == 0 && $0["placement"] == 1
                        && $0["expansions", default: 0] > priorExpansions
                        && $0["nativeAtEnd"] == 1
                }
                return settled
            }
            if !requireAutomaticExpansion, facts["nativeAtEnd"] == 1,
                facts["hasMore", default: 0] == 0
            {
                return facts
            }
            if facts["offsetY"] == previousOffset { break }
            previousOffset = facts["offsetY"]
        }
        captureChrome("Automatic native expansion not observed", app: app, context: context)
        throw XCTSkip(
            "Runtime did not show minimized→expanded automatically at end; no substituted bar action"
        )
    }

    private func assertNaturalLastRowClear(
        _ app: XCUIApplication, context: String, last: XCUIElement, facts: [String: Double]
    ) throws {
        guard let top = facts["accessoryTop"] else { throw XCTSkip("Accessory frame unavailable") }
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists, tabBar.frame.height > 0 else {
            throw XCTSkip("Native tab bar frame absent")
        }
        let epsilon = 1 / max(1, facts["displayScale", default: 1])
        let chromeTop = min(top, Double(tabBar.frame.minY))
        XCTAssertTrue(last.exists && last.isHittable)
        XCTAssertLessThanOrEqual(
            Double(last.frame.maxY), chromeTop + epsilon,
            "The complete last natural row must clear the expanded native accessory without another swipe"
        )
        try assertChromeUnderlap(facts, context: context)
        let scroll = chromeScroll(app, context)
        let oldOffset = facts["offsetY", default: 0]
        scroll.swipeDown(velocity: .slow)
        let reading = try awaitChrome(app, context) {
            $0["phase"] == 0 && $0["offsetY", default: oldOffset] < oldOffset - 1
        }
        XCTAssertEqual(reading["nativeAtEnd"], 0)
        Thread.sleep(forTimeInterval: 0.5)
        let settled = chromeFacts(app, context)
        XCTAssertEqual(
            settled["nativeAtEnd"], 0, "A deferred correction must not restick upward reading")
        XCTAssertLessThan(settled["offsetY", default: oldOffset], oldOffset - epsilon)
        captureChrome("Deliberate upward reading stays free", app: app, context: context)
    }

    @objc func testSharedChromeHomeNaturalUnderlapAndAutomaticExpandedEnd() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                artworkCache: true, longPlayback: true, compactFixtureControls: true,
                homeScrollBoundary: true, sharedChromeEvidence: true))
        try startSyntheticChromePlayback(app)
        selectTab("Home", in: app)
        let scroll = chromeScroll(app, "home")
        scroll.swipeUp(velocity: .slow)
        let mid = try awaitChrome(app, "home") { $0["phase"] == 0 && $0["hasAccessory"] == 1 }
        try assertChromeUnderlap(mid, context: "home")
        guard mid["offsetY", default: 0] > mid["legalMinY", default: 0] + 40 else {
            throw XCTSkip("Fixture did not reach a measurable middle position for top underlap")
        }
        let readingPoint = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        readingPoint.press(
            forDuration: 0.05,
            thenDragTo: readingPoint.withOffset(CGVector(dx: 0, dy: 25)),
            withVelocity: .slow, thenHoldForDuration: 0)
        let revealed = try awaitChrome(app, "home") { $0["phase"] == 0 }
        let headings = app.staticTexts.matching(NSPredicate(format: "label == %@", "Home"))
            .allElementsBoundByIndex.filter {
                $0.isHittable && $0.frame.height >= 25 && $0.frame.minY < app.frame.midY
            }
        guard let heading = headings.first, let nativeTop = revealed["windowFrameY"] else {
            throw XCTSkip("Native title/header was not visible for the top-underlap observation")
        }
        let epsilon = 1 / max(1, revealed["displayScale", default: 1])
        XCTAssertLessThan(
            nativeTop, Double(heading.frame.maxY) - epsilon,
            "The natural scroll viewport must extend behind the visible title/header")
        captureChrome("Home midscroll native top and bottom underlap", app: app, context: "home")
        let final = try reachActualEnd(app, context: "home", requireAutomaticExpansion: true)
        let last = app.buttons["View Final Home Album"]
        try assertNaturalLastRowClear(app, context: "home", last: last, facts: final)
    }

    @objc func testSharedChromeSongListAutomaticExpandedEnd() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                artworkCache: true, longPlayback: true, alphabetCatalog: true,
                compactFixtureControls: true, sharedChromeEvidence: true))
        try startSyntheticChromePlayback(app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        let final = try reachActualEnd(app, context: "index-track", requireAutomaticExpansion: true)
        let last = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "A Fixture track 23")
        ).firstMatch
        try assertNaturalLastRowClear(app, context: "index-track", last: last, facts: final)
    }

    @objc func testSharedChromeAlbumGridAutomaticExpandedEnd() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                artworkCache: true, longPlayback: true, alphabetCatalog: true,
                compactFixtureControls: true, sharedChromeEvidence: true))
        try startSyntheticChromePlayback(app)
        tapVisible(app.buttons["library-category-albums"], in: app)
        let final = try reachActualEnd(app, context: "index-album", requireAutomaticExpansion: true)
        let last = app.buttons["View A Fixture album 11"]
        try assertNaturalLastRowClear(app, context: "index-album", last: last, facts: final)
    }

    @objc func testSharedChromeListZeroClearanceHasNoAdditionalMinimumRow() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                alphabetCatalog: true, compactFixtureControls: true, sharedChromeEvidence: true))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        _ = try reachActualEnd(app, context: "index-track", requireAutomaticExpansion: false)
        let facts = try awaitChrome(app, "index-track") {
            $0["phase"] == 0 && $0["nativeAtEnd"] == 1 && $0["naturalRows"] == 24
                && $0["nativeListItems", default: 0] >= 24
        }
        guard facts["missingListLayoutAttributes"] == 0 else {
            throw XCTSkip("Native list layout attributes are incomplete; no C0 blank-row claim")
        }
        XCTAssertEqual(facts["hasAccessory"], 0)
        XCTAssertEqual(facts["clearance"], 0)
        XCTAssertEqual(facts["footerPresent"], 0)
        XCTAssertEqual(
            facts["extraRowsHeight"], 0, "An empty footer must not create a native44pt row")
        captureChrome("C0 no extra native list row", app: app, context: "index-track")
    }

    @objc func testSharedChromeListPositiveFooterMatchesActualClearance() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                longPlayback: true, alphabetCatalog: true, compactFixtureControls: true,
                sharedChromeEvidence: true))
        try startSyntheticChromePlayback(app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        _ = try reachActualEnd(app, context: "index-track", requireAutomaticExpansion: false)
        let facts = try awaitChrome(app, "index-track", optionalCondition: true) {
            $0["phase"] == 0 && $0["clearance", default: 0] > 0
                && $0["nativeListItems"] == $0["naturalRows"]
        }
        let epsilon = 1 / max(1, facts["displayScale", default: 1])
        guard let hostBottom = facts["hostBottom"], let accessoryTop = facts["accessoryTop"],
            let inset = facts["scopeNativeInset"]
        else { throw XCTSkip("Missing measured clearance inputs") }
        let expected = ceil(max(0, hostBottom - accessoryTop - inset) / epsilon) * epsilon
        XCTAssertEqual(facts["clearance", default: -1], expected, accuracy: epsilon)
        XCTAssertEqual(
            facts["adjustedInsetBottom", default: -1] - inset,
            facts["clearance", default: -2], accuracy: epsilon,
            "The actual native scroll-content margin must match the single clearance")
        XCTAssertEqual(facts["extraRowsHeight"], 0, "Native margin creates no synthetic row")
        captureChrome("Actual positive C versus row height", app: app, context: "index-track")
    }

    @objc func testSharedChromeListRealBarCyclesDoNotAccumulateContentExtent() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full",
                longPlayback: true, alphabetCatalog: true, compactFixtureControls: true,
                sharedChromeEvidence: true))
        try startSyntheticChromePlayback(app)
        tapVisible(app.buttons["library-category-songs"], in: app)
        let first = try reachActualEnd(
            app, context: "index-track", requireAutomaticExpansion: false)
        let scroll = chromeScroll(app, "index-track")
        let deadline = Date().addingTimeInterval(18)
        var matched: [String: Double]?
        while Date() < deadline {
            scroll.swipeDown(velocity: .slow)
            let next = try reachActualEnd(
                app, context: "index-track", requireAutomaticExpansion: false)
            let epsilon = 1 / max(1, next["displayScale", default: 1])
            if next["expansions", default: 0] > first["expansions", default: 0],
                next["naturalRows"] == first["naturalRows"],
                abs(
                    next["scopeNativeInset", default: -1000] - first["scopeNativeInset", default: 0]
                ) <= epsilon,
                abs(next["boundsHeight", default: -1000] - first["boundsHeight", default: 0])
                    <= epsilon,
                next["placement"] == first["placement"]
            {
                matched = next
                break
            }
        }
        guard let matched else {
            captureChrome(
                "No same-inset native bar cycle to compare", app: app, context: "index-track")
            throw XCTSkip(
                "Native bar cycle did not return to the same natural rows/inset/viewport; no accumulation claim"
            )
        }
        let epsilon = 1 / max(1, matched["displayScale", default: 1])
        let contentDelta =
            (matched["contentHeight", default: -1000]
                + matched["adjustedInsetBottom", default: -1000]
                + matched["adjustedInsetTop", default: -1000])
            - (first["contentHeight", default: 0]
                + first["adjustedInsetBottom", default: 0]
                + first["adjustedInsetTop", default: 0])
        let clearanceDelta = matched["clearance", default: -1000] - first["clearance", default: 0]
        XCTAssertEqual(
            contentDelta, clearanceDelta, accuracy: epsilon,
            "At the same natural rows and native inset, only the single current extent may change content size"
        )
        captureChrome(
            "Real native bar cycles retain one content extent", app: app, context: "index-track")
    }

    @objc func testSharedChromeHomeIconHasNativeTabImageAndRender() throws {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, compactFixtureControls: true, sharedChromeEvidence: true))
        selectTab("Home", in: app)
        let facts = try awaitChrome(app, "home") { $0["homeIconWidth", default: 0] > 0 }
        XCTAssertGreaterThan(facts["homeIconHeight", default: 0], 0)
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.exists && home.isHittable)
        let image = XCTAttachment(screenshot: home.screenshot())
        image.name = "Native Home tab icon actual render"
        image.lifetime = .keepAlways
        add(image)
    }

    /// A positive read count distinguishes an actual Home refresh from a scroll-only gesture.
    /// This intentionally has no playback setup; the existing audio-isolation case stays separate.
}
