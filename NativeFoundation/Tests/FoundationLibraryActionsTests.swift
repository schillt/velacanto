import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLibraryActionsTests: XCTestCase {
    private let album = FoundationItem(
        id: "synthetic", title: "Synthetic", subtitle: "", kind: .album, duration: nil)

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
