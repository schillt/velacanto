import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    func queueSnapshot(_ app: XCUIApplication) -> [String: Any] {
        let element = app.staticTexts["fixture-player-queue-snapshot"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        guard let data = element.label.data(using: .utf8),
            let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("Synthetic queue snapshot must contain JSON")
            return [:]
        }
        return snapshot
    }

    private func revealQueueControl(
        _ control: XCUIElement, entryID: String, in app: XCUIApplication
    ) {
        let list = app.descendants(matching: .any)["fixture-queue-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let window = mainWindow(in: app)
        let windowFrame = window.frame
        let viewport = list.frame.intersection(windowFrame).insetBy(dx: 8, dy: 16)
        XCTAssertGreaterThan(viewport.height, 44)
        for _ in 0..<16 {
            if control.exists && control.frame.width > 0 && control.frame.height > 0,
                control.isHittable,
                viewport.contains(CGPoint(x: control.frame.midX, y: control.frame.midY))
            {
                break
            }
            let order = queueSnapshot(app)["queue"] as? [String] ?? []
            guard let target = order.firstIndex(of: entryID) else {
                XCTFail("The target queue occurrence must remain in the real queue")
                return
            }
            let visible = order.enumerated().compactMap { index, id -> Int? in
                let row = app.buttons["fixture-queue-select-" + id]
                guard row.exists, row.frame.width > 0, row.frame.height > 0,
                    row.isHittable,
                    viewport.contains(CGPoint(x: row.frame.midX, y: row.frame.midY))
                else { return nil }
                return index
            }
            let upward = visible.min().map { target >= $0 } ?? (target > 0)
            let origin = window.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(
                CGVector(
                    dx: viewport.midX - windowFrame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.8 : 0.2) - windowFrame.minY))
            let end = origin.withOffset(
                CGVector(
                    dx: viewport.midX - windowFrame.minX,
                    dy: viewport.minY + viewport.height * (upward ? 0.2 : 0.8) - windowFrame.minY))
            start.press(
                forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        XCTAssertTrue(control.exists && control.frame.width > 0 && control.frame.height > 0)
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(viewport.contains(CGPoint(x: control.frame.midX, y: control.frame.midY)))
    }

    @objc func testNativeQueueAppearanceLightDarkAndReducedTransparency() {
        continueAfterFailure = false
        for (scheme, reduced) in [("light", false), ("dark", false), ("dark", true)] {
            let app = launch(
                .init(
                    productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                    reducedAccessibilityEffects: reduced, colorScheme: scheme,
                    queuePresentation: true))
            selectTab("Library", in: app)
            openCanonicalCollection("album", fromDownloads: false, in: app)
            tapVisible(app.buttons["collection-track-0"], in: app)
            let identity = app.staticTexts["fixture-playback-identity"]
            let playing = expectation(
                for: NSPredicate(format: "label CONTAINS %@", "state playing"),
                evaluatedWith: identity)
            wait(for: [playing], timeout: 10)
            let baseline = identity.label
            openNowPlaying(app)
            app.buttons["Show queue"].tap()
            XCTAssertEqual((queueSnapshot(app)["queue"] as? [String])?.count, 5)
            XCTAssertEqual((queueSnapshot(app)["upcoming"] as? [String])?.count, 4)
            XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, baseline)
            capture(
                "Native Queue appearance " + scheme + (reduced ? " reduced transparency" : ""),
                in: app)
            app.buttons["Show artwork"].tap()
            XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
            app.buttons["Show queue"].tap()
            XCTAssertEqual(app.staticTexts["fixture-player-playback-identity"].label, baseline)
            capture("Native Queue repeated appearance " + scheme, in: app)
            app.terminate()
        }
    }

    private func dragQueueEntry(
        _ source: XCUIElement, to target: XCUIElement, in app: XCUIApplication
    ) {
        let list = app.descendants(matching: .any)["fixture-queue-list"]
        let window = mainWindow(in: app)
        let windowFrame = window.frame
        let viewport = list.frame.intersection(windowFrame)
        let sourcePoint = CGPoint(x: list.frame.maxX - 24, y: source.frame.midY)
        let targetPoint = CGPoint(x: list.frame.maxX - 24, y: target.frame.midY)
        XCTAssertTrue(viewport.contains(sourcePoint) && viewport.contains(targetPoint))
        let geometry = XCTAttachment(
            string:
                "App \(app.frame); window \(windowFrame); list \(list.frame); source \(source.frame); target \(target.frame); handle \(sourcePoint); destination \(targetPoint)"
        )
        geometry.name = "Native Queue drag window and handle geometry"
        geometry.lifetime = .keepAlways
        add(geometry)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let handle = origin.withOffset(
            CGVector(dx: sourcePoint.x - windowFrame.minX, dy: sourcePoint.y - windowFrame.minY))
        let destination = origin.withOffset(
            CGVector(dx: targetPoint.x - windowFrame.minX, dy: targetPoint.y - windowFrame.minY))
        handle.press(
            forDuration: 0.8, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3
        )
    }

    @objc func testQueueRepeatedDragReordersOccurrencesAndKeepsCurrentPlayback() {
        continueAfterFailure = false
        let app = launch(.playbackQueue)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        app.buttons["Show queue"].tap()
        let selected = queueSnapshot(app)["selected"] as? String
        capture("Native Queue reorder handles preserve row styling", in: app)
        for _ in 0..<3 {
            let before = queueSnapshot(app)["upcoming"] as? [String] ?? []
            XCTAssertGreaterThanOrEqual(before.count, 2)
            guard before.count >= 2 else { return }
            let source = app.buttons["fixture-queue-select-" + before[1]]
            let target = app.buttons["fixture-queue-select-" + before[0]]
            XCTAssertTrue(source.isHittable && target.isHittable)
            dragQueueEntry(source, to: target, in: app)
            let after = queueSnapshot(app)
            XCTAssertEqual(
                after["upcoming"] as? [String], [before[1], before[0]] + Array(before.dropFirst(2)))
            XCTAssertEqual(after["selected"] as? String, selected)
            XCTAssertEqual(after["history"] as? [String], [])
            XCTAssertTrue(app.buttons["Pause"].exists)
        }
        app.buttons["Collapse Now Playing"].tap()
        XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
        capture("Repeated occurrence drag keeps current playback and dismissal", in: app)
    }

    @objc func testQueueArtworkZoomAndNativeSwipeActionsPreserveOccurrencePlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                queuePresentation: true, queueArtworkTransition: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        let identity = app.staticTexts["fixture-player-playback-identity"]
        let startingIdentity = identity.label
        app.buttons["Show queue"].tap()
        let transition = app.staticTexts["fixture-player-artwork-transition"]
        let zoomed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "queueCompleted 1"),
            object: transition)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 5), .completed, transition.label)
        XCTAssertFalse(modal.buttons["More playback options"].exists)
        XCTAssertTrue(transition.label.contains("metadataCompleted 1"), transition.label)
        let before = queueSnapshot(app)
        let upcoming = before["upcoming"] as? [String] ?? []
        XCTAssertEqual(upcoming.count, 14)
        guard upcoming.count == 14 else { return }
        let first = app.buttons["fixture-queue-select-" + upcoming[0]]
        first.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo:
                    first.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.5)))
        let playNext = modal.buttons["Play Next"]
        let playLast = modal.buttons["Play Last"]
        XCTAssertTrue(playNext.waitForExistence(timeout: 5) && playNext.isHittable)
        XCTAssertTrue(playLast.isHittable)
        capture("Queue native right swipe exposes Next and Last", in: app)
        playLast.tap()
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String], Array(upcoming.dropFirst()) + [upcoming[0]]
        )
        let removeEntry = app.buttons["fixture-queue-select-" + upcoming[1]]
        removeEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo:
                    removeEntry.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)))
        let remove = modal.buttons["Remove from Up Next"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5) && remove.isHittable)
        capture("Queue native left swipe exposes minus removal", in: app)
        remove.tap()
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String],
            Array(upcoming.dropFirst(2)) + [upcoming[0]])
        XCTAssertEqual(queueSnapshot(app)["selected"] as? String, before["selected"] as? String)
        XCTAssertEqual(queueSnapshot(app)["history"] as? [String], [])
        XCTAssertEqual(identity.label, startingIdentity)
        let fullNext = app.buttons["fixture-queue-select-" + upcoming[3]]
        fullNext.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo:
                    fullNext.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.05)
        capture("Queue full leading swipe default", in: app)
        var expected = Array(upcoming.dropFirst(2)) + [upcoming[0]]
        expected.removeAll { $0 == upcoming[3] }
        expected.insert(upcoming[3], at: 0)
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], expected)
        fullNext.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo:
                    fullNext.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.05)
        capture("Queue full trailing swipe default", in: app)
        expected.removeFirst()
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], expected)
        XCTAssertEqual(identity.label, startingIdentity)
        let queue = app.descendants(matching: .any)["fixture-queue-list"]
        queue.swipeUp()
        let current = app.buttons["fixture-queue-select-" + (before["selected"] as? String ?? "")]
        XCTAssertTrue(current.isHittable && modal.buttons["Shuffle"].isHittable)
        capture("Queue rows disappear below the transparent pinned current header", in: app)
        app.buttons["Show artwork"].tap()
        let expanded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "queueCompleted 2"),
            object: transition)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed, transition.label)
        XCTAssertEqual(identity.label, startingIdentity)
        XCTAssertTrue(transition.label.contains("metadataCompleted 2"), transition.label)
        XCTAssertTrue(modal.buttons["More playback options"].exists)
        capture("Queue artwork expands back without replacing playback", in: app)
    }

    @objc func testQueueModeControlsCycleRepeatAndKeepPlayback() {
        continueAfterFailure = false
        let app = launch(.playbackQueue)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        let identity = app.staticTexts["fixture-player-playback-identity"]
        let original = identity.label
        app.buttons["Show queue"].tap()
        let repeatControl = modal.buttons["Repeat"]
        XCTAssertTrue(repeatControl.waitForExistence(timeout: 5))
        XCTAssertEqual(repeatControl.value as? String, "Off")
        for mode in ["All", "One", "Off"] {
            repeatControl.tap()
            let changed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", mode), object: repeatControl)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
            capture("Queue repeat click cycle " + mode, in: app)
            XCTAssertEqual(identity.label, original)
        }
        let shuffle = modal.buttons["Shuffle"]
        shuffle.tap()
        XCTAssertEqual(shuffle.value as? String, "On")
        capture("Queue selected Shuffle has contrasting symbol", in: app)
        shuffle.tap()
        XCTAssertEqual(shuffle.value as? String, "Off")
        XCTAssertEqual(identity.label, original)
    }

    @objc func testQueueHistoryContextMenuOffersReplayAndSharedTrackActions() {
        continueAfterFailure = false
        let app = launch(.playbackQueue)
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        modal.buttons["Next"].tap()
        app.buttons["Show queue"].tap()
        let before = queueSnapshot(app)
        let history = before["history"] as? [String] ?? []
        XCTAssertEqual(history.count, 1)
        guard let id = history.first else { return }
        let historyRow = app.buttons["fixture-queue-select-" + id]
        revealQueueControl(historyRow, entryID: id, in: app)
        historyRow.press(forDuration: 1)
        XCTAssertTrue(app.cells.buttons["Play Next"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.cells.buttons["Play Last"].exists)
        XCTAssertTrue(app.cells.buttons["View Album"].exists)
        XCTAssertTrue(app.cells.buttons["View Artist"].exists)
        XCTAssertTrue(app.cells.buttons["Favorite"].exists)
        XCTAssertFalse(app.cells.buttons["Download"].exists)
        XCTAssertFalse(app.cells.buttons["Remove Downloads"].exists)
        XCTAssertFalse(app.cells.buttons["Move Up"].exists)
        XCTAssertFalse(app.cells.buttons["Move Down"].exists)
        XCTAssertFalse(app.cells.buttons["Remove from Up Next"].exists)
        capture("Queue History has icon-labelled replay and shared track menu", in: app)
        XCTAssertEqual(queueSnapshot(app)["history"] as? [String], history)
        XCTAssertEqual(queueSnapshot(app)["selected"] as? String, before["selected"] as? String)
    }

    @objc func testQueuePinnedCurrentRevealsAndClearsHistoryWithoutChangingPlayback() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                queuePresentation: true, queueArtworkTransition: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        for _ in 0..<4 { modal.buttons["Next"].tap() }
        app.buttons["Show queue"].tap()
        let before = queueSnapshot(app)
        let selected = before["selected"] as? String ?? ""
        XCTAssertEqual((before["history"] as? [String])?.count, 4)
        let current = app.buttons["fixture-queue-select-" + selected]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.isHittable)
        let openingY = current.frame.minY
        let shuffle = modal.buttons["Shuffle"]
        let repeatControl = modal.buttons["Repeat"]
        capture("Queue opening current and mode controls", in: app)
        XCTAssertTrue(shuffle.isHittable && repeatControl.isHittable)
        XCTAssertEqual(shuffle.frame.midY, current.frame.midY, accuracy: 2)
        capture("Queue current artwork and modes at opening", in: app)
        let list = app.descendants(matching: .any)["fixture-queue-list"]
        list.swipeUp()
        XCTAssertTrue(current.isHittable && shuffle.isHittable)
        XCTAssertEqual(current.frame.minY, openingY, accuracy: 2)
        let clear = app.buttons["Clear History"]
        for _ in 0..<4 {
            if clear.isHittable { break }
            list.swipeDown()
        }
        XCTAssertTrue(clear.isHittable)
        XCTAssertGreaterThan(current.frame.minY, openingY + 8)
        XCTAssertEqual(shuffle.frame.midY, current.frame.midY, accuracy: 2)
        capture("Queue history reveal carries current artwork and modes together", in: app)
        let identity = app.staticTexts["fixture-player-playback-identity"]
        let playback = identity.label
        clear.tap()
        let after = queueSnapshot(app)
        XCTAssertEqual(after["history"] as? [String], [])
        XCTAssertEqual(after["selected"] as? String, selected)
        XCTAssertEqual(after["upcoming"] as? [String], before["upcoming"] as? [String])
        XCTAssertEqual(identity.label, playback)
        XCTAssertTrue(current.isSelected)
        XCTAssertFalse(clear.exists)
        capture("Queue clear history preserves current playback and Up Next", in: app)
    }

    @objc func testNativeQueuePresentationActionsReorderAndPlaybackContinuity() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                colorScheme: "light", queuePresentation: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        let rootIdentity = app.staticTexts["fixture-playback-identity"]
        let playing = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state playing"),
            evaluatedWith: rootIdentity)
        wait(for: [playing], timeout: 10)
        let startingIdentity = rootIdentity.label
        openNowPlaying(app)
        let identity = app.staticTexts["fixture-player-playback-identity"]
        XCTAssertEqual(identity.label, startingIdentity)
        // Check menu semantics with a paused clock; advancing playback is covered
        // separately by repeated handle reorder and interrupted dismissal tests.
        let modal = app.descendants(matching: .any)["foundation-now-playing"]
        modal.buttons["Pause"].tap()
        let paused = expectation(
            for: NSPredicate(format: "label CONTAINS %@", "state paused"),
            evaluatedWith: identity)
        wait(for: [paused], timeout: 5)
        let originalIdentity = identity.label
        app.buttons["Show queue"].tap()
        let snapshot = queueSnapshot(app)
        guard let queue = snapshot["queue"] as? [String],
            let initial = snapshot["upcoming"] as? [String]
        else {
            XCTFail("Queue occurrence arrays are required")
            return
        }
        XCTAssertEqual(queue.count, 5)
        XCTAssertEqual(Set(queue).count, 5)
        XCTAssertEqual(initial.count, 4)
        XCTAssertEqual(snapshot["selected"] as? String, queue.first)
        XCTAssertEqual(identity.label, originalIdentity)
        let current = app.buttons["fixture-queue-select-" + queue[0]]
        XCTAssertEqual(current.value as? String, "Current track")
        XCTAssertTrue(current.isSelected)
        XCTAssertEqual(snapshot["history"] as? [String], [])
        capture("Native Queue baseline light", in: app)
        func action(_ title: String, entry: String) {
            let row = app.buttons["fixture-queue-select-" + entry]
            revealQueueControl(row, entryID: entry, in: app)
            row.press(forDuration: 1)
            let button = app.cells.buttons.matching(
                NSPredicate(format: "label == %@", title))
            XCTAssertTrue(button.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(button.count, 1)
            XCTAssertTrue(button.element.isHittable)
            button.element.tap()
        }
        action("Play Last", entry: initial[0])
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String],
            Array(initial.dropFirst()) + [initial[0]])
        action("Play Next", entry: initial[0])
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], initial)
        XCTAssertEqual(identity.label, originalIdentity)
        // Cancel a real native menu without selecting any queue action.
        let menu = app.buttons["fixture-queue-select-" + initial[1]]
        menu.press(forDuration: 1)
        let lastAction = app.cells.buttons["Play Last"]
        XCTAssertTrue(lastAction.waitForExistence(timeout: 5))
        let artworkToggle = app.buttons["Show artwork"]
        XCTAssertTrue(artworkToggle.frame.width > 0)
        let outside = artworkToggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        XCTAssertFalse(
            lastAction.frame.contains(
                CGPoint(x: artworkToggle.frame.midX, y: artworkToggle.frame.midY)))
        outside.tap()
        let gone = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: lastAction)
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], initial)
        let cancellationOutcome = XCTAttachment(
            string:
                "Outside native menu tap: Show artwork exists \(app.buttons["Show artwork"].exists); Show queue exists \(app.buttons["Show queue"].exists)"
        )
        cancellationOutcome.name = "Synthetic Queue cancellation gesture consumption"
        cancellationOutcome.lifetime = .keepAlways
        add(cancellationOutcome)
        XCTAssertTrue(
            app.buttons["Show artwork"].exists,
            "Native menu cancellation must retain the visible Queue")
        XCTAssertFalse(app.buttons["Show queue"].exists)
        let source = app.buttons["fixture-queue-select-" + initial[3]]
        let destination = app.buttons["fixture-queue-select-" + initial[0]]
        reveal(source, in: app)
        XCTAssertTrue(source.isHittable && destination.isHittable)
        dragQueueEntry(source, to: destination, in: app)
        let reordered = [initial[3]] + Array(initial.prefix(3))
        XCTAssertEqual(queueSnapshot(app)["upcoming"] as? [String], reordered)
        action("Remove from Up Next", entry: initial[2])
        XCTAssertEqual(
            queueSnapshot(app)["upcoming"] as? [String],
            reordered.filter { $0 != initial[2] })
        XCTAssertEqual(identity.label, originalIdentity)
        modal.buttons["Shuffle"].tap()
        XCTAssertEqual(queueSnapshot(app)["shuffle"] as? Bool, true)
        XCTAssertEqual(
            Set(queueSnapshot(app)["upcoming"] as? [String] ?? []),
            Set(reordered.filter { $0 != initial[2] }))
        modal.buttons["Shuffle"].tap()
        XCTAssertEqual(queueSnapshot(app)["shuffle"] as? Bool, false)
        modal.buttons["Repeat"].tap()
        XCTAssertEqual(queueSnapshot(app)["repeat"] as? String, "all")
        modal.buttons["Repeat"].tap()
        XCTAssertEqual(queueSnapshot(app)["repeat"] as? String, "one")
        modal.buttons["Repeat"].tap()
        XCTAssertEqual(queueSnapshot(app)["repeat"] as? String, "off")
        XCTAssertEqual(identity.label, originalIdentity)
        capture(
            "Native Queue edited upcoming occurrences preserve active playback", in: app)
        for _ in 0..<2 {
            app.buttons["Show artwork"].tap()
            XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
            app.buttons["Show queue"].tap()
            XCTAssertEqual(identity.label, originalIdentity)
        }
        capture("Native Queue repeated presentation light", in: app)
        let beforeSelection = queueSnapshot(app)
        guard let beforeOrder = beforeSelection["queue"] as? [String],
            let selectedIndex = beforeOrder.firstIndex(of: initial[1])
        else {
            XCTFail("The chosen duplicate occurrence must remain queued")
            return
        }
        let selection = app.buttons["fixture-queue-select-" + initial[1]]
        revealQueueControl(selection, entryID: initial[1], in: app)
        selection.tap()
        let selectedIdentity =
            "Fixture identity: \(initial[1]); item tone; intent true; state playing"
        let selectedPlaying = expectation(
            for: NSPredicate(format: "label == %@", selectedIdentity), evaluatedWith: identity)
        wait(for: [selectedPlaying], timeout: 10)
        XCTAssertNotEqual(identity.label, originalIdentity)
        XCTAssertEqual(identity.label, selectedIdentity)
        let afterSelection = queueSnapshot(app)
        XCTAssertEqual(afterSelection["selected"] as? String, initial[1])
        XCTAssertEqual(afterSelection["queue"] as? [String], beforeOrder)
        XCTAssertEqual(
            afterSelection["history"] as? [String], Array(beforeOrder.prefix(selectedIndex)))
        XCTAssertEqual(
            afterSelection["upcoming"] as? [String], Array(beforeOrder.dropFirst(selectedIndex + 1))
        )
        XCTAssertEqual(selection.value as? String, "Current track")
        XCTAssertTrue(selection.isSelected)
        XCTAssertFalse(current.isSelected)
        capture("Native Queue selects the exact duplicate occurrence", in: app)
        app.terminate()
    }

    @objc func testQueueSkipPauseCollapseAndReopenRepeatedly() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                queuePresentation: true, detachedPlayerArtwork: true))
        selectTab("Library", in: app)
        openCanonicalCollection("album", fromDownloads: false, in: app)
        tapVisible(app.buttons["collection-track-0"], in: app)
        openNowPlaying(app)
        for iteration in 0..<3 {
            if app.buttons["Show queue"].exists { app.buttons["Show queue"].tap() }
            XCTAssertTrue(app.descendants(matching: .any)["fixture-queue-list"].exists)
            app.buttons["Next"].tap()
            let pause = app.buttons["Pause"]
            XCTAssertTrue(pause.waitForExistence(timeout: 5))
            pause.tap()
            app.buttons["Play"].tap()
            let collapse = app.buttons["Collapse Now Playing"]
            XCTAssertTrue(collapse.exists && collapse.isHittable)
            let grabber = collapse.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            grabber.press(
                forDuration: 0.1, thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: 15)),
                withVelocity: .slow, thenHoldForDuration: 0.2)
            XCTAssertTrue(collapse.exists && collapse.isHittable)
            XCTAssertTrue(app.buttons["Show artwork"].exists)
            if iteration == 1 {
                grabber.press(
                    forDuration: 0.1,
                    thenDragTo: grabber.withOffset(CGVector(dx: 0, dy: app.frame.height * 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
            } else {
                collapse.tap()
            }
            XCTAssertTrue(app.buttons["Show Now Playing"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Show Now Playing"].isHittable)
            openNowPlaying(app)
            // Previous may first restart a track after three seconds. Two taps guarantee
            // return to the first occurrence, including when the controls took time to settle.
            app.buttons["Previous"].tap()
            app.buttons["Previous"].tap()
        }
        app.buttons["Collapse Now Playing"].tap()
        selectTab("Search", in: app)
        XCTAssertTrue(app.textFields["Search music"].waitForExistence(timeout: 5))
        capture(
            "Repeated queue skips and playback controls retain collapse and navigation", in: app)
    }
}
