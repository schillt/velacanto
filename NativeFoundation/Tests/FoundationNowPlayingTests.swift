import AVFoundation
import Combine
import NowPlaying
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationNowPlayingTests: XCTestCase {
    private let track = FoundationItem(
        id: "synthetic", title: "Test title", subtitle: "Test artist", kind: .track, duration: 8)

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
            FoundationDiagnosticTones.resolve(FoundationDiagnosticTones.items[0]))
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

    func testDeniedPrimacyDoesNotRetryDuringNaturalHandoff() async throws {
        let file = try XCTUnwrap(
            FoundationDiagnosticTones.resolve(FoundationDiagnosticTones.items[0]))
        let source = NowPlayingHandoffProbe(file: file)
        let player = FoundationPlayer(
            resolve: { _ in await source.resolve() }, activateSession: {}, deactivateSession: {})
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
        }
        await bridge.primacyTask?.value
        XCTAssertEqual(requests, 1)
        player.didReachEnd(try XCTUnwrap(player.nativePlayer.currentItem))
        await source.waitForPending()
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

    func testPauseBeforeQueuedPrimacyPreventsRequest() async throws {
        let file = try XCTUnwrap(
            FoundationDiagnosticTones.resolve(FoundationDiagnosticTones.items[0]))
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
    private var calls = 0
    private var pending: CheckedContinuation<URL, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(file: URL) { self.file = file }

    func resolve() async -> URL {
        calls += 1
        guard calls == 2 else { return file }
        return await withCheckedContinuation { continuation in
            pending = continuation
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForPending() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func complete() {
        pending?.resume(returning: file)
        pending = nil
    }
}
