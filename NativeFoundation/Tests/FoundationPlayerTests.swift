import AVFoundation
import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPlayerTests: XCTestCase {
    private let track = FoundationItem(
        id: "synthetic", title: "", subtitle: "", kind: .track, duration: nil)

    func testDiagnosticTonesAreBoundedDistinctPCMWithoutArtwork() throws {
        let items = FoundationDiagnosticTones.items
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
        var payloads: [Data] = []
        for index in items.indices {
            let item = items[index]
            XCTAssertNil(item.album)
            XCTAssertNil(item.primaryImageTag)
            XCTAssertNil(item.isFavorite)
            let data = FoundationDiagnosticTones.wave(index: index)
            XCTAssertEqual(data.count, 44 + 22_050 * 8 * 2)
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            let samples = stride(from: 44, to: data.count, by: 2).map {
                Int(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8))
            }
            XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 2_000)
            XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 2_622)
            XCTAssertEqual(samples.first, 0)
            XCTAssertEqual(samples.last, 0)
            payloads.append(data)
        }
        XCTAssertNotEqual(payloads[0], payloads[1])
        XCTAssertNotEqual(payloads[1], payloads[2])
        XCTAssertNil(try FoundationDiagnosticTones.resolve(track))
    }

    func testDiagnosticNativeQueueCompletesEveryOccurrenceWithoutManualAdvance() async throws {
        let player = FoundationPlayer(
            resolve: { item in
                guard let url = try FoundationDiagnosticTones.resolve(item) else {
                    throw URLError(.unsupportedURL)
                }
                return url
            }, activateSession: {}, deactivateSession: {})
        player.nativePlayer.volume = 0  // Automated evidence is native completion, not audibility.
        defer { player.stop() }
        let ended = XCTestExpectation(description: "Three native tone items finish")
        var selections: [UUID] = []
        let selection = player.$selectedEntryID.compactMap { $0 }.sink { selections.append($0) }
        let state = player.$state.filter { $0 == .ended }.first().sink { _ in ended.fulfill() }
        defer {
            selection.cancel()
            state.cancel()
        }
        player.setQueue(FoundationDiagnosticTones.items, selectedIndex: 0)
        let expected = player.queue.map(\.id)
        let result = await XCTWaiter.fulfillment(of: [ended], timeout: 40)
        XCTAssertEqual(result, .completed)
        XCTAssertEqual(selections, expected)
        XCTAssertFalse(player.wantsPlayback)
    }

    func testPauseDuringActivationSuppressesLateNativeStart() async {
        let session = SessionOperationProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: { try await session.run("activate") }, deactivateSession: {},
            startPlayback: { _ in starts += 1 })
        player.setQueue([track], selectedIndex: 0)
        await session.waitForCalls(1)
        let activation = player.playTask
        player.pause()
        await session.finish(0)
        await activation?.value
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        player.stop()
        await player.sessionTask?.value
    }

    func testStopThenNewSelectionSerializesActivationDeactivationAndStart() async {
        let session = SessionOperationProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: { try await session.run("activate") },
            deactivateSession: { try await session.run("deactivate") },
            startPlayback: { _ in starts += 1 })
        player.setQueue([track], selectedIndex: 0)
        await session.waitForCalls(1)
        player.stop()
        player.setQueue([track], selectedIndex: 0)
        let selected = player.selectedEntryID
        await session.finish(0)
        await session.waitForCalls(2)
        let beforeDeactivation = await session.events
        XCTAssertEqual(beforeDeactivation, ["activate", "deactivate"])
        XCTAssertEqual(starts, 0)
        await session.finish(1)
        await session.waitForCalls(3)
        let activation = player.playTask
        await session.finish(2)
        await activation?.value
        let events = await session.events
        XCTAssertEqual(events, ["activate", "deactivate", "activate"])
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(player.selectedEntryID, selected)
        player.stop()
        await session.waitForCalls(4)
        await session.finish(3)
        await player.sessionTask?.value
    }

    func testRetiringPlayerDeactivationPrecedesNewAccountOwnerActivation() async {
        let session = SessionOperationProbe()
        var oldStarts = 0
        var newStarts = 0
        let oldPlayer = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: { try await session.run("oldActivate") },
            deactivateSession: { try await session.run("oldDeactivate") },
            startPlayback: { _ in oldStarts += 1 })
        let newPlayer = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: { try await session.run("newActivate") }, deactivateSession: {},
            startPlayback: { _ in newStarts += 1 })
        oldPlayer.setQueue([track], selectedIndex: 0)
        await session.waitForCalls(1)
        oldPlayer.stop()
        newPlayer.setQueue([track], selectedIndex: 0)
        await session.finish(0)
        await session.waitForCalls(2)
        XCTAssertEqual(newStarts, 0)
        await session.finish(1)
        await session.waitForCalls(3)
        let activation = newPlayer.playTask
        await session.finish(2)
        await activation?.value
        let events = await session.events
        XCTAssertEqual(events, ["oldActivate", "oldDeactivate", "newActivate"])
        XCTAssertEqual(oldStarts, 0)
        XCTAssertEqual(newStarts, 1)
        newPlayer.stop()
        await newPlayer.sessionTask?.value
    }

    #if os(iOS)
        func testSystemInterruptionDuringActivationCannotStartAudio() async {
            let session = SessionOperationProbe()
            var starts = 0
            let player = FoundationPlayer(
                resolve: { _ in URL(fileURLWithPath: "/synthetic") },
                makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
                activateSession: { try await session.run("activate") }, deactivateSession: {},
                startPlayback: { _ in starts += 1 })
            player.setQueue([track], selectedIndex: 0)
            await session.waitForCalls(1)
            let activation = player.playTask
            player.didDeactivateAudioSession(source: .system)
            await session.finish(0)
            await activation?.value
            XCTAssertEqual(starts, 0)
            XCTAssertFalse(player.wantsPlayback)
            player.stop()
            await player.sessionTask?.value
        }
    #endif

    func testObsoleteActivationFailureCannotFailReplacementSelection() async {
        let session = SessionOperationProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: { try await session.run("activate") }, deactivateSession: {},
            startPlayback: { _ in starts += 1 })
        player.setQueue([track, track], selectedIndex: 0)
        await session.waitForCalls(1)
        player.next()
        await session.finish(0, failing: true)
        await session.waitForCalls(2)
        XCTAssertNotEqual(player.state, .failed)
        let activation = player.playTask
        await session.finish(1, failing: true)
        await activation?.value
        XCTAssertEqual(player.state, .failed)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(starts, 0)
        player.stop()
        await player.sessionTask?.value
    }

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
        await player.playTask?.value
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
            await player.playTask?.value

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
            await player.playTask?.value
            XCTAssertNil(player.nativePlayer.currentItem)
            await resolver.succeed(1)
            await newSelection?.value
            await player.playTask?.value
            let item = try XCTUnwrap(player.nativePlayer.currentItem)
            player.didDeactivateAudioSession(source: .app)
            XCTAssertTrue(player.wantsPlayback)
            XCTAssertTrue(player.nativePlayer.currentItem === item)
        }
    #endif

    func testRejectedStartResumesSameItemWithOneToggleAndIgnoresLateFailure() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        try Self.silentWAV().write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let resolver = PlayerResolutionProbe()
        var starts = 0
        var activations = 0
        let player = FoundationPlayer(
            resolve: { _ in try await resolver.resolve() },
            makeItem: { _ in AVPlayerItem(url: file) },
            activateSession: { activations += 1 }, deactivateSession: {},
            startPlayback: { native in
                starts += 1
                if starts > 1 {
                    // A prior rejection arrives inside the newer native start, before rate changes.
                    NotificationCenter.default.post(
                        name: AVPlayer.rateDidChangeNotification, object: native,
                        userInfo: [
                            AVPlayer.rateDidChangeReasonKey: AVPlayer.RateDidChangeReason
                                .setRateFailed.rawValue
                        ])
                    native.play()
                }
            })
        defer { player.stop() }
        player.setQueue([track], selectedIndex: 0)
        let selection = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await selection?.value
        await player.playTask?.value
        let item = try XCTUnwrap(player.nativePlayer.currentItem)
        let occurrence = player.selectedEntryID
        let ready = XCTestExpectation(description: "Real item becomes ready without native start")
        let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay { ready.fulfill() }
        }
        defer { observation.invalidate() }
        let readiness = await XCTWaiter.fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(readiness, .completed)
        // Readiness plus paused alone is not proof that the requested start was rejected.
        XCTAssertTrue(player.wantsPlayback)
        Self.postRateFailure(player)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        XCTAssertTrue(player.nativePlayer.currentItem === item)

        let playing = XCTestExpectation(description: "One toggle resumes the retained native item")
        let subscription = player.$state.filter { $0 == .playing }.first().sink { _ in
            playing.fulfill()
        }
        defer { subscription.cancel() }
        player.togglePlayback()
        await player.playTask?.value
        XCTAssertGreaterThan(player.nativePlayer.rate, 0)
        // Delivered before any queued KVO task runs: a newer waiting/playing request wins.
        Self.postRateFailure(player)
        XCTAssertTrue(player.wantsPlayback)
        player.play()
        await player.playTask?.value
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(activations, 2)
        let playback = await XCTWaiter.fulfillment(of: [playing], timeout: 10)
        XCTAssertEqual(playback, .completed)
        XCTAssertTrue(player.nativePlayer.currentItem === item)
        XCTAssertEqual(player.selectedEntryID, occurrence)
        let resolutions = await resolver.count
        XCTAssertEqual(resolutions, 1)

        player.pause()
        player.pause()
        Self.postRateFailure(player)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(starts, 2)
    }

    func testOldRateFailureCannotCancelReplacementResolutionOrExplicitPause() async {
        let resolver = PlayerResolutionProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in try await resolver.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in starts += 1 })
        defer { player.stop() }
        player.setQueue([track, track], selectedIndex: 0)
        let oldSelection = player.selectionTask
        await resolver.waitForCalls(1)
        player.next()
        let replacement = player.selectionTask
        await resolver.waitForCalls(2)
        Self.postRateFailure(player)
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(player.state, .loading)
        player.play()
        await player.playTask?.value
        player.pause()
        Self.postRateFailure(player)
        await resolver.succeed(0)
        await oldSelection?.value
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await replacement?.value
        await player.playTask?.value
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(starts, 0)
    }

    func testImmediateNativeRejectionFinishesIntentWithoutAutomaticRetry() async throws {
        let resolver = PlayerResolutionProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in try await resolver.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {},
            startPlayback: { native in
                starts += 1
                NotificationCenter.default.post(
                    name: AVPlayer.rateDidChangeNotification, object: native,
                    userInfo: [
                        AVPlayer.rateDidChangeReasonKey: AVPlayer.RateDidChangeReason.setRateFailed
                            .rawValue
                    ])
            })
        defer { player.stop() }
        player.setQueue([track], selectedIndex: 0)
        let selection = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await selection?.value
        await player.playTask?.value
        let item = try XCTUnwrap(player.nativePlayer.currentItem)
        await Task.yield()
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(starts, 1)
        player.play()
        await player.playTask?.value
        XCTAssertEqual(starts, 2)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertTrue(player.nativePlayer.currentItem === item)
        let resolutions = await resolver.count
        XCTAssertEqual(resolutions, 1)
    }

    private static func postRateFailure(_ player: FoundationPlayer) {
        NotificationCenter.default.post(
            name: AVPlayer.rateDidChangeNotification, object: player.nativePlayer,
            userInfo: [
                AVPlayer.rateDidChangeReasonKey: AVPlayer.RateDidChangeReason.setRateFailed.rawValue
            ])
    }

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
        await player.playTask?.value
        let installed = player.nativePlayer.currentItem
        await resolver.succeed(0)  // Deliberately ignores task cancellation.
        await obsolete?.value
        await player.playTask?.value
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
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await current?.value
        await player.playTask?.value
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
        await player.playTask?.value
        player.next()
        let second = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertNil(player.nativePlayer.currentItem)  // Old item gone before resolution.
        player.next()
        await resolver.succeed(1)
        await second?.value
        await player.playTask?.value
        let count = await resolver.count
        XCTAssertEqual(count, 2)
        XCTAssertEqual(player.selectedEntryID, player.queue[1].id)
        player.previous()
        let previous = player.selectionTask
        await resolver.waitForCalls(3)
        await resolver.succeed(2)
        await previous?.value
        await player.playTask?.value
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
        await player.playTask?.value
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
        await player.playTask?.value
        let restarted = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(player.state, .loading)
        await resolver.succeed(0)
        await obsolete?.value
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await restarted?.value
        await player.playTask?.value
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
        await player.playTask?.value
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(player.state, .paused)
        await resolver.succeed(0)
        await selection?.value
        await player.playTask?.value
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
        await player.playTask?.value
        XCTAssertEqual(player.state, .failed)
        XCTAssertNotNil(player.errorMessage)
        player.togglePlayback()  // Explicit Play re-resolves a failed selection.
        await player.playTask?.value
        let recovery = player.selectionTask
        await resolver.waitForCalls(2)
        await resolver.succeed(1)
        await recovery?.value
        await player.playTask?.value
        XCTAssertNil(player.errorMessage)
        XCTAssertNotNil(player.nativePlayer.currentItem)
        XCTAssertNotEqual(player.state, .playing)
        player.stop()
    }

    func testNaturalHandoffRetainsItemAndPendingCommandsDoNotReplayIt() async throws {
        let resolver = PlayerResolutionProbe()
        var starts = 0
        let player = FoundationPlayer(
            resolve: { _ in try await resolver.resolve() },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in starts += 1 })
        defer { player.stop() }
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        await player.playTask?.value
        let oldItem = try XCTUnwrap(player.nativePlayer.currentItem)
        XCTAssertEqual(player.nativePlayer.actionAtItemEnd, .none)
        player.didReachEnd(oldItem)
        let successor = player.selectionTask
        await resolver.waitForCalls(2)
        XCTAssertTrue(player.nativePlayer.currentItem === oldItem)
        let startCount = starts
        player.play()
        await player.playTask?.value
        player.play()
        await player.playTask?.value
        player.didReachEnd(oldItem)
        XCTAssertEqual(starts, startCount)
        player.pause()
        await resolver.succeed(1)
        await successor?.value
        await player.playTask?.value
        XCTAssertFalse(player.nativePlayer.currentItem === oldItem)
        XCTAssertFalse(player.wantsPlayback)
        XCTAssertEqual(starts, startCount)
        let resolutions = await resolver.count
        XCTAssertEqual(resolutions, 2)
    }

    func testPreviousDuringNaturalHandoffDiscardsOldEventsAndLateSuccessor() async throws {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        defer { player.stop() }
        player.setQueue([track, track], selectedIndex: 0)
        let firstID = player.queue[0].id
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        await player.playTask?.value
        let oldItem = try XCTUnwrap(player.nativePlayer.currentItem)
        player.didReachEnd(oldItem)
        let successor = player.selectionTask
        await resolver.waitForCalls(2)
        Self.postRateFailure(player)
        NotificationCenter.default.post(
            name: AVPlayerItem.failedToPlayToEndTimeNotification, object: oldItem)
        await Task.yield()
        XCTAssertTrue(player.wantsPlayback)
        XCTAssertEqual(player.state, .loading)
        player.previous()
        let replacement = player.selectionTask
        await resolver.waitForCalls(3)
        XCTAssertEqual(player.selectedEntryID, firstID)
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(1)
        await successor?.value
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        await resolver.succeed(2)
        await replacement?.value
        await player.playTask?.value
        XCTAssertNotNil(player.nativePlayer.currentItem)
        XCTAssertEqual(player.selectedEntryID, firstID)
    }

    func testStoppedNaturalHandoffRejectsLateResolution() async throws {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        await player.playTask?.value
        player.didReachEnd(try XCTUnwrap(player.nativePlayer.currentItem))
        let successor = player.selectionTask
        await resolver.waitForCalls(2)
        player.stop()
        await resolver.succeed(1)
        await successor?.value
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        XCTAssertEqual(player.state, .idle)
        XCTAssertFalse(player.wantsPlayback)
    }

    func testFailedNaturalHandoffReleasesExhaustedItem() async throws {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        defer { player.stop() }
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        await player.playTask?.value
        player.didReachEnd(try XCTUnwrap(player.nativePlayer.currentItem))
        let successor = player.selectionTask
        await resolver.waitForCalls(2)
        await resolver.fail(1)
        await successor?.value
        await player.playTask?.value
        XCTAssertNil(player.nativePlayer.currentItem)
        XCTAssertEqual(player.state, .failed)
        XCTAssertFalse(player.wantsPlayback)
    }

    func testNaturalEndAdvancesOnceAndStaleEndIsIgnored() async throws {
        let resolver = PlayerResolutionProbe()
        let player = player(resolver)
        player.setQueue([track, track], selectedIndex: 0)
        let first = player.selectionTask
        await resolver.waitForCalls(1)
        await resolver.succeed(0)
        await first?.value
        await player.playTask?.value
        let oldItem = try XCTUnwrap(player.nativePlayer.currentItem)
        player.didReachEnd(oldItem)
        let second = player.selectionTask
        await resolver.waitForCalls(2)
        player.didReachEnd(oldItem)
        await resolver.succeed(1)
        await second?.value
        await player.playTask?.value
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

private actor SessionOperationProbe {
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var events: [String] = []

    func run(_ event: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pending[events.count] = continuation
            events.append(event)
            let ready = waiters.filter { $0.0 <= events.count }
            waiters.removeAll { $0.0 <= events.count }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitForCalls(_ count: Int) async {
        if events.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(_ index: Int, failing: Bool = false) {
        if failing {
            pending.removeValue(forKey: index)?.resume(throwing: URLError(.unknown))
        } else {
            pending.removeValue(forKey: index)?.resume()
        }
    }
}
