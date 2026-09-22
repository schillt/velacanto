import AVFoundation
import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPlayerTests: XCTestCase {
    private let track = FoundationItem(
        id: "synthetic", title: "", subtitle: "", kind: .track, duration: nil)

    private func player(_ resolver: PlayerResolutionProbe) -> FoundationPlayer {
        FoundationPlayer(
            resolve: { _ in try await resolver.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in }
        )
    }

    func testNativeSilentWAVPublishesPlayingAndStopReleasesItem() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Self.silentWAV().write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }

        // Real native item construction, loading and play; only audio-session
        // configuration is bypassed. PCM samples are all zero (digital silence).
        let player = FoundationPlayer(
            resolve: { _ in file }, activateSession: {}, deactivateSession: {}
        )
        defer { player.stop() }
        let playing = XCTestExpectation(description: "Native player publishes playing")
        let subscription = player.$state.filter { $0 == .playing }.first().sink { _ in
            playing.fulfill()
        }
        defer { subscription.cancel() }

        player.setQueue([track], selectedIndex: 0)
        XCTAssertEqual(player.state, .loading)
        XCTAssertNotEqual(player.state, .playing)
        let result = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
        XCTAssertEqual(result, .completed, "Native silent playback did not reach playing")
        XCTAssertEqual(player.nativePlayer.timeControlStatus, .playing)
        XCTAssertEqual(player.nativePlayer.currentItem?.status, .readyToPlay)
        player.togglePlayback()
        let entryID = try XCTUnwrap(player.selectedEntryID)
        for target in [2.0, 0.5, 4.0] {
            let landed = XCTestExpectation(description: "Native seek publishes requested position")
            let positionSubscription = player.$elapsed.filter { abs($0 - target) < 0.1 }.first()
                .sink { _ in
                    landed.fulfill()
                }
            player.seek(to: target, entryID: entryID)
            let seekResult = await XCTWaiter.fulfillment(of: [landed], timeout: 5)
            positionSubscription.cancel()
            XCTAssertEqual(seekResult, .completed)
            XCTAssertEqual(player.nativePlayer.currentTime().seconds, target, accuracy: 0.1)
            XCTAssertEqual(player.state, .paused)
        }
        let restarted = XCTestExpectation(description: "Previous restarts current occurrence")
        let restartSubscription = player.$elapsed.filter { $0 < 0.1 }.first().sink { _ in
            restarted.fulfill()
        }
        player.previous()
        let restartResult = await XCTWaiter.fulfillment(of: [restarted], timeout: 5)
        restartSubscription.cancel()
        XCTAssertEqual(restartResult, .completed)
        XCTAssertEqual(player.selectedEntryID, entryID)
        XCTAssertEqual(player.state, .paused)
        player.stop()
        XCTAssertEqual(player.state, .idle)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertNil(player.nativePlayer.currentItem)
    }

    #if os(iOS)
        func testSystemDeactivationPausesNativePlaybackAndRetainsItem() async throws {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
            try Self.silentWAV().write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            let player = FoundationPlayer(
                resolve: { _ in file }, activateSession: {}, deactivateSession: {})
            defer { player.stop() }
            let playing = XCTestExpectation(description: "Native playback started")
            let subscription = player.$state.filter { $0 == .playing }.first().sink { _ in
                playing.fulfill()
            }
            defer { subscription.cancel() }
            player.setQueue([track], selectedIndex: 0)
            let result = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
            XCTAssertEqual(result, .completed)
            let item = try XCTUnwrap(player.nativePlayer.currentItem)
            let selected = player.selectedEntryID

            player.didDeactivateAudioSession(source: .system)

            XCTAssertFalse(player.wantsPlayback)
            XCTAssertEqual(player.state, .paused)
            XCTAssertEqual(player.nativePlayer.rate, 0)
            XCTAssertTrue(player.nativePlayer.currentItem === item)
            XCTAssertEqual(player.selectedEntryID, selected)
        }

        func testSystemDeactivationBeforeResolutionPreventsLateAutomaticStart() async {
            let resolver = PlayerResolutionProbe()
            var starts = 0
            let player = FoundationPlayer(
                resolve: { _ in try await resolver.resolve() },
                makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
                activateSession: {}, deactivateSession: {}, startPlayback: { _ in starts += 1 })
            defer { player.stop() }
            player.setQueue([track], selectedIndex: 0)
            let selection = player.selectionTask
            await resolver.waitForCalls(1)

            player.didDeactivateAudioSession(source: .system)
            await resolver.succeed(0)
            await selection?.value

            XCTAssertFalse(player.wantsPlayback)
            XCTAssertEqual(player.state, .paused)
            XCTAssertNotNil(player.nativePlayer.currentItem)
            XCTAssertEqual(starts, 0)
        }

        func testLateAppDeactivationDoesNotPauseNewSelection() async throws {
            let resolver = PlayerResolutionProbe()
            let player = player(resolver)
            defer { player.stop() }
            player.setQueue([track], selectedIndex: 0)
            let oldSelection = player.selectionTask
            await resolver.waitForCalls(1)
            player.stop()
            player.setQueue([track], selectedIndex: 0)
            let newSelection = player.selectionTask
            await resolver.waitForCalls(2)

            player.didDeactivateAudioSession(source: .app)
            XCTAssertTrue(player.wantsPlayback)
            await resolver.succeed(0)
            await oldSelection?.value
            XCTAssertNil(player.nativePlayer.currentItem)
            await resolver.succeed(1)
            await newSelection?.value
            let item = try XCTUnwrap(player.nativePlayer.currentItem)
            player.didDeactivateAudioSession(source: .app)
            XCTAssertTrue(player.wantsPlayback)
            XCTAssertTrue(player.nativePlayer.currentItem === item)
        }
    #endif

    private static func silentWAV() -> Data {
        // Six seconds of 8 kHz, mono, signed 16-bit little-endian PCM.
        let byteCount: UInt32 = 8_000 * 6 * 2
        var data = Data()
        func append16(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(36 + byteCount)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(1)
        append32(8_000)
        append32(16_000)
        append16(2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(byteCount)
        data.append(Data(repeating: 0, count: Int(byteCount)))
        return data
    }

    func testLatestSelectionRejectsCancelledLateResolution() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track, track], selectedIndex: 0)
        let obsolete = player.selectionTask
        await resolver.waitForCalls(1)
        player.select(player.queue[1].id)
        let current = player.selectionTask
        await resolver.waitForCalls(2)
        await resolver.succeed(1)
        await current?.value
        let installed = player.nativePlayer.currentItem
        await resolver.succeed(0)  // Deliberately ignores task cancellation.
        await obsolete?.value
        XCTAssertNotNil(installed)
        XCTAssertTrue(player.nativePlayer.currentItem === installed)
        XCTAssertEqual(player.selectedEntryID, player.queue[1].id)
        XCTAssertNotEqual(player.state, .playing)
        player.stop()
    }

    func testQueueReplacementDuringLoadRejectsOldCompletion() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track], selectedIndex: 0)
        let obsolete = player.selectionTask
        let oldID = player.selectedEntryID
        await resolver.waitForCalls(1)
        player.setQueue([track], selectedIndex: 0)
        let current = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertNotEqual(player.selectedEntryID, oldID)
        await resolver.succeed(0)
        await obsolete?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await current?.value
        XCTAssertNotNil(player.nativePlayer.currentItem)
        player.stop()
    }

    func testDuplicateOccurrencesAndBoundaryRequestBudget() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        XCTAssertNotEqual(player.queue[0].id, player.queue[1].id)
        XCTAssertEqual(player.queue[0].item, player.queue[1].item)
        player.previous()
        await resolver.succeed(0)
        await first?.value
        player.next()
        let second = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertNil(player.nativePlayer.currentItem)  // Old item gone before resolution.
        player.next()
        await resolver.succeed(1)
        await second?.value
        let count = await resolver.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(player.selectedEntryID, player.queue[1].id)
        player.previous()
        let previous = player.selectionTask
        await resolver.waitForCalls(3)
        await resolver.succeed(2)
        await previous?.value
        XCTAssertEqual(player.selectedEntryID, player.queue[0].id)
        player.stop()
    }

    func testStopAndInvalidQueueCannotInstallPendingItem() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track], selectedIndex: 0)
        let obsolete = player.selectionTask
        await resolver.waitForCalls(1)
        player.stop()
        await resolver.succeed(0)
        await obsolete?.value
        XCTAssertEqual(player.state, .idle)
        XCTAssertEqual(player.selectedEntryID, player.queue[0].id)
        XCTAssertNil(player.nativePlayer.currentItem)
        player.setQueue([], selectedIndex: 0)
        player.next()
        player.previous()
        player.select(UUID())
        let count = await resolver.count
        XCTAssertEqual(count, 1)
    }

    func testStopThenPlayResolvesRetainedOccurrenceFresh() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track], selectedIndex: 0)
        let obsolete = player.selectionTask
        let selected = player.selectedEntryID
        await resolver.waitForCalls(1)
        player.stop()
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.selectedEntryID, selected)
        player.togglePlayback()
        let restarted = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(player.state, .loading)
        await resolver.succeed(0)
        await obsolete?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await restarted?.value
        XCTAssertNotNil(player.nativePlayer.currentItem)
        XCTAssertEqual(player.selectedEntryID, selected)
        let count = await resolver.count
        XCTAssertEqual(count, 2)
        player.stop()
    }

    func testPauseButtonIntentDuringResolutionPreventsAutomaticPlay() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track], selectedIndex: 0)
        let selection = player.selectionTask
        await resolver.waitForCalls(1)
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(player.state, .loading)
        player.togglePlayback()
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        await resolver.succeed(0)
        await selection?.value
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        player.stop()
    }

    func testFailureNeedsExplicitSelectionAndCanRecover() async {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track], selectedIndex: 0)
        let failed = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.fail(0)
        await failed?.value
        XCTAssertEqual(player.state, .failed)
        XCTAssertNotNil(player.errorMessage)
        player.togglePlayback()  // Explicit Play re-resolves a failed selection.
        let recovery = player.selectionTask
        await resolver.waitForCalls(2)
        await resolver.succeed(1)
        await recovery?.value
        XCTAssertNil(player.errorMessage)
        XCTAssertNotNil(player.nativePlayer.currentItem)
        XCTAssertNotEqual(player.state, .playing)
        player.stop()
    }

    func testNaturalEndAdvancesOnceAndStaleEndIsIgnored() async throws {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        let oldItem = try XCTUnwrap(player.nativePlayer.currentItem)
        player.didReachEnd(oldItem)
        let second = player.selectionTask
        await resolver.waitForCalls(2)
        player.didReachEnd(oldItem)
        await resolver.succeed(1)
        await second?.value
        let lastItem = try XCTUnwrap(player.nativePlayer.currentItem)
        player.didReachEnd(lastItem)
        XCTAssertEqual(player.state, .ended)
        let count = await resolver.count
        XCTAssertEqual(count, 2)
        player.stop()
    }
}

private actor PlayerResolutionProbe {
    private var pending: [Int: CheckedContinuation<URL, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var count = 0

    func resolve() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            pending[count] = continuation
            count += 1
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }

    func succeed(_ index: Int) {
        // Factory ignores this local URL; tests never load a file or remote asset.
        pending.removeValue(forKey: index)?.resume(returning: URL(fileURLWithPath: "/synthetic"))
    }

    func fail(_ index: Int) {
        pending.removeValue(forKey: index)?.resume(throwing: CancellationError())
    }
}
