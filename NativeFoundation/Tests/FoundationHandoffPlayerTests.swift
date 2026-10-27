import AVFoundation
import Combine
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationHandoffPlayerTests: XCTestCase {
    func testPausedContinuationPreservesFullQueueModesAndPositionWithoutResolving() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        let value = snapshot()
        XCTAssertTrue(player.continueSession(value, position: 3, wasPlaying: false))
        XCTAssertEqual(player.persistedQueue.map(\.id), value.entries.map(\.id))
        XCTAssertEqual(player.selectedEntryID, value.selectedEntryID)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.elapsed, 3)
        XCTAssertEqual(player.state, .paused)
        XCTAssertNil(player.nativePlayer.currentItem)
        XCTAssertNil(player.selectionTask)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(probe.starts, 0)
        XCTAssertEqual(probe.activations, 0)
    }

    func testExplicitPlayResolvesOnceAndCannotStartBeforeInitialSeekCompletes() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        let value = snapshot()
        XCTAssertTrue(player.continueSession(value, position: 2, wasPlaying: false))
        player.seek(to: 5, entryID: value.selectedEntryID!)
        XCTAssertEqual(player.elapsed, 5)
        player.play()
        await initialSeek(probe)
        XCTAssertEqual(try request(probe).0.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(probe.starts, 0)
        XCTAssertEqual(probe.activations, 0)
        player.play()
        XCTAssertEqual(probe.requests.count, 1)
        try request(probe).1(true)
        await started(probe)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(probe.starts, 1)
        XCTAssertEqual(player.selectedEntryID, value.selectedEntryID)
    }

    func testPauseDuringInitialSeekDoesNotStartButLaterPlayUsesItsCompletedPosition() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        XCTAssertTrue(player.continueSession(snapshot(), position: 3, wasPlaying: true))
        await initialSeek(probe)
        player.pause()
        try request(probe).1(true)
        let noStart = probe.noStartWindow()
        await assertCompleted([noStart], timeout: 0.2)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        probe.forbiddenStart = nil
        player.play()
        await started(probe)
        XCTAssertEqual(probe.requests.count, 1)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 1)
    }

    func testFailedInitialSeekCannotStartAndExplicitRetryDoesNotRestoreStalePosition() async throws
    {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        XCTAssertTrue(player.continueSession(snapshot(), position: 3, wasPlaying: true))
        await initialSeek(probe)
        let failed = expectation(description: "Initial seek fails")
        let observation = player.$state.filter { $0 == .failed }.first().sink { _ in
            failed.fulfill()
        }
        try request(probe).1(false)
        await assertCompleted([failed], timeout: 5)
        observation.cancel()
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(probe.starts, 0)
        XCTAssertEqual(probe.activations, 0)
        XCTAssertEqual(
            player.errorMessage, FoundationHandoffError.positionUnavailable.errorDescription)
        player.play()
        await started(probe)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(probe.requests.count, 1)
    }

    func testReplacementSelectionRejectsLateSeekCompletion() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        let value = snapshot()
        XCTAssertTrue(player.continueSession(value, position: 3, wasPlaying: true))
        await initialSeek(probe)
        let other = try XCTUnwrap(player.queue.first { $0.id != value.selectedEntryID })
        player.select(other.id)
        await started(probe)
        let installed = player.nativePlayer.currentItem
        let noStart = probe.noStartWindow()
        try request(probe).1(true)
        await assertCompleted([noStart], timeout: 0.2)
        XCTAssertEqual(player.selectedEntryID, other.id)
        XCTAssertTrue(player.nativePlayer.currentItem === installed)
        XCTAssertEqual(probe.starts, 1)
    }

    func testStopRejectsLateSeekAndCannotAcknowledgeNativeStart() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        let value = snapshot()
        XCTAssertTrue(player.continueSession(value, position: 3, wasPlaying: true))
        let generation = player.continuationGeneration
        await initialSeek(probe)
        player.stop()
        let noStart = probe.noStartWindow()
        try request(probe).1(true)
        await assertCompleted([noStart], timeout: 0.2)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertNil(player.nativePlayer.currentItem)
        XCTAssertFalse(
            player.isNativeContinuationPlaying(
                generation: generation, occurrence: value.selectedEntryID!))
    }

    func testExplicitNewSeekSupersedesAnEarlierInitialPosition() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        let value = snapshot()
        XCTAssertTrue(player.continueSession(value, position: 2, wasPlaying: true))
        await initialSeek(probe)
        probe.seek = expectation(description: "New explicit position")
        player.seek(to: 5, entryID: value.selectedEntryID!)
        await assertCompleted([probe.seek], timeout: 5)
        XCTAssertEqual(probe.requests.count, 2)
        XCTAssertEqual(try request(probe, index: 1).0.seconds, 5, accuracy: 0.001)
        let noStart = probe.noStartWindow()
        try request(probe).1(true)
        await assertCompleted([noStart], timeout: 0.2)
        probe.forbiddenStart = nil
        try request(probe, index: 1).1(true)
        await started(probe)
        XCTAssertEqual(probe.starts, 1)
    }

    func testNativeContinuationStartsAfterTheRequestedPositionOnExistingPlayer() async throws {
        let resolver = HandoffResourceProbe()
        let player = FoundationPlayer(
            resolve: { try await resolver.resolve($0) }, activateSession: {}, deactivateSession: {})
        player.nativePlayer.volume = 0
        defer { player.stop() }
        let value = snapshot()
        let native = player.nativePlayer
        let playing = expectation(description: "Native continued playback")
        let observation = player.$state.filter { $0 == .playing }.first().sink { _ in
            playing.fulfill()
        }
        XCTAssertTrue(player.continueSession(value, position: 3, wasPlaying: true))
        let generation = player.continuationGeneration
        await assertCompleted([playing], timeout: 8)
        observation.cancel()
        XCTAssertTrue(player.nativePlayer === native)
        XCTAssertGreaterThanOrEqual(player.nativePlayer.currentTime().seconds, 2.9)
        XCTAssertTrue(
            player.isNativeContinuationPlaying(
                generation: generation, occurrence: value.selectedEntryID!))
        XCTAssertFalse(
            player.isNativeContinuationPlaying(
                generation: generation &- 1, occurrence: value.selectedEntryID!))
    }

    func testInvalidContinuationLeavesExistingQueueAndModesUntouched() async throws {
        let probe = HandoffPlaybackProbe()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        let original = snapshot()
        player.restoreSession(original)
        let invalid = FoundationPlaybackSnapshot(
            entries: original.entries.map(\.entry), selectedEntryID: UUID(),
            shuffleEnabled: false, repeatMode: .off)
        XCTAssertFalse(player.continueSession(invalid, position: 4, wasPlaying: true))
        XCTAssertEqual(player.persistedQueue.map(\.id), original.entries.map(\.id))
        XCTAssertEqual(player.selectedEntryID, original.selectedEntryID)
        XCTAssertTrue(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
    }

    func testReadinessProviderRunsOnceAfterNativeItemReadyAndBeforeSeekOrActivation() async throws {
        let probe = HandoffPlaybackProbe()
        let gate = FinalPositionGate()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer {
            gate.complete(5)
            player.stop()
        }
        XCTAssertTrue(
            player.continueSession(
                snapshot(), position: 1, wasPlaying: true,
                finalPosition: { try await gate.position() }))
        await assertCompleted([gate.entered], timeout: 5)
        XCTAssertEqual(player.nativePlayer.currentItem?.status, .readyToPlay)
        XCTAssertEqual(gate.calls, 1)
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(probe.activations, 0)
        XCTAssertEqual(probe.starts, 0)
        gate.complete(5)
        await initialSeek(probe)
        XCTAssertEqual(try request(probe).0.seconds, 5, accuracy: 0.001)
        XCTAssertEqual(probe.requests.count, 1)
        try request(probe).1(true)
        await started(probe)
        XCTAssertEqual(probe.starts, 1)
    }

    func testPausedContinuationNeverRequestsReadinessClockOrAudio() async throws {
        let probe = HandoffPlaybackProbe()
        let gate = FinalPositionGate()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer { player.stop() }
        XCTAssertTrue(
            player.continueSession(
                snapshot(), position: 3, wasPlaying: false,
                finalPosition: { try await gate.position() }))
        XCTAssertEqual(gate.calls, 0)
        XCTAssertEqual(player.elapsed, 3)
        XCTAssertNil(player.nativePlayer.currentItem)
        XCTAssertTrue(probe.requests.isEmpty)
        let calls = await resolver.calls
        XCTAssertEqual(calls, 0)
    }

    func testReplacementSelectionRejectsLateReadinessClockWithoutOldSeek() async throws {
        let probe = HandoffPlaybackProbe()
        let gate = FinalPositionGate()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer {
            gate.complete(5)
            player.stop()
        }
        let value = snapshot()
        XCTAssertTrue(
            player.continueSession(
                value, position: 1, wasPlaying: true,
                finalPosition: { try await gate.position() }))
        await assertCompleted([gate.entered], timeout: 5)
        let other = try XCTUnwrap(player.queue.first { $0.id != value.selectedEntryID })
        player.select(other.id)
        await started(probe)
        let noSeek = expectation(description: "no late old readiness seek")
        noSeek.isInverted = true
        probe.forbiddenSeek = noSeek
        gate.complete(5)
        await assertCompleted([noSeek], timeout: 0.2)
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(player.selectedEntryID, other.id)
        XCTAssertEqual(probe.starts, 1)
    }

    func testPauseDuringReadinessClockCannotLateSeekAndExplicitPlayUsesNewIntent() async throws {
        let probe = HandoffPlaybackProbe()
        let gate = FinalPositionGate()
        let resolver = HandoffResourceProbe()
        let player = makePlayer(probe, resolver: resolver)
        defer {
            gate.complete(5)
            player.stop()
        }
        XCTAssertTrue(
            player.continueSession(
                snapshot(), position: 1, wasPlaying: true,
                finalPosition: { try await gate.position() }))
        await assertCompleted([gate.entered], timeout: 5)
        player.pause()
        let noSeek = expectation(description: "paused clock cannot seek")
        noSeek.isInverted = true
        probe.forbiddenSeek = noSeek
        gate.complete(5)
        await assertCompleted([noSeek], timeout: 0.2)
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertEqual(probe.starts, 0)
        XCTAssertFalse(player.wantsPlayback)
        player.play()
        await started(probe)
        XCTAssertEqual(probe.starts, 1)
        XCTAssertTrue(probe.requests.isEmpty)
    }

    private func request(_ probe: HandoffPlaybackProbe, index: Int = 0) throws
        -> (CMTime, @Sendable (Bool) -> Void)
    {
        try XCTUnwrap(probe.requests.indices.contains(index) ? probe.requests[index] : nil)
    }

    private func assertCompleted(_ expectations: [XCTestExpectation], timeout: TimeInterval) async {
        let result = await XCTWaiter.fulfillment(of: expectations, timeout: timeout)
        XCTAssertEqual(result, .completed)
    }

    private func snapshot() -> FoundationPlaybackSnapshot {
        let item = FoundationTestTones.items[0]
        let entries = [FoundationQueueEntry(item: item), FoundationQueueEntry(item: item)]
        return .init(
            entries: entries, selectedEntryID: entries[1].id, shuffleEnabled: true, repeatMode: .all
        )
    }

    private func makePlayer(_ probe: HandoffPlaybackProbe, resolver: HandoffResourceProbe)
        -> FoundationPlayer
    {
        FoundationPlayer(
            resolve: { try await resolver.resolve($0) },
            activateSession: { probe.activations += 1 },
            deactivateSession: {}, startPlayback: { _ in probe.started() },
            seekForContinuation: { _, time, completion in
                probe.requested(time, completion: completion)
            })
    }

    private func initialSeek(_ probe: HandoffPlaybackProbe) async {
        await assertCompleted([probe.seek], timeout: 5)
    }

    private func started(_ probe: HandoffPlaybackProbe) async {
        await assertCompleted([probe.start], timeout: 5)
    }
}

