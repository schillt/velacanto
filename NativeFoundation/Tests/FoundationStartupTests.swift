import Security
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import CarPlay
    import UIKit
#endif

@MainActor
final class FoundationStartupTests: XCTestCase {
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

        func testCarPlaySearchOffersNativeSiriAndTypingOnlyWhenVehicleAllowsIt() throws {
            let template = CPListTemplate(title: "Search", sections: [])
            var typed = 0
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, keyboardLimited: false, siriAuthorized: true,
                typeSearch: { typed += 1 }, close: {})
            XCTAssertNotNil(template.assistantCellConfiguration)
            XCTAssertTrue(template.leadingNavigationBarButtons.isEmpty)
            XCTAssertEqual(template.backButton?.accessibilityLabel, "Back")
            let row = try XCTUnwrap(template.sections.first?.items.first as? CPListItem)
            XCTAssertEqual(row.text, "Type to Search")
            var completions = 0
            row.handler?(row, { completions += 1 })
            XCTAssertEqual(typed, 1)
            XCTAssertEqual(completions, 1)
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, keyboardLimited: true, siriAuthorized: true,
                typeSearch: { typed += 1 }, close: {})
            XCTAssertTrue(template.sections.isEmpty)
            XCTAssertNotNil(template.assistantCellConfiguration)
            XCTAssertTrue(template.leadingNavigationBarButtons.isEmpty)
            XCTAssertEqual(template.backButton?.accessibilityLabel, "Back")
            XCTAssertEqual(typed, 1, "Changing restrictions must not invoke typing or Siri.")
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, keyboardLimited: false, siriAuthorized: true,
                typeSearch: { typed += 1 }, close: {})
            XCTAssertEqual(template.sections.first?.items.count, 1)
        }

        func testCarPlaySearchExplainsSiriAuthorizationWithoutAnInactiveAssistantCell() throws {
            let template = CPListTemplate(title: "Search", sections: [])
            FoundationCarPlaySceneDelegate.configureSearchOptions(
                template, keyboardLimited: true, siriAuthorized: false,
                typeSearch: { XCTFail("Typing is restricted") }, close: {})
            XCTAssertNil(template.assistantCellConfiguration)
            XCTAssertTrue(template.leadingNavigationBarButtons.isEmpty)
            XCTAssertEqual(template.backButton?.accessibilityLabel, "Back")
            let guidance = try XCTUnwrap(template.sections.first?.items.first as? CPListItem)
            XCTAssertEqual(guidance.text, "Enable Siri on iPhone")
            XCTAssertFalse(guidance.isEnabled)
        }

        func testCarPlaySearchReturnsToExactNestedOriginAndSelectedContentTab() {
            let home = CPListTemplate(title: "Home", sections: [])
            let library = CPListTemplate(title: "Library", sections: [])
            let album = CPListTemplate(title: "Album", sections: [])
            let hub = CPListTemplate(title: "Search", sections: [])
            let root = CPTabBarTemplate(templates: [home, library])
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
            let keyboard = CPSearchTemplate()
            let root = CPTabBarTemplate(templates: [home, search])
            let step = FoundationCarPlaySceneDelegate.searchReturnStep
            XCTAssertEqual(
                step(home, root, keyboard, [root, search, keyboard], [home, search]), .popToRoot)
            XCTAssertEqual(step(home, root, root, [root], [home, search]), .selectTab)
            XCTAssertEqual(step(home, root, search, [root, search], [home, search]), .selectTab)
            XCTAssertEqual(
                step(album, root, keyboard, [root, album, search, keyboard], [home, search]),
                .popOne)
            XCTAssertEqual(step(album, root, album, [root, album], [home, search]), .done)
            XCTAssertEqual(
                step(album, root, keyboard, [root, keyboard], [home, search]),
                .unavailable)
        }

        func testCarPlayKeyboardSearchUsesNativeCancelWithoutAnExtraResultRow() {
            let result = CPListItem(text: "Result", detailText: nil)
            XCTAssertTrue(FoundationCarPlaySceneDelegate.searchRows([], budget: 4).isEmpty)
            let limited = FoundationCarPlaySceneDelegate.searchRows([result, result], budget: 2)
            XCTAssertEqual(limited.count, 2)
            XCTAssertTrue(limited.first === result)
            XCTAssertTrue(limited.last === result)
            XCTAssertEqual(FoundationCarPlaySceneDelegate.searchRows([result], budget: 1).count, 1)
            XCTAssertTrue(FoundationCarPlaySceneDelegate.searchRows([result], budget: 0).isEmpty)
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

        func testCarPlayCancelledSearchResponseCompletesOnlyOnce() {
            var completions = 0
            let response = FoundationCarPlaySceneDelegate.SearchResponse { rows in
                completions += 1
                XCTAssertTrue(rows.isEmpty)
            }
            response.finish([])
            response.finish([CPListItem(text: "Late result", detailText: nil)])
            XCTAssertEqual(completions, 1)
        }
    #endif

    @MainActor
    private final class PreparationGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        private var started = false

        func prepare() async -> Bool {
            started = true
            return await withCheckedContinuation { continuation = $0 }
        }

        private enum WaitError: Error {
            case startupTimedOut
        }

        func waitUntilStarted() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !started {
                guard clock.now < deadline else { throw WaitError.startupTimedOut }
                try await Task.sleep(for: .milliseconds(10))
            }
        }

        func complete(_ result: Bool) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    func testConcurrentEntrypointsRestoreOnceWithoutCreatingPlayback() async throws {
        let gate = PreparationGate()
        var preparations = 0
        var restorations = 0
        let model = FoundationAppModel(
            prepareCaches: {
                preparations += 1
                return await gate.prepare()
            }, restoreAccount: { _ in restorations += 1 })
        let phone = Task { await model.ensureReady() }
        try await gate.waitUntilStarted()
        let carPlay = Task { await model.ensureReady() }
        model.restore()
        gate.complete(true)
        let phoneResult = await phone.value
        let carPlayResult = await carPlay.value
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
            restoreAccount: { _ in restorations += 1 })
        let caller = Task { await model.ensureReady() }
        try await gate.waitUntilStarted()
        caller.cancel()
        gate.complete(true)
        let cancelled = await caller.value
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
            restoreAccount: { _ in restorations += 1 })
        let caller = Task { await model.ensureReady() }
        try await gate.waitUntilStarted()
        model.invalidateAccountReadiness()
        gate.complete(true)
        let result = await caller.value
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
            }, restoreAccount: { _ in restorations += 1 })
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
            }, restoreAccount: { _ in restorations += 1 })
        let original = Task { await model.ensureReady() }
        try await first.waitUntilStarted()
        model.retryCachePreparation()
        try await second.waitUntilStarted()
        first.complete(false)
        let retired = await original.value
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
            }, restoreAccount: { _ in restorations += 1 })
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
            restoreAccount: { $0.credentialError = "Saved sign-in unavailable." })
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
            var artworkStarted: CheckedContinuation<Void, Never>?
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
                            return await withCheckedContinuation {
                                self.heldArtwork = $0
                                self.artworkStarted?.resume()
                                self.artworkStarted = nil
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
            try accept()
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
                XCTAssertThrowsError(try accept())
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
            XCTAssertThrowsError(try accept())
            XCTAssertEqual(fixture.published, 0)
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testCancelledAndRetiredAuthenticationCannotPruneOrPublish() async throws {
            let fixture = Fixture()
            let model = fixture.model()
            _ = await model.ensureReady()
            let stale = try await model.prepareSignIn { fixture.session }
            model.cancelCredentialUpgrade()
            XCTAssertThrowsError(try stale())
            XCTAssertTrue(fixture.calls.isEmpty)
            let retired = try await model.prepareSignIn { fixture.session }
            model.invalidateAccountReadiness()
            XCTAssertThrowsError(try retired())
            XCTAssertTrue(fixture.calls.isEmpty)
            let task = Task {
                let accept = try await model.prepareSignIn {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return fixture.session
                }
                try accept()
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
                try accept()
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
            do { try accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
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
            fixture.holdArtwork = true
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            try accept()
            await withCheckedContinuation { continuation in
                if fixture.heldArtwork != nil {
                    continuation.resume()
                } else {
                    fixture.artworkStarted = continuation
                }
            }
            XCTAssertNotNil(fixture.heldArtwork)
            model.invalidateAccountReadiness()
            fixture.heldArtwork?.resume(returning: true)
            fixture.heldArtwork = nil
            await model.waitForAccountCleanup()
            XCTAssertFalse(fixture.names.contains("pages"))
            XCTAssertTrue(model.awaitsCredentialUpgrade)
        }

        func testNewAuthenticationCannotLosePendingPrunePolicyToOldCleanup() async throws {
            let fixture = Fixture()
            fixture.holdArtwork = true
            let model = fixture.model()
            _ = await model.ensureReady()
            let first = try await model.prepareSignIn { fixture.session }
            try first()
            await withCheckedContinuation { continuation in
                if fixture.heldArtwork != nil {
                    continuation.resume()
                } else {
                    fixture.artworkStarted = continuation
                }
            }
            let second = try await model.prepareSignIn { fixture.session }
            fixture.heldArtwork?.resume(returning: true)
            fixture.heldArtwork = nil
            await model.waitForAccountCleanup()
            XCTAssertTrue(model.awaitsCredentialUpgrade)
            fixture.holdArtwork = false
            try second()
            XCTAssertEqual(fixture.names.filter { $0 == "pins" }.count, 2)
            await model.waitForAccountCleanup()
            XCTAssertFalse(model.awaitsCredentialUpgrade)
        }

        func testFailedOptionalCleanupDoesNotMarkReady() async throws {
            let fixture = Fixture()
            fixture.pagesSucceeded = false
            let model = fixture.model()
            _ = await model.ensureReady()
            let accept = try await model.prepareSignIn { fixture.session }
            try accept()
            await model.waitForAccountCleanup()
            XCTAssertTrue(model.awaitsCredentialUpgrade)
            XCTAssertNotNil(model.credentialError)
        }

        func testReadyMissingCredentialKeepsOrdinarySignedOutCleanup() async {
            let fixture = Fixture()
            fixture.defaults.set(
                "data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
            let model = fixture.model()
            _ = await model.ensureReady()
            XCTAssertFalse(model.awaitsCredentialUpgrade)
            XCTAssertEqual(
                Array(fixture.names.prefix(4)), ["pins", "playback", "downloads", "selections"])
            XCTAssertTrue(fixture.calls.prefix(4).allSatisfy { $0.1 == nil })
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
            XCTAssertThrowsError(try accept())
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
            do { try accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
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
            do { try accept() } catch FoundationCredentialUpgradeError.confirmationRequired(
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
                    roots: [(root, "a")]), .matching)
            let bad = root.appendingPathComponent("file")
            try Data().write(to: bad)
            XCTAssertThrowsError(
                try FoundationAccountRetention.inventory(
                    scope: "a", defaults: fixture.defaults,
                    roots: [(bad, "a")]))
        }
    }
#endif
