import AVFoundation
import Foundation
import MediaPlayer
import XCTest

@testable import Velacanto

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

private final class SendableArtworkBox: @unchecked Sendable {
    let artwork: MPMediaItemArtwork

    init(_ artwork: MPMediaItemArtwork) {
        self.artwork = artwork
    }
}

@MainActor
final class PlaybackFoundationTests: XCTestCase {
    func testDurationFormattingHandlesInvalidValues() {
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: -1), "0:00")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: .nan), "0:00")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: .infinity), "0:00")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: 197), "3:17")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: 3_661), "61:01")
    }

    func testMusicSourceIdentifiersRemainOpenEnded() {
        let futureSource = MusicSourceID(rawValue: "future-provider")

        XCTAssertNotEqual(futureSource, .localFiles)
        XCTAssertNotEqual(futureSource, .jellyfin)
        XCTAssertEqual(futureSource.rawValue, "future-provider")
    }

    func testLocalAdapterPreservesTheSelectedURL() async throws {
        let url = try await DemoToneFactory.makeURL()
        let request = try await LocalFilePlaybackAdapter().playbackRequest(
            for: LocalFileSelection(url: url)
        )
        let playerItem = request.asset.makePlayerItem()
        let asset = try XCTUnwrap(playerItem.asset as? AVURLAsset)

        XCTAssertEqual(asset.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(request.item.source, .localFiles)
        XCTAssertEqual(request.item.title, "playback-test-tone-60s")
        XCTAssertNotNil(request.asset.resourceLease)
    }

    func testLocalAdapterRejectsRemoteURLs() async throws {
        let adapter = LocalFilePlaybackAdapter()
        let remoteURL = try XCTUnwrap(URL(string: "https://example.com/audio.mp3"))

        await assertThrowsErrorAsync {
            _ = try await adapter.playbackRequest(
                for: LocalFileSelection(url: remoteURL)
            )
        }
    }

    func testGeneratedPlaybackToneIsReadableAudio() async throws {
        let url = try await DemoToneFactory.makeURL()
        let file = try AVAudioFile(forReading: url)
        let measuredDuration = Double(file.length) / file.processingFormat.sampleRate

        XCTAssertEqual(
            measuredDuration,
            DemoToneFactory.duration,
            accuracy: 0.01
        )
    }

    func testPlaybackCoordinatorFollowsEngineEventsAndSystemCommands() async throws {
        let engine = RecordingAudioPlayerEngine()
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: systemMediaController
        )
        let request = try await makePlaybackRequest()

        coordinator.play(request)

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(engine.playCallCount, 1)

        engine.send(.stateChanged(.waiting))
        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertFalse(coordinator.showsPauseControl)

        engine.send(.stateChanged(.playing))
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, true)

        systemMediaController.pause?()
        XCTAssertEqual(engine.pauseCallCount, 1)
        engine.send(.stateChanged(.paused))
        XCTAssertFalse(coordinator.isPlaying)

        systemMediaController.play?()
        XCTAssertEqual(engine.playCallCount, 2)
        engine.send(.stateChanged(.playing))

        engine.send(.timeChanged(elapsed: 1, duration: 60))
        let snapshotCountAfterDurationChange = systemMediaController.snapshots.count
        engine.send(.timeChanged(elapsed: 1.25, duration: 60))
        XCTAssertEqual(
            systemMediaController.snapshots.count,
            snapshotCountAfterDurationChange
        )

        systemMediaController.seek?(2.5)
        XCTAssertEqual(engine.seekTimes.last, 2.5)
        XCTAssertEqual(coordinator.elapsed, 2.5, accuracy: 0.001)

        engine.send(.timeChanged(elapsed: 60, duration: 60))
        engine.send(.stateChanged(.ended))
        XCTAssertEqual(coordinator.playbackState, .ended)
        XCTAssertFalse(coordinator.isPlaying)

        coordinator.stop()
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertNil(coordinator.currentItem)
        XCTAssertEqual(systemMediaController.latestSnapshot, .empty)
    }

    func testPlaybackCoordinatorPublishesEngineFailure() async throws {
        let engine = RecordingAudioPlayerEngine()
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: systemMediaController
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.failed("Stream unavailable")))

        XCTAssertEqual(coordinator.playbackState, .failed("Stream unavailable"))
        XCTAssertEqual(coordinator.errorMessage, "Stream unavailable")
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, false)

        engine.send(.stateChanged(.paused))
        XCTAssertEqual(coordinator.playbackState, .failed("Stream unavailable"))
    }

    func testPlaybackUsesItemDurationUntilTheEnginePublishesOne()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        let request = PlaybackRequest(
            item: PlaybackItem(
                title: "Known Duration",
                artist: "Velacanto",
                source: .jellyfin,
                duration: 120
            ),
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/known-duration.caf")
            )
        )

        coordinator.play(request)

        XCTAssertEqual(coordinator.duration, 120)
        engine.send(.timeChanged(elapsed: 10, duration: 90))
        XCTAssertEqual(coordinator.duration, 90)
    }

    func testPlaybackLifecycleReportsRemainSerializedAndSuppressDuplicates()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "session",
            recorder: recorder,
            startDelay: .milliseconds(50)
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )

        coordinator.play(
            try makeJellyfinPlaybackRequest(reporter: reporter)
        )
        engine.send(.stateChanged(.playing))
        engine.send(.stateChanged(.playing))
        engine.send(.timeChanged(elapsed: 10, duration: 60))
        engine.send(.timeChanged(elapsed: 15, duration: 60))
        coordinator.pausePlayback()
        coordinator.stop()
        coordinator.stop()

        await waitUntilAsync {
            await recorder.snapshot().count == 4
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(
            events,
            [
                .started(session: "session", position: 0),
                .progress(session: "session", position: 10, isPaused: false),
                .progress(session: "session", position: 15, isPaused: true),
                .stopped(session: "session", position: 15),
            ]
        )
    }

    func testPlaybackLifecyclePipelineContinuesAfterReporterFailure() async throws {
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "session",
            recorder: recorder,
            failingEvent: .started
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )

        coordinator.play(
            try makeJellyfinPlaybackRequest(reporter: reporter)
        )
        engine.send(.stateChanged(.playing))
        engine.send(.timeChanged(elapsed: 10, duration: 60))
        coordinator.stop()

        await waitUntilAsync {
            await recorder.snapshot().count == 2
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(
            events,
            [
                .progress(session: "session", position: 10, isPaused: false),
                .stopped(session: "session", position: 10),
            ]
        )
    }

    func testFailedJellyfinStreamUsesFreshReporterAndRetriesOnlyOnce()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let firstReporter = RecordingPlaybackLifecycleReporter(
            id: "first-session",
            recorder: recorder
        )
        let retryReporter = RecordingPlaybackLifecycleReporter(
            id: "retry-session",
            recorder: recorder
        )
        let retryRequest = try makeJellyfinPlaybackRequest(
            reporter: retryReporter
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            XCTAssertEqual(item.id, "jellyfin-track")
            resolverCallCount += 1
            return retryRequest
        }

        coordinator.play(
            try makeJellyfinPlaybackRequest(reporter: firstReporter)
        )
        engine.send(.stateChanged(.playing))
        engine.send(.timeChanged(elapsed: 12, duration: 60))
        engine.send(.stateChanged(.failed("Connection lost")))

        await waitUntil {
            engine.loadCallCount == 2
        }
        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertEqual(engine.seekTimes.last, 12)

        engine.send(.stateChanged(.playing))
        engine.send(.timeChanged(elapsed: 20, duration: 60))
        engine.send(.stateChanged(.failed("Connection lost again")))
        coordinator.stop()

        await waitUntilAsync {
            await recorder.snapshot().count == 6
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertEqual(
            events,
            [
                .started(session: "first-session", position: 0),
                .progress(
                    session: "first-session",
                    position: 12,
                    isPaused: false
                ),
                .stopped(session: "first-session", position: 12),
                .started(session: "retry-session", position: 12),
                .progress(
                    session: "retry-session",
                    position: 20,
                    isPaused: false
                ),
                .stopped(session: "retry-session", position: 20),
            ]
        )
    }

    func testExplicitResumeAfterFailedJellyfinRetryNegotiatesAnotherStream()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let retryRequest = try makeJellyfinPlaybackRequest()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            return retryRequest
        }

        coordinator.play(try makeJellyfinPlaybackRequest())
        engine.send(.stateChanged(.playing))
        engine.send(.timeChanged(elapsed: 12, duration: 60))
        engine.send(.stateChanged(.failed("Connection lost")))

        await waitUntil {
            engine.loadCallCount == 2
        }
        engine.send(.stateChanged(.failed("Still unavailable")))
        XCTAssertEqual(
            coordinator.playbackState,
            .failed(
                "The Jellyfin stream stopped unexpectedly. Try playing the track again."
            )
        )

        coordinator.resumePlayback()

        await waitUntil {
            engine.loadCallCount == 3
        }
        XCTAssertEqual(resolverCallCount, 2)
        XCTAssertEqual(engine.seekTimes.last, 12)
        XCTAssertEqual(coordinator.playbackState, .loading)
    }

    func testPlaybackStartsOnlyAfterAudioSessionActivation() async throws {
        let engine = RecordingAudioPlayerEngine()
        let audioSession = ControlledAudioSessionController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            audioSessionController: audioSession
        )

        coordinator.play(try await makePlaybackRequest())

        await waitUntilAsync {
            await audioSession.activationCount() == 1
        }
        XCTAssertEqual(engine.playCallCount, 0)

        await audioSession.completeNextActivation()
        await waitUntil {
            engine.playCallCount == 1
        }
    }

    func testCanceledOrReplacedActivationCannotStartPlayback() async throws {
        let engine = RecordingAudioPlayerEngine()
        let audioSession = ControlledAudioSessionController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            audioSessionController: audioSession
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntilAsync {
            await audioSession.activationCount() == 1
        }

        coordinator.pausePlayback()
        await audioSession.completeNextActivation()
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(engine.playCallCount, 0)

        coordinator.play(try await makePlaybackRequest())
        await waitUntilAsync {
            await audioSession.activationCount() == 2
        }
        await audioSession.completeNextActivation()
        await waitUntil {
            engine.playCallCount == 1
        }
    }

    func testStoppingPlaybackDeactivatesAndNotifiesOtherAudio() async throws {
        let engine = RecordingAudioPlayerEngine()
        let audioSession = ControlledAudioSessionController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            audioSessionController: audioSession
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntilAsync {
            await audioSession.activationCount() == 1
        }
        await audioSession.completeNextActivation()
        await waitUntil {
            engine.playCallCount == 1
        }

        coordinator.stop()
        await waitUntilAsync {
            let requests = await audioSession.deactivationRequests()
            return requests.count == 1
        }
        let requests = await audioSession.deactivationRequests()
        XCTAssertEqual(requests, [true])
    }

    func testAudioInterruptionResumesOnlyWhenSystemPermitsIt() async throws {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let stateStore = RecordingNowPlayingStateStore()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            nowPlayingStateStore: stateStore,
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertNotNil(stateStore.state)

        platformEvents.sendInterruption(.ended(shouldResume: false))
        XCTAssertEqual(engine.playCallCount, 1)

        coordinator.resumePlayback()
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))
        platformEvents.sendInterruption(.ended(shouldResume: true))

        XCTAssertEqual(engine.pauseCallCount, 2)
        XCTAssertEqual(engine.playCallCount, 3)
    }

    func testUserPauseDuringInterruptionPreventsAutomaticResume() async throws {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))
        coordinator.pausePlayback()
        platformEvents.sendInterruption(.ended(shouldResume: true))

        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.pauseCallCount, 2)
        XCTAssertEqual(coordinator.playbackState, .paused)
    }

    func testExplicitResumeRecoversFromAnInterruptionWithoutAnEndEvent()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))

        coordinator.resumePlayback()

        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testRemovedOutputRoutePausesAndSynchronizesNowPlaying() async throws {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: systemMediaController,
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))
        platformEvents.sendRouteChange(.other)
        XCTAssertEqual(engine.pauseCallCount, 0)

        platformEvents.sendRouteChange(.oldDeviceUnavailable)
        engine.send(.stateChanged(.paused))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, false)
    }

    func testRouteRemovalKeepsLatePlayerEventsPausedUntilUserResumes()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))

        platformEvents.sendRouteChange(.oldDeviceUnavailable)
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertFalse(coordinator.showsPauseControl)

        // AVPlayer can emit a late waiting/playing observation while the route
        // changes. It must not turn a route-policy pause back into playback.
        engine.send(.stateChanged(.waiting))
        engine.send(.stateChanged(.playing))
        XCTAssertEqual(coordinator.playbackState, .paused)

        coordinator.togglePlayback()
        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertEqual(engine.pauseCallCount, 2)
        XCTAssertEqual(engine.playCallCount, 2)

        engine.send(.stateChanged(.playing))
        XCTAssertEqual(coordinator.playbackState, .playing)
    }

    func testRouteRecoveryAllowsAnExplicitResumeDuringLingeringInterruption()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            platformEventObserver: platformEvents
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.playing))
        platformEvents.sendRouteChange(.oldDeviceUnavailable)
        platformEvents.sendInterruption(.began)

        coordinator.togglePlayback()

        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertEqual(engine.playCallCount, 2)
        XCTAssertEqual(engine.pauseCallCount, 3)
    }

    func testToggleResumesInsteadOfPausingWhenThePlayerIsWaiting()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.waiting))

        coordinator.togglePlayback()

        XCTAssertEqual(engine.pauseCallCount, 0)
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testFailedStreamResolutionIsSafeAndReplayable() async throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        var resolverCallCount = 0
        var resolverFinished = false
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            defer { resolverFinished = true }
            throw JellyfinAPIError.unreachable
        }

        coordinator.play(try makeJellyfinPlaybackRequest())
        engine.send(.stateChanged(.playing))
        engine.send(
            .stateChanged(
                .failed(
                    "Failed https://example.com/audio?api_key=secret-token"
                )
            )
        )

        await waitUntil {
            resolverFinished
        }
        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertEqual(
            coordinator.playbackState,
            .failed(
                "The Jellyfin stream stopped unexpectedly. Try playing the track again."
            )
        )
        XCTAssertFalse(coordinator.errorMessage?.contains("secret-token") == true)
        XCTAssertFalse(coordinator.errorMessage?.contains("https://") == true)

        coordinator.play(try makeJellyfinPlaybackRequest())
        engine.send(.stateChanged(.playing))

        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertNil(coordinator.errorMessage)
    }

    func testPlaybackCoordinatorRetainsResourceLeaseUntilStop() throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        var lease: RecordingResourceLease? = RecordingResourceLease()
        weak let retainedLease = lease
        var request: PlaybackRequest? = PlaybackRequest(
            item: PlaybackItem(
                title: "Lease Test",
                artist: "Velacanto",
                source: .localFiles
            ),
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/lease-test.caf"),
                resourceLease: lease
            )
        )

        try play(request, on: coordinator)
        request = nil
        lease = nil
        XCTAssertNotNil(retainedLease)

        coordinator.stop()
        XCTAssertNil(retainedLease)
    }

    func testPlaybackCoordinatorRecordsSourceNeutralRecentItems() async throws {
        let engine = RecordingAudioPlayerEngine()
        let history = RecordingPlaybackHistoryStore()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            historyStore: history
        )
        let request = try await makePlaybackRequest()

        coordinator.play(request)

        XCTAssertEqual(coordinator.recentItems.first, request.item)
        XCTAssertEqual(history.savedItems.first, request.item)
    }

    func testPlaybackCoordinatorDoesNotRecordDiagnostics() async throws {
        let engine = RecordingAudioPlayerEngine()
        let history = RecordingPlaybackHistoryStore()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            historyStore: history
        )
        let request = try await makePlaybackRequest()

        coordinator.play(
            PlaybackRequest(
                item: request.item,
                asset: request.asset,
                recordsHistory: false
            )
        )

        XCTAssertTrue(coordinator.recentItems.isEmpty)
        XCTAssertTrue(history.savedItems.isEmpty)
    }

    func testNowPlayingMetadataContainsSemanticMediaFields() {
        let item = PlaybackItem(
            title: "Night Drive",
            artist: "Velacanto",
            albumTitle: "Open Roads",
            source: .localFiles
        )
        let snapshot = NowPlayingSnapshot(
            item: item,
            elapsed: 12,
            duration: 120,
            isPlaying: true
        )

        let info = MediaPlayerSystemMediaController.makeNowPlayingInfo(
            snapshot: snapshot,
            item: item
        )

        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Night Drive")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Velacanto")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Open Roads")
        XCTAssertEqual(
            info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval,
            120
        )
        XCTAssertEqual(
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval,
            12
        )
        XCTAssertEqual(
            info[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            1
        )
    }

    func testNowPlayingMetadataContainsResolvedArtwork() {
        let item = PlaybackItem(
            title: "Artwork",
            artist: "Velacanto",
            source: .jellyfin
        )
        #if os(macOS)
            let image = NSImage(size: NSSize(width: 32, height: 32))
        #else
            let image = UIImage()
        #endif
        let snapshot = NowPlayingSnapshot(
            item: item,
            elapsed: 0,
            duration: 60,
            isPlaying: false,
            artworkIdentifier: "artwork-key",
            artwork: image
        )

        let info = MediaPlayerSystemMediaController.makeNowPlayingInfo(
            snapshot: snapshot,
            item: item
        )

        XCTAssertNotNil(info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
    }

    func testNowPlayingArtworkHandlerCanRunOutsideMainActor() async {
        let item = PlaybackItem(
            title: "Artwork",
            artist: "Velacanto",
            source: .jellyfin
        )
        #if os(macOS)
            let image = NSImage(size: NSSize(width: 32, height: 32))
        #else
            let image = UIImage()
        #endif
        let snapshot = NowPlayingSnapshot(
            item: item,
            elapsed: 0,
            duration: 60,
            isPlaying: false,
            artworkIdentifier: "artwork-key",
            artwork: image
        )
        let info = MediaPlayerSystemMediaController.makeNowPlayingInfo(
            snapshot: snapshot,
            item: item
        )
        guard
            let artwork =
                info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        else {
            XCTFail("Expected resolved system artwork.")
            return
        }
        let artworkBox = SendableArtworkBox(artwork)

        let renderedImageExists = await Task.detached {
            artworkBox.artwork.image(at: CGSize(width: 16, height: 16)) != nil
        }.value

        XCTAssertTrue(renderedImageExists)
    }

    func testPlaybackCoordinatorPublishesResolvedSystemArtwork() async {
        let engine = RecordingAudioPlayerEngine()
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: systemMediaController
        )
        let item = PlaybackItem(
            id: "artwork-track",
            title: "Artwork",
            artist: "Velacanto",
            source: .jellyfin,
            artworkItemID: "artwork-album",
            artworkTag: "image-tag"
        )
        #if os(macOS)
            let image = NSImage(size: NSSize(width: 32, height: 32))
        #else
            let image = UIImage()
        #endif
        coordinator.configureArtworkResolver { resolvedItem in
            XCTAssertEqual(resolvedItem, item)
            return ResolvedNowPlayingArtwork(
                identifier: "resolved-artwork",
                image: image
            )
        }

        coordinator.play(
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/artwork-track.caf")
                )
            )
        )
        await waitUntil {
            systemMediaController.latestSnapshot?.artworkIdentifier
                == "resolved-artwork"
        }

        XCTAssertEqual(
            systemMediaController.latestSnapshot?.artworkIdentifier,
            "resolved-artwork"
        )
        XCTAssertTrue(systemMediaController.latestSnapshot?.artwork === image)
    }

    func testDelayedArtworkCannotReplaceCurrentTrackArtwork() async {
        let engine = RecordingAudioPlayerEngine()
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: systemMediaController
        )
        let firstItem = PlaybackItem(
            id: "first-track",
            title: "First",
            artist: "Velacanto",
            source: .jellyfin,
            artworkItemID: "first-album"
        )
        let secondItem = PlaybackItem(
            id: "second-track",
            title: "Second",
            artist: "Velacanto",
            source: .jellyfin,
            artworkItemID: "second-album"
        )
        #if os(macOS)
            let firstImage = NSImage(size: NSSize(width: 32, height: 32))
            let secondImage = NSImage(size: NSSize(width: 32, height: 32))
        #else
            let firstImage = UIImage()
            let secondImage = UIImage()
        #endif
        var firstContinuation:
            CheckedContinuation<
                ResolvedNowPlayingArtwork?, Never
            >?
        coordinator.configureArtworkResolver { item in
            if item == firstItem {
                return await withCheckedContinuation { continuation in
                    firstContinuation = continuation
                }
            }
            return ResolvedNowPlayingArtwork(
                identifier: "second-artwork",
                image: secondImage
            )
        }

        coordinator.play(
            PlaybackRequest(
                item: firstItem,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/first-track.caf")
                )
            )
        )
        await waitUntil { firstContinuation != nil }
        coordinator.play(
            PlaybackRequest(
                item: secondItem,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/second-track.caf")
                )
            )
        )
        await waitUntil {
            systemMediaController.latestSnapshot?.artworkIdentifier
                == "second-artwork"
        }

        firstContinuation?.resume(
            returning: ResolvedNowPlayingArtwork(
                identifier: "first-artwork",
                image: firstImage
            )
        )
        await Task.yield()

        XCTAssertEqual(
            systemMediaController.latestSnapshot?.artworkIdentifier,
            "second-artwork"
        )
        XCTAssertTrue(
            systemMediaController.latestSnapshot?.artwork === secondImage
        )
    }

    func testPlaybackQueuePreservesOrderAndBoundsSavedWindow() {
        let items = (0..<100).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        var queue = PlaybackQueue(
            items: items,
            currentItemID: "track-40",
            context: .album(id: "album")
        )

        XCTAssertEqual(queue.previousItem?.id, "track-39")
        XCTAssertEqual(queue.nextItem?.id, "track-41")
        queue.moveNext()
        XCTAssertEqual(queue.currentItem?.id, "track-41")

        let saved = queue.persistenceWindow()
        XCTAssertEqual(saved.currentItem?.id, "track-41")
        XCTAssertLessThanOrEqual(saved.currentIndex, 25)
        XCTAssertLessThanOrEqual(saved.items.count, 76)
    }

    func testPlaybackQueueEditsOnlyUpcomingItemsWithoutDuplicates() {
        let items = (0..<4).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let inserted = PlaybackItem(
            id: "inserted",
            title: "Inserted",
            artist: "Velacanto",
            source: .jellyfin
        )
        var queue = PlaybackQueue(
            items: items,
            currentItemID: "track-1",
            context: .songs
        )

        XCTAssertFalse(queue.removeUpcomingItem(items[0]))
        XCTAssertFalse(queue.removeUpcomingItem(items[1]))
        XCTAssertTrue(queue.playNext(inserted))
        XCTAssertTrue(queue.playLast(items[2]))
        XCTAssertEqual(
            queue.upcomingItems.map(\.id),
            ["inserted", "track-3", "track-2"]
        )

        XCTAssertTrue(queue.moveUpcomingItem(from: 2, to: 0))
        XCTAssertTrue(queue.removeUpcomingItem(inserted))
        XCTAssertTrue(queue.shuffleUpcoming(randomIndex: { $0.lowerBound }))

        XCTAssertEqual(queue.items.prefix(2).map(\.id), ["track-0", "track-1"])
        XCTAssertEqual(Set(queue.items.map(\.id)).count, queue.items.count)
        XCTAssertEqual(Set(queue.upcomingItems.map(\.id)), ["track-2", "track-3"])
    }

    func testQueueEditsAndPlaybackModesRestoreSafely() {
        let stateStore = RecordingNowPlayingStateStore()
        let systemMediaController = RecordingSystemMediaController()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let items = (0..<3).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let inserted = PlaybackItem(
            id: "inserted",
            title: "Inserted",
            artist: "Velacanto",
            source: .jellyfin
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
            systemMediaController: systemMediaController,
            nowPlayingStateStore: stateStore
        )
        coordinator.play(
            PlaybackRequest(
                item: items[0],
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/track-0.caf")
                )
            ),
            queueItems: items,
            context: .songs,
            account: account
        )

        coordinator.playNext(inserted)
        systemMediaController.changeRepeatMode?(.all)
        systemMediaController.shuffle?()

        XCTAssertEqual(coordinator.repeatMode, .all)
        XCTAssertEqual(
            Set(coordinator.upcomingItems.map(\.id)),
            [
                "inserted", "track-1", "track-2",
            ]
        )
        XCTAssertEqual(stateStore.state?.queue.repeatMode, .all)

        let restored = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
            systemMediaController: RecordingSystemMediaController(),
            nowPlayingStateStore: stateStore
        )
        restored.restoreSavedState(serverID: "server", userID: "user")

        XCTAssertEqual(restored.repeatMode, .all)
        XCTAssertEqual(restored.queue, stateStore.state?.queue)
        XCTAssertEqual(restored.playbackState, .paused)
    }

    func testRepeatModesHandleQueueBoundaries() async {
        let engine = RecordingAudioPlayerEngine()
        let first = PlaybackItem(
            id: "first",
            title: "First",
            artist: "Velacanto",
            source: .jellyfin
        )
        let last = PlaybackItem(
            id: "last",
            title: "Last",
            artist: "Velacanto",
            source: .jellyfin
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                )
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: last,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/last.caf")
                )
            ),
            queueItems: [first, last],
            context: .songs
        )
        coordinator.setRepeatMode(.all)

        coordinator.nextTrack()
        await waitUntil { coordinator.currentItem == first }
        XCTAssertEqual(coordinator.currentItem, first)

        coordinator.setRepeatMode(.one)
        let playCount = engine.playCallCount
        engine.send(.stateChanged(.ended))

        XCTAssertEqual(coordinator.currentItem, first)
        XCTAssertEqual(engine.seekTimes.last, 0)
        XCTAssertEqual(engine.playCallCount, playCount + 1)
    }

    func testPlaybackWaitsForLatePagingAtQueueBoundary() async {
        let engine = RecordingAudioPlayerEngine()
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let pagedItem = PlaybackItem(
            id: "paged",
            title: "Paged",
            artist: "Velacanto",
            source: .jellyfin
        )
        var expansionContinuation: CheckedContinuation<[PlaybackItem], Never>?
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                )
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                )
            ),
            queueItems: [current],
            context: .songs,
            queueExpansion: {
                await withCheckedContinuation { continuation in
                    expansionContinuation = continuation
                }
            }
        )
        await waitUntil { expansionContinuation != nil }

        engine.send(.stateChanged(.ended))
        expansionContinuation?.resume(returning: [pagedItem])
        await waitUntil { coordinator.currentItem == pagedItem }

        XCTAssertEqual(coordinator.currentItem, pagedItem)
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testExplicitQueueEditInvalidatesPreloadAndLatePaging() async {
        let engine = RecordingAudioPlayerEngine()
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let originalNext = PlaybackItem(
            id: "original-next",
            title: "Original Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let explicitNext = PlaybackItem(
            id: "explicit-next",
            title: "Explicit Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let latePage = PlaybackItem(
            id: "late-page",
            title: "Late Page",
            artist: "Velacanto",
            source: .jellyfin
        )
        var expansionContinuation: CheckedContinuation<[PlaybackItem], Never>?
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                )
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                )
            ),
            queueItems: [current],
            context: .songs,
            queueExpansion: {
                await withCheckedContinuation { continuation in
                    expansionContinuation = continuation
                }
            }
        )
        await waitUntil { expansionContinuation != nil }

        coordinator.playNext(originalNext)
        await waitUntil {
            engine.preloadedURLs.last
                == URL(
                    fileURLWithPath: "/tmp/original-next.caf"
                )
        }

        coordinator.playNext(explicitNext)
        await waitUntil {
            engine.preloadedURLs.last
                == URL(
                    fileURLWithPath: "/tmp/explicit-next.caf"
                )
        }
        coordinator.removeUpcomingItem(originalNext)
        expansionContinuation?.resume(returning: [latePage])
        await Task.yield()

        XCTAssertEqual(coordinator.upcomingItems, [explicitNext])
        XCTAssertTrue(engine.preloadReceivedNil)
    }

    func testSavedNowPlayingRestoresPausedWithoutLoadingStream() {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "track",
            title: "Restore",
            artist: "Velacanto",
            source: .jellyfin
        )
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [item],
                currentItemID: item.id,
                context: .single
            ),
            elapsed: 42,
            duration: 180,
            account: account,
            savedAt: Date()
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            nowPlayingStateStore: stateStore
        )

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )

        XCTAssertEqual(coordinator.currentItem, item)
        XCTAssertEqual(coordinator.elapsed, 42)
        XCTAssertEqual(coordinator.duration, 180)
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertFalse(engine.hasCurrentItem)
    }

    func testSavedNowPlayingDecodesLegacyStateWithoutDuration() throws {
        struct LegacyState: Codable {
            let queue: PlaybackQueue
            let elapsed: TimeInterval
            let account: PlaybackAccount?
            let savedAt: Date
        }

        let item = PlaybackItem(
            id: "track",
            title: "Restore",
            artist: "Velacanto",
            source: .jellyfin
        )
        let legacyState = LegacyState(
            queue: PlaybackQueue(
                items: [item],
                currentItemID: item.id,
                context: .single
            ),
            elapsed: 42,
            account: PlaybackAccount(serverID: "server", userID: "user"),
            savedAt: Date()
        )

        let data = try JSONEncoder().encode(legacyState)
        let decoded = try JSONDecoder().decode(
            SavedNowPlayingState.self,
            from: data
        )

        XCTAssertEqual(decoded.elapsed, 42)
        XCTAssertNil(decoded.duration)
    }

    func testCorruptNowPlayingStateIsDiscarded() throws {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not JSON".utf8), forKey: "velacanto.now-playing-state-v1")

        let store = UserDefaultsNowPlayingStateStore(defaults: defaults)

        XCTAssertNil(store.loadState())
        XCTAssertNil(defaults.data(forKey: "velacanto.now-playing-state-v1"))
    }

    func testCorruptPlaybackHistoryIsDiscarded() throws {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not JSON".utf8), forKey: "velacanto.playback-history")

        let store = UserDefaultsPlaybackHistoryStore(defaults: defaults)

        XCTAssertTrue(store.loadItems().isEmpty)
        XCTAssertNil(defaults.data(forKey: "velacanto.playback-history"))
    }

    func testNowPlayingWriteFailureDoesNotInterruptPlayback() async throws {
        let recorder = PersistenceWriteAttemptRecorder()
        let store = UserDefaultsNowPlayingStateStore(
            writeData: recorder.failWrite
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            nowPlayingStateStore: store
        )

        coordinator.play(try await makePlaybackRequest())

        XCTAssertTrue(recorder.didAttemptWrite)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertNotNil(coordinator.currentItem)
    }

    func testPlaybackHistoryWriteFailureDoesNotInterruptPlayback() async throws {
        let recorder = PersistenceWriteAttemptRecorder()
        let store = UserDefaultsPlaybackHistoryStore(
            writeData: recorder.failWrite
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController(),
            historyStore: store
        )
        let request = try await makePlaybackRequest()

        coordinator.play(request)

        XCTAssertTrue(recorder.didAttemptWrite)
        XCTAssertEqual(coordinator.recentItems.first, request.item)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testBufferStateIsPublishedByCoordinator() {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            systemMediaController: RecordingSystemMediaController()
        )
        let state = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        engine.send(.bufferStateChanged(state))

        XCTAssertEqual(coordinator.bufferState, state)
    }

    func testArtworkRepositoryCoalescesAndCachesRequests() async throws {
        MockArtworkURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockArtworkURLProtocol.self]
        let repository = ArtworkRepository(
            session: URLSession(configuration: configuration)
        )
        let key = ArtworkKey(
            serverID: UUID().uuidString,
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 512
        )
        let url = try XCTUnwrap(URL(string: "https://artwork.test/image"))
        let first = Task { @MainActor in
            await repository.image(for: key) {
                URLRequest(url: url)
            }
        }
        let second = Task { @MainActor in
            await repository.image(for: key) {
                URLRequest(url: url)
            }
        }

        let firstImage = await first.value
        let secondImage = await second.value
        let cachedImage = await repository.image(for: key) {
            URLRequest(url: url)
        }
        XCTAssertNotNil(firstImage)
        XCTAssertNotNil(secondImage)
        XCTAssertNotNil(cachedImage)
        XCTAssertEqual(MockArtworkURLProtocol.requestCount, 1)
    }

    func testArtworkDiskCacheDiscardsCorruptIndex() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoArtworkCacheTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let indexURL = directory.appending(path: "index.json")
        try Data("not JSON".utf8).write(to: indexURL)

        let cache = ArtworkDiskCache(directory: directory)
        let key = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )

        let cachedData = await cache.data(for: key)
        XCTAssertNil(cachedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testArtworkDiskCacheTreatsBlockedWriteDirectoryAsACacheMiss()
        async throws
    {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoArtworkCacheFile-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL)
        let cache = ArtworkDiskCache(directory: fileURL)
        let key = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )

        await cache.store(Data([1, 2, 3]), for: key)

        let cachedData = await cache.data(for: key)
        XCTAssertNil(cachedData)
    }

    private func makePlaybackRequest() async throws -> PlaybackRequest {
        let url = try await DemoToneFactory.makeURL()
        return try await LocalFilePlaybackAdapter().playbackRequest(
            for: LocalFileSelection(
                url: url,
                title: "Control Center Test",
                artist: "Velacanto"
            )
        )
    }

    private func makeJellyfinPlaybackRequest(
        reporter: (any PlaybackLifecycleReporting)? = nil
    ) throws -> PlaybackRequest {
        PlaybackRequest(
            item: PlaybackItem(
                id: "jellyfin-track",
                title: "Network Track",
                artist: "Velacanto",
                source: .jellyfin
            ),
            asset: PlaybackAsset(
                url: try XCTUnwrap(
                    URL(string: "https://example.com/audio.mp3")
                )
            ),
            reporter: reporter
        )
    }

    private func play(
        _ request: PlaybackRequest?,
        on coordinator: AudioPlaybackCoordinator
    ) throws {
        coordinator.play(try XCTUnwrap(request))
    }
}

