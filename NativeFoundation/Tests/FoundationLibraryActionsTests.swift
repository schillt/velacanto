import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLibraryActionsTests: XCTestCase {
    private let album = FoundationItem(
        id: "synthetic", title: "Synthetic", subtitle: "", kind: .album, duration: nil)

    func testDelayedCollectionPlayAndEnqueueCannotOverwriteExplicitUpcomingEdits() async throws {
        for startsPlayback in [true, false] {
            for removesEntry in [true, false] {
                let gate = CollectionGate()
                let session = FoundationSession(
                    serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                    userID: "00000000000000000000000000000001", deviceID: "synthetic")
                let library = FoundationJellyfinLibrary(session: session) { request in
                    await gate.hold()
                    let body = """
                        {"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"}],"TotalRecordCount":1}
                        """
                    return (
                        Data(body.utf8),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let player = FoundationPlayer(resolve: { _ in throw CancellationError() })
                let track = FoundationItem(
                    id: "synthetic-track", title: "", subtitle: "", kind: .track, duration: nil)
                player.setQueue([track, track, track, track], selectedIndex: 1)
                await player.selectionTask?.value
                let actions = FoundationLibraryActions(
                    sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
                    mutateFavorite: { _, _ in })
                let collection = FoundationItem(
                    id: "00000000000000000000000000000003", title: "", subtitle: "", kind: .album,
                    duration: nil)
                if startsPlayback {
                    actions.play(collection, shuffled: false, library: library, player: player)
                } else {
                    actions.enqueue(collection, position: .last, library: library, player: player)
                }
                let expansion = try XCTUnwrap(actions.queueTask)
                try await gate.waitUntilStarted()
                let selected = player.selectedEntryID
                if removesEntry {
                    player.removeUpcoming(player.upcoming[0].id)
                } else {
                    player.reorderUpcoming([player.upcoming[0].id], before: nil)
                }
                let edited = player.queue
                XCTAssertTrue(expansion.isCancelled)
                await gate.release()
                await expansion.value
                XCTAssertEqual(player.queue, edited)
                XCTAssertEqual(player.selectedEntryID, selected)
                XCTAssertFalse(actions.isQueueLoading)
                XCTAssertNil(actions.queueErrorMessage)
            }
        }
    }

    private actor CollectionGate {
        private var held: CheckedContinuation<Void, Never>?
        func hold() async { await withCheckedContinuation { held = $0 } }
        func waitUntilStarted() async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while held == nil {
                guard clock.now < deadline else { throw Failure.synthetic }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func release() {
            held?.resume()
            held = nil
        }
    }

    func testPinsPersistWithinSourceAndSeparateKindsWithoutNetwork() {
        var storage: [String: Data] = [:]
        let make: (String) -> FoundationLibraryActions = { scope in
            FoundationLibraryActions(
                sourceScope: scope, read: { storage[$0] }, write: { storage[$0] = $1 },
                mutateFavorite: { _, _ in XCTFail("Pinning must not call the provider") })
        }
        let first = make("source-a")
        let artist = FoundationItem(
            id: album.id, title: "Synthetic", subtitle: "", kind: .artist, duration: nil)
        first.togglePin(album)
        first.togglePin(artist)
        XCTAssertEqual(make("source-a").pins, [album, artist])
        XCTAssertTrue(make("source-b").pins.isEmpty)
        first.togglePin(album)
        XCTAssertEqual(make("source-a").pins, [artist])
    }

    func testLegacyScopedPinsAreRemovedWithoutTouchingCurrentAccountOrOtherPreferences() {
        let defaults = UserDefaults(suiteName: "Velacanto.PinTests.\(UUID().uuidString)")!
        let currentKey = FoundationPinStorage.key(for: "current")
        let oldKey = FoundationPinStorage.key(for: "old-account")
        let unrelatedKey = "Velacanto.Foundation.OtherPreference"
        defer {
            for key in [currentKey, oldKey, unrelatedKey] { defaults.removeObject(forKey: key) }
        }
        let make: (String) -> FoundationLibraryActions = { scope in
            FoundationLibraryActions(
                sourceScope: scope, read: { defaults.data(forKey: $0) },
                write: { defaults.set($1, forKey: $0) },
                mutateFavorite: { _, _ in XCTFail("Pinning must not call the provider") })
        }
        make("current").togglePin(album)
        defaults.set(Data("synthetic-old-pin".utf8), forKey: oldKey)
        defaults.set("keep", forKey: unrelatedKey)

        // Relaunch with a saved session keeps only its own pins.
        XCTAssertTrue(
            FoundationPinStorage.removeStoredPins(retaining: "current", defaults: defaults))
        XCTAssertEqual(make("current").pins, [album])
        XCTAssertNil(defaults.object(forKey: oldKey))
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "keep")

        // Sign-out (including offline sign-out) leaves no scoped pin snapshots.
        XCTAssertTrue(FoundationPinStorage.removeStoredPins(defaults: defaults))
        XCTAssertTrue(make("current").pins.isEmpty)
        XCTAssertNil(defaults.object(forKey: currentKey))
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "keep")
    }

    func testAccountSwitchRemovesPreviousPinSnapshotBeforeNewScopeLoads() {
        let defaults = UserDefaults(suiteName: "Velacanto.PinTests.\(UUID().uuidString)")!
        let previousKey = FoundationPinStorage.key(for: "previous")
        let nextKey = FoundationPinStorage.key(for: "next")
        defer {
            defaults.removeObject(forKey: previousKey)
            defaults.removeObject(forKey: nextKey)
        }
        let previous = FoundationLibraryActions(
            sourceScope: "previous", read: { defaults.data(forKey: $0) },
            write: { defaults.set($1, forKey: $0) }, mutateFavorite: { _, _ in })
        previous.togglePin(album)
        XCTAssertNotNil(defaults.object(forKey: previousKey))

        XCTAssertTrue(FoundationPinStorage.removeStoredPins(defaults: defaults))
        previous.invalidate()
        let next = FoundationLibraryActions(
            sourceScope: "next", read: { defaults.data(forKey: $0) },
            write: { defaults.set($1, forKey: $0) }, mutateFavorite: { _, _ in })
        XCTAssertNil(defaults.object(forKey: previousKey))
        XCTAssertTrue(next.pins.isEmpty)
    }

    func testFailedLocalSignOutKeepsActivePinsAndStoredPinsCoherent() {
        var storage: [String: Data] = [:]
        let key = FoundationPinStorage.key(for: "current")
        let make: () -> FoundationLibraryActions = {
            FoundationLibraryActions(
                sourceScope: "current", read: { storage[$0] },
                write: { storage[$0] = $1 }, mutateFavorite: { _, _ in })
        }
        let actions = make()
        actions.togglePin(album)
        let savedBeforeAttempt = storage[key]
        var cleanupCalls = 0

        let attempt = FoundationSignOutPolicy.begin {
            Task { false }
        } clear: {
            throw FoundationLibraryError.credentials
        } clearPins: {
            cleanupCalls += 1
            storage.removeValue(forKey: key)
            return true
        }
        XCTAssertFalse(attempt.localCleared)
        XCTAssertFalse(attempt.pinsCleared)
        XCTAssertEqual(cleanupCalls, 0)
        XCTAssertEqual(storage[key], savedBeforeAttempt)
        XCTAssertEqual(actions.pins, [album])

        let artist = FoundationItem(
            id: "synthetic-artist", title: "Synthetic", subtitle: "", kind: .artist,
            duration: nil)
        actions.togglePin(artist)
        XCTAssertEqual(make().pins, [album, artist])
    }

    func testPinWriteFailureRetainsPriorStateAndTrackCannotPin() {
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil },
            write: { _, _ in throw Failure.synthetic }, mutateFavorite: { _, _ in })
        actions.togglePin(album)
        XCTAssertTrue(actions.pins.isEmpty)
        XCTAssertNotNil(actions.pinErrorMessage)
        let track = FoundationItem(
            id: "track", title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        actions.togglePin(track)
        XCTAssertTrue(actions.pins.isEmpty)
    }

    func testFavoriteFailureKeepsInitialStateWithoutRetry() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in
                await gate.countCall()
                throw Failure.synthetic
            })
        await actions.setFavorite(for: album, isFavorite: true)
        XCTAssertEqual(actions.favoriteState(for: album, initial: false), false)
        XCTAssertNotNil(actions.errorMessage(for: album))
        XCTAssertFalse(actions.isPending(album))
        XCTAssertEqual(actions.favoriteRevision, 0)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testPendingFavoriteDeduplicatesAndPublishesOnlyAfterSuccess() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.hold() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        await actions.setFavorite(for: item, isFavorite: false)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release()
        await task.value
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), true)
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteRevision, 1)
    }

    func testSourceInvalidationDiscardsLateFavoriteCompletion() async {
        let gate = MutationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.hold() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        actions.invalidate()
        await gate.release()
        await task.value
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
        XCTAssertFalse(actions.isPending(item))
    }

    func testSourceInvalidationCancelsUnderlyingFavoriteOperation() async {
        let gate = CancellationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.holdUntilCancelled() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        actions.invalidate()
        await gate.waitUntilCancelled()
        await task.value
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
    }

    func testCallerCancellationCancelsUnderlyingFavoriteOperation() async {
        let gate = CancellationGate()
        let actions = FoundationLibraryActions(
            sourceScope: "source", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in await gate.holdUntilCancelled() })
        let item = album
        let task = Task { await actions.setFavorite(for: item, isFavorite: true) }
        await gate.waitUntilStarted()
        XCTAssertTrue(actions.isPending(item))
        task.cancel()
        await gate.waitUntilCancelled()
        await task.value
        XCTAssertFalse(actions.isPending(item))
        XCTAssertEqual(actions.favoriteState(for: item, initial: false), false)
        XCTAssertEqual(actions.favoriteRevision, 0)
        XCTAssertNil(actions.errorMessage(for: item))
    }

    /// Only the actual provider task's cancellation handler can release this gate.
    private actor CancellationGate {
        private var didStart = false
        private var didCancel = false
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var cancelWaiter: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        func holdUntilCancelled() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    didStart = true
                    startWaiter?.resume()
                    startWaiter = nil
                    if didCancel { continuation.resume() } else { held = continuation }
                }
            } onCancel: {
                Task { await self.observeCancellation() }
            }
        }

        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func waitUntilCancelled() async {
            if didCancel { return }
            await withCheckedContinuation { cancelWaiter = $0 }
        }

        private func observeCancellation() {
            didCancel = true
            held?.resume()
            held = nil
            cancelWaiter?.resume()
            cancelWaiter = nil
        }
    }

    private enum Failure: Error { case synthetic }

    private actor MutationGate {
        private(set) var calls = 0
        private var started: CheckedContinuation<Void, Never>?
        private var held: CheckedContinuation<Void, Never>?

        func countCall() { calls += 1 }

        func hold() async {
            calls += 1
            await withCheckedContinuation { continuation in
                held = continuation
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            if held != nil { return }
            await withCheckedContinuation { started = $0 }
        }

        func release() {
            held?.resume()
            held = nil
        }
    }
}
