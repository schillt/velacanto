import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    private func assertOfflineIconIsAccessible(in app: XCUIApplication) {
        let badge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "Available offline")
        ).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Downloaded"].exists)
    }

    struct CollectionPresentation: Equatable {
        let rowLabels: [String]
        let rowEnabled: [Bool]
        let rowValues: [String]
        let actionLabels: [String]
        let playEnabled: Bool
        let shuffleEnabled: Bool
    }

    func canonicalPresentation(
        _ app: XCUIApplication, state: String, offline: Bool, captureName: String,
        context: XCUIElement? = nil
    ) -> CollectionPresentation {
        let root = context ?? app
        let expectedTitles = ["Fixture Tone", "Fixture Missing Tone", "Fixture Tone"]
        var labels: [String] = []
        var enabled: [Bool] = []
        var actions: [String] = []
        var values: [String] = []
        let headerEnabled = !offline || state != "none"
        for title in ["Play", "Shuffle"] {
            let settled = expectation(
                for: NSPredicate(format: "enabled == %@", NSNumber(value: headerEnabled)),
                evaluatedWith: root.buttons[title])
            wait(for: [settled], timeout: 5)
        }
        let playEnabled = root.buttons["Play"].isEnabled
        let shuffleEnabled = root.buttons["Shuffle"].isEnabled
        capture(captureName + " header", in: app)
        for index in expectedTitles.indices {
            let row = root.buttons["collection-track-\(index)"]
            for _ in 0..<12 {
                if row.exists { break }
                scrollContent(in: app, context: context)
            }
            XCTAssertTrue(row.exists, "Known occurrence \(index) must remain in the collection")
            XCTAssertTrue(row.label.contains(expectedTitles[index]))
            let ready = state == "full" || (state == "partial" && index != 1)
            let playable = !offline || ready
            let settled = expectation(
                for: NSPredicate(format: "enabled == %@", NSNumber(value: playable)),
                evaluatedWith: row)
            wait(for: [settled], timeout: 5)
            if offline && !ready {
                XCTAssertTrue((row.value as? String ?? "").contains("unavailable offline"))
            }
            let action = root.buttons["collection-track-actions-\(index)"]
            XCTAssertTrue(action.exists)
            XCTAssertEqual(action.label, "Actions for " + expectedTitles[index])
            let badge = root.images["collection-track-download-\(index)"]
            if ready {
                XCTAssertTrue(badge.exists)
                XCTAssertEqual(badge.label, "Available offline")
                if badge.isHittable && action.isHittable {
                    XCTAssertLessThan(badge.frame.maxX, action.frame.midX)
                    XCTAssertEqual(badge.frame.midY, action.frame.midY, accuracy: 12)
                }
            } else {
                XCTAssertFalse(badge.exists)
            }
            labels.append(row.label)
            enabled.append(row.isEnabled)
            values.append(row.value as? String ?? "")
            actions.append(action.label)
        }
        for title in [
            "Play All", "Play All Songs", "Play Available Tracks", "Saved download",
            "2 of 3 available", "3 saved tracks", "Downloaded",
        ] {
            XCTAssertFalse(app.staticTexts[title].exists)
            XCTAssertFalse(root.buttons[title].exists)
        }
        capture(captureName, in: app)
        return CollectionPresentation(
            rowLabels: labels, rowEnabled: enabled, rowValues: values, actionLabels: actions,
            playEnabled: playEnabled, shuffleEnabled: shuffleEnabled)
    }

    private func verifyCanonicalEntryPoints(state: String, largeText: Bool = false) {
        let app = launch(
            .init(
                productionShell: true, largeText: largeText, canonicalDownloadState: state))
        selectTab("Library", in: app)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.waitForExistence(timeout: 5))
        if largeText {
            XCTAssertEqual(
                app.staticTexts["fixture-dynamic-type-size"].label,
                "Synthetic Dynamic Type: accessibility3")
            XCUIDevice.shared.orientation = .landscapeLeft
            addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
            let landscape = XCTNSPredicateExpectation(
                predicate: NSPredicate { element, _ in
                    MainActor.assumeIsolated {
                        guard let app = element as? XCUIApplication else { return false }
                        return app.frame.width > app.frame.height
                    }
                }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
            XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.isSelected)
            XCTAssertTrue(app.staticTexts["Library"].firstMatch.exists)
            capture("Accessibility-sized landscape Library navigation", in: app)
        }
        for offline in [false, true] {
            if offline {
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
            let status = app.descendants(matching: .any)["browsing-offline-status"]
            if offline {
                XCTAssertTrue(status.waitForExistence(timeout: 5))
                XCTAssertLessThanOrEqual(
                    status.frame.maxY,
                    app.buttons["Profile and settings"].firstMatch.frame.minY + 1
                )
            } else {
                XCTAssertFalse(status.exists)
            }
            for kind in ["playlist", "album"] {
                var baseline: CollectionPresentation?
                for downloadedEntry in [false, true] {
                    openCanonicalCollection(kind, fromDownloads: downloadedEntry, in: app)
                    let presentation = canonicalPresentation(
                        app, state: state, offline: offline,
                        captureName:
                            "Canonical \(kind) \(state) \(offline ? "offline" : "online") via \(downloadedEntry ? "Downloads" : "Library")"
                    )
                    if let baseline {
                        XCTAssertEqual(
                            presentation, baseline,
                            "Entry point must not change known occurrences or available actions")
                    } else {
                        baseline = presentation
                    }
                    XCTAssertEqual(presentation.playEnabled, !offline || state != "none")
                    XCTAssertEqual(presentation.shuffleEnabled, !offline || state != "none")
                    for _ in 0..<(downloadedEntry ? 3 : 2) {
                        app.navigationBars.buttons.firstMatch.tap()
                    }
                }
            }
        }
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        let status = app.descendants(matching: .any)["browsing-offline-status"]
        let online = expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: status)
        wait(for: [online], timeout: 5)
        XCTAssertTrue(app.staticTexts["Library"].firstMatch.exists)
    }

    @objc func testOfflineLandscapeHeaderAndInlineActionsRemainReachable() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(
            .init(productionShell: true, largeText: true, canonicalDownloadState: "full"))
        app.buttons["Library"].firstMatch.tap()
        openCanonicalCollection("playlist", fromDownloads: false, in: app)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browsing-offline-status"].exists)
        capture("Full-screen offline landscape canonical playlist header", in: app)
        XCTAssertTrue(app.buttons["More actions"].isHittable)
        app.buttons["More actions"].tap()
        XCTAssertTrue(app.buttons["Edit Playlist"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Edit Playlist"].isEnabled)
        capture("Full-screen offline landscape reachable playlist actions", in: app)
        app.staticTexts["Canonical fixture ready"].tap()
        _ = canonicalPresentation(
            app, state: "full", offline: true,
            captureName: "Full-screen offline landscape canonical playlist rows")
        tapVisible(app.buttons["collection-track-actions-2"], in: app)
        let removalActions = app.buttons.matching(
            NSPredicate(format: "label == %@", "Remove Downloads")
        ).allElementsBoundByIndex
        XCTAssertTrue(removalActions.contains(where: { $0.isHittable }))
        capture("Full-screen offline landscape reachable inline track actions", in: app)
    }

    @objc func testPartialCollectionsHaveIdenticalLibraryAndDownloadsEntryPoints() {
        continueAfterFailure = false
        verifyCanonicalEntryPoints(state: "partial")
    }

    @objc func testFullCollectionsHaveIdenticalEntryPointsAtAccessibilityTextSize() {
        continueAfterFailure = false
        verifyCanonicalEntryPoints(state: "full", largeText: true)
    }

    @objc func testKnownUndownloadedCollectionsKeepAllOccurrencesAcrossEntryPoints() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true, canonicalDownloadState: "none"))
        app.buttons["Library"].firstMatch.tap()
        for kind in ["playlist", "album"] {
            var onlineBaseline: CollectionPresentation?
            var offlineBaseline: CollectionPresentation?
            for downloadedEntry in [false, true] {
                openCanonicalCollection(kind, fromDownloads: downloadedEntry, in: app)
                let online = canonicalPresentation(
                    app, state: "none", offline: false,
                    captureName:
                        "Known undownloaded \(kind) online via \(downloadedEntry ? "Downloads" : "Library")"
                )
                if let onlineBaseline { XCTAssertEqual(online, onlineBaseline) }
                onlineBaseline = online
                XCTAssertTrue(online.playEnabled)
                XCTAssertTrue(online.shuffleEnabled)
                // Zero-ready cards are intentionally filtered from offline catalog lists.
                // An already-open canonical detail must nevertheless retain all occurrences.
                for _ in 0..<4 { app.swipeDown() }
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
                let strip = app.descendants(matching: .any)["browsing-offline-status"]
                XCTAssertTrue(strip.waitForExistence(timeout: 5))
                XCTAssertTrue(
                    app.descendants(matching: .any)["collection-detail-" + kind + "-" + kind].exists
                )
                let offline = canonicalPresentation(
                    app, state: "none", offline: true,
                    captureName:
                        "Known undownloaded \(kind) preserved offline via \(downloadedEntry ? "Downloads" : "Library")"
                )
                if let offlineBaseline { XCTAssertEqual(offline, offlineBaseline) }
                offlineBaseline = offline
                XCTAssertFalse(offline.playEnabled)
                XCTAssertFalse(offline.shuffleEnabled)
                for _ in 0..<(downloadedEntry ? 3 : 2) {
                    app.navigationBars.buttons.firstMatch.tap()
                }
                app.switches["Simulate unavailable network"].switches.firstMatch.tap()
            }
        }
    }

    @objc func testOfflineModeSettingsFiltersDownloadsAndKeepsPlayerBannerFree() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", longPlayback: true,
                compactFixtureControls: true))
        selectTab("Home", in: app)
        tapNativeChrome(app.buttons["Profile and settings"], in: app)
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        let toggle = app.switches["settings-offline-mode"].firstMatch
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.exists)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        assertOfflineBannerBelow(app.navigationBars["Profile & Settings"], in: app)
        tapNativeChrome(app.navigationBars["Profile & Settings"].buttons["Done"], in: app)
        assertOfflineBannerBelow(app.staticTexts["Home"].firstMatch, in: app)
        XCTAssertFalse(app.buttons["offline-retry"].exists)
        XCTAssertFalse(app.buttons["offline-status-retry"].exists)
        capture("Offline banner below Home title", in: app)
        selectTab("Library", in: app)
        assertOfflineBannerBelow(app.staticTexts["Library"].firstMatch, in: app)
        tapVisible(app.buttons["library-category-downloads"], in: app)
        XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
        assertOfflineBannerBelow(app.navigationBars["Downloads"], in: app)
        capture("Offline banner below native Downloads title", in: app)
        tapVisible(app.buttons["downloads-category-track"], in: app)
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        assertOfflineBannerBelow(app.navigationBars["Songs"], in: app)
        capture("Offline banner persists below Songs title", in: app)
        let song = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
            .firstMatch
        tapVisible(song, in: app)
        openNowPlaying(app)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "browsing-offline-status")
                .allElementsBoundByIndex.allSatisfy { !$0.isHittable })
        capture("Now Playing excludes browsing offline banner", in: app)
    }

    @objc func testOfflineCustomHeaderAndBannerFadeTogetherWhenScrolling() {
        continueAfterFailure = false
        // A short viewport makes both production browsing roots scrollable with saved fixtures.
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", compactFixtureControls: true)
        )
        selectTab("Home", in: app)
        tapNativeChrome(app.buttons["Profile and settings"], in: app)
        let settings = app.navigationBars["Profile & Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let toggle = app.switches["settings-offline-mode"].firstMatch
        reveal(toggle, in: app)
        toggle.switches.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        tapNativeChrome(settings.buttons["Done"], in: app)

        for name in ["Home", "Library"] {
            selectTab(name, in: app)
            let title = app.staticTexts["browsing-screen-title-" + name]
            assertOfflineBannerBelow(title, in: app)
            capture(
                "\(name) offline strip below the visible custom title before scrolling", in: app)
            scrollContent(in: app)
            let hiddenTogether = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        let banners = app.descendants(matching: .any).matching(
                            identifier: "browsing-offline-status")
                        // The safe-area header stays mounted while its visible surface fades.
                        return !title.isHittable
                            && banners.allElementsBoundByIndex.allSatisfy { !$0.isHittable }
                    }
                }, object: nil)
            XCTAssertEqual(
                XCTWaiter.wait(for: [hiddenTogether], timeout: 5), .completed,
                "\(name) title and offline strip must leave the browsing surface together")
            capture("\(name) offline strip fades with its custom header", in: app)
            scrollContent(in: app, upward: false)
            let returnedTogether = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in
                    MainActor.assumeIsolated {
                        title.exists && title.isHittable
                            && app.descendants(matching: .any).matching(
                                identifier: "browsing-offline-status"
                            ).allElementsBoundByIndex.contains { $0.isHittable }
                    }
                }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [returnedTogether], timeout: 5), .completed)
            assertOfflineBannerBelow(title, in: app)
            capture("\(name) title and offline strip return below the same header surface", in: app)
        }
    }

    private func assertOfflineBannerBelow(
        _ title: XCUIElement, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let banners = app.descendants(matching: .any).matching(
            identifier: "browsing-offline-status")
        XCTAssertTrue(banners.firstMatch.waitForExistence(timeout: 5), file: file, line: line)
        let visible = banners.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertEqual(
            visible.count, 1, "Exactly one browsing banner is visible", file: file, line: line)
        guard let banner = visible.first else { return }
        XCTAssertTrue(title.exists, file: file, line: line)
        let measured = XCTNSPredicateExpectation(
            predicate: NSPredicate { [weak self] object, _ in
                guard let element = object as? XCUIElement,
                    let frame = self?.offlineBannerFrame(element)
                else { return false }
                return frame.width > 0 && frame.height > 0
            }, object: banner)
        XCTAssertEqual(
            XCTWaiter.wait(for: [measured], timeout: 5), .completed, file: file, line: line)
        guard let frame = offlineBannerFrame(banner) else {
            XCTFail("Rendered banner geometry is required", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(
            frame.minY, title.frame.maxY - 1,
            "Offline banner must start below the title bar", file: file, line: line)
        XCTAssertLessThanOrEqual(
            frame.height, 32,
            "The default-size iPhone banner remains a slim strip", file: file, line: line)
    }

    private func offlineBannerFrame(_ banner: XCUIElement) -> CGRect? {
        guard let value = banner.value as? String, value.hasPrefix("frame=") else { return nil }
        let numbers = value.dropFirst(6).split(separator: ",").compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    @objc func testOfflineImmersiveAlbumHeaderKeepsArtworkSurfaceInBothAppearances() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        for scheme in ["light", "dark"] {
            let app = launch(
                .init(
                    productionShell: true, canonicalDownloadState: "full", artworkCache: true,
                    colorScheme: scheme,
                    compactFixtureControls: true))
            selectTab("Library", in: app)
            openCanonicalCollection("album", fromDownloads: false, in: app, useVerifiedCenter: true)
            let detail = app.descendants(matching: .any)["collection-detail-album-album"]
            XCTAssertTrue(detail.exists)
            capture("\(scheme) online album native header and artwork surface", in: app)
            toggleAlphabetNetwork(app, offline: true)
            let banner = app.descendants(matching: .any)["browsing-offline-status"]
            XCTAssertTrue(banner.waitForExistence(timeout: 5))
            XCTAssertTrue(detail.exists)
            XCTAssertFalse(app.buttons["offline-retry"].exists)
            capture("\(scheme) offline status inherits album surface at top", in: app)
            app.swipeUp()
            XCTAssertTrue(detail.exists)
            XCTAssertTrue(banner.exists)
            capture("\(scheme) offline album native collapsed header", in: app)
            app.terminate()
        }
    }

    @objc func testOfflinePreservesAlbumHomeAndPlayerWithoutPlaybackBadges() {
        continueAfterFailure = false
        let app = launch(.init(productionShell: true))
        app.buttons["Queue fixture playlist"].tap()
        app.buttons["Library"].firstMatch.tap()
        let downloads = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Downloads")
        ).firstMatch
        tapVisible(downloads, in: app)
        waitForSavedDownload(app)
        app.navigationBars.buttons.firstMatch.tap()
        let albums = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Albums")
        ).firstMatch
        tapVisible(albums, in: app)
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        let album = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Album")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        XCTAssertTrue(app.buttons["Shuffle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Album"].firstMatch.exists)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Fixture Album"].firstMatch.exists)
        XCTAssertFalse(app.navigationBars["Downloads"].exists)
        capture("Offline preserves the open album detail", in: app)
        app.buttons["Play"].tap()
        let backToAlbums = app.navigationBars.buttons["Albums"].firstMatch
        XCTAssertTrue(backToAlbums.waitForExistence(timeout: 5))
        backToAlbums.tap()
        capture("Offline album grid retained after playback", in: app)
        XCTAssertTrue(app.navigationBars["Albums"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        selectTab("Home", in: app)
        XCTAssertTrue(app.staticTexts["Home"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 5))
        let resume = app.buttons["Open Now Playing"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertFalse(resume.label.contains("Available offline"))
        XCTAssertFalse((resume.value as? String ?? "").contains("Available offline"))
        XCTAssertFalse(resume.images["Available offline"].exists)
        capture("Offline Home retains Continue Listening without a download badge", in: app)
        resume.tap()
        XCTAssertTrue(app.buttons["Show queue"].waitForExistence(timeout: 5))
        capture("Now Playing excludes download badges", in: app)
        // The hierarchy may retain background catalog elements during the native zoom transition.
        XCTAssertTrue(
            app.images.matching(identifier: "Available offline")
                .allElementsBoundByIndex.allSatisfy { !$0.isHittable })
        XCTAssertFalse(app.staticTexts["Downloaded"].exists)
    }

    @objc func testDownloadedPlaylistGridDetailAndSongsUseAccessibleIconBadges() {
        continueAfterFailure = false
        let app = launch(.init(largeText: true))
        XCTAssertEqual(
            app.staticTexts["fixture-dynamic-type-size"].label,
            "Synthetic Dynamic Type: accessibility3")
        app.buttons["Queue fixture playlist"].tap()
        openDownloads(app)
        enableCellular(app)
        waitForSavedDownload(app)
        tapVisible(app.buttons["Playlists"], in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        let playlist = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Playlist")
        ).firstMatch
        XCTAssertTrue(playlist.waitForExistence(timeout: 5))
        assertOfflineIconIsAccessible(in: app)
        capture("Accessibility-sized shared downloaded playlist grid", in: app)
        tapVisible(playlist, in: app)
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Shuffle"].exists)
        capture("Accessibility-sized shared downloaded playlist hero", in: app)
        app.swipeUp()
        let track = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone")
        ).firstMatch
        for _ in 0..<5 {
            if track.exists && track.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(track.exists && track.isHittable)
        assertOfflineIconIsAccessible(in: app)
        capture("Accessibility-sized shared downloaded playlist song rows", in: app)
        returnToFixtureRoot(app)
        openDownloads(app)
        app.buttons["Songs"].tap()
        XCTAssertTrue(app.navigationBars["Songs"].waitForExistence(timeout: 5))
        assertOfflineIconIsAccessible(in: app)
        XCTAssertFalse(app.buttons["Play All"].exists)
        XCTAssertFalse(app.buttons["Play All Songs"].exists)
        capture("Accessibility-sized downloaded Songs icon badge", in: app)
    }

    @objc func testMeasuredTrackAndIndeterminateCollectionFeedback() {
        continueAfterFailure = false
        let app = launch(
            .init(productionShell: true, canonicalDownloadState: nil, slowTransfer: true))
        app.buttons["Queue fixture playlist"].tap()
        app.buttons["Library"].firstMatch.tap()
        tapVisible(app.buttons["library-category-songs"], in: app)
        let progress = app.descendants(matching: .any)["collection-track-download-0"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 8))
        XCTAssertEqual(progress.label, "Downloading")
        XCTAssertEqual(progress.value as? String, "50 percent")
        let queued = app.descendants(matching: .any)["collection-track-download-1"].firstMatch
        XCTAssertTrue(queued.exists)
        XCTAssertEqual(queued.label, "Download queued")
        capture("Measured track uses accessible determinate circular progress", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(app.buttons["library-category-playlists"], in: app)
        let aggregate = app.descendants(matching: .any)["download-state-active-indeterminate"]
            .firstMatch
        XCTAssertTrue(aggregate.waitForExistence(timeout: 5))
        XCTAssertFalse((aggregate.value as? String ?? "").contains("percent"))
        capture("Collection feedback does not invent aggregate percentages", in: app)
        XCTAssertTrue(app.staticTexts["Fixture download ready"].waitForExistence(timeout: 65))
        assertOfflineIconIsAccessible(in: app)
    }
}
