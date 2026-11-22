import CryptoKit
import Security
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import CarPlay
    import UIKit
#endif

@MainActor
final class FoundationStartupTests: XCTestCase {
    private func backgroundFixture() throws -> (
        root: URL, directory: URL, identifier: String, data: Data,
        store: FoundationNativeAllocationStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = FoundationSession(
            serverURL: URL(string: "https://background-fixture.invalid")!,
            accessToken: "fixture-token",
            userID: "00000000000000000000000000000001",
            deviceID: "00000000-0000-0000-0000-000000000002")
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        let scope = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }
            .joined()
        let directory = FoundationDownloadStorage.directory(scope: scope, root: root)
        try FoundationDownloadStorage.prepare(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let identifier =
            "dev.novoluxor.velacanto.offline." + directory.lastPathComponent + "."
            + UUID().uuidString
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: identifier)
        try store.reserve()
        var manifest = FoundationDownloadManifest()
        manifest.nativePendingSessions = [identifier]
        try FoundationDownloadStorage.save(manifest, directory: directory)
        return (root, directory, identifier, try JSONEncoder().encode(session), store)
    }

    private func backgroundPreferences() throws -> FoundationPlaybackPreferences {
        let suite = "BackgroundSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return FoundationPlaybackPreferences(defaults: defaults)
    }

    private func backgroundCredentials(_ data: Data, status: OSStatus = errSecSuccess)
        -> FoundationCredentials.Operations
    {
        .init(
            update: { _, _ in
                XCTFail("Background events must not save credentials")
                return errSecParam
            },
            add: { _ in
                XCTFail("Background events must not add credentials")
                return errSecParam
            },
            copy: { _ in (status, status == errSecSuccess ? data as CFData : nil) },
            delete: { _ in
                XCTFail("Background events must not clear credentials")
                return errSecParam
            })
    }

    private enum BackgroundOutcomeFailure: Error { case handoffTimedOut }

    private func waitForBackgroundOutcome(_ outcome: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while !outcome() {
            guard clock.now < deadline else {
                throw BackgroundOutcomeFailure.handoffTimedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testBackgroundEventDrainWaitsForDurableAccountRecoveryAndSerializesStartup() async throws {
        let fixture = try backgroundFixture()
        let gate = PreparationGate()
        var preparations = 0
        var restorations = 0
        var completions = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return true
            },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(fixture.data),
            playbackPreferences: try backgroundPreferences(),
            backgroundDownloadRoot: fixture.root,
            backgroundNativeRetirement: { identifiers, directory in
                guard await gate.prepare() else { return [] }
                for identifier in identifiers {
                    try? FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier
                    ).retire()
                }
                return identifiers
            })
        let completion: @MainActor () -> Void = {
            XCTAssertTrue(Thread.isMainThread)
            completions += 1
        }
        model.receiveBackgroundDownloadEvents(fixture.identifier, completionHandler: completion)
        model.receiveBackgroundDownloadEvents(fixture.identifier, completionHandler: completion)
        do {
            try await gate.waitUntilStarted()
        } catch {
            model.invalidateAccountReadiness()
            model.finishBackgroundDownloadEvents(fixture.identifier)
            throw error
        }
        // Drain arrives before durable publication.
        model.finishBackgroundDownloadEvents(fixture.identifier)
        XCTAssertEqual(completions, 0)
        model.restore()
        await Task.yield()
        let startup = Task { await model.ensureReady() }
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(restorations, 0)
        gate.complete(true)
        let readiness = try await requireStartupTask(
            startup, model: model, gates: [gate], name: "background startup")
        XCTAssertEqual(readiness, .signedOut)
        XCTAssertEqual(completions, 2)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 1)
        XCTAssertTrue(
            try FoundationDownloadStorage.load(directory: fixture.directory).nativePendingSessions?
                .isEmpty == true)
        XCTAssertEqual(try fixture.store.load().retired, true)
        model.finishBackgroundDownloadEvents(fixture.identifier)
        XCTAssertEqual(completions, 2)
    }

    func testBackgroundDurableRecoveryWaitsForNativeDrainWithoutBootstrappingAccount() async throws
    {
        let fixture = try backgroundFixture()
        var completions = 0
        let completed = XCTestExpectation(description: "background completion delivered")
        let model = FoundationAppModel(
            prepareCaches: {
                XCTFail("Headless callback bootstrapped caches")
                return false
            },
            restoreAccount: { _ in XCTFail("Headless callback restored catalog/player") },
            credentialOperations: backgroundCredentials(fixture.data),
            playbackPreferences: try backgroundPreferences(),
            backgroundDownloadRoot: fixture.root,
            backgroundNativeRetirement: { identifiers, directory in
                for identifier in identifiers {
                    try? FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier
                    ).retire()
                }
                return identifiers
            })
        model.receiveBackgroundDownloadEvents(fixture.identifier) {
            completions += 1
            if completions == 1 { completed.fulfill() }
        }
        do {
            try await waitForBackgroundOutcome {
                (try? FoundationDownloadStorage.load(directory: fixture.directory)
                    .nativePendingSessions?.isEmpty) == true
            }
        } catch {
            model.finishBackgroundDownloadEvents(fixture.identifier)
            throw error
        }
        XCTAssertEqual(completions, 0)
        XCTAssertNil(model.library)
        XCTAssertFalse(model.cachesReady)
        model.finishBackgroundDownloadEvents(fixture.identifier)
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 3) == .completed else {
            model.invalidateAccountReadiness()
            XCTFail("Background completion was not delivered within 3 seconds")
            return
        }
        XCTAssertEqual(completions, 1)
        model.finishBackgroundDownloadEvents(fixture.identifier)
        XCTAssertEqual(completions, 1)
    }

    #if DEBUG
        func testUnknownAndLockedBackgroundEventsPreserveProtectedAccountRecords() async throws {
            for locked in [false, true] {
                let fixture = try backgroundFixture()
                let manifestURL = fixture.directory.appendingPathComponent("manifest.json")
                let manifestBefore = try Data(contentsOf: manifestURL)
                let receiptBefore = try Data(contentsOf: fixture.store.receiptURL)
                var completions = 0
                let model = FoundationAppModel(
                    prepareCaches: {
                        XCTFail("Unexpected bootstrap")
                        return false
                    },
                    restoreAccount: { _ in XCTFail("Unexpected account restore") },
                    credentialOperations: backgroundCredentials(
                        fixture.data, status: locked ? errSecInteractionNotAllowed : errSecSuccess),
                    playbackPreferences: try backgroundPreferences(),
                    backgroundDownloadRoot: fixture.root,
                    backgroundNativeRetirement: { _, _ in
                        XCTFail("Unadmitted native session opened")
                        return []
                    })
                let settled = expectation(description: "unresolved background route settled")
                model.backgroundRoutingSettled = { _ in settled.fulfill() }
                model.receiveBackgroundDownloadEvents(
                    locked ? fixture.identifier : fixture.identifier + ".unknown"
                ) { completions += 1 }
                let result = await XCTWaiter.fulfillment(of: [settled], timeout: 5)
                XCTAssertEqual(result, .completed)
                model.finishBackgroundDownloadEvents(fixture.identifier)
                XCTAssertEqual(completions, 0)
                XCTAssertEqual(try Data(contentsOf: manifestURL), manifestBefore)
                XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), receiptBefore)
                XCTAssertNil(model.library)
            }
        }

        func testFailedNativeRetirementRetainsBackgroundCompletion() async throws {
            let fixture = try backgroundFixture()
            let beforeManifest = try Data(
                contentsOf: fixture.directory.appendingPathComponent("manifest.json"))
            let beforeReceipt = try Data(contentsOf: fixture.store.receiptURL)
            var completions = 0
            let model = FoundationAppModel(
                prepareCaches: {
                    XCTFail("Unexpected bootstrap")
                    return false
                },
                restoreAccount: { _ in XCTFail("Unexpected account restore") },
                credentialOperations: backgroundCredentials(fixture.data),
                playbackPreferences: try backgroundPreferences(),
                backgroundDownloadRoot: fixture.root,
                backgroundNativeRetirement: { _, _ in [] })
            let settled = expectation(description: "failed retirement route settled")
            model.backgroundRoutingSettled = { _ in settled.fulfill() }
            model.receiveBackgroundDownloadEvents(fixture.identifier) { completions += 1 }
            model.finishBackgroundDownloadEvents(fixture.identifier)
            let result = await XCTWaiter.fulfillment(of: [settled], timeout: 5)
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(completions, 0)
            XCTAssertEqual(
                try Data(contentsOf: fixture.directory.appendingPathComponent("manifest.json")),
                beforeManifest)
            XCTAssertEqual(try Data(contentsOf: fixture.store.receiptURL), beforeReceipt)
        }

        func testRetiredAccountCannotPublishLateBackgroundRecovery() async throws {
            let fixture = try backgroundFixture()
            let gate = PreparationGate()
            var completions = 0
            let model = FoundationAppModel(
                prepareCaches: {
                    XCTFail("Unexpected bootstrap")
                    return false
                },
                restoreAccount: { _ in XCTFail("Unexpected account restore") },
                credentialOperations: backgroundCredentials(fixture.data),
                playbackPreferences: try backgroundPreferences(),
                backgroundDownloadRoot: fixture.root,
                backgroundNativeRetirement: { identifiers, directory in
                    guard await gate.prepare() else { return [] }
                    for identifier in identifiers {
                        try? FoundationNativeAllocationStore(
                            directory: directory, sessionIdentifier: identifier
                        ).retire()
                    }
                    return identifiers
                })
            let settled = XCTestExpectation(description: "retired background route settled")
            model.backgroundRoutingSettled = { _ in settled.fulfill() }
            model.receiveBackgroundDownloadEvents(fixture.identifier) { completions += 1 }
            do {
                try await gate.waitUntilStarted()
            } catch {
                model.invalidateAccountReadiness()
                model.finishBackgroundDownloadEvents(fixture.identifier)
                throw error
            }
            model.invalidateAccountReadiness()
            model.finishBackgroundDownloadEvents(fixture.identifier)
            gate.complete(true)
            let result = await XCTWaiter.fulfillment(of: [settled], timeout: 5)
            XCTAssertEqual(result, .completed)
            XCTAssertEqual(completions, 0)
            XCTAssertTrue(
                try FoundationDownloadStorage.load(directory: fixture.directory)
                    .nativePendingSessions?
                    .contains(fixture.identifier) == true)
            // Retain cleanup authority for the matching account.
            XCTAssertEqual(try fixture.store.load().retired, true)
            XCTAssertNil(model.library)
        }

    #endif

    func testInactiveSceneDoesNotRestoreAccountButExplicitReadinessStillWorks() async throws {
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return true
            },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound),
            playbackPreferences: try backgroundPreferences())
        await model.prepareForScene(isActive: false)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(restorations, 0)
        XCTAssertTrue(model.isPreparingCaches)
        // Siri/Handoff explicitly call readiness without relying on scene activity.
        let explicit = await model.ensureReady()
        XCTAssertEqual(explicit, .signedOut)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 1)
        await model.prepareForScene(isActive: true)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 1)
        let freshForegroundModel = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return true
            },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound),
            playbackPreferences: try backgroundPreferences())
        await freshForegroundModel.prepareForScene(isActive: false)
        XCTAssertEqual(preparations, 1)
        await freshForegroundModel.prepareForScene(isActive: true)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(restorations, 2)
        XCTAssertTrue(freshForegroundModel.cachesReady)
    }

    func testAppModelRetainsInjectedPlaybackPreferencesDuringReadiness() async throws {
        let suite = "StartupPlaybackPreferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            FoundationStreamingQuality.aac128.rawValue,
            forKey: FoundationPlaybackPreferences.streamingCellularQualityKey)
        let preferences = FoundationPlaybackPreferences(defaults: defaults)
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return true
            },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound),
            credentialDefaults: defaults,
            playbackPreferences: preferences)
        let readiness = await model.ensureReady()
        XCTAssertEqual(readiness, .signedOut)
        XCTAssertTrue(model.playbackPreferences === preferences)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 1)
        XCTAssertEqual(model.playbackPreferences.streamingCellularQuality, .aac128)
        model.playbackPreferences.setStreamingCellularQuality(.aac192)
        XCTAssertEqual(
            defaults.string(
                forKey:
                    FoundationPlaybackPreferences.streamingCellularQualityKey), "aac192")
    }

    #if DEBUG
        func testTestingRuntimeUsesDisposablePreferencesAndDoesNotRestoreAnAccount() async throws {
            guard ProcessInfo.processInfo.arguments.contains("-foundationTesting") else {
                XCTFail("This isolated bootstrap check requires the existing test-host argument")
                return
            }
            let suite = "StartupTestingRuntime-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("aac192", forKey: FoundationPlaybackPreferences.streamingQualityKey)
            defaults.set("data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
            let model = FoundationAppRuntime.makeTestingModel(defaults: defaults)
            XCTAssertEqual(model.playbackPreferences.streamingWiFiQuality, .aac192)
            XCTAssertEqual(model.playbackPreferences.streamingCellularQuality, .aac192)
            XCTAssertEqual(
                defaults.string(
                    forKey:
                        FoundationPlaybackPreferences.streamingWiFiQualityKey), "aac192")
            #if os(macOS)
                XCTAssertFalse(model.awaitsCredentialUpgrade)
                defaults.removeObject(forKey: FoundationAppModel.credentialBackendKey)
                XCTAssertTrue(model.awaitsCredentialUpgrade)
            #endif
            let readiness = await model.ensureReady()
            XCTAssertEqual(readiness, .unavailable)
            XCTAssertTrue(model.isPreparingCaches)
            XCTAssertFalse(model.cachesReady)
            #if os(iOS) && targetEnvironment(simulator)
                if Bundle.main.bundleIdentifier == "com.chameleonenterprise.velacanto.uitesting" {
                    guard FoundationDownloadsTestHarness.enabled else {
                        XCTFail(
                            "UITesting runtime qualification requires its validated fixture context"
                        )
                        return
                    }
                    // Native background callbacks must stop at this explicitly
                    // isolated global model, before account/session work starts.
                    for candidate in [model, FoundationAppRuntime.model] {
                        var completions = 0
                        candidate.receiveBackgroundDownloadEvents("synthetic-fixture-callback") {
                            completions += 1
                        }
                        XCTAssertEqual(completions, 1)
                        XCTAssertNil(candidate.library)
                        XCTAssertNil(candidate.player)
                        XCTAssertNil(candidate.downloads)
                    }
                }
            #endif
            XCTAssertNil(model.library)
            XCTAssertNil(model.player)
            XCTAssertNil(model.downloads)
            XCTAssertNil(model.librarySelection)
        }
    #endif
    #if os(iOS)
        func testPhoneRoutingDoesNotRecycleExistingDelegateConfiguration() {
            let existing = UISceneConfiguration(name: nil, sessionRole: .windowApplication)
            existing.delegateClass = FoundationCarPlaySceneDelegate.self
            let routed = FoundationCarPlayApplicationDelegate.sceneConfiguration(for: existing)
            XCTAssertFalse(routed === existing)
            XCTAssertEqual(routed.role, .windowApplication)
            XCTAssertNil(routed.delegateClass)
            XCTAssertTrue(existing.delegateClass == FoundationCarPlaySceneDelegate.self)
        }

        func testCarPlayRoutingUsesNativeSceneAndOwnedDelegate() {
            let existing = UISceneConfiguration(name: nil, sessionRole: .carTemplateApplication)
            existing.sceneClass = UIWindowScene.self
            existing.delegateClass = FoundationCarPlayApplicationDelegate.self
            let routed = FoundationCarPlayApplicationDelegate.sceneConfiguration(for: existing)
            XCTAssertFalse(routed === existing)
            XCTAssertEqual(routed.role, .carTemplateApplication)
            XCTAssertTrue(routed.sceneClass == CPTemplateApplicationScene.self)
            XCTAssertTrue(routed.delegateClass == FoundationCarPlaySceneDelegate.self)
        }

        func testCarPlayAudioSearchUsesOnlyNativeAssistantAndBrowseAction() throws {
            let template = CPListTemplate(title: "Search", sections: [])
            var browsed = 0
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: true, isRootTab: false, isActive: { true },
                browse: { browsed += 1 }, close: {})
            let assistant = try XCTUnwrap(template.assistantCellConfiguration)
            XCTAssertEqual(assistant.assistantAction, .playMedia)
            XCTAssertTrue(template.leadingNavigationBarButtons.isEmpty)
            XCTAssertEqual(template.backButton?.accessibilityLabel, "Back")
            let row = try XCTUnwrap(template.sections.first?.items.first as? CPListItem)
            XCTAssertEqual(row.text, "Browse Library")
            XCTAssertEqual(template.sections.first?.items.count, 1)
            XCTAssertEqual(browsed, 0, "Configuring the hub must not invoke browsing or Siri.")
            var completions = 0
            row.handler?(row, { completions += 1 })
            XCTAssertEqual(browsed, 1)
            XCTAssertEqual(completions, 1)
        }

        func testCarPlaySearchWithoutSiriKeepsBrowsingAndExplainsAuthorization() throws {
            let template = CPListTemplate(title: "Search", sections: [])
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: false, isRootTab: false, isActive: { true },
                browse: {}, close: {})
            XCTAssertNil(template.assistantCellConfiguration)
            let rows = try XCTUnwrap(template.sections.first?.items as? [CPListItem])
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.first?.text, "Browse Library")
            XCTAssertEqual(rows.last?.text, "Enable Siri on iPhone")
            XCTAssertEqual(rows.last?.isEnabled, false)
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: true, isRootTab: false, isActive: { true },
                browse: {}, close: {})
            XCTAssertNotNil(template.assistantCellConfiguration)
            XCTAssertEqual(template.sections.first?.items.count, 1)
        }

        func testCarPlayRootSearchHasExplicitCloseWithoutDuplicatingPushedBack() {
            let template = CPListTemplate(title: "Search", sections: [])
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: true, isRootTab: true, isActive: { true },
                browse: {}, close: {})
            XCTAssertEqual(template.leadingNavigationBarButtons.count, 1)
            XCTAssertEqual(template.leadingNavigationBarButtons.first?.title, "Close")
            XCTAssertEqual(
                template.leadingNavigationBarButtons.first?.accessibilityLabel, "Close Search")
            XCTAssertNil(template.backButton)
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: true, isRootTab: false, isActive: { true },
                browse: {}, close: {})
            XCTAssertTrue(template.leadingNavigationBarButtons.isEmpty)
            XCTAssertEqual(template.backButton?.accessibilityLabel, "Back")
        }

        func testCarPlaySearchCompletesInactiveNativeRowWithoutNavigating() throws {
            let template = CPListTemplate(title: "Search", sections: [])
            var active = true
            var navigations = 0
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, siriAuthorized: true, isRootTab: false, isActive: { active },
                browse: { navigations += 1 }, close: { navigations += 1 })
            let row = try XCTUnwrap(template.sections.first?.items.first as? CPListItem)
            active = false
            var completions = 0
            row.handler?(row, { completions += 1 })
            XCTAssertEqual(completions, 1)
            XCTAssertEqual(navigations, 0)
        }

        func testCarPlaySearchEntryKeepsNowPlayingAboveAnAlreadySelectedSearchTab() {
            let home = CPListTemplate(title: "Home", sections: [])
            let search = CPListTemplate(title: "Search", sections: [])
            let root = CPTabBarTemplate(templates: [home, search])
            root.select(search)
            let nowPlaying = CPNowPlayingTemplate.shared
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchEntryOrigin(
                    root: root, top: nowPlaying) === nowPlaying)
            let album = CPListTemplate(title: "Album", sections: [])
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchEntryOrigin(
                    root: root, top: album) === album)
        }

        func testCarPlayInitialNowPlayingIsConsumedOnceForReadyRoot() {
            let delegate = FoundationCarPlaySceneDelegate()
            let library = CPListTemplate(title: "Library", sections: [])
            let root = CPTabBarTemplate(templates: [library])
            XCTAssertTrue(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: root, contextIsCurrent: true))
            XCTAssertFalse(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: root, contextIsCurrent: true))
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate().consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: library, contextIsCurrent: true))
        }

        func testCarPlayInitialNowPlayingRejectsStaleContextAndReplacedRootWithoutConsuming() {
            let delegate = FoundationCarPlaySceneDelegate()
            let root = CPTabBarTemplate(templates: [CPListTemplate(title: "Library", sections: [])])
            let replacement = CPTabBarTemplate(templates: [
                CPListTemplate(title: "Home", sections: [])
            ])
            XCTAssertFalse(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: root, contextIsCurrent: false))
            XCTAssertFalse(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: replacement, top: replacement, contextIsCurrent: true))
            XCTAssertTrue(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: root, contextIsCurrent: true))
        }

        func testCarPlayInitialNowPlayingDoesNotOverrideOrLaterFollowUserNavigation() {
            let delegate = FoundationCarPlaySceneDelegate()
            let root = CPTabBarTemplate(templates: [CPListTemplate(title: "Library", sections: [])])
            let album = CPListTemplate(title: "Album", sections: [])
            XCTAssertFalse(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: album, contextIsCurrent: true))
            XCTAssertFalse(
                delegate.consumeInitialNowPlaying(
                    root: root, currentRoot: root, top: root, contextIsCurrent: true))
        }

        func testCarPlaySearchReturnsToExactNestedOriginAndSelectedContentTab() {
            let home = CPListTemplate(title: "Home", sections: [])
            let library = CPListTemplate(title: "Library", sections: [])
            let album = CPListTemplate(title: "Album", sections: [])
            let hub = CPListTemplate(title: "Search", sections: [])
            let root = CPTabBarTemplate(templates: [home, library])
            let nowPlaying = CPNowPlayingTemplate.shared
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchReturnTarget(
                    origin: nowPlaying, lastContentTab: library,
                    stack: [root, nowPlaying, hub], tabs: [home, library]) === nowPlaying)
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchReturnTarget(
                    origin: album, lastContentTab: library,
                    stack: [root, album, hub], tabs: [home, library]) === album)
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchReturnTarget(
                    origin: library, lastContentTab: home,
                    stack: [root, hub], tabs: [home, library]) === library)
            XCTAssertTrue(
                FoundationCarPlaySceneDelegate.searchReturnTarget(
                    origin: album, lastContentTab: library,
                    stack: [root, hub], tabs: [home, library]) === library,
                "A retired route must not be resurrected.")
        }

        func testSearchReturnUsesRootOperationForTabsAndSinglePopsForBrowsePages() {
            let home = CPListTemplate(title: "Home", sections: [])
            let search = CPListTemplate(title: "Search", sections: [])
            let album = CPListTemplate(title: "Album", sections: [])
            let destination = CPListTemplate(title: "Destination", sections: [])
            let root = CPTabBarTemplate(templates: [home, search])
            let step = FoundationCarPlaySceneDelegate.searchReturnStep
            XCTAssertEqual(
                step(home, root, destination, [root, search, destination], [home, search]),
                .popToRoot)
            XCTAssertEqual(step(home, root, root, [root], [home, search]), .selectTab)
            XCTAssertEqual(step(home, root, search, [root, search], [home, search]), .selectTab)
            XCTAssertEqual(
                step(
                    album, root, destination, [root, album, search, destination], [home, search]),
                .popOne)
            XCTAssertEqual(step(album, root, album, [root, album], [home, search]), .done)
            let nowPlaying = CPNowPlayingTemplate.shared
            XCTAssertEqual(
                step(nowPlaying, root, search, [root, nowPlaying, search], [home, search]), .popOne)
            XCTAssertEqual(
                step(nowPlaying, root, nowPlaying, [root, nowPlaying], [home, search]), .done)
            XCTAssertEqual(
                step(album, root, destination, [root, destination], [home, search]),
                .unavailable)
        }

        func testCarPlayCategoryArtworkPreservesAspectAndInsetsAtDisplayScale() throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = UIGraphicsImageRenderer(
                size: CGSize(width: 80, height: 20), format: format
            )
            .image { _ in
                UIColor.white.setFill()
                UIRectFill(CGRect(x: 0, y: 0, width: 80, height: 20))
            }
            let traits = UITraitCollection { value in
                value.userInterfaceStyle = .dark
                value.displayScale = 3
            }
            let rendered = FoundationCarPlaySceneDelegate.insetNavigationImage(
                source, size: CGSize(width: 100, height: 100), traits: traits)
            let image = try XCTUnwrap(rendered.cgImage)
            XCTAssertEqual(image.width, 300)
            XCTAssertEqual(image.height, 300)
            var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try XCTUnwrap(
                CGContext(
                    data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var minX = image.width
            var minY = image.height
            var maxX = -1
            var maxY = -1
            for y in 0..<image.height {
                for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 127 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            XCTAssertGreaterThan(maxX, minX)
            XCTAssertEqual(Double(maxX - minX + 1) / Double(maxY - minY + 1), 4, accuracy: 0.1)
            XCTAssertGreaterThanOrEqual(minX, 59)
            XCTAssertGreaterThanOrEqual(minY, 59)
            XCTAssertEqual(minX, image.width - 1 - maxX, accuracy: 1)
            XCTAssertEqual(minY, image.height - 1 - maxY, accuracy: 1)
            let category = FoundationCarPlaySceneDelegate.libraryCategorySymbol(
                "heart.fill", traits: traits)
            XCTAssertEqual(category.size, CPListImageRowItemCondensedElement.maximumImageSize)
            XCTAssertEqual(category.scale, 3)
        }

    #endif

    @MainActor
    private final class PreparationGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var started = false
        private var completed: Bool?

        func prepare() async -> Bool {
            started = true
            if let completed { return completed }
            return await withCheckedContinuation { continuation = $0 }
        }

        private enum WaitError: Error {
            case startupTimedOut
        }

        func waitUntilStarted() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            do {
                while !started {
                    guard clock.now < deadline else { throw WaitError.startupTimedOut }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch {
                complete(false)
                throw error
            }
        }

        func complete(_ result: Bool) {
            completed = result
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private enum StartupTaskFailure: Error {
        case completionTimedOut(String)
    }

    @MainActor
    private final class StartupTaskObservation {
        let finished: XCTestExpectation
        private(set) var result: FoundationAppModel.Readiness?
        init(name: String) { finished = XCTestExpectation(description: name) }
        func record(_ value: FoundationAppModel.Readiness) {
            result = value
            finished.fulfill()
        }
    }

    private func requireStartupTask(
        _ task: Task<FoundationAppModel.Readiness, Never>,
        companions: [Task<FoundationAppModel.Readiness, Never>] = [],
        model: FoundationAppModel, gates: [PreparationGate], name: String
    ) async throws -> FoundationAppModel.Readiness {
        let observation = StartupTaskObservation(name: name)
        let observer = Task { observation.record(await task.value) }
        guard await XCTWaiter.fulfillment(of: [observation.finished], timeout: 5) == .completed,
            let result = observation.result
        else {
            task.cancel()
            for companion in companions { companion.cancel() }
            model.invalidateAccountReadiness()
            for gate in gates { gate.complete(false) }
            observer.cancel()
            throw StartupTaskFailure.completionTimedOut(name)
        }
        return result
    }

    func testConcurrentEntrypointsRestoreOnceWithoutCreatingPlayback() async throws {
        let gate = PreparationGate()
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return await gate.prepare()
            }, restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let phone = Task { await model.ensureReady() }
        do {
            try await gate.waitUntilStarted()
        } catch {
            phone.cancel()
            model.invalidateAccountReadiness()
            throw error
        }
        let carPlay = Task { await model.ensureReady() }
        model.restore()
        gate.complete(true)
        let phoneResult = try await requireStartupTask(
            phone, companions: [carPlay], model: model, gates: [gate], name: "phone startup")
        let carPlayResult = try await requireStartupTask(
            carPlay, model: model, gates: [gate], name: "CarPlay startup")
        let repeatedResult = await model.ensureReady()
        XCTAssertEqual(phoneResult, .signedOut)
        XCTAssertEqual(carPlayResult, .signedOut)
        XCTAssertEqual(repeatedResult, .signedOut)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 1)
        XCTAssertNil(model.player)
        XCTAssertNil(model.library)
        XCTAssertFalse(model.isPreparingCaches)
    }

    func testCancelledCallerDoesNotCancelSharedStartup() async throws {
        let gate = PreparationGate()
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: { await gate.prepare() },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let caller = Task { await model.ensureReady() }
        do {
            try await gate.waitUntilStarted()
        } catch {
            caller.cancel()
            model.invalidateAccountReadiness()
            throw error
        }
        caller.cancel()
        gate.complete(true)
        let cancelled = try await requireStartupTask(
            caller, model: model, gates: [gate], name: "cancelled startup caller")
        let later = await model.ensureReady()
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(later, .signedOut)
        XCTAssertEqual(restorations, 1)
    }

    func testAccountRetirementRejectsSuspendedRestoration() async throws {
        let gate = PreparationGate()
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: { await gate.prepare() },
            restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let caller = Task { await model.ensureReady() }
        do {
            try await gate.waitUntilStarted()
        } catch {
            caller.cancel()
            model.invalidateAccountReadiness()
            throw error
        }
        model.invalidateAccountReadiness()
        gate.complete(true)
        let result = try await requireStartupTask(
            caller, model: model, gates: [gate], name: "retired startup caller")
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(restorations, 0)
        XCTAssertNil(model.player)
        XCTAssertFalse(model.isPreparingCaches)
    }

    func testPreparationFailureIsRetainedUntilExplicitRetry() async throws {
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return preparations > 1
            }, restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let failed = await model.ensureReady()
        let repeated = await model.ensureReady()
        XCTAssertEqual(failed, .unavailable)
        XCTAssertEqual(repeated, .unavailable)
        XCTAssertEqual(preparations, 1)
        XCTAssertEqual(restorations, 0)
        model.retryCachePreparation()
        let retried = await model.ensureReady()
        XCTAssertEqual(retried, .signedOut)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(restorations, 1)
        XCTAssertNil(model.credentialError)
    }

    func testRetryRejectsLatePreparationFromPreviousGeneration() async throws {
        let first = PreparationGate()
        let second = PreparationGate()
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return await (preparations == 1 ? first : second).prepare()
            }, restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let original = Task { await model.ensureReady() }
        do {
            try await first.waitUntilStarted()
        } catch {
            original.cancel()
            model.invalidateAccountReadiness()
            throw error
        }
        model.retryCachePreparation()
        do {
            try await second.waitUntilStarted()
        } catch {
            original.cancel()
            first.complete(false)
            model.invalidateAccountReadiness()
            throw error
        }
        first.complete(false)
        let retired = try await requireStartupTask(
            original, model: model, gates: [first, second], name: "retired startup generation")
        XCTAssertEqual(retired, .cancelled)
        XCTAssertTrue(model.isPreparingCaches)
        XCTAssertNil(model.credentialError)
        second.complete(true)
        let current = await model.ensureReady()
        XCTAssertEqual(current, .signedOut)
        XCTAssertEqual(restorations, 1)
    }

    func testAlreadyCancelledCallerDoesNotStartPreparation() async throws {
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return true
            }, restoreAccount: { _ in restorations += 1 },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await model.ensureReady()
        }
        let result = await caller.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(restorations, 0)
        XCTAssertNil(model.player)
    }

    func testUnavailableCredentialsRemainAnHonestReadinessFailure() async throws {
        let model = FoundationAppModel(
            prepareCaches: { true },
            restoreAccount: { $0.credentialError = "Saved sign-in unavailable." },
            credentialOperations: backgroundCredentials(Data(), status: errSecItemNotFound))
        let result = await model.ensureReady()
        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(model.player)
        XCTAssertNil(model.library)
        XCTAssertTrue(model.cachesReady)
    }
}

