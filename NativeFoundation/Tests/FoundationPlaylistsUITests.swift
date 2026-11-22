import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testNativePlaylistOccurrenceDragAndActionsPreservePlayingQueue() {
        assertNativePlaylistReorderPreservesQueue(failOnce: false)
    }

    @objc func testNativePlaylistUnconfirmedMoveRequiresRefreshAndPreservesPlayingQueue() {
        assertNativePlaylistReorderPreservesQueue(failOnce: true)
    }

    private func assertNativePlaylistReorderPreservesQueue(failOnce: Bool) {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                longPlayback: true, compactFixtureControls: true, playlistReorder: true,
                playlistReorderFailOnce: failOnce))
        selectTab("Library", in: app)
        openCanonicalCollection("playlist", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let identity = app.staticTexts["fixture-playback-identity"]
        let playing = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "state playing"), object: identity)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        let baselineIdentity = identity.label
        let baselineQueue = queueSnapshot(app)
        XCTAssertEqual((baselineQueue["queue"] as? [String])?.count, 3)
        tapNativeChrome(app.buttons["More actions"], in: app)
        let open = app.buttons["Manage Playlist"]
        XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isHittable)
        open.tap()
        XCTAssertTrue(app.navigationBars["Manage Playlist"].waitForExistence(timeout: 5))
        let first = app.staticTexts["playlist-reorder-occurrence-0"]
        let last = app.staticTexts["playlist-reorder-occurrence-2"]
        // Rows are virtualized: occurrence zero can be offscreen after an authoritative reorder.
        let managers = app.collectionViews.matching(
            NSPredicate(format: "identifier != %@", "collection-detail-playlist-playlist"))
        let manager = managers.element(boundBy: 0)
        XCTAssertTrue(manager.waitForExistence(timeout: 5))
        XCTAssertEqual(managers.count, 1, "Exactly one modal manager List is required")
        let window = mainWindow(in: app)
        func qualifyManagerFrame() {
            let frame = manager.frame
            XCTAssertFalse(frame.isNull || frame.isInfinite || frame.isEmpty)
            XCTAssertTrue(window.frame.contains(frame), "The modal List must fit the actual window")
        }
        qualifyManagerFrame()
        let navigation = app.navigationBars["Manage Playlist"]
        func managerCloseControl() -> XCUIElement {
            // Adaptive toolbars can live outside the named navigation bar.
            let candidates = window.toolbars.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Close")
            ).allElementsBoundByIndex.filter {
                ($0.elementType == .button || $0.elementType == .other)
                    && $0.isEnabled && $0.isHittable && window.frame.contains($0.frame)
            }
            XCTAssertEqual(
                candidates.count, 1, "Exactly one visible manager toolbar Close is required")
            return candidates.first ?? window.buttons["Missing manager Close"]
        }
        func waitForManagerDismissal() {
            let dismissed = expectation(
                for: NSPredicate(format: "exists == false"), evaluatedWith: navigation)
            wait(for: [dismissed], timeout: 5)
        }
        let handle = app.images["playlist-reorder-occurrence-0"]
        let footer = app.buttons["playlist-manager-add-disclosure"]
        XCTAssertTrue(footer.waitForExistence(timeout: 5) && footer.frame.height > 0)
        func managerViewport() -> CGRect {
            guard manager.exists, navigation.exists, footer.exists else { return .zero }
            let original = manager.frame.intersection(window.frame)
            guard !original.isNull, !original.isInfinite else { return .zero }
            let top = max(original.minY, navigation.frame.maxY)
            let bottom = min(original.maxY, footer.frame.minY)
            guard original.width > 16, bottom - top > 16 else { return .zero }
            // Modal chrome only: the background's trailing tab bar is not a bottom inset.
            return CGRect(
                x: original.minX + 8, y: top + 8,
                width: original.width - 16, height: bottom - top - 16)
        }
        func dropPoint() -> CGPoint? {
            guard last.exists else { return nil }
            return CGPoint(x: last.frame.midX, y: last.frame.maxY + 12)
        }
        func attachDragGeometry() {
            func frameDescription(_ element: XCUIElement) -> String {
                element.exists ? String(describing: element.frame) : "absent"
            }
            let attachment = XCTAttachment(
                string: """
                    app=\(app.frame)
                    window=\(window.frame)
                    manager=\(frameDescription(manager))
                    modalNavigation=\(frameDescription(navigation))
                    uncovered=\(managerViewport())
                    first=\(frameDescription(first))
                    last=\(frameDescription(last))
                    sourceHandle=\(frameDescription(handle))
                    afterLastDrop=\(dropPoint().map { String(describing: $0) } ?? "absent")
                    footer=\(frameDescription(footer))
                    """)
            attachment.name = "Native playlist drag geometry"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func revealOccurrences() {
            for attempt in 0...8 {
                let viewport = managerViewport()
                let destination = dropPoint()
                if let destination,
                    first.exists && first.isHittable && last.exists && last.isHittable
                        && handle.exists && handle.isHittable && viewport.width > 0
                        && viewport.height > 0 && viewport.contains(first.frame)
                        && viewport.contains(last.frame) && viewport.contains(handle.frame)
                        && viewport.contains(destination)
                        && (!footer.exists || !footer.frame.contains(destination))
                {
                    return
                }
                guard attempt < 8, viewport.width > 0, viewport.height > 48 else { break }
                // Small content drags expose the after-last gap without full-swipe oscillation.
                let moveDown = first.exists && first.frame.minY < viewport.minY
                let overflow =
                    moveDown
                    ? viewport.minY - first.frame.minY
                    : (destination?.y ?? viewport.maxY) - viewport.maxY
                let distance = min(max(overflow + 8, 24), min(64, viewport.height * 0.25))
                let origin = CGPoint(x: viewport.midX, y: viewport.midY)
                let target = CGPoint(x: origin.x, y: origin.y + (moveDown ? distance : -distance))
                let start = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(
                        CGVector(dx: origin.x - window.frame.minX, dy: origin.y - window.frame.minY)
                    )
                let end = window.coordinate(withNormalizedOffset: .zero)
                    .withOffset(
                        CGVector(dx: target.x - window.frame.minX, dy: target.y - window.frame.minY)
                    )
                start.press(
                    forDuration: 0.05, thenDragTo: end, withVelocity: .slow,
                    thenHoldForDuration: 0)
            }
            attachDragGeometry()
            XCTFail("Playlist source, last row and after-last drop must clear the manager footer")
        }
        revealOccurrences()
        XCTAssertTrue(first.exists && last.exists && first.isHittable && last.isHittable)
        assertPlaylistReorderRows([0, 1, 2], in: app)
        capture("Native playlist occurrences before reorder", in: app)
        attachDragGeometry()
        let viewport = managerViewport()
        guard let point = dropPoint() else {
            XCTFail("The last playlist occurrence must exist before dragging")
            return
        }
        XCTAssertTrue(handle.exists && handle.isHittable && viewport.contains(handle.frame))
        XCTAssertTrue(last.exists && viewport.contains(last.frame) && viewport.contains(point))
        XCTAssertFalse(footer.exists && footer.frame.contains(point))
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let destination = last.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
            .withOffset(CGVector(dx: 0, dy: 12))
        start.press(
            forDuration: 0.7, thenDragTo: destination, withVelocity: .slow,
            thenHoldForDuration: 0.2)
        if failOnce {
            let alert = app.alerts["Playlist Update"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            XCTAssertTrue(
                alert.staticTexts[
                    "The order could not be confirmed. Some songs may have moved; refresh before trying again."
                ].exists)
            alert.buttons["Close"].tap()
            XCTAssertTrue(
                app.staticTexts["Review the latest songs before making another change."].exists)
            first.press(forDuration: 1)
            let blockedMove = app.cells.buttons["Move Up"]
            XCTAssertTrue(blockedMove.waitForExistence(timeout: 5))
            XCTAssertFalse(blockedMove.isEnabled)
            // The context menu occludes toolbar controls; dismiss its native backdrop first.
            let backdrop = CGPoint(x: navigation.frame.midX, y: navigation.frame.midY)
            XCTAssertTrue(window.frame.contains(navigation.frame))
            for title in ["Remove from Playlist", "Move Up", "Move Down"] {
                let action = app.cells.buttons[title]
                XCTAssertTrue(action.exists)
                XCTAssertFalse(action.frame.contains(backdrop))
            }
            window.coordinate(withNormalizedOffset: .zero)
                .withOffset(
                    CGVector(
                        dx: backdrop.x - window.frame.minX,
                        dy: backdrop.y - window.frame.minY)
                ).tap()
            let menuGone = expectation(
                for: NSPredicate(format: "exists == false"), evaluatedWith: blockedMove)
            wait(for: [menuGone], timeout: 5)
            // Reopen management to reload the authoritative occurrence order.
            if navigation.exists { tapNativeChrome(managerCloseControl(), in: app) }
            waitForManagerDismissal()
            tapNativeChrome(app.buttons["More actions"], in: app)
            XCTAssertTrue(open.waitForExistence(timeout: 5) && open.isHittable)
            open.tap()
            XCTAssertTrue(app.navigationBars["Manage Playlist"].waitForExistence(timeout: 5))
            XCTAssertTrue(manager.waitForExistence(timeout: 5))
            XCTAssertEqual(
                managers.count, 1, "Exactly one modal manager List is required")
            qualifyManagerFrame()
            revealOccurrences()
        }
        assertPlaylistReorderRows([1, 2, 0], in: app)
        capture("Authoritative native playlist order after drag", in: app)
        XCTAssertTrue(first.exists && first.isHittable)
        first.press(forDuration: 1)
        let moveUp = app.cells.buttons["Move Up"]
        XCTAssertTrue(moveUp.waitForExistence(timeout: 5) && moveUp.isEnabled)
        moveUp.tap()
        assertPlaylistReorderRows([1, 0, 2], in: app)
        capture("Native playlist occurrence action after drag", in: app)
        tapNativeChrome(managerCloseControl(), in: app)
        waitForManagerDismissal()
        XCTAssertEqual(identity.label, baselineIdentity)
        let after = queueSnapshot(app)
        for key in ["queue", "history", "upcoming"] {
            XCTAssertEqual(after[key] as? [String], baselineQueue[key] as? [String])
        }
        XCTAssertEqual(after["selected"] as? String, baselineQueue["selected"] as? String)
        XCTAssertEqual(after["shuffle"] as? Bool, baselineQueue["shuffle"] as? Bool)
        XCTAssertEqual(after["repeat"] as? String, baselineQueue["repeat"] as? String)
    }

    private func assertPlaylistReorderRows(_ expected: [Int], in app: XCUIApplication) {
        let settled = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    let rows = (0..<3).map { index in
                        (
                            index,
                            app.staticTexts["playlist-reorder-occurrence-\(index)"]
                        )
                    }
                    guard rows.allSatisfy({ $0.1.exists && $0.1.frame.height > 0 }) else {
                        return false
                    }
                    return rows.sorted { $0.1.frame.minY < $1.1.frame.minY }.map(\.0) == expected
                }
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }
}