@MainActor
private func waitUntil(
    attempts: Int = 100,
    condition: () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() {
            return
        }
        await Task.yield()
    }
}

@MainActor
private func waitUntilAsync(
    attempts: Int = 1_000,
    condition: () async -> Bool
) async {
    for _ in 0..<attempts {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func assertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}

@MainActor
private final class RecordingAudioPlayerEngine: AudioPlayerEngine {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)?
    private(set) var hasCurrentItem = false
    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var seekTimes: [TimeInterval] = []
    private(set) var preloadedURLs: [URL] = []
    private(set) var preloadReceivedNil = false

    func load(_ item: AVPlayerItem) {
        hasCurrentItem = true
        loadCallCount += 1
    }

    func preload(_ item: AVPlayerItem?) {
        guard let item else {
            preloadReceivedNil = true
            return
        }
        if let asset = item.asset as? AVURLAsset {
            preloadedURLs.append(asset.url)
        }
    }

    func advanceToNextItem() {
        eventHandler?(.advancedToNextItem)
    }

    func play() {
        guard hasCurrentItem else { return }
        playCallCount += 1
    }

    func pause() {
        guard hasCurrentItem else { return }
        pauseCallCount += 1
    }

    func seek(to time: TimeInterval) {
        guard hasCurrentItem else { return }
        seekTimes.append(time)
    }

    func stop() {
        hasCurrentItem = false
        stopCallCount += 1
    }

    func send(_ event: AudioPlayerEngineEvent) {
        eventHandler?(event)
    }
}

