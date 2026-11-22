import AVFoundation
import Combine
import NowPlaying
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationNowPlayingTests: XCTestCase {
    private let track = FoundationItem(
        id: "synthetic", title: "Test title", subtitle: "Test artist", kind: .track, duration: 8)

    func testPendingSeekHoldsBothPresentationsWhileActualClockStillAdvances() async throws {
        let seeks = UserSeekProbe()
        let player = try await readySeekPlayer(seeks)
        let bridge = FoundationNowPlaying(player: player)
        defer {
            bridge.invalidate()
            player.stop()
        }
        try bridge.perform(.seek(6), entryID: player.selectedEntryID)
        XCTAssertEqual(player.pendingSeekPosition, 6)
        XCTAssertEqual(player.presentationElapsed, 6)
        XCTAssertLessThan(player.elapsed, 6)
        let ticked = expectation(description: "Actual native clock advances during held seek")
        let tick = player.$elapsed.filter { $0 >= 1 }.first().sink { _ in ticked.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [ticked], timeout: 5)
        tick.cancel()
        XCTAssertEqual(result, .completed)
        XCTAssertLessThan(player.elapsed, 6)
        XCTAssertEqual(player.presentationElapsed, 6)
        let timestamp = Date(timeIntervalSince1970: 100)
        bridge.refresh(timestamp: timestamp)
        XCTAssertEqual(
            bridge.playbackSnapshot,
            MediaPlaybackSnapshot(state: .buffering, elapsedTime: 6, timestamp: timestamp))

        let completed = expectation(description: "Actual seek completes")
        let completion = player.playbackPositionChanged.first().sink { completed.fulfill() }
        seeks.land(0)
        let landed = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        completion.cancel()
        XCTAssertEqual(landed, .completed)
        XCTAssertNil(player.pendingSeekPosition)
        XCTAssertEqual(player.presentationElapsed, 6, accuracy: 0.3)
        XCTAssertEqual(player.nativePlayer.currentTime().seconds, 6, accuracy: 0.3)
    }

    func testObsoleteSeekCannotClearLatestTargetAndCancelledLatestRestoresNativeClock() async throws
    {
        let seeks = UserSeekProbe()
        let player = try await readySeekPlayer(seeks)
        defer { player.stop() }
        player.pause()
        let occurrence = try XCTUnwrap(player.selectedEntryID)
        player.seek(to: 3, entryID: occurrence)
        player.seek(to: 6, entryID: occurrence)
        let cleared = expectation(description: "Obsolete completion must not clear latest seek")
        cleared.isInverted = true
        let observation = player.$pendingSeekPosition.dropFirst().sink { _ in cleared.fulfill() }
        seeks.complete(0, finished: false)
        let obsolete = await XCTWaiter.fulfillment(of: [cleared], timeout: 0.2)
        observation.cancel()
        XCTAssertEqual(obsolete, .completed)
        XCTAssertEqual(player.presentationElapsed, 6)
        let bridge = FoundationNowPlaying(player: player)
        defer { bridge.invalidate() }
        let timestamp = Date(timeIntervalSince1970: 100)
        bridge.refresh(timestamp: timestamp)
        XCTAssertEqual(
            bridge.playbackSnapshot,
            MediaPlaybackSnapshot(state: .paused, elapsedTime: 6, timestamp: timestamp))
        let completed = expectation(description: "Latest cancelled seek retires its target")
        let completion = player.playbackPositionChanged.first().sink { completed.fulfill() }
        seeks.complete(1, finished: false)
        let cancelled = await XCTWaiter.fulfillment(of: [completed], timeout: 5)
        completion.cancel()
        XCTAssertEqual(cancelled, .completed)
        XCTAssertNil(player.pendingSeekPosition)
        XCTAssertEqual(player.presentationElapsed, player.elapsed)
        XCTAssertEqual(player.elapsed, player.nativePlayer.currentTime().seconds, accuracy: 0.1)
    }

    func testSeekPresentationRetiresOnStopEndAndNativeFailure() async throws {
        for boundary in ["stop", "end", "failure"] {
            let seeks = UserSeekProbe()
            let player = try await readySeekPlayer(seeks)
            defer { player.stop() }
            player.pause()
            let occurrence = try XCTUnwrap(player.selectedEntryID)
            let item = try XCTUnwrap(player.nativePlayer.currentItem)
            player.seek(to: 6, entryID: occurrence)
            XCTAssertEqual(player.presentationElapsed, 6)
            switch boundary {
            case "stop": player.stop()
            case "end": player.didReachEnd(item)
            default:
                let failed = expectation(description: "Native failure")
                let failure = player.$state.filter { $0 == .failed }.first().sink { _ in
                    failed.fulfill()
                }
                NotificationCenter.default.post(
                    name: AVPlayerItem.failedToPlayToEndTimeNotification, object: item)
                let result = await XCTWaiter.fulfillment(of: [failed], timeout: 5)
                failure.cancel()
                XCTAssertEqual(result, .completed)
            }
            XCTAssertNil(player.pendingSeekPosition, boundary)
            let stale = expectation(description: "Retired seek cannot publish completion")
            stale.isInverted = true
            let event = player.playbackPositionChanged.first().sink { stale.fulfill() }
            seeks.complete(0, finished: true)
            let result = await XCTWaiter.fulfillment(of: [stale], timeout: 0.2)
            event.cancel()
            XCTAssertEqual(result, .completed)
            XCTAssertNil(player.pendingSeekPosition, boundary)
        }
    }

    private func readySeekPlayer(_ seeks: UserSeekProbe) async throws -> FoundationPlayer {
        let file = try XCTUnwrap(FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let player = FoundationPlayer(
            resolve: { _ in file }, activateSession: {}, deactivateSession: {},
            seekForUser: { native, target, completion in
                seeks.calls.append((native, target, completion))
            })
        player.nativePlayer.volume = 0
        let playing = expectation(description: "Real native player ready")
        let state = player.$state.filter { $0 == .playing }.first().sink { _ in playing.fulfill() }
        player.setQueue([track], selectedIndex: 0)
        let result = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
        state.cancel()
        XCTAssertEqual(result, .completed)
        guard result == .completed else {
            player.stop()
            return try XCTUnwrap(nil as FoundationPlayer?)
        }
        return player
    }

    func testHLSCredentialResourcesPreservePlayingMetadataWithoutPublishingSecrets() async throws {
        let file = try XCTUnwrap(FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let token = "synthetic-metadata-credential-25"
        let sourceID = "synthetic-private-source-25"
        let sessionID = "synthetic-private-session-25"
        for delivery in [FoundationPlaybackSource.Delivery.hlsCopy, .hlsAAC] {
            let url = try XCTUnwrap(
                URL(
                    string: "https://playback-metadata.invalid/audio/master.m3u8?ApiKey=\(token)"
                        + "&MediaSourceId=\(sourceID)&PlaySessionId=\(sessionID)"))
            var receivedURLs: [URL] = []
            let player = FoundationPlayer(
                resolve: { _ in
                    XCTFail("Resource resolver must own this selection")
                    return file
                },
                resolveResource: { _ in
                    FoundationPlaybackResource(
                        url: url,
                        source: .init(
                            delivery: delivery, mediaSourceID: sourceID, serverSessionID: sessionID)
                    )
                },
                makeItem: { received in
                    receivedURLs.append(received)
                    // Exercise real native playback without allowing a synthetic remote request.
                    return AVPlayerItem(url: file)
                },
                activateSession: {}, deactivateSession: {})
            player.nativePlayer.volume = 0
            let bridge = FoundationNowPlaying(player: player)
            defer {
                bridge.invalidate()
                player.stop()
            }
            player.setQueue([track], selectedIndex: 0)
            await player.selectionTask?.value
            await player.playTask?.value
            await waitForPlayback(player)
            await bridge.updateTask?.value
            XCTAssertEqual(player.state, .playing)
            XCTAssertTrue(player.wantsPlayback)
            XCTAssertNil(player.errorMessage)
            XCTAssertEqual(receivedURLs, [url])
            let occurrence = try XCTUnwrap(player.selectedEntryID)
            let content = try XCTUnwrap(bridge.content as? MusicContent)
            XCTAssertEqual(bridge.entryID, occurrence)
            XCTAssertEqual(content.id, occurrence.uuidString)
            XCTAssertEqual(content.songTitle, track.title)
            XCTAssertEqual(content.artistName, track.subtitle)
            XCTAssertEqual(content.albumName, "")
            XCTAssertNil(content.artwork)
            XCTAssertNotNil(bridge.playbackSnapshot)
            // Include the full public content projection, not just an empty/error placeholder.
            let metadata = String(reflecting: content)
            for sentinel in [
                token, url.absoluteString, "playback-metadata.invalid", sourceID, sessionID,
            ] {
                XCTAssertFalse(metadata.contains(sentinel))
            }
            #if DEBUG
                XCTAssertTrue(FoundationJournal.shared.isEnabled)
                let journal = FoundationJournal.shared.snapshot()
                XCTAssertTrue(journal.contains("requestedDelivery=" + delivery.rawValue))
                for sentinel in [
                    token, url.absoluteString, "playback-metadata.invalid", sourceID, sessionID,
                ] {
                    XCTAssertFalse(journal.contains(sentinel))
                }
            #endif
        }
    }

    func testRepeatAllEnablesSystemNextAtEndAndWrapsOccurrence() async throws {
        let source = NowPlayingSourceProbe()
        let player = FoundationPlayer(
            resolve: { _ in await source.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
        let bridge = FoundationNowPlaying(player: player)
        defer {
            bridge.invalidate()
            player.stop()
        }
        player.enqueue([track, track], position: .last)
        player.select(player.queue[1].id)
        await player.selectionTask?.value
        await player.playTask?.value
        await bridge.updateTask?.value
        let last = try XCTUnwrap(player.selectedEntryID)
        XCTAssertFalse(bridge.availability.next)
        player.setRepeat(.all)
        await bridge.updateTask?.value
        XCTAssertTrue(bridge.availability.next)
        try bridge.perform(.next, entryID: last)
        await player.selectionTask?.value
        await player.playTask?.value
        XCTAssertEqual(player.selectedEntryID, player.queue.first?.id)
        XCTAssertThrowsError(try bridge.perform(.next, entryID: last))
    }

    func testTextCommandsBoundariesAndDuplicateOccurrenceOwnership() async throws {
        let source = NowPlayingSourceProbe()
        let player = FoundationPlayer(
            resolve: { _ in await source.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
        let bridge = FoundationNowPlaying(player: player)
        defer {
            bridge.invalidate()
            player.stop()
        }
        XCTAssertNil(bridge.content)
        XCTAssertFalse(bridge.availability.play)
        player.setQueue([track, track], selectedIndex: 0)
        await player.selectionTask?.value
        await player.playTask?.value
        await bridge.updateTask?.value
        let first = try XCTUnwrap(bridge.entryID)
        let content = try XCTUnwrap(bridge.content as? MusicContent)
        XCTAssertEqual(content.songTitle, track.title)
        XCTAssertNil(content.artwork)
        XCTAssertTrue(bridge.availability.next)
        try bridge.perform(.pause, entryID: first)
        try bridge.perform(.play, entryID: first)
        await player.playTask?.value
        XCTAssertTrue(player.wantsPlayback)
        try bridge.perform(.play, entryID: first)
        await player.playTask?.value
        XCTAssertTrue(player.wantsPlayback)
        try bridge.perform(.next, entryID: first)
        await player.selectionTask?.value
        await player.playTask?.value
        await bridge.updateTask?.value
        let second = try XCTUnwrap(bridge.entryID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual((bridge.content as? MusicContent)?.id, second.uuidString)
        XCTAssertFalse(bridge.availability.next)
        XCTAssertThrowsError(try bridge.perform(.next, entryID: second))
        XCTAssertThrowsError(try bridge.perform(.seek(2), entryID: first))
        XCTAssertThrowsError(try bridge.perform(.pause, entryID: first))
        let before = await source.count
        _ = bridge.commands
        _ = bridge.content
        _ = bridge.playbackSnapshot
        let after = await source.count
        XCTAssertEqual(before, after)
        XCTAssertEqual(after, 2)
        bridge.invalidate()
        XCTAssertNil(bridge.content)
        XCTAssertNil(bridge.playbackSnapshot)
        XCTAssertThrowsError(try bridge.perform(.pause, entryID: second))
        XCTAssertTrue(player.wantsPlayback)
    }

    func testSnapshotsDoNotFollowPeriodicElapsedTicksButUpdateAfterSeek() async throws {
        let file = try XCTUnwrap(
            FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let player = FoundationPlayer(
            resolve: { _ in file }, activateSession: {}, deactivateSession: {})
        player.nativePlayer.volume = 0
        let bridge = FoundationNowPlaying(player: player)
        defer {
            bridge.invalidate()
            player.stop()
        }
        let playing = XCTestExpectation(description: "Native playback")
        let state = player.$state.filter { $0 == .playing }.first().sink { _ in playing.fulfill() }
        defer { state.cancel() }
        player.setQueue([track], selectedIndex: 0)
        let started = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
        XCTAssertEqual(started, .completed)
        await bridge.updateTask?.value
        let snapshot = bridge.playbackSnapshot
        let ticked = XCTestExpectation(description: "Existing player elapsed tick")
        let tick = player.$elapsed.filter { $0 >= 1 }.first().sink { _ in ticked.fulfill() }
        let tickResult = await XCTWaiter.fulfillment(of: [ticked], timeout: 5)
        tick.cancel()
        XCTAssertEqual(tickResult, .completed)
        await bridge.updateTask?.value
        XCTAssertEqual(bridge.playbackSnapshot, snapshot)
        let sought = XCTestExpectation(description: "Native seek completed")
        let seek = player.playbackPositionChanged.first().sink { sought.fulfill() }
        try bridge.perform(.seek(3), entryID: bridge.entryID)
        let seekResult = await XCTWaiter.fulfillment(of: [sought], timeout: 5)
        seek.cancel()
        XCTAssertEqual(seekResult, .completed)
        await bridge.updateTask?.value
        XCTAssertNotEqual(bridge.playbackSnapshot, snapshot)
        XCTAssertEqual(player.nativePlayer.currentTime().seconds, 3, accuracy: 0.3)
    }

    func testNativePauseBeforePublishedStateKeepsSnapshotValid() async throws {
        let file = try XCTUnwrap(FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let player = FoundationPlayer(
            resolve: { _ in file }, activateSession: {}, deactivateSession: {})
        player.nativePlayer.volume = 0
        player.setQueue([track], selectedIndex: 0)
        await waitForPlayback(player)
        // Native changes precede the queued MainActor callback updating published state.
        player.nativePlayer.pause()
        XCTAssertEqual(player.state, .playing)
        XCTAssertEqual(player.nativePlayer.rate, 0)
        let bridge = FoundationNowPlaying(player: player)
        defer {
            bridge.invalidate()
            player.stop()
        }
        XCTAssertNotNil(bridge.playbackSnapshot)
        XCTAssertTrue(player.wantsPlayback, "Presentation must not change playback intent")
        XCTAssertTrue(bridge.availability.pause)
        let paused = XCTestExpectation(description: "Native pause reaches published player state")
        let subscription = player.$state.filter { $0 == .paused }.first()
            .sink { _ in paused.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [paused], timeout: 5)
        subscription.cancel()
        XCTAssertEqual(result, .completed)
        await bridge.updateTask?.value
        XCTAssertEqual(player.state, .paused)
        XCTAssertNotNil(bridge.playbackSnapshot)
    }

    func testDeniedPrimacyDoesNotRetryDuringNaturalHandoff() async throws {
        let file = try XCTUnwrap(
            FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let source = NowPlayingHandoffProbe(file: file)
        let player = FoundationPlayer(
            resolve: { _ in try await source.resolve() }, activateSession: {}, deactivateSession: {}
        )
        player.nativePlayer.volume = 0
        player.setQueue([track, track], selectedIndex: 0)
        await waitForPlayback(player)
        var requests = 0
        let bridge = FoundationNowPlaying(player: player) {
            requests += 1
            throw MediaSessionError.invalidState
        }
        defer {
            bridge.invalidate()
            player.stop()
            Task { await source.complete() }
        }
        await bridge.primacyTask?.value
        XCTAssertEqual(requests, 1)
        player.didReachEnd(try XCTUnwrap(player.nativePlayer.currentItem))
        let handoff = await source.waitForPending()
        guard handoff == .completed else {
            let calls = await source.calls
            await source.complete()
            XCTFail(
                "Natural handoff did not reach the second source resolve; observed \(calls) resolves"
            )
            return
        }
        await bridge.updateTask?.value
        XCTAssertEqual(player.state, .loading)
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(requests, 1)
        await source.complete()
        await player.selectionTask?.value
        await waitForPlayback(player)
        await bridge.updateTask?.value
        await bridge.primacyTask?.value
        XCTAssertEqual(requests, 1)
        player.pause()
        await bridge.updateTask?.value
        player.play()
        await waitForPlayback(player)
        await bridge.updateTask?.value
        await bridge.primacyTask?.value
        XCTAssertEqual(requests, 2)
    }

    func testHandoffProbeMissingSecondResolveHasFiniteTimeout() async throws {
        let source = NowPlayingHandoffProbe(file: URL(fileURLWithPath: "/synthetic"))
        _ = try await source.resolve()
        let outcome = await source.waitForPending(timeout: 0.01)
        XCTAssertEqual(outcome, .timedOut)
        let calls = await source.calls
        XCTAssertEqual(calls, 1, "The missing event is the second source resolve")
        await source.complete()
    }

    func testHandoffProbeCancellationReleasesHeldResolve() async throws {
        let source = NowPlayingHandoffProbe(file: URL(fileURLWithPath: "/synthetic"))
        _ = try await source.resolve()
        let finished = XCTestExpectation(description: "Cancelled source resolve completed")
        let resolving = Task {
            defer { finished.fulfill() }
            return try await source.resolve()
        }
        let outcome = await source.waitForPending(timeout: 2)
        guard outcome == .completed else {
            resolving.cancel()
            await source.complete()
            XCTFail("Fixture did not hold the second source resolve")
            return
        }
        resolving.cancel()
        let cancelled = await XCTWaiter.fulfillment(of: [finished], timeout: 2)
        guard cancelled == .completed else {
            await source.complete()
            XCTFail("Cancellation did not release the held second source resolve")
            return
        }
        do {
            _ = try await resolving.value
            XCTFail("Cancelled fixture returned a playable source")
        } catch is CancellationError {} catch {
            XCTFail("Unexpected fixture cancellation error")
        }
        let isPending = await source.isPending
        XCTAssertFalse(isPending)
        await source.complete()
    }

    func testPauseBeforeQueuedPrimacyPreventsRequest() async throws {
        let file = try XCTUnwrap(
            FoundationTestTones.resolve(FoundationTestTones.items[0]))
        let player = FoundationPlayer(
            resolve: { _ in file }, activateSession: {}, deactivateSession: {})
        player.nativePlayer.volume = 0
        player.setQueue([track], selectedIndex: 0)
        await waitForPlayback(player)
        var requests = 0
        let bridge = FoundationNowPlaying(player: player) { requests += 1 }
        defer {
            bridge.invalidate()
            player.stop()
        }
        XCTAssertNotNil(bridge.primacyTask)
        player.pause()
        await bridge.primacyTask?.value
        await bridge.updateTask?.value
        XCTAssertEqual(requests, 0)
    }

    private func waitForPlayback(_ player: FoundationPlayer) async {
        let playing = XCTestExpectation(description: "Native playback")
        let subscription = player.$state.filter { $0 == .playing }.first()
            .sink { _ in playing.fulfill() }
        let result = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
        subscription.cancel()
        XCTAssertEqual(result, .completed)
    }

    #if os(iOS)
        func testSystemInterruptionPublishesInterruptedAndExplicitPlayClearsIt() async {
            let player = FoundationPlayer(
                resolve: { _ in URL(fileURLWithPath: "/synthetic") },
                makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
                activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
            let bridge = FoundationNowPlaying(player: player)
            defer {
                bridge.invalidate()
                player.stop()
            }
            player.setQueue([track], selectedIndex: 0)
            await player.selectionTask?.value
            await player.playTask?.value
            player.didDeactivateAudioSession(source: .system)
            await bridge.updateTask?.value
            XCTAssertTrue(player.isInterrupted)
            XCTAssertTrue(bridge.availability.play)
            player.play()
            XCTAssertFalse(player.isInterrupted)
        }
    #endif
}

private actor NowPlayingSourceProbe {
    private(set) var count = 0
    func resolve() -> URL {
        count += 1
        return URL(fileURLWithPath: "/synthetic")
    }
}

private actor NowPlayingHandoffProbe {
    let file: URL
    private(set) var calls = 0
    private var pending: CheckedContinuation<URL, Error>?
    private let pendingEvent = XCTestExpectation(description: "Second source resolve reached")
    var isPending: Bool { pending != nil }

    init(file: URL) { self.file = file }

    func resolve() async throws -> URL {
        try Task.checkCancellation()
        calls += 1
        guard calls == 2 else { return file }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                pendingEvent.fulfill()
            }
        } onCancel: {
            Task { await self.cancelPending() }
        }
    }

    func waitForPending(timeout: TimeInterval = 10) async -> XCTWaiter.Result {
        await XCTWaiter.fulfillment(of: [pendingEvent], timeout: timeout)
    }

    private func cancelPending() {
        pending?.resume(throwing: CancellationError())
        pending = nil
    }

    func complete() {
        pending?.resume(returning: file)
        pending = nil
    }
}

@MainActor
private final class UserSeekProbe {
    var calls: [(AVPlayer, CMTime, @Sendable (Bool) -> Void)] = []

    func land(_ index: Int) {
        let (player, target, completion) = calls[index]
        player.seek(
            to: target, toleranceBefore: .zero, toleranceAfter: .zero,
            completionHandler: completion)
    }

    func complete(_ index: Int, finished: Bool) {
        calls[index].2(finished)
    }
}