@MainActor
final class FoundationCredentialsTests: XCTestCase {
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic-test-token",
            userID: "00000000-0000-0000-0000-000000000002",
            deviceID: "00000000-0000-0000-0000-000000000001")
    }

    private func assertIsolatedStore(
        _ query: [String: Any], file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            query[kSecClass as String] as? String, kSecClassGenericPassword as String,
            file: file, line: line)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            "Velacanto.NativeFoundation.Session", file: file, line: line)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String, "current-session",
            file: file, line: line)
        XCTAssertEqual(
            query[kSecAttrSynchronizable as String] as? Bool, false,
            file: file, line: line)
        #if os(macOS)
            XCTAssertEqual(
                query[kSecUseDataProtectionKeychain as String] as? Bool, true,
                file: file, line: line)
        #else
            XCTAssertNil(query[kSecUseDataProtectionKeychain as String], file: file, line: line)
        #endif
        XCTAssertNil(query[kSecAttrAccessControl as String], file: file, line: line)
    }

    func testSaveLoadAndDeleteUseOnlyTheSelectedStore() throws {
        var stored: Data?
        var calls: [String] = []
        let operations = FoundationCredentials.Operations(
            update: { query, attributes in
                self.assertIsolatedStore(query)
                XCTAssertEqual(
                    attributes[kSecAttrAccessible as String] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
                calls.append("update")
                return errSecItemNotFound
            },
            add: { query in
                self.assertIsolatedStore(query)
                XCTAssertEqual(
                    query[kSecAttrAccessible as String] as? String,
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
                stored = query[kSecValueData as String] as? Data
                calls.append("add")
                return errSecSuccess
            },
            copy: { query in
                self.assertIsolatedStore(query)
                XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
                calls.append("copy")
                return (errSecSuccess, stored as CFTypeRef?)
            },
            delete: { query in
                self.assertIsolatedStore(query)
                calls.append("delete")
                return errSecSuccess
            })
        try FoundationCredentials.save(session, operations: operations)
        let restored = try XCTUnwrap(FoundationCredentials.load(operations: operations))
        XCTAssertEqual(restored.accessToken, session.accessToken)
        try FoundationCredentials.clear(operations: operations)
        XCTAssertEqual(calls, ["update", "add", "copy", "delete"])
    }

    func testEmptyOrUnavailableModernStoreNeverFallsBackToLegacy() throws {
        for status in [
            errSecItemNotFound, errSecMissingEntitlement, errSecInteractionNotAllowed,
            errSecAuthFailed,
        ] {
            var reads = 0
            let operations = FoundationCredentials.Operations(
                update: { _, _ in
                    XCTFail("No writes on restore")
                    return errSecParam
                },
                add: { _ in
                    XCTFail("No writes on restore")
                    return errSecParam
                },
                copy: { query in
                    self.assertIsolatedStore(query)
                    reads += 1
                    return (status, nil)
                },
                delete: { _ in
                    XCTFail("Legacy items must remain untouched")
                    return errSecParam
                })
            if status == errSecItemNotFound {
                XCTAssertNil(try FoundationCredentials.load(operations: operations))
            } else {
                XCTAssertThrowsError(try FoundationCredentials.load(operations: operations))
            }
            XCTAssertEqual(reads, 1)
        }
    }

    func testRejectedUpdateDoesNotAttemptInsertOrDelete() {
        let operations = FoundationCredentials.Operations(
            update: { query, _ in
                self.assertIsolatedStore(query)
                return errSecMissingEntitlement
            },
            add: { _ in
                XCTFail("Do not retry a rejected update")
                return errSecParam
            },
            copy: { _ in
                XCTFail("No fallback read")
                return (errSecParam, nil)
            },
            delete: { _ in
                XCTFail("No deletion")
                return errSecParam
            })
        XCTAssertThrowsError(try FoundationCredentials.save(session, operations: operations))
    }

    func testMissingModernItemCanBeClearedWithoutLegacyDeletion() throws {
        var deletes = 0
        let operations = FoundationCredentials.Operations(
            update: { _, _ in
                XCTFail("No update")
                return errSecParam
            },
            add: { _ in
                XCTFail("No insert")
                return errSecParam
            },
            copy: { _ in
                XCTFail("No read")
                return (errSecParam, nil)
            },
            delete: { query in
                self.assertIsolatedStore(query)
                deletes += 1
                return errSecItemNotFound
            })
        try FoundationCredentials.clear(operations: operations)
        XCTAssertEqual(deletes, 1)
    }
}

#if os(macOS)
    @MainActor
    final class FoundationCredentialUpgradeTests: XCTestCase {
        @MainActor
        private final class Fixture {
            let suite = "VelaCanto.CredentialUpgrade.Tests." + UUID().uuidString
            let defaults: UserDefaults
            var calls: [(String, String?)] = []
            var match: FoundationRetainedScopeMatch = .matching
            var inspectedScopes: [String] = []
            var failingStore: String?
            var readStatus = errSecItemNotFound
            var saved: Data?
            var saveStatus = errSecSuccess
            var published = 0
            var heldArtwork: CheckedContinuation<Bool, Never>?
            var holdArtwork = false
            let artworkEntered = XCTestExpectation(
                description: "credential artwork cleanup entered")
            private var artworkRetired = false
            private var artworkAnnounced = false

            func releaseArtwork(retiring: Bool = false) {
                if retiring { artworkRetired = true }
                let pending = heldArtwork
                heldArtwork = nil
                pending?.resume(returning: true)
            }
            var pagesSucceeded = true

            init() { defaults = UserDefaults(suiteName: suite)! }
            isolated deinit { defaults.removePersistentDomain(forName: suite) }

            var session: FoundationSession {
                FoundationSession(
                    serverURL: URL(string: "https://example.invalid")!,
                    accessToken: "synthetic-token", userID: "00000000000000000000000000000001",
                    deviceID: "00000000-0000-0000-0000-000000000002")
            }
            func retain(_ name: String, _ scope: String?) -> Bool {
                calls.append((name, scope))
                return failingStore != name
            }
            func model() -> FoundationAppModel {
                let credentials = FoundationCredentials.Operations(
                    update: { _, attributes in
                        self.calls.append(("save", nil))
                        self.saved = attributes[kSecValueData as String] as? Data
                        return self.saveStatus
                    },
                    add: { _ in
                        XCTFail("Update is synthetic success")
                        return errSecParam
                    },
                    copy: { _ in (self.readStatus, self.saved as CFTypeRef?) },
                    delete: { _ in
                        self.calls.append(("credential-delete", nil))
                        return errSecSuccess
                    })
                let stores = FoundationAccountRetention(
                    inventory: {
                        self.inspectedScopes.append($0)
                        return self.match
                    },
                    pins: { self.retain("pins", $0) },
                    playback: { self.retain("playback", $0) },
                    downloads: { self.retain("downloads", $0) },
                    selections: { self.retain("selections", $0) },
                    artwork: { scope in
                        self.calls.append(("artwork", scope))
                        if self.holdArtwork {
                            guard !self.artworkRetired else { return false }
                            guard self.heldArtwork == nil else {
                                XCTFail(
                                    "Concurrent held artwork cleanup is unsupported by this fixture"
                                )
                                return false
                            }
                            return await withCheckedContinuation {
                                self.heldArtwork = $0
                                if !self.artworkAnnounced {
                                    self.artworkAnnounced = true
                                    self.artworkEntered.fulfill()
                                }
                            }
                        }
                        return true
                    },
                    pages: { scope in
                        self.calls.append(("pages", scope))
                        return self.pagesSucceeded
                    })
                return FoundationAppModel(
                    prepareCaches: { true },
                    restoreAccount: { $0.restoreCredentials() }, credentialOperations: credentials,
                    accountRetention: stores, credentialDefaults: defaults,
                    publishAccount: { _, _ in self.published += 1 })
            }
            var names: [String] { calls.map { $0.0 } }
        }

        private func requireArtworkCleanup(
            _ model: FoundationAppModel, fixture: Fixture
        ) async -> Bool {
            let finished = XCTestExpectation(description: "credential artwork cleanup returned")
            let observer = Task {
                await model.waitForAccountCleanup()
                finished.fulfill()
            }
            guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
                model.invalidateAccountReadiness()
                fixture.releaseArtwork(retiring: true)
                observer.cancel()
                XCTFail("Credential artwork cleanup did not finish within 5 seconds")
                return false
            }
            return true
        }

        func testPendingMissingOrLockedCredentialsPreserveAllStoresAcrossRelaunch() async {
            for status in [
                errSecItemNotFound, errSecInteractionNotAllowed, errSecMissingEntitlement,
            ] {
                let fixture = Fixture()
                fixture.readStatus = status
                for _ in 0..<2 {
                    let model = fixture.model()
                    _ = await model.ensureReady()
                    XCTAssertTrue(model.awaitsCredentialUpgrade)
                    XCTAssertNil(model.library)
                    XCTAssertNil(model.player)
                    XCTAssertNil(model.downloads)
                }
                XCTAssertTrue(fixture.calls.isEmpty)
                XCTAssertEqual(fixture.published, 0)
            }
        }

        func testAuthenticatedExactScopePrunesBeforeSaveAndOpenThenCompletes() async throws {
            let fixture = Fixture()
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            XCTAssertTrue(fixture.calls.isEmpty)
            try await accept()
            XCTAssertEqual(
                Array(fixture.names.prefix(5)),
                ["pins", "playback", "downloads", "selections", "save"])
            let scopes = fixture.calls.prefix(4).compactMap { $0.1 }
            XCTAssertEqual(Set(scopes).count, 1)
            XCTAssertEqual(scopes.first?.count, 64)
            XCTAssertEqual(fixture.published, 1)
            await model.waitForAccountCleanup()
            XCTAssertFalse(model.awaitsCredentialUpgrade)
            XCTAssertEqual(fixture.names.suffix(2), ["artwork", "pages"])
            XCTAssertEqual(fixture.calls.last?.1, FoundationArtworkCache.digest(scopes[0]))
        }

        func testPendingSavedModernCredentialResumesPruningWithoutWritingCredential() async throws {
            let fixture = Fixture()
            fixture.saved = try JSONEncoder().encode(fixture.session)
            fixture.readStatus = errSecSuccess
            let model = fixture.model()
            _ = await model.ensureReady()
            await model.waitForAccountCleanup()
            XCTAssertEqual(fixture.published, 1)
            XCTAssertFalse(fixture.names.contains("save"))
            XCTAssertFalse(model.awaitsCredentialUpgrade)
        }

        func testEveryEssentialPruneFailureBlocksSaveOpenAndReady() async throws {
            for failure in ["pins", "playback", "downloads", "selections"] {
                let fixture = Fixture()
                fixture.failingStore = failure
                let model = fixture.model()
                _ = await model.ensureReady()
                let accept = try await model.prepareSignIn { fixture.session }
                do {
                    try await accept()
                    XCTFail("Expected acceptance to fail")
                } catch {}
                XCTAssertFalse(fixture.names.contains("save"))
                XCTAssertEqual(fixture.published, 0)
                XCTAssertTrue(model.awaitsCredentialUpgrade)
            }
        }

        func testFailedAuthenticationAndCredentialSaveKeepUpgradePending() async throws {
            let fixture = Fixture()
            let model = fixture.model()
            _ = await model.ensureReady()
            do {
                _ = try await model.prepareSignIn { throw URLError(.notConnectedToInternet) }
                XCTFail("Authentication failed")
            } catch {}
            XCTAssertTrue(fixture.calls.isEmpty)
            fixture.saveStatus = errSecAuthFailed
            let accept = try await model.prepareSignIn { fixture.session }
            do {
                try await accept()
                XCTFail("Expected acceptance to fail")
            } catch {}
            XCTAssertEqual(fixture.published, 0)
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testCancelledAndRetiredAuthenticationCannotPruneOrPublish() async throws {
            let fixture = Fixture()
            let model = fixture.model()
            _ = await model.ensureReady()
            let stale = try await model.prepareSignIn { fixture.session }
            model.cancelCredentialUpgrade()
            do {
                try await stale()
                XCTFail("Expected stale acceptance to fail")
            } catch {}
            XCTAssertTrue(fixture.calls.isEmpty)
            let retired = try await model.prepareSignIn { fixture.session }
            model.invalidateAccountReadiness()
            do {
                try await retired()
                XCTFail("Expected retired acceptance to fail")
            } catch {}
            XCTAssertTrue(fixture.calls.isEmpty)
            let task = Task {
                let accept = try await model.prepareSignIn {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return fixture.session
                }
                try await accept()
            }
            do {
                try await task.value
                XCTFail("Cancelled authentication accepted")
            } catch {}
            XCTAssertTrue(fixture.calls.isEmpty)
        }

        func testMismatchRequiresOwnedConfirmationAndCancelPreservesData() async throws {
            let fixture = Fixture()
            fixture.match = .unmatched
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            var ticket: UUID?
            do {
                try await accept()
                XCTFail("Mismatch accepted")
            } catch FoundationCredentialUpgradeError.confirmationRequired(let value) {
                ticket = value
            }
            XCTAssertTrue(fixture.calls.isEmpty)
            XCTAssertEqual(fixture.published, 0)
            model.cancelCredentialUpgrade()
            XCTAssertThrowsError(try model.confirmCredentialUpgrade(XCTUnwrap(ticket)))
            XCTAssertTrue(fixture.calls.isEmpty)
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testConfirmedMismatchPrunesOnceAndLateOrDoubleConfirmCannotRepeat() async throws {
            let fixture = Fixture()
            fixture.match = .unmatched
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            var ticket: UUID?
            do { try await accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
                let value)
            { ticket = value }
            let valid = try XCTUnwrap(ticket)
            try model.confirmCredentialUpgrade(valid)
            XCTAssertEqual(fixture.published, 1)
            XCTAssertThrowsError(try model.confirmCredentialUpgrade(valid))
            XCTAssertEqual(fixture.names.filter { $0 == "save" }.count, 1)
            await model.waitForAccountCleanup()
            XCTAssertFalse(model.awaitsCredentialUpgrade)
        }

        func testLateCacheCleanupCannotPruneNextStoreOrMarkReady() async throws {
            let fixture = Fixture()
            defer { fixture.releaseArtwork(retiring: true) }
            fixture.holdArtwork = true
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            try await accept()
            guard
                await XCTWaiter.fulfillment(of: [fixture.artworkEntered], timeout: 5) == .completed
            else {
                model.invalidateAccountReadiness()
                fixture.releaseArtwork(retiring: true)
                XCTFail("Credential artwork cleanup did not enter within 5 seconds")
                return
            }
            XCTAssertNotNil(fixture.heldArtwork)
            model.invalidateAccountReadiness()
            fixture.releaseArtwork()
            guard await requireArtworkCleanup(model, fixture: fixture) else { return }
            XCTAssertFalse(fixture.names.contains("pages"))
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testNewAuthenticationCannotLosePendingPrunePolicyToOldCleanup() async throws {
            let fixture = Fixture()
            defer { fixture.releaseArtwork(retiring: true) }
            fixture.holdArtwork = true
            let model = fixture.model()
            _ = await model.ensureReady()
            let first = try await model.prepareSignIn { fixture.session }
            try await first()
            guard
                await XCTWaiter.fulfillment(of: [fixture.artworkEntered], timeout: 5) == .completed
            else {
                model.invalidateAccountReadiness()
                fixture.releaseArtwork(retiring: true)
                XCTFail("Credential artwork cleanup did not enter within 5 seconds")
                return
            }
            let second = try await model.prepareSignIn { fixture.session }
            fixture.releaseArtwork()
            guard await requireArtworkCleanup(model, fixture: fixture) else { return }
            XCTAssertTrue(model.awaitsCredentialUpgrade)
            fixture.holdArtwork = false
            try await second()
            XCTAssertEqual(fixture.names.filter { $0 == "pins" }.count, 2)
            guard await requireArtworkCleanup(model, fixture: fixture) else { return }
            XCTAssertFalse(model.awaitsCredentialUpgrade)
        }

        func testFailedOptionalCleanupDoesNotMarkReady() async throws {
            let fixture = Fixture()
            fixture.pagesSucceeded = false
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            try await accept()
            await model.waitForAccountCleanup()
            XCTAssertTrue(model.awaitsCredentialUpgrade)
            XCTAssertNotNil(model.credentialError)
        }

        func testReadyMissingCredentialPreservesAccountStores() async {
            let fixture = Fixture()
            fixture.defaults.set(
                "data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
            let model = fixture.model()
            _ = await model.ensureReady()
            XCTAssertFalse(model.awaitsCredentialUpgrade)
            await model.waitForAccountCleanup()
            XCTAssertTrue(fixture.calls.isEmpty)
        }

        func testURLAliasCannotSilentlyMergeOrEraseRetainedScopes() async throws {
            let fixture = Fixture()
            fixture.match = .unmatched
            let model = fixture.model()
            _ = await model.ensureReady()
            let old = fixture.session
            let alias = FoundationSession(
                serverURL: URL(string: "https://example.invalid/")!,
                accessToken: old.accessToken, userID: old.userID, deviceID: old.deviceID)
            let accept = try await model.prepareSignIn { alias }
            do {
                try await accept()
                XCTFail("Expected acceptance to fail")
            } catch {}
            let oldScope = FoundationMusicLibraryStore.digest(
                "jellyfin\0" + old.serverURL.absoluteString + "\0" + old.userID)
            XCTAssertNotEqual(fixture.inspectedScopes.first, oldScope)
            XCTAssertTrue(fixture.calls.isEmpty)
            XCTAssertEqual(fixture.published, 0)
            model.cancelCredentialUpgrade()
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testNativeDismissalAndNewAttemptInvalidateOlderConfirmation() async throws {
            let fixture = Fixture()
            fixture.match = .unmatched
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            var ticket: UUID?
            do { try await accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
                let value)
            { ticket = value }
            // Both native dismissal and view disappearance retire this owner method.
            model.cancelCredentialUpgrade()
            _ = try await model.prepareSignIn { fixture.session }
            XCTAssertThrowsError(try model.confirmCredentialUpgrade(XCTUnwrap(ticket)))
            XCTAssertTrue(fixture.calls.isEmpty)
            XCTAssertEqual(fixture.published, 0)
        }

        func testConfirmedCleanupFailureConsumesTicketAndKeepsPending() async throws {
            let fixture = Fixture()
            fixture.match = .unmatched
            fixture.failingStore = "downloads"
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            var ticket: UUID?
            do { try await accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
                let value)
            { ticket = value }
            let value = try XCTUnwrap(ticket)
            XCTAssertThrowsError(try model.confirmCredentialUpgrade(value))
            XCTAssertThrowsError(try model.confirmCredentialUpgrade(value))
            XCTAssertFalse(fixture.names.contains("save"))
            XCTAssertEqual(fixture.published, 0)
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testCompletedMarkerSurvivesOrdinaryExplicitSignOutPolicy() async throws {
            let fixture = Fixture()
            fixture.defaults.set(
                "data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
            let model = fixture.model()
            let result = FoundationSignOutPolicy.begin(
                startRevocation: { Task { true } },
                clear: { fixture.calls.append(("credential-delete", nil)) },
                clearPins: { fixture.retain("pins", nil) })
            XCTAssertTrue(result.localCleared)
            XCTAssertTrue(result.pinsCleared)
            let revoked = await result.revocation.value
            XCTAssertTrue(revoked)
            XCTAssertFalse(model.awaitsCredentialUpgrade)
            XCTAssertEqual(fixture.names, ["credential-delete", "pins"])
        }

        func testInventoryRequiresExactOpaqueScopeAndRejectsUnreadableRoot() throws {
            let fixture = Fixture()
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertEqual(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(root, "a")]), .empty)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("different"), withIntermediateDirectories: true)
            XCTAssertEqual(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(root, "a")]), .unmatched)
            fixture.defaults.set([], forKey: FoundationPinStorage.key(for: "a"))
            XCTAssertEqual(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(root, "a")]), .unmatched)
            try FileManager.default.removeItem(at: root.appendingPathComponent("different"))
            XCTAssertEqual(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(root, "a")]), .matching)
            fixture.defaults.set([], forKey: FoundationPinSync.storagePrefix + "b")
            XCTAssertEqual(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(root, "a")]), .unmatched)
            let bad = root.appendingPathComponent("file")
            try Data().write(to: bad)
            XCTAssertThrowsError(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(bad, "a")]))
        }
    }
#endif