private enum PlaybackLifecycleEvent: Equatable, Sendable {
    case started(session: String, position: TimeInterval)
    case progress(
        session: String,
        position: TimeInterval,
        isPaused: Bool
    )
    case stopped(session: String, position: TimeInterval)
}

private enum PlaybackLifecycleEventKind: Equatable, Sendable {
    case started
    case progress
    case stopped
}

private enum RecordingPlaybackLifecycleError: Error {
    case intentionalFailure
}

private actor PlaybackLifecycleEventRecorder {
    private var events: [PlaybackLifecycleEvent] = []

    func record(_ event: PlaybackLifecycleEvent) {
        events.append(event)
    }

    func snapshot() -> [PlaybackLifecycleEvent] {
        events
    }
}

private struct RecordingPlaybackLifecycleReporter: PlaybackLifecycleReporting {
    let id: String
    let recorder: PlaybackLifecycleEventRecorder
    var startDelay: Duration?
    var failingEvent: PlaybackLifecycleEventKind?

    init(
        id: String,
        recorder: PlaybackLifecycleEventRecorder,
        startDelay: Duration? = nil,
        failingEvent: PlaybackLifecycleEventKind? = nil
    ) {
        self.id = id
        self.recorder = recorder
        self.startDelay = startDelay
        self.failingEvent = failingEvent
    }

