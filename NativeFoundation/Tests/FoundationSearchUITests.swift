import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testSearchUpdatesWhileTypingWithoutSubmitAndRetiresRapidReplacement() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, compactFixtureControls: true))
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Fixture Artist")
        let result = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Artist")
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.isHittable, "Typed results must render before keyboard dismissal")
        XCTAssertEqual(field.value as? String, "Fixture Artist")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.exists)
        XCTAssertGreaterThan(keyboard.frame.height, 0)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(keyboard.frame))
        capture("Live search shows typed results without Enter", in: app)

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
        field.typeText("Fixture Al")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        field.typeText("NoSuchLiveMatch")
        let empty = app.staticTexts["No results found."]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "NoSuchLiveMatch")
        XCTAssertFalse(result.exists, "An obsolete typed query must not retain visible rows")
        XCTAssertTrue(keyboard.exists)
        capture("Rapid typed query replacement rejects obsolete results without Enter", in: app)
    }

    @objc func testSearchReportsUnwalkedFallbackWithNoVisibleMatches() {
        continueAfterFailure = false
        let app = launch(.searchCoverage)
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Zorlan")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)

        // Accessible static text verifies exposure to assistive technology. It does
        // not simulate VoiceOver speech or replace a physical accessibility check.
        let notice = app.staticTexts["More close matches may exist. Narrow your search."]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.isHittable)
        let empty = app.staticTexts["No matches in the pages checked."]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.isHittable)
        XCTAssertFalse(app.staticTexts["No results found."].exists)
        let counts = app.buttons["Read catalog counts"]
        tapNativeChrome(counts, in: app)
        let firstRead = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "bounded-track-zor-0 "),
            object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [firstRead], timeout: 5), .completed)
        XCTAssertFalse((counts.value as? String ?? "").contains("bounded-track-zor-50 "))
        capture("Bounded fuzzy search reports incomplete empty results", in: app)

        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Zorlan".count))
        field.typeText("Silent")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)
        let noResults = app.staticTexts["No results found."]
        XCTAssertTrue(noResults.waitForExistence(timeout: 10))
        for _ in 0..<5 {
            tapNativeChrome(counts, in: app)
            if (counts.value as? String ?? "").contains("bounded-track-silent-0 ") { break }
        }
        let secondRead = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "bounded-track-silent-0 "),
            object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [secondRead], timeout: 5), .completed)
        let oldNoticeGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [oldNoticeGone], timeout: 5), .completed)
        XCTAssertFalse(empty.exists)
    }

    @objc func testSearchEmptyFallbackContinuesAtVisibleEndWithoutScanningFurtherPages() {
        continueAfterFailure = false
        let app = launch(.searchCoverage)
        let counts = app.buttons["Read catalog counts"]
        func readCounts(containing key: String) -> [String: Int] {
            tapNativeChrome(counts, in: app)
            let refreshed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value CONTAINS %@", key + " "), object: counts)
            XCTAssertEqual(XCTWaiter.wait(for: [refreshed], timeout: 5), .completed)
            return Dictionary(
                uniqueKeysWithValues: (counts.value as? String ?? "")
                    .split(separator: ",").compactMap { entry -> (String, Int)? in
                        let fields = entry.split(separator: " ")
                        guard fields.count == 2, let count = Int(fields[1]) else { return nil }
                        return (String(fields[0]), count)
                    })
        }
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Zorlan")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)
        let overviewNotice = app.staticTexts["More close matches may exist. Narrow your search."]
        XCTAssertTrue(overviewNotice.waitForExistence(timeout: 10))
        let songs = app.buttons["See all songs"]
        XCTAssertTrue(
            songs.waitForExistence(timeout: 5), "An empty first page must keep Songs reachable")
        XCTAssertTrue(songs.isHittable)
        let initial = readCounts(containing: "bounded-track-zor-0")
        XCTAssertEqual(initial["bounded-track-zorlan-0"], 1)
        XCTAssertEqual(initial["bounded-track-zor-0"], 1)
        XCTAssertNil(
            initial["bounded-track-zor-50"], "The overview must not walk the fallback cursor")
        tapVisibleCenter(songs, in: app)

        let notice = app.staticTexts[
            "More close matches may exist. Continue scrolling to search further."]
        let match = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zorlan"))
            .firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        XCTAssertTrue(match.isHittable)
        XCTAssertFalse(app.buttons["Load more"].exists)
        let exhausted = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [exhausted], timeout: 5), .completed)
        let continued = readCounts(containing: "bounded-track-zor-50")
        XCTAssertEqual(
            continued["bounded-track-zorlan-0"], 1, "The category reuses its scoped overview seed")
        XCTAssertEqual(continued["bounded-track-zor-0"], 1)
        XCTAssertEqual(
            continued["bounded-track-zor-50"], 1, "The visible end requests exactly one next page")
        XCTAssertNil(continued["bounded-track-zor-100"])
        XCTAssertNil(continued["bounded-track-zorlan-50"])
        capture("Visible end reveals the next match without a continuation button", in: app)

        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "BackButton").count, 1)
        XCTAssertTrue(back.isHittable)
        tapNativeChrome(back, in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Zorlan".count))
        field.typeText("Silent")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)
        XCTAssertTrue(app.staticTexts["No results found."].waitForExistence(timeout: 10))
        XCTAssertFalse(match.exists)
        XCTAssertFalse(overviewNotice.exists)
        XCTAssertFalse(notice.exists)
        let retired = readCounts(containing: "bounded-track-silent-0")
        XCTAssertEqual(
            retired["bounded-track-zor-50"], 1, "Query retirement must not restart the old stream")
        XCTAssertNil(retired["bounded-track-zor-100"])
        capture("New query retires continued search rows and fallback notice", in: app)
    }

    @objc func testPlaylistSearchStartsBelowFoldAndSharesProgressWithSeeAll() {
        continueAfterFailure = false
        let app = launch(.playlistSearch)
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Opalite")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)
        let counts = app.buttons["Read catalog counts"]
        // Read the fixture's actual request counter before scrolling to the
        // below-fold section; startup must not depend on exposing its rows.
        for _ in 0..<5 {
            tapNativeChrome(counts, in: app)
            if (counts.value as? String ?? "").contains("playlist-search 1") { break }
        }
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "playlist-search 1"), object: counts
        )
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
        let progress = app.descendants(matching: .any)["search-playlists-progress"].firstMatch
        revealPlaylistSearchElement(progress, in: app)
        XCTAssertGreaterThan(progress.frame.height, 0)
        XCTAssertFalse(app.buttons["search-playlist-check-more"].exists)
        capture(
            "Zero-match playlist search progresses automatically below earlier sections", in: app)
        tapNativeChrome(app.buttons["Release playlist search batch"], in: app)
        let seeAll = app.buttons["See all Playlists with “Opalite”"]
        XCTAssertTrue(seeAll.waitForExistence(timeout: 5))
        revealPlaylistSearchElement(seeAll, in: app, requiresTap: true)
        seeAll.tap()
        XCTAssertTrue(app.navigationBars["Playlists with “Opalite”"].waitForExistence(timeout: 5))
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        tapNativeChrome(counts, in: app)
        XCTAssertTrue((counts.value as? String ?? "").contains("playlist-search 2"))
        capture("See All shares in-flight automatic playlist search", in: app)
        tapNativeChrome(app.buttons["Release playlist search batch"], in: app)
        let dayDrive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Day Drive"))
            .firstMatch
        XCTAssertTrue(dayDrive.waitForExistence(timeout: 5))
        revealPlaylistSearchElement(
            dayDrive, in: app, scrollID: "foundation-playlist-lookup-scroll", requiresTap: true)
        let finished = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 5), .completed)
        tapNativeChrome(counts, in: app)
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "playlist-search 2"), object: counts
        )
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
        XCTAssertFalse((counts.value as? String ?? "").contains("playlist-search-cancelled"))
        capture("Day Drive appears after the automatic continuation completes", in: app)
    }

    @objc func testPlaylistSearchCancelsHeldBatchWhenLeavingSearch() {
        continueAfterFailure = false
        let app = launch(.playlistSearch)
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Opalite")
        tapNativeChrome(app.buttons["Dismiss search keyboard"], in: app)
        let counts = app.buttons["Read catalog counts"]
        for _ in 0..<5 {
            tapNativeChrome(counts, in: app)
            if (counts.value as? String ?? "").contains("playlist-search 1") { break }
        }
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "playlist-search 1"), object: counts
        )
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 5), .completed)
        let progress = app.descendants(matching: .any)["search-playlists-progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        selectFreshHomeFromSearch(in: app)
        tapNativeChrome(counts, in: app)
        let cancelled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "playlist-search-cancelled 1"),
            object: counts)
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 5), .completed)
        XCTAssertTrue((counts.value as? String ?? "").contains("playlist-search 1"))
        tapNativeChrome(app.buttons["Release playlist search batch"], in: app)
        XCTAssertFalse(progress.exists)
        capture("Leaving Search cancels its held playlist batch", in: app)
    }

    /// This fixture starts at the Home root before opening Search.

    private func selectFreshHomeFromSearch(in app: XCUIApplication) {
        if app.tabBars.buttons["Home"].firstMatch.exists {
            selectTab("Home", in: app)
        } else {
            let match = NSPredicate(format: "label == %@", "Home")
            func homeControls() -> [XCUIElement] {
                (app.buttons.matching(match).allElementsBoundByIndex
                    + app.popUpButtons.matching(match).allElementsBoundByIndex)
                    .filter { $0.exists && $0.isHittable }
            }
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated { homeControls().count == 1 }
                }, object: nil)
            guard XCTWaiter.wait(for: [available], timeout: 5) == .completed else {
                capture("Adaptive Home unavailable", in: app)
                captureDiagnosticText("Adaptive Home accessibility hierarchy", app.debugDescription)
                XCTFail("Adaptive Home has no unique hittable control")
                return
            }
            let controls = homeControls()
            guard controls.count == 1, let control = controls.first,
                control.exists, control.isHittable
            else {
                capture("Adaptive Home became unavailable", in: app)
                captureDiagnosticText("Adaptive Home accessibility hierarchy", app.debugDescription)
                XCTFail("Adaptive Home control became unavailable before tapping")
                return
            }
            control.tap()
        }
        let heading = app.staticTexts["browsing-screen-title-Home"]
        let visibleHome = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: heading)
        XCTAssertEqual(
            XCTWaiter.wait(for: [visibleHome], timeout: 5), .completed,
            "Home destination was not visible after leaving Search")
    }

    /// Progress is not a tappable control. Reveal it in its actual result scroll,
    /// without asking decorative indicators or hidden profile chrome for a tap point.

    private func revealPlaylistSearchElement(
        _ element: XCUIElement, in app: XCUIApplication,
        scrollID: String = "foundation-search-results-scroll", requiresTap: Bool = false
    ) {
        let scroll = app.scrollViews[scrollID]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        var geometry: [String] = []
        var previousPositions: [String: CGFloat]?
        var previousDirectionWasUp = true
        for attempt in 0...8 {
            let viewport = playlistSearchViewport(scroll, in: app)
            let frame = element.exists ? element.frame : .zero
            let albums = scroll.staticTexts["Related Albums"].firstMatch
            let playlists = scroll.staticTexts["Playlists"].firstMatch
            var positions: [String: CGFloat] = [:]
            if element.exists, frame.height > 0 {
                let identifier = element.identifier
                let label = element.label
                let predicate: NSPredicate? =
                    if !identifier.isEmpty {
                        NSPredicate(format: "identifier == %@", identifier)
                    } else if !label.isEmpty {
                        NSPredicate(format: "label == %@", label)
                    } else { nil }
                if let predicate {
                    let scoped = scroll.descendants(matching: .any).matching(predicate)
                        .allElementsBoundByIndex.filter { $0.exists && $0.frame == frame }
                    if scoped.count == 1 { positions["target"] = frame.midY }
                }
            }
            if albums.exists { positions["albums"] = albums.frame.midY }
            if playlists.exists { positions["playlists"] = playlists.frame.midY }
            geometry.append(
                "attempt=\(attempt) app=\(app.frame) scroll=\(scroll.frame) viewport=\(viewport) "
                    + "targetExists=\(element.exists) target=\(frame) "
                    + "albums=\(albums.exists ? String(describing: albums.frame) : "absent") "
                    + "playlists=\(playlists.exists ? String(describing: playlists.frame) : "absent")"
            )
            if frame.width.isFinite, frame.height.isFinite,
                frame.minX.isFinite, frame.minY.isFinite, frame.width > 0, frame.height > 0,
                !frame.intersection(viewport).isEmpty,
                !requiresTap
                    || (viewport.contains(CGPoint(x: frame.midX, y: frame.midY))
                        && element.isHittable)
            {
                captureDiagnosticText("Search scroll geometry", geometry.joined(separator: "\n"))
                return
            }
            if let previousPositions {
                let movement = positions.compactMap { name, position -> CGFloat? in
                    guard let previous = previousPositions[name] else { return nil }
                    return previousDirectionWasUp ? previous - position : position - previous
                }
                if movement.isEmpty {
                    geometry.append("Scroll movement unknown: no common scoped anchor")
                } else if !movement.contains(where: { $0 > 2 }) {
                    geometry.append("No measurable movement after prior drag: \(movement)")
                    break
                }
            }
            guard attempt < 8 else { break }
            let upward = frame.height <= 0 || frame.midY >= viewport.midY
            previousPositions = positions
            previousDirectionWasUp = upward
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(
                    dx: viewport.midX - app.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.85 : 0.15) - app.frame.minY))
            let end = origin.withOffset(
                CGVector(
                    dx: viewport.midX - app.frame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.15 : 0.85) - app.frame.minY))
            start.press(
                forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        capture("Search target not visible after bounded result-scroll drags", in: app)
        captureDiagnosticText("Search scroll geometry", geometry.joined(separator: "\n"))
        captureDiagnosticText("Search viewport accessibility hierarchy", app.debugDescription)
        XCTFail("Search target must intersect the actual results viewport")
    }

    private func playlistSearchViewport(_ scroll: XCUIElement, in app: XCUIApplication) -> CGRect {
        let original = scroll.frame.intersection(app.frame)
        XCTAssertFalse(original.isEmpty || original.isNull)
        var top = original.minY
        var bottom = original.maxY
        for bar in app.navigationBars.allElementsBoundByIndex {
            let frame = bar.frame
            if frame.intersects(original), frame.minY < original.midY {
                top = max(top, frame.maxY)
            }
        }
        let search = app.textFields["Search music"]
        if search.exists {
            let frame = search.frame
            if frame.intersects(original), frame.minY < original.midY {
                top = max(top, frame.maxY + 8)
            }
        }
        if app.tabBars.firstMatch.exists {
            let frame = app.tabBars.firstMatch.frame
            if frame.intersects(original), frame.minY > original.midY {
                bottom = min(bottom, frame.minY)
            }
        }
        let viewport = CGRect(
            x: original.minX + 8, y: top + 8,
            width: max(0, original.width - 16), height: max(0, bottom - top - 16))
        XCTAssertTrue(
            viewport.minX.isFinite && viewport.minY.isFinite
                && viewport.width.isFinite && viewport.height.isFinite)
        XCTAssertGreaterThan(viewport.width, 44)
        XCTAssertGreaterThan(viewport.height, 44)
        return viewport
    }

    @objc func testSearchLiquidGlassReducedEffectsLargeTextKeepsQueryAndFocus() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, largeText: true, canonicalDownloadState: "full",
                reducedAccessibilityEffects: true))
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["Search music"]
        field.typeText("Fixture")
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        XCTAssertEqual(
            app.staticTexts["fixture-accessibility-effects"].label,
            "Synthetic accessibility: reduced motion, reduced transparency")
        capture("Accessible opaque Search bubble active with large text", in: app)
        dismiss.tap()
        let hidden = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 5)
        XCTAssertEqual(field.value as? String, "Fixture")
        XCTAssertFalse(dismiss.exists)
        capture("Accessible Search dismissal preserves query without glass morph", in: app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
    }

    @objc func testSearchRepeatedOpeningAndFocusReentryKeepsDismissalResponsive() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, canonicalDownloadState: "full"))
        selectTab("Search", in: app)
        let field = app.textFields["Search music"]
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        field.typeText("Fixture")
        for _ in 0..<5 {
            dismiss.tap()
            XCTAssertTrue(dismiss.waitForNonExistence(timeout: 3))
            field.tap()
            XCTAssertTrue(dismiss.waitForExistence(timeout: 1))
            XCTAssertTrue(dismiss.isHittable)
            XCTAssertEqual(field.value as? String, "Fixture")
        }
        dismiss.tap()
        field.tap()
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 3))
        selectTab("Library", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(dismiss.waitForExistence(timeout: 1) && dismiss.isHittable)
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 3))
        XCTAssertEqual(field.value as? String, "Fixture")
        capture("Repeated Search split merge and tab reentry preserves query", in: app)
    }

    @objc func testSearchKeyboardAutofocusCancelManualFocusAndReentryPreserveQuery() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, canonicalDownloadState: "full"))
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let field = app.textFields["Search music"]
        XCTAssertTrue(field.exists)
        field.typeText("Fixture")
        let dismiss = app.buttons["search-dismiss-keyboard"]
        XCTAssertTrue(dismiss.exists && dismiss.isHittable)
        XCTAssertGreaterThanOrEqual(dismiss.frame.width, 44)
        XCTAssertGreaterThanOrEqual(dismiss.frame.height, 44)
        capture("Active Search bar and separate 44 point Liquid Glass bubble", in: app)
        dismiss.tap()
        let hidden = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: app.keyboards.firstMatch)
        wait(for: [hidden], timeout: 5)
        XCTAssertEqual(field.value as? String, "Fixture")
        XCTAssertFalse(app.buttons["search-dismiss-keyboard"].exists)
        capture("Inactive Search bar after bubble merges query preserved", in: app)
        scrollContent(in: app)
        XCTAssertFalse(
            app.keyboards.firstMatch.exists, "Cancelled visit must not refocus on redraw")
        for _ in 0..<8 {
            if field.exists && field.isHittable { break }
            scrollContent(in: app, upward: false)
        }
        XCTAssertTrue(field.exists && field.isHittable)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
        app.buttons["search-dismiss-keyboard"].tap()
        selectTab("Library", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Fixture")
        capture("Search native focus reentry keeps query", in: app)
    }

    @objc func testLibraryTypedListsPagedDedupRetryEndAndScopedSearch() {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, pagedCatalog: true, catalogPageFailOnce: true))
        selectTab("Library", in: app)
        for (category, kind) in [
            ("Albums", "album"), ("Artists", "artist"), ("Songs", "track"),
            ("Playlists", "playlist"),
        ] {
            tapVisible(app.buttons["library-category-" + category.lowercased()], in: app)
            XCTAssertTrue(
                app.descendants(matching: .any)["library-index-" + kind]
                    .waitForExistence(timeout: 5))
            if kind != "track" {
                XCTAssertFalse(
                    app.descendants(matching: .any).matching(
                        NSPredicate(format: "label == %@", "Section index")
                    ).firstMatch.exists)
            }
            let skeleton = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Loading")
            ).firstMatch
            XCTAssertTrue(skeleton.waitForExistence(timeout: 5))
            capture("Native typed Library index " + kind + " viewport skeleton", in: app)
            let release = app.buttons["Release initial catalog page"]
            XCTAssertTrue(release.exists && release.isHittable)
            release.tap()
            let last = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Paged " + kind + " 11")
            ).firstMatch
            for _ in 0..<12 {
                if app.buttons["Retry"].exists || last.exists { break }
                scrollContent(in: app)
            }
            XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 5))
            capture("Typed Library page error retains first page " + kind, in: app)
            tapVisible(app.buttons["Retry"], in: app)
            reveal(last, in: app)
            XCTAssertTrue(last.exists)
            XCTAssertFalse(app.buttons["Load more"].exists)
            let duplicate = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "Paged " + kind + " 5"))
            reveal(duplicate.firstMatch, in: app)
            XCTAssertEqual(
                duplicate.count, 1, "Overlapping provider page must deduplicate item identity")
            capture("Typed Library complete paged list " + kind, in: app)
            if kind == "album" {
                let field = app.searchFields["Search albums"]
                for _ in 0..<16 {
                    if field.exists && field.isHittable { break }
                    scrollContent(in: app, upward: false)
                }
                tapNativeChrome(field, in: app)
                field.typeText("Paged album 10")
                let result = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Paged album 10")
                ).firstMatch
                XCTAssertTrue(result.waitForExistence(timeout: 10))
                XCTAssertFalse(
                    app.buttons.matching(
                        NSPredicate(format: "label BEGINSWITH %@", "Paged album 0")
                    ).firstMatch.exists)
                capture("Scoped Library search finds item beyond first browse page", in: app)
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
                field.typeText("slow")
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4))
                let clearedValue = field.value as? String ?? ""
                XCTAssertTrue(clearedValue.isEmpty || clearedValue == "Search albums")
                tapNativeChrome(app.navigationBars["Albums"].buttons["Close"], in: app)
                let keyboardDismissed = expectation(
                    for: NSPredicate(format: "exists == false"),
                    evaluatedWith: app.keyboards.firstMatch)
                wait(for: [keyboardDismissed], timeout: 5)
                reveal(last, in: app)
                XCTAssertTrue(
                    last.exists, "Clearing pending scoped query restores complete baseline")
            }
            app.navigationBars.buttons.firstMatch.tap()
        }
        tapNativeChrome(app.buttons["Read catalog counts"], in: app)
        let counts = app.staticTexts["fixture-catalog-counts"].label
        for kind in ["album", "artist", "track", "playlist"] {
            XCTAssertTrue(counts.contains(kind + "-browse-6 2"), counts)
            XCTAssertFalse(counts.contains(kind + "-browse-12"), counts)
        }
        XCTAssertTrue(counts.contains("album-Paged album 10-0 1"), counts)
        capture("Bounded typed catalog requests after page end", in: app)
    }

    @objc func testPartialTrackDiscoversAlbumArtistPlaylistAndOfflineSearchAfterColdLaunch() {
        assertPartialMembership(mode: "track")
    }

    @objc func testPartialAlbumDiscoversUnownedPlaylistAndOfflineSearchAfterColdLaunch() {
        assertPartialMembership(mode: "album")
    }

    private func assertPartialMembership(mode: String) {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, membership: mode))
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        app.terminate()
        app.launchArguments.append("-fixtureStartOffline")
        app.launch()
        XCTAssertTrue(app.staticTexts["Membership fixture ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.descendants(matching: .any)["browsing-offline-status"].waitForExistence(timeout: 5))
        app.buttons["Library"].firstMatch.tap()
        for (category, title) in [
            ("albums", "Fixture Album"), ("artists", "Fixture Artist"),
            ("playlists", "Fixture Playlist"),
        ] {
            tapVisible(app.buttons["library-category-" + category], in: app)
            let match = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                .firstMatch
            XCTAssertTrue(match.waitForExistence(timeout: 5))
            match.tap()
            if category == "artists" {
                let album = app.buttons.matching(
                    NSPredicate(format: "label BEGINSWITH %@", "Fixture Album")
                ).firstMatch
                tapVisible(album, in: app)
            }
            let playable = app.buttons["collection-track-0"]
            let missing = app.buttons["collection-track-1"]
            XCTAssertTrue(playable.waitForExistence(timeout: 5))
            XCTAssertTrue(playable.isEnabled)
            XCTAssertTrue(missing.exists)
            XCTAssertFalse(missing.isEnabled)
            XCTAssertTrue((missing.value as? String ?? "").contains("unavailable offline"))
            XCTAssertTrue(app.buttons["Play"].isEnabled)
            capture("Cold offline partial " + mode + " discovers " + category, in: app)
            app.navigationBars.buttons.firstMatch.tap()
            if category == "artists" { app.navigationBars.buttons.firstMatch.tap() }
            app.navigationBars.buttons.firstMatch.tap()
        }
        selectTab("Home", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["offline-notice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
        selectTab("Search", in: app)
        let search = app.textFields["Search music"]
        XCTAssertTrue(search.waitForExistence(timeout: 5) && search.isEnabled)
        search.tap()
        search.typeText("Fixture")
        // The keyboard obscures lower native result sections; dismiss through normal scrolling.
        scrollContent(in: app)
        XCTAssertTrue(
            app.staticTexts["Searching downloaded music and saved collections."].waitForExistence(
                timeout: 5))
        for title in ["Fixture Tone", "Fixture Album", "Fixture Artist", "Fixture Playlist"] {
            let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                .firstMatch
            for _ in 0..<8 {
                if result.exists { break }
                scrollContent(in: app)
            }
            XCTAssertTrue(result.exists, "Missing local search result: " + title)
        }
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Missing Tone"))
                .firstMatch.exists)
        capture("Offline local search includes playable track and related collections", in: app)
        app.buttons["offline-status-retry"].tap()
        XCTAssertTrue(app.switches["Simulate unavailable network"].waitForExistence(timeout: 5))
        let online = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "0"),
            object: app.switches["Simulate unavailable network"])
        XCTAssertEqual(XCTWaiter.wait(for: [online], timeout: 5), .completed)
        XCTAssertTrue(search.isEnabled)
        let onlineMissing = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Missing Tone")
        ).firstMatch
        for _ in 0..<8 {
            if onlineMissing.exists { break }
            scrollContent(in: app, upward: false)
        }
        XCTAssertTrue(onlineMissing.waitForExistence(timeout: 5))
        XCTAssertTrue(onlineMissing.isEnabled)
        capture("Explicit Retry restores online search without losing navigation", in: app)
    }
}
