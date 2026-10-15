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