    func reportStarted(at position: TimeInterval) async throws {
        if let startDelay {
            try await Task.sleep(for: startDelay)
        }
        if failingEvent == .started {
            throw RecordingPlaybackLifecycleError.intentionalFailure
        }
        await recorder.record(.started(session: id, position: position))
    }

    func reportProgress(
        at position: TimeInterval,
        isPaused: Bool
    ) async throws {
        if failingEvent == .progress {
            throw RecordingPlaybackLifecycleError.intentionalFailure
        }
        await recorder.record(
            .progress(
                session: id,
                position: position,
                isPaused: isPaused
            )
        )
    }

    func reportStopped(at position: TimeInterval) async throws {
        if failingEvent == .stopped {
            throw RecordingPlaybackLifecycleError.intentionalFailure
        }
        await recorder.record(.stopped(session: id, position: position))
    }
}

@MainActor
private final class RecordingSystemMediaController: SystemMediaControlling {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var play: (@MainActor () -> Void)?
    private(set) var pause: (@MainActor () -> Void)?
    private(set) var previous: (@MainActor () -> Void)?
    private(set) var next: (@MainActor () -> Void)?
    private(set) var togglePlayPause: (@MainActor () -> Void)?
    private(set) var seek: (@MainActor (TimeInterval) -> Void)?
    private(set) var changeRepeatMode: (@MainActor (PlaybackRepeatMode) -> Void)?
    private(set) var shuffle: (@MainActor () -> Void)?

