import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPinSyncLifecycleTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var started = false
        private(set) var calls = 0
        func hold() async {
            calls += 1
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { continuation = $0 }
        }
        func waitForStart() async {
            if !started { await withCheckedContinuation { startedWaiter = $0 } }
        }
        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "PinSyncTests." + UUID().uuidString)!
    }

    func testUnavailableBuildDefaultsOffAndCannotEnable() {
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: defaults(),
            currentPins: { [] }, apply: { _, _ in XCTFail("Unavailable sync applied pins") })
        XCTAssertFalse(sync.available)
        XCTAssertFalse(sync.enabled)
        sync.setEnabled(true)
        sync.refresh()
        XCTAssertFalse(sync.enabled)
        XCTAssertNil(sync.task)
        sync.invalidate()
    }

    func testDisableAndRetirementRejectLateCloudResults() async {
        for retire in [false, true] {
            let gate = Gate()
            let state = FoundationPinSyncState(scope: scope)
            var applied = false
            let sync = FoundationPinSync(
                scope: scope, containerIdentifier: nil, defaults: defaults(),
                exchange: { _, _, _, _, _, _ in
                    await gate.hold()
                    // Deliberately ignores cancellation, as a late native callback may.
                    return .init(state: state, account: "synthetic", reset: false)
                }, currentPins: { [] }, apply: { _, _ in applied = true })
            XCTAssertFalse(sync.enabled)
            XCTAssertNil(sync.task)
            sync.setEnabled(true)
            let pending = sync.task
            await gate.waitForStart()
            if retire { sync.invalidate() } else { sync.setEnabled(false) }
            await gate.release()
            await pending?.value
            XCTAssertFalse(applied)
            let calls = await gate.calls
            XCTAssertEqual(calls, 1)
            sync.refresh()
            XCTAssertNil(sync.task)
            sync.invalidate()
        }
    }

    func testDisabledPinChangesNeverStartCloudOperation() async {
        let gate = Gate()
        let state = FoundationPinSyncState(scope: scope)
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: defaults(),
            exchange: { _, _, _, _, _, _ in
                await gate.hold()
                return .init(state: state, account: "synthetic", reset: false)
            }, currentPins: { [] }, apply: { _, _ in XCTFail("Disabled sync applied") })
        sync.pinsChanged()
        sync.refresh()
        sync.deleteCloudPins()
        XCTAssertNil(sync.task)
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        sync.invalidate()
    }

    func testDisableDuringMetadataResolutionInvalidatesCommitGuard() async {
        let gate = Gate()
        let state = FoundationPinSyncState(scope: scope)
        var committed = false
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: defaults(),
            exchange: { _, _, _, _, _, _ in
                .init(state: state, account: "synthetic", reset: false)
            }, currentPins: { [] },
            apply: { _, isCurrent in
                await gate.hold()
                if isCurrent() { committed = true }
            })
        sync.setEnabled(true)
        let pending = sync.task
        await gate.waitForStart()
        sync.setEnabled(false)
        await gate.release()
        await pending?.value
        XCTAssertFalse(committed)
        sync.invalidate()
    }

    func testQueuedAccountNotificationCannotRecreateRetiredJournal() async {
        let store = defaults()
        let key = FoundationPinSync.storagePrefix + scope
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: store,
            currentPins: { [] }, apply: { _, _ in XCTFail("Retired owner applied pins") })
        sync.setEnabled(false)
        XCTAssertNotNil(store.data(forKey: key))
        // This is the exact Task enqueued by the native main-queue observer.
        let notification = sync.accountChanged()
        sync.invalidate()
        store.removeObject(forKey: key)
        let retiredMessage = sync.message
        await notification.value
        XCTAssertNil(store.data(forKey: key))
        XCTAssertEqual(sync.message, retiredMessage)
    }

    private actor ExchangeLog {
        private(set) var states: [FoundationPinSyncState?] = []
        func record(_ state: FoundationPinSyncState?) -> Int {
            states.append(state)
            return states.count
        }
    }

    func testInitialHeldExchangePreservesLocalReorderAndRemoteOnlyPin() async throws {
        let gate = Gate()
        let log = ExchangeLog()
        let a = FoundationPinSyncState.Identity(id: "a", kind: "album")
        let b = FoundationPinSyncState.Identity(id: "b", kind: "album")
        let remoteOnly = FoundationPinSyncState.Identity(id: "remote", kind: "album")
        var remote = FoundationPinSyncState(scope: scope)
        try remote.edit([a, b, remoteOnly], device: UUID())
        let initialRemote = remote
        var local = [a, b]
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: defaults(),
            exchange: { _, state, _, _, _, _ in
                let call = await log.record(state)
                if call == 1 { await gate.hold() }
                return .init(state: state ?? initialRemote, account: "synthetic", reset: false)
            }, currentPins: { local },
            apply: { identities, isCurrent in
                if isCurrent() { local = identities }
            })
        sync.setEnabled(true)
        let first = sync.task
        await gate.waitForStart()
        local = [b, a]
        sync.pinsChanged()
        await gate.release()
        await first?.value
        await sync.task?.value
        let uploads = await log.states
        XCTAssertEqual(uploads.count, 2)
        XCTAssertNil(uploads.first!)
        let last = try XCTUnwrap(uploads.last ?? nil)
        XCTAssertEqual(last.pins, [b, a, remoteOnly])
        XCTAssertEqual(local, [b, a, remoteOnly])
        sync.invalidate()
    }

    func testCapacityPauseBlocksReEnableAndRelaunchUntilLocalIntentFits() async throws {
        let store = defaults()
        let gate = Gate()
        let existing = (0..<FoundationPinSyncState.maximumEntries).map {
            FoundationPinSyncState.Identity(id: "pin-\($0)", kind: "album")
        }
        var state = FoundationPinSyncState(scope: scope)
        let device = UUID()
        try state.edit(existing, device: device)
        let prior = state
        let key = FoundationPinSync.storagePrefix + scope
        let journal = FoundationPinSync.Journal(
            state: state, account: "synthetic", device: device, enabled: false)
        store.set(try JSONEncoder().encode(journal), forKey: key)
        var local = existing
        let extra = FoundationPinSyncState.Identity(id: "unsynced-extra", kind: "album")
        let exchange: FoundationPinSync.Exchange = { _, _, _, _, _, _ in
            await gate.hold()
            return .init(state: prior, account: "synthetic", reset: false)
        }
        let sync = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: store, exchange: exchange,
            currentPins: { local },
            apply: { _, _ in XCTFail("Paused sync must not replace local pins") })
        local.append(extra)
        sync.pinsChanged()
        sync.setEnabled(true)
        sync.refresh()
        XCTAssertFalse(sync.enabled)
        XCTAssertNil(sync.task)
        XCTAssertEqual(local.last, extra)
        let paused = try JSONDecoder().decode(
            FoundationPinSync.Journal.self, from: XCTUnwrap(store.data(forKey: key)))
        XCTAssertEqual(paused.needsRecovery, true)
        sync.invalidate()
        let relaunched = FoundationPinSync(
            scope: scope, containerIdentifier: nil, defaults: store, exchange: exchange,
            currentPins: { local },
            apply: { _, _ in XCTFail("Relaunch must preserve unsynced pins") })
        relaunched.setEnabled(true)
        XCTAssertFalse(relaunched.enabled)
        XCTAssertNil(relaunched.task)
        let calls = await gate.calls
        XCTAssertEqual(calls, 0)
        // Relaunch must not reinterpret the still-visible extra as an old local-only pin.
        // Unrelated ordering and removal cannot clear its outstanding addition.
        local.swapAt(0, 1)
        relaunched.pinsChanged()
        relaunched.setEnabled(true)
        XCTAssertFalse(relaunched.enabled)
        XCTAssertNil(relaunched.task)
        XCTAssertEqual(local.last, extra)
        local.removeFirst()
        relaunched.pinsChanged()
        relaunched.setEnabled(true)
        XCTAssertFalse(relaunched.enabled)
        XCTAssertNil(relaunched.task)
        XCTAssertEqual(local.last, extra)
        let stillPaused = try JSONDecoder().decode(
            FoundationPinSync.Journal.self, from: XCTUnwrap(store.data(forKey: key)))
        XCTAssertEqual(stillPaused.needsRecovery, true)
        XCTAssertEqual(stillPaused.recoveryBaseline, existing)
        let callsAfterUnrelatedEdits = await gate.calls
        XCTAssertEqual(callsAfterUnrelatedEdits, 0)
        // Undoing the unjournaled addition permits an explicit later opt-in.
        local.removeLast()
        relaunched.pinsChanged()
        let recovered = try JSONDecoder().decode(
            FoundationPinSync.Journal.self, from: XCTUnwrap(store.data(forKey: key)))
        XCTAssertEqual(recovered.needsRecovery, false)
        XCTAssertNil(recovered.recoveryBaseline)
        XCTAssertEqual(local.count, existing.count - 1)
        XCTAssertFalse(local.contains(extra))
        relaunched.invalidate()
    }

    func testPinOrderingPersistsLocallyWithoutCloudAndHonorsBounds() {
        var storage: [String: Data] = [:]
        let actions = FoundationLibraryActions(
            sourceScope: scope, read: { storage[$0] }, write: { storage[$0] = $1 },
            mutateFavorite: { _, _ in })
        let a = FoundationItem(id: "a", title: "A", subtitle: "", kind: .album, duration: nil)
        let b = FoundationItem(id: "b", title: "B", subtitle: "", kind: .artist, duration: nil)
        actions.togglePin(a)
        actions.togglePin(b)
        XCTAssertFalse(actions.canMovePin(a, earlier: true))
        XCTAssertFalse(actions.canMovePin(b, earlier: false))
        actions.movePin(b, earlier: true)
        XCTAssertEqual(actions.pins, [b, a])
        let restored = FoundationLibraryActions(
            sourceScope: scope, read: { storage[$0] }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        XCTAssertEqual(restored.pins, [b, a])
        actions.movePin(b, earlier: true)
        XCTAssertEqual(actions.pins, [b, a])
        actions.invalidate()
        restored.invalidate()
    }

    func testLocalSignOutClearsSyncJournalsAcrossScopes() {
        let store = defaults()
        let retained = String(repeating: "b", count: 64)
        store.set(Data([1]), forKey: FoundationPinSync.storagePrefix + scope)
        store.set(Data([2]), forKey: FoundationPinSync.storagePrefix + retained)
        XCTAssertTrue(FoundationPinStorage.removeStoredPins(retaining: scope, defaults: store))
        XCTAssertNotNil(store.data(forKey: FoundationPinSync.storagePrefix + scope))
        XCTAssertNil(store.data(forKey: FoundationPinSync.storagePrefix + retained))
        XCTAssertTrue(FoundationPinStorage.removeStoredPins(defaults: store))
        XCTAssertNil(store.data(forKey: FoundationPinSync.storagePrefix + scope))
    }

    func testFailedCredentialClearDoesNotRetirePinOwner() {
        let actions = FoundationLibraryActions(
            sourceScope: scope, read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        actions.configurePinSync(
            sourceScope: scope, containerIdentifier: nil, resolve: { _ in nil })
        let result = FoundationSignOutPolicy.begin {
            Task { false }
        } clear: {
            throw FoundationLibraryError.credentials
            // App.signOut calls actions.invalidate only after credential clear succeeds.
        } clearPins: {
            XCTFail("Failed credential clear must not reach local cleanup")
            actions.invalidate()
            return true
        }
        XCTAssertFalse(result.localCleared)
        let album = FoundationItem(
            id: "synthetic", title: "Synthetic", subtitle: "", kind: .album, duration: nil)
        actions.togglePin(album)
        XCTAssertEqual(actions.pins, [album])
        actions.invalidate()
    }
}
