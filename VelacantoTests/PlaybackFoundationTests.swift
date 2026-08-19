import AVFoundation
import Foundation
import XCTest

@testable import Velacanto

#if canImport(NowPlaying)
    import NowPlaying
#endif

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

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
        XCTAssertEqual(request.transportKind, .localFile)
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

    func testPlaybackCoordinatorFollowsEngineEvents() async throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let request = try await makePlaybackRequest()

        coordinator.play(request)

        await waitUntil { engine.playCallCount == 1 }

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(engine.playCallCount, 1)

        engine.send(.stateChanged(.waiting))
        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertFalse(coordinator.showsPauseControl)

        engine.send(.stateChanged(.playing))
        XCTAssertTrue(coordinator.isPlaying)

        coordinator.pausePlayback()
        XCTAssertEqual(engine.pauseCallCount, 1)
        engine.send(.stateChanged(.paused))
        XCTAssertFalse(coordinator.isPlaying)

        coordinator.resumePlayback()
        await waitUntil { engine.playCallCount == 2 }
        XCTAssertEqual(engine.playCallCount, 2)
        engine.send(.stateChanged(.playing))

        coordinator.seek(toTime: 2.5)
        XCTAssertEqual(engine.seekTimes.last, 2.5)
        XCTAssertEqual(coordinator.elapsed, 2.5, accuracy: 0.001)

        engine.send(.timeChanged(elapsed: 60, duration: 60))
        engine.send(.stateChanged(.ended))
        XCTAssertEqual(coordinator.playbackState, .ended)
        XCTAssertFalse(coordinator.isPlaying)

        coordinator.stop()
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertNil(coordinator.currentItem)
    }

    func testPlaybackCoordinatorPublishesEngineFailure() async throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine
        )

        coordinator.play(try await makePlaybackRequest())
        engine.send(.stateChanged(.failed("Stream unavailable")))

        XCTAssertEqual(coordinator.playbackState, .failed("Stream unavailable"))
        XCTAssertEqual(coordinator.errorMessage, "Stream unavailable")
        XCTAssertFalse(coordinator.isPlaying)

        engine.send(.stateChanged(.paused))
        XCTAssertEqual(coordinator.playbackState, .failed("Stream unavailable"))
    }

    func testPlaybackUsesItemDurationUntilTheEnginePublishesOne()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
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
            ),
            transportKind: .directPlay
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
            nowPlayingStateStore: stateStore,
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertNotNil(stateStore.state)

        platformEvents.sendInterruption(.ended(shouldResume: false))
        XCTAssertEqual(engine.playCallCount, 1)

        coordinator.resumePlayback()
        await waitUntil { engine.playCallCount == 2 }
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))
        platformEvents.sendInterruption(.ended(shouldResume: true))
        await waitUntil { engine.playCallCount == 3 }

        XCTAssertEqual(engine.pauseCallCount, 2)
        XCTAssertEqual(engine.playCallCount, 3)
    }

    func testUserPauseDuringInterruptionPreventsAutomaticResume() async throws {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
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
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.playing))
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))

        coordinator.resumePlayback()

        await waitUntil { engine.playCallCount == 2 }

        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testRemovedOutputRoutePausesAndSynchronizesNowPlaying() async throws {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.playing))
        platformEvents.sendRouteChange(.other)
        XCTAssertEqual(engine.pauseCallCount, 0)

        platformEvents.sendRouteChange(.oldDeviceUnavailable)
        engine.send(.stateChanged(.paused))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertEqual(coordinator.playbackState, .paused)
    }

    func testRouteRemovalKeepsLatePlayerEventsPausedUntilUserResumes()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
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
        await waitUntil { engine.playCallCount == 2 }
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
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.playing))
        platformEvents.sendRouteChange(.oldDeviceUnavailable)
        platformEvents.sendInterruption(.began)

        coordinator.togglePlayback()

        await waitUntil { engine.playCallCount == 2 }

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
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(try await makePlaybackRequest())
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.waiting))

        coordinator.togglePlayback()

        await waitUntil { engine.playCallCount == 2 }

        XCTAssertEqual(engine.pauseCallCount, 0)
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testFailedStreamResolutionIsSafeAndReplayable() async throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine
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
            engine: engine
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
            ),
            transportKind: .localFile
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
            historyStore: history
        )
        let request = try await makePlaybackRequest()

        coordinator.play(
            PlaybackRequest(
                item: request.item,
                asset: request.asset,
                transportKind: request.transportKind,
                recordsHistory: false
            )
        )

        XCTAssertTrue(coordinator.recentItems.isEmpty)
        XCTAssertTrue(history.savedItems.isEmpty)
    }

    func testSystemMediaIdentifiersAreAppLocalAndRotateForNewContent() {
        let first = PlaybackItem(
            id: "provider-item-id",
            title: "First",
            artist: "Velacanto",
            source: MusicSourceID(rawValue: "provider-server-user")
        )
        let second = PlaybackItem(
            id: "replacement-provider-item-id",
            title: "Second",
            artist: "Velacanto",
            source: MusicSourceID(rawValue: "provider-server-user")
        )
        let artworkIdentifier = "server-id/user-id/artwork-item/image-tag"
        var identifiers = SystemMediaIdentifiers()

        identifiers.update(
            for: first,
            artworkSourceIdentifier: artworkIdentifier
        )
        let firstContentID = identifiers.contentID
        let firstArtworkID = identifiers.artworkID

        XCTAssertNotEqual(firstContentID, first.id)
        XCTAssertNotEqual(firstContentID, first.source.rawValue)
        XCTAssertNotEqual(firstArtworkID, artworkIdentifier)

        identifiers.update(
            for: first,
            artworkSourceIdentifier: artworkIdentifier
        )
        XCTAssertEqual(identifiers.contentID, firstContentID)
        XCTAssertEqual(identifiers.artworkID, firstArtworkID)

        identifiers.update(
            for: second,
            artworkSourceIdentifier: artworkIdentifier
        )
        XCTAssertNotEqual(identifiers.contentID, firstContentID)
        XCTAssertNotEqual(identifiers.artworkID, firstArtworkID)
    }

    #if canImport(NowPlaying)
        func testSystemMediaSessionMirrorsSemanticPlaybackContent()
            async throws
        {
            let engine = RecordingAudioPlayerEngine()
            let coordinator = AudioPlaybackCoordinator(
                engine: engine
            )
            let media = PlaybackSystemMediaSession(playback: coordinator)
            let item = PlaybackItem(
                id: "artwork-track",
                title: "Artwork",
                artist: "Velacanto",
                source: .jellyfin,
                artworkItemID: "artwork-album",
                artworkTag: "image-tag"
            )
            coordinator.play(
                PlaybackRequest(
                    item: item,
                    asset: PlaybackAsset(
                        url: URL(fileURLWithPath: "/tmp/artwork-track.caf")
                    ),
                    transportKind: .localFile
                )
            )
            engine.send(.stateChanged(.playing))
            engine.send(.timeChanged(elapsed: 12, duration: 120))
            await waitUntil { media.content != nil }

            let content = try XCTUnwrap(media.content as? MusicContent)
            XCTAssertNotEqual(content.id, item.id)
            XCTAssertEqual(content.songTitle, "Artwork")
            XCTAssertEqual(content.artistName, "Velacanto")
            guard case .finite(let duration) = content.duration else {
                return XCTFail("Expected finite media duration.")
            }
            XCTAssertEqual(duration, 120)
            XCTAssertNotNil(media.playbackSnapshot)
            XCTAssertFalse(media.commands.isEmpty)
        }
    #endif

    func testStaleResolutionCannotReplaceCurrentTransportKind() async {
        let first = PlaybackItem(
            id: "first",
            title: "First",
            artist: "Velacanto",
            source: .jellyfin
        )
        let queued = PlaybackItem(
            id: "queued",
            title: "Queued",
            artist: "Velacanto",
            source: .jellyfin
        )
        let replacement = PlaybackItem(
            id: "replacement",
            title: "Replacement",
            artist: "Velacanto",
            source: .jellyfin
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
        )
        coordinator.play(
            PlaybackRequest(
                item: first,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/first.caf")
                ),
                transportKind: .directPlay
            ),
            queueItems: [first, queued],
            context: .songs
        )

        var staleContinuation: CheckedContinuation<PlaybackRequest, Never>?
        coordinator.configureRequestResolver { item in
            await withCheckedContinuation { continuation in
                staleContinuation = continuation
            }
        }
        coordinator.nextTrack()
        await waitUntil { staleContinuation != nil }

        coordinator.play(
            PlaybackRequest(
                item: replacement,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/replacement.caf")
                ),
                transportKind: .directStream
            )
        )
        staleContinuation?.resume(
            returning: PlaybackRequest(
                item: queued,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/queued.caf")
                ),
                transportKind: .transcoding
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.currentItem, replacement)
        XCTAssertEqual(coordinator.transportKind, .directStream)
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

    func testNativeReorderKeepsHistoryAndCurrentItemFixed() {
        let items = (0..<5).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        var queue = PlaybackQueue(
            items: items,
            currentItemID: "track-1",
            context: .songs
        )

        XCTAssertTrue(
            queue.reorderUpcomingItems(
                withIDs: [items[4].queueIdentity, items[3].queueIdentity],
                before: items[2].queueIdentity
            )
        )
        XCTAssertEqual(
            queue.items.map(\.id),
            [
                "track-0", "track-1", "track-3", "track-4", "track-2",
            ]
        )
        XCTAssertEqual(queue.currentItem?.id, "track-1")
        XCTAssertFalse(
            queue.reorderUpcomingItems(
                withIDs: [items[0].queueIdentity],
                before: nil
            )
        )
    }

    func testNativeReorderUsesSourceScopedOpaqueIDs() {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let jellyfinDuplicate = PlaybackItem(
            id: "same-provider-id",
            title: "Jellyfin",
            artist: "Velacanto",
            source: .jellyfin
        )
        let localDuplicate = PlaybackItem(
            id: "same-provider-id",
            title: "Local",
            artist: "Velacanto",
            source: .localFiles
        )
        let destination = PlaybackItem(
            id: "destination",
            title: "Destination",
            artist: "Velacanto",
            source: .jellyfin
        )
        var queue = PlaybackQueue(
            items: [current, jellyfinDuplicate, localDuplicate, destination],
            currentItemID: current.id,
            context: .songs
        )

        XCTAssertTrue(
            queue.reorderUpcomingItems(
                withIDs: [localDuplicate.queueIdentity],
                before: jellyfinDuplicate.queueIdentity
            )
        )
        XCTAssertEqual(
            queue.upcomingItems.map(\.queueIdentity),
            [
                localDuplicate.queueIdentity,
                jellyfinDuplicate.queueIdentity,
                destination.queueIdentity,
            ]
        )
    }

    func testSelectingUpcomingItemMovesItToCurrentWithoutChangingHistory()
        async throws
    {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let firstUpcoming = PlaybackItem(
            id: "first-upcoming",
            title: "First Upcoming",
            artist: "Velacanto",
            source: .jellyfin
        )
        let selectedUpcoming = PlaybackItem(
            id: "selected-upcoming",
            title: "Selected Upcoming",
            artist: "Velacanto",
            source: .localFiles
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                ),
                transportKind: .directPlay
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                ),
                transportKind: .directPlay
            ),
            queueItems: [current, firstUpcoming, selectedUpcoming],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }

        coordinator.playQueueItem(selectedUpcoming)

        await waitUntil { coordinator.currentItem == selectedUpcoming }
        await waitUntil { engine.playCallCount == 2 }
        XCTAssertEqual(coordinator.playedQueueItems, [current])
        XCTAssertEqual(coordinator.upcomingItems, [firstUpcoming])
        XCTAssertEqual(engine.playCallCount, 2)
    }

    func testQueueEditsAndPlaybackModesRestoreSafely() {
        let stateStore = RecordingNowPlayingStateStore()
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
            nowPlayingStateStore: stateStore
        )
        coordinator.play(
            PlaybackRequest(
                item: items[0],
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/track-0.caf")
                ),
                transportKind: .directPlay
            ),
            queueItems: items,
            context: .songs,
            account: account
        )

        coordinator.playNext(inserted)
        coordinator.setRepeatMode(.all)
        coordinator.shuffleUpcoming()

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
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                ),
                transportKind: .directPlay
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: last,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/last.caf")
                ),
                transportKind: .directPlay
            ),
            queueItems: [first, last],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }
        coordinator.setRepeatMode(.all)

        coordinator.nextTrack()
        await waitUntil { coordinator.currentItem == first }
        XCTAssertEqual(coordinator.currentItem, first)

        coordinator.setRepeatMode(.one)
        let playCount = engine.playCallCount
        engine.send(.stateChanged(.ended))

        await waitUntil { engine.playCallCount == playCount + 1 }

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
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                ),
                transportKind: .directPlay
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                ),
                transportKind: .directPlay
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
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                ),
                transportKind: .directPlay
            )
        }
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                ),
                transportKind: .directPlay
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

    func testVisibleArtworkPromotesAheadOfSpeculativeWork() async {
        let limiter = ArtworkDownloadLimiter(limit: 1)
        let heldKey = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "held",
            imageTag: "tag",
            sizeBucket: 128
        )
        let speculativeKey = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "speculative",
            imageTag: "tag",
            sizeBucket: 128
        )
        let visibleKey = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "visible",
            imageTag: "tag",
            sizeBucket: 128
        )
        await limiter.acquire(key: heldKey, intent: .visible)

        let (order, continuation) = AsyncStream<String>.makeStream()
        let speculative = Task {
            await limiter.acquire(key: speculativeKey, intent: .speculative)
            continuation.yield("speculative")
        }
        while !(await limiter.hasQueuedRequest(for: speculativeKey)) {
            await Task.yield()
        }
        let visible = Task {
            await limiter.acquire(key: visibleKey, intent: .visible)
            continuation.yield("visible")
        }
        while !(await limiter.hasQueuedRequest(for: visibleKey)) {
            await Task.yield()
        }
        await limiter.release()

        var iterator = order.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, "visible")
        await limiter.release()
        let second = await iterator.next()
        XCTAssertEqual(second, "speculative")
        _ = await (speculative.value, visible.value)
    }

    func testArtworkCancelsOnlyAfterFinalConsumerLeaves() async {
        let repository = ArtworkRepository()
        let probe = ArtworkRequestProbe()
        let key = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )
        let first = Task { @MainActor in
            await repository.image(for: key) {
                await probe.request()
            }
        }
        while (await probe.startedCount) == 0 {
            await Task.yield()
        }
        let second = Task { @MainActor in
            await repository.image(for: key) {
                await probe.request()
            }
        }
        while (await repository.consumerCount(for: key)) != 2 {
            await Task.yield()
        }

        first.cancel()
        while (await repository.consumerCount(for: key)) != 1 {
            await Task.yield()
        }
        let cancellationCountAfterFirst = await probe.cancellationCount
        XCTAssertEqual(cancellationCountAfterFirst, 0)

        second.cancel()
        _ = await (first.value, second.value)
        while (await probe.cancellationCount) == 0 {
            await Task.yield()
        }
        let finalCancellationCount = await probe.cancellationCount
        XCTAssertEqual(finalCancellationCount, 1)
    }

    func testCancelledArtworkLimiterWaiterIsRemovedBeforeRelease() async {
        let limiter = ArtworkDownloadLimiter(limit: 1)
        let heldKey = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "held",
            imageTag: "tag",
            sizeBucket: 128
        )
        let queuedKey = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "queued",
            imageTag: "tag",
            sizeBucket: 128
        )
        await limiter.acquire(key: heldKey, intent: .visible)

        let queued = Task {
            await limiter.acquire(key: queuedKey, intent: .nearViewport)
        }
        while !(await limiter.hasQueuedRequest(for: queuedKey)) {
            await Task.yield()
        }

        queued.cancel()
        _ = await queued.value
        while await limiter.hasQueuedRequest(for: queuedKey) {
            await Task.yield()
        }

        await limiter.release()
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

    func testArtworkDiskCacheDefersAndFlushesIndexPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoArtworkCacheTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ArtworkDiskCache(directory: directory)
        let key = ArtworkKey(
            serverID: "server",
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )

        await cache.store(Data([1, 2, 3]), for: key)

        let hasPendingWrite = await cache.hasPendingIndexPersistence()
        XCTAssertTrue(hasPendingWrite)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "index.json").path
            )
        )

        await cache.flushIndexPersistence()

        let hasFlushedWrite = await cache.hasPendingIndexPersistence()
        XCTAssertFalse(hasFlushedWrite)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appending(path: "index.json").path
            )
        )
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
            transportKind: .directPlay,
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

private struct ImmediateAudioSessionController: PlaybackAudioSessionControlling {
    func activate() async throws {}

    func deactivate(notifyingOthers: Bool) async {}
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

private actor ArtworkRequestProbe {
    private(set) var startedCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func request() async -> URLRequest? {
        startedCount += 1
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.continuation = continuation
                }
                return nil as URLRequest?
            },
            onCancel: {
                Task { await self.recordCancellation() }
            }
        )
    }

    private func recordCancellation() {
        cancellationCount += 1
        continuation?.resume()
        continuation = nil
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