@MainActor
private final class HandoffPlaybackProbe {
    var requests: [(CMTime, @Sendable (Bool) -> Void)] = []
    var starts = 0
    var activations = 0
    var seek = XCTestExpectation(description: "Native initial seek")
    let start = XCTestExpectation(description: "Native playback requested")
    var forbiddenStart: XCTestExpectation?
    var forbiddenSeek: XCTestExpectation?

    func requested(_ time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
        requests.append((time, completion))
        seek.fulfill()
        forbiddenSeek?.fulfill()
    }

    func started() {
        starts += 1
        start.fulfill()
        forbiddenStart?.fulfill()
    }

    func noStartWindow() -> XCTestExpectation {
        let value = XCTestExpectation(description: "No obsolete native start")
        value.isInverted = true
        forbiddenStart = value
        return value
    }
}

private actor HandoffResourceProbe {
    private(set) var calls = 0
    func resolve(_ item: FoundationItem) throws -> URL {
        calls += 1
        guard let url = try FoundationTestTones.resolve(item) else {
            throw URLError(.unsupportedURL)
        }
        return url
    }
}

@MainActor
private final class FinalPositionGate {
    let entered = XCTestExpectation(description: "native readiness clock requested")
    var calls = 0
    private var continuation: CheckedContinuation<Double, Error>?
    func position() async throws -> Double {
        calls += 1
        entered.fulfill()
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func complete(_ seconds: Double) {
        continuation?.resume(returning: seconds)
        continuation = nil
    }
}
