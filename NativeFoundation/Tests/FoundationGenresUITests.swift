import UIKit
import XCTest

// Methods retain FoundationDownloadsUITests selectors across source organization.
extension FoundationDownloadsUITests {
    @objc func testSharedArtistPlaylistAndDistinctGenreArtworkSources() {
        let app = launch(.init(productionShell: true, artworkCache: true))
        func counts(_ expected: String) {
            app.buttons["Read artwork counts"].tap()
            let label = app.staticTexts["fixture-artwork-counts"]
            let predicate = NSPredicate(format: "label CONTAINS %@", expected)
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: predicate, object: label)],
                    timeout: 5), .completed)
        }
        func tab(_ title: String) { selectTab(title, in: app) }
        tab("Home")
        counts("Album 1")
        tapNativeChrome(app.buttons["fixture-build-primary-genres"], in: app)
        let genre = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Genre")
        ).firstMatch
        tab("New")
        for _ in 0..<12 {
            if genre.exists && genre.isHittable { break }
            scrollContent(in: app)
        }
        XCTAssertTrue(genre.exists && genre.isHittable)
        counts("Album 1")
        counts("Genre 0")
        capture("New genre representative reuses album without aliasing genre Primary", in: app)
        tab("Library")
        tapVisible(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Artists")).firstMatch,
            in: app)
        XCTAssertTrue(app.navigationBars["Artists"].waitForExistence(timeout: 5))
        counts("Artist 1")
        capture("Shared artist artwork", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tapVisible(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Playlists"))
                .firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Playlists"].waitForExistence(timeout: 5))
        counts("Playlist 1")
        capture("Shared playlist artwork", in: app)
        app.navigationBars.buttons.firstMatch.tap()
        tab("Search")
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        XCTAssertTrue(app.buttons["Fixture Genre"].waitForExistence(timeout: 5))
        counts("Genre 1")
        capture("Search genre Primary shares its identity independently of New", in: app)
    }

    @objc func testGenresPrepareAutomaticallyWithoutManualBuild() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, compactFixtureControls: true,
                primaryGenres: true, automaticGenres: true))
        selectTab("Library", in: app)
        tapVisibleCenter(app.buttons["library-category-genres"], in: app)
        XCTAssertTrue(app.navigationBars["Genres"].waitForExistence(timeout: 5))
        let genre = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fixture Genre")
        ).firstMatch
        XCTAssertTrue(
            genre.waitForExistence(timeout: 10),
            "First-launch genres must not require the Build button")
        XCTAssertFalse(app.buttons["Rebuild Genres"].exists)
        XCTAssertFalse(app.buttons["Cancel indexing"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Indexed "))
                .firstMatch.exists)
        selectTab("Search", in: app)
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertTrue(app.buttons["Fixture Genre"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Rebuild Genres"].exists)
        XCTAssertFalse(app.buttons["Cancel indexing"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Indexed "))
                .firstMatch.exists)
        capture("Automatic genres browse without maintenance in Search and Library", in: app)
        openGenreLibrarySettings(in: app)
        XCTAssertTrue(app.buttons["settings-rebuild-genres"].waitForExistence(timeout: 5))
        capture("Genre maintenance remains in Library Settings", in: app)
        closeGenreLibrarySettings(in: app)
    }

    private func openGenreLibrarySettings(in app: XCUIApplication) {
        selectTab("Home", in: app)
        tapNativeChrome(app.buttons["Profile and settings"], in: app)
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        tapVisibleCenter(app.buttons["Library Settings"], in: app)
        XCTAssertTrue(app.navigationBars["Library Settings"].waitForExistence(timeout: 5))
    }

    private func closeGenreLibrarySettings(in app: XCUIApplication) {
        tapNativeChrome(app.navigationBars["Library Settings"].buttons.firstMatch, in: app)
        XCTAssertTrue(app.navigationBars["Profile & Settings"].waitForExistence(timeout: 5))
        tapNativeChrome(app.navigationBars["Profile & Settings"].buttons["Done"], in: app)
    }

    @objc func testExplicitPrimaryGenreBuildCancelLateResponseAndSharedSearchLibrarySnapshot() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, compactFixtureControls: true, primaryGenres: true,
                heldPrimaryGenreMetadata: true))
        selectTab("Search", in: app)
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        XCTAssertFalse(app.buttons["Fixture Genre"].exists)

        func reads(_ expected: String, release: Bool = false) {
            openAlphabetFixtureControls(app)
            if release { app.buttons["Release primary genre metadata"].tap() }
            app.buttons["Read primary genre counts"].tap()
            let proof = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", expected),
                object: app.staticTexts["fixture-primary-genre-counts"])
            XCTAssertEqual(XCTWaiter.wait(for: [proof], timeout: 5), .completed)
            closeAlphabetFixtureControls(app)
        }

        reads("metadata 0 returned 0")
        openGenreLibrarySettings(in: app)
        tapNativeChrome(app.buttons["settings-rebuild-genres"], in: app)
        XCTAssertTrue(app.buttons["settings-cancel-genres"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 songs checked"].exists)
        closeGenreLibrarySettings(in: app)
        reads("metadata 1 returned 0")
        openGenreLibrarySettings(in: app)
        tapNativeChrome(app.buttons["settings-cancel-genres"], in: app)
        XCTAssertTrue(app.buttons["settings-rebuild-genres"].isEnabled)
        closeGenreLibrarySettings(in: app)
        selectTab("Search", in: app)
        XCTAssertFalse(app.buttons["Fixture Rare Genre"].exists)
        XCTAssertFalse(app.buttons["primary-genres-cancel"].exists)

        openGenreLibrarySettings(in: app)
        tapNativeChrome(app.buttons["settings-rebuild-genres"], in: app)
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: app.buttons["settings-rebuild-genres"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
        closeGenreLibrarySettings(in: app)
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-genres"], in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["library-index-genre"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        let libraryGenre = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Fixture Genre", "View Fixture Genre")
        ).firstMatch
        XCTAssertTrue(libraryGenre.waitForExistence(timeout: 5))
        let other = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Fixture Other Genre", "View Fixture Other Genre")
        ).firstMatch
        XCTAssertTrue(other.exists)
        XCTAssertFalse(app.staticTexts["Fixture Rare Genre"].exists)
        reads("metadata 2 returned 2", release: true)
        XCTAssertTrue(libraryGenre.exists)
        XCTAssertFalse(
            app.staticTexts["Fixture Rare Genre"].exists,
            "Late cancelled rare-only metadata cannot replace the accepted primary set")
        selectTab("Search", in: app)
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertTrue(app.buttons["Fixture Genre"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Fixture Other Genre"].exists)
        XCTAssertFalse(app.buttons["Fixture Rare Genre"].exists)
        reads("metadata 2 returned 2")
        capture("Settings-only genre maintenance shares one Search and Library snapshot", in: app)
    }

    @objc func testPrimaryGenreSeededQueryClearsAndColdDownloadedDestinationUsesCanonicalSongs() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", compactFixtureControls: true,
                primaryGenres: true, primaryGenreScopedQuery: true, automaticGenres: true))
        selectTab("Search", in: app)
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        XCTAssertTrue(app.buttons["Fixture Genre"].waitForExistence(timeout: 5))
        let search = app.textFields["Search music"]
        tapNativeChrome(search, in: app)
        search.typeText("Fixture Genre")
        app.buttons["search-dismiss-keyboard"].tap()
        tapVisible(app.buttons["See all genres"], in: app)
        let scoped = app.searchFields["Search genres"]
        for _ in 0..<16 {
            if scoped.exists && scoped.isHittable { break }
            scrollContent(in: app, upward: false)
        }
        XCTAssertTrue(scoped.waitForExistence(timeout: 5))
        XCTAssertEqual(scoped.value as? String, "Fixture Genre")
        tapNativeChrome(scoped, in: app)
        scoped.typeText(
            String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Fixture Genre".count))
        let other = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Fixture Other Genre", "View Fixture Other Genre")
        ).firstMatch
        let closeSearch = app.navigationBars["Genres"].buttons["Close"]
        if closeSearch.exists { tapNativeChrome(closeSearch, in: app) }
        reveal(other, in: app)
        XCTAssertTrue(other.exists, "Clearing seeded query must clear the filter")
        let genre = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Fixture Genre", "View Fixture Genre")
        ).firstMatch
        tapVisible(genre, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["primary-genre-songs"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Tracks", title: "Fixture Genre", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
                .firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Primary Song 2"))
                .firstMatch.exists,
            "Online destination must include song-only genres without album tags")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Canonical fixture ready"].waitForExistence(timeout: 15))
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-genres"], in: app)
        let restored = app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label BEGINSWITH %@",
                "Fixture Genre", "View Fixture Genre")
        ).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        openAlphabetFixtureControls(app)
        app.buttons["Read primary genre counts"].tap()
        let noScan = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "metadata 0 returned 0"),
            object: app.staticTexts["fixture-primary-genre-counts"])
        XCTAssertEqual(XCTWaiter.wait(for: [noScan], timeout: 5), .completed)
        app.switches["Simulate unavailable network"].switches.firstMatch.tap()
        closeAlphabetFixtureControls(app)
        tapVisible(restored, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["primary-genre-songs"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Tracks", title: "Fixture Genre", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Fixture Tone"))
                .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Primary Song 2"))
                .firstMatch.exists, "Offline destination contains only ready canonical members")
        capture("Cold downloaded primary genre resolves songs without a prior album page", in: app)
    }

    @objc func testHomeAutomaticGenrePreviewCardsRenderAcrossSiblingShelvesAndTabReentry() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", compactFixtureControls: true,
                primaryGenres: true, automaticGenres: true))
        selectTab("Library", in: app)
        tapVisibleCenter(app.buttons["library-category-genres"], in: app)
        for title in ["Fixture Genre", "Fixture Other Genre"] {
            XCTAssertTrue(
                app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title))
                    .firstMatch.waitForExistence(timeout: 10),
                "The canonical snapshot must contain both eligible genres before Home proof")
        }
        selectTab("Home", in: app)
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        for pass in 0..<2 {
            for (id, title) in [("genre", "Fixture Genre"), ("other-genre", "Fixture Other Genre")]
            {
                let heading = app.buttons["home-shelf-" + title]
                revealHomeGenrePreview(heading, in: app)
                let card = app.buttons["home-genre-album-" + id + "-album"]
                XCTAssertTrue(
                    card.waitForExistence(timeout: 10),
                    "Automatic publication must render preview albums for every eligible shelf")
                revealHomeGenrePreview(card, in: app)
                XCTAssertTrue(card.isHittable)
                XCTAssertGreaterThanOrEqual(card.frame.width, 140)
                XCTAssertGreaterThanOrEqual(card.frame.height, 144)
                XCTAssertTrue(app.frame.contains(CGPoint(x: card.frame.midX, y: card.frame.midY)))
                capture("Home \(title) populated preview pass \(pass)", in: app)
            }
            if pass == 0 {
                if !app.tabBars.buttons["Library"].exists {
                    tapNativeChrome(app.tabBars.buttons["Home"], in: app)
                }
                selectTab("Library", in: app)
                selectTab("Home", in: app)
            }
        }
    }

    private func selectCanonicalGenreContent(
        _ content: String, title: String, in app: XCUIApplication
    ) {
        let picker = app.segmentedControls["primary-genre-content-picker"]
        XCTAssertTrue(
            picker.waitForExistence(timeout: 5), "\(title) must show its segmented control")
        XCTAssertTrue(picker.isHittable, "Genre choices must be visible without opening a menu")
        let navigation = app.navigationBars[title]
        XCTAssertTrue(navigation.exists)
        XCTAssertTrue(
            navigation.frame.contains(CGPoint(x: picker.frame.midX, y: picker.frame.midY)),
            "The icon segments belong in the native title bar")
        XCTAssertTrue(app.buttons["primary-genre-sort-filter"].isHittable)
        for choice in ["Albums", "Tracks", "Artists"] {
            XCTAssertTrue(picker.buttons[choice].exists)
        }
        let choice = picker.buttons[content]
        choice.tap()
        XCTAssertTrue(picker.buttons[content].isSelected)
        capture("Genre segmented control selected \(content)", in: app)
    }

    private func revealHomeGenrePreview(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["foundation-home-scroll"]
        XCTAssertTrue(scroll.exists)
        for _ in 0..<6 {
            let viewport = scroll.frame.intersection(app.frame)
            let visible = viewport.insetBy(dx: 0, dy: 100)
            let frame = element.exists ? element.frame : .zero
            if frame.width > 0, frame.height > 0,
                visible.contains(CGPoint(x: frame.midX, y: frame.midY)), element.isHittable
            {
                return
            }
            let upward = frame.height == 0 || frame.midY >= visible.midY
            let start = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.75 : 0.3))
            let end = scroll.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.3 : 0.75))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        capture("Home genre preview target missing after bounded scroll", in: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Home genre preview bounded scroll hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Home must render and expose every eligible genre preview target")
    }

    @objc func testHomeAutomaticallyPreparedGenresOpenCanonicalSongMembership() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", compactFixtureControls: true,
                primaryGenres: true, automaticGenres: true))
        selectTab("Home", in: app)
        let shelf = app.buttons["home-shelf-Fixture Genre"]
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        revealHomeGenrePreview(shelf, in: app)
        XCTAssertTrue(shelf.waitForExistence(timeout: 10))
        shelf.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["primary-genre-songs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["View Fixture Album"].waitForExistence(timeout: 5))
        let picker = app.segmentedControls["primary-genre-content-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)
        XCTAssertTrue(picker.buttons["Albums"].isSelected)
        selectCanonicalGenreContent("Artists", title: "Fixture Genre", in: app)
        XCTAssertTrue(app.buttons["View Fixture Artist"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Albums", title: "Fixture Genre", in: app)
        XCTAssertTrue(app.buttons["View Fixture Album"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Tracks", title: "Fixture Genre", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Primary Song 2"))
                .firstMatch.exists, "Home genre routes must preserve song-only canonical membership"
        )
        selectCanonicalGenreContent("Albums", title: "Fixture Genre", in: app)
        XCTAssertTrue(app.buttons["View Fixture Album"].waitForExistence(timeout: 5))
        capture("Home automatic genres use visible native segments and canonical content", in: app)
    }

    @objc func testNewAndPinnedGenresUseCanonicalSongDestinationsWithoutAlbumGenreQueries() {
        continueAfterFailure = false
        let app = launch(
            .init(
                productionShell: true, canonicalDownloadState: "full", compactFixtureControls: true,
                primaryGenres: true, automaticGenres: true))
        selectTab("Search", in: app)
        if app.buttons["search-dismiss-keyboard"].exists {
            app.buttons["search-dismiss-keyboard"].tap()
        }
        XCTAssertFalse(app.buttons["primary-genres-build"].exists)
        XCTAssertTrue(app.buttons["Fixture Genre"].waitForExistence(timeout: 5))
        selectTab("New", in: app)
        tapVisible(app.buttons["Fixture Genre"], in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["primary-genre-songs"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Tracks", title: "Fixture Genre", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Primary Song 2"))
                .firstMatch.exists,
            "New must navigate canonical songs even without album genre tags")
        selectTab("Library", in: app)
        tapVisible(app.buttons["library-category-genres"], in: app)
        tapVisible(app.buttons["Actions for Fixture Genre"], in: app)
        let pin = app.buttons["Pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        pin.tap()
        tapNativeChrome(app.navigationBars["Genres"].buttons.firstMatch, in: app)
        let pinned = app.buttons["Fixture Genre"]
        tapVisible(pinned, in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["primary-genre-songs"].waitForExistence(timeout: 5))
        selectCanonicalGenreContent("Tracks", title: "Fixture Genre", in: app)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Primary Song 2"))
                .firstMatch.exists,
            "Saved genre pin must resolve the current canonical descriptor")
        openAlphabetFixtureControls(app)
        app.buttons["Read primary genre counts"].tap()
        let census = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "metadata 1 returned 1"),
            object: app.staticTexts["fixture-primary-genre-counts"])
        XCTAssertEqual(XCTWaiter.wait(for: [census], timeout: 5), .completed)
        closeAlphabetFixtureControls(app)
        capture("New and pinned genres share canonical song membership", in: app)
    }
}