    var latestSnapshot: NowPlayingSnapshot? {
        snapshots.last
    }

    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (TimeInterval) -> Void,
        changeRepeatMode: @escaping @MainActor (PlaybackRepeatMode) -> Void,
        shuffle: @escaping @MainActor () -> Void
    ) {
        self.play = play
        self.pause = pause
        self.previous = previous
        self.next = next
        self.togglePlayPause = togglePlayPause
        self.seek = seek
        self.changeRepeatMode = changeRepeatMode
        self.shuffle = shuffle
    }

    func update(_ snapshot: NowPlayingSnapshot) {
        snapshots.append(snapshot)
    }
}

@MainActor
private final class RecordingPlaybackPlatformEventObserver:
    PlaybackPlatformEventObserving
{
    private var interruptionHandler: (@MainActor (PlaybackAudioInterruption) -> Void)?
    private var routeChangeHandler: (@MainActor (PlaybackAudioRouteChange) -> Void)?
    private var backgroundHandler: (@MainActor () -> Void)?

    func start(
        interruption: @escaping @MainActor (PlaybackAudioInterruption) -> Void,
        routeChange: @escaping @MainActor (PlaybackAudioRouteChange) -> Void,
        didEnterBackground: @escaping @MainActor () -> Void
    ) {
        interruptionHandler = interruption
        routeChangeHandler = routeChange
        backgroundHandler = didEnterBackground
    }

    func sendInterruption(_ event: PlaybackAudioInterruption) {
        interruptionHandler?(event)
    }

    func sendRouteChange(_ event: PlaybackAudioRouteChange) {
        routeChangeHandler?(event)
    }
}

private actor ControlledAudioSessionController: PlaybackAudioSessionControlling {
    private var activationContinuations: [CheckedContinuation<Void, Error>] = []
    private var recordedActivationCount = 0
    private var recordedDeactivationRequests: [Bool] = []

    func activate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            recordedActivationCount += 1
            activationContinuations.append(continuation)
        }
    }

    func deactivate(notifyingOthers: Bool) async {
        recordedDeactivationRequests.append(notifyingOthers)
    }

    func activationCount() -> Int {
        recordedActivationCount
    }

    func completeNextActivation() {
        guard !activationContinuations.isEmpty else { return }
        activationContinuations.removeFirst().resume()
    }

    func deactivationRequests() -> [Bool] {
        recordedDeactivationRequests
    }
}

private final class RecordingResourceLease: PlaybackResourceLease, @unchecked Sendable {}

private enum PersistenceWriteFailure: Error {
    case unavailable
}

private final class PersistenceWriteAttemptRecorder {
    private(set) var didAttemptWrite = false

    func failWrite(_: UserDefaults, _: Data, _: String) throws {
        didAttemptWrite = true
        throw PersistenceWriteFailure.unavailable
    }
}

private final class RecordingPlaybackHistoryStore: PlaybackHistoryStoring {
    private(set) var savedItems: [PlaybackItem] = []

    func loadItems() -> [PlaybackItem] {
        []
    }

    func saveItems(_ items: [PlaybackItem]) {
        savedItems = items
    }
}

private final class RecordingNowPlayingStateStore: NowPlayingStateStoring {
    var state: SavedNowPlayingState?

    func loadState() -> SavedNowPlayingState? {
        state
    }

    func saveState(_ state: SavedNowPlayingState) {
        self.state = state
    }

    func clearState() {
        state = nil
    }
}

private final class MockArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        let data =
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
            ) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
