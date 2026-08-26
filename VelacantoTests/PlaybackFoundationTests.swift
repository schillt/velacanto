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
    override func setUp() {
        super.setUp()
        VelacantoNetworkPolicy.resetSharedForTesting()
    }

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

    func testRemoteCurrentAndSuccessorItemsBoundForwardBufferDuringPlayback()
        throws
    {
        let currentURL = try XCTUnwrap(
            URL(string: "https://example.com/audio/current.flac")
        )
        let successorURL = try XCTUnwrap(
            URL(string: "https://example.com/audio/successor.flac")
        )

        let current = PlaybackAsset(url: currentURL).makePlayerItem()
        let successor = PlaybackAsset(url: successorURL).makePlayerItem()
        let local = PlaybackAsset(
            url: URL(fileURLWithPath: "/tmp/velacanto-local-audio.flac")
        ).makePlayerItem()

        XCTAssertEqual(current.preferredForwardBufferDuration, 15)
        XCTAssertEqual(successor.preferredForwardBufferDuration, 15)
        XCTAssertEqual(local.preferredForwardBufferDuration, 0)
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

    func testFoundationEngineCommitsStagedAdvanceOnlyAfterCandidateIsReady()
        async throws
    {
        let player = AVQueuePlayer()
        let engine = AVFoundationAudioPlayerEngine(player: player)
        let url = try await DemoToneFactory.makeURL()
        let current = AVPlayerItem(url: url)
        let next = AlwaysReadyPlayerItem(asset: AVURLAsset(url: url))
        var didAdvance = false
        engine.eventHandler = { event in
            if event == .advancedToNextItem {
                didAdvance = true
            }
        }

        engine.load(current, identity: testQueueIdentity("current"))
        engine.play()
        engine.preload(next, identity: testQueueIdentity("next"))

        XCTAssertEqual(player.items().count, 2)
        XCTAssertTrue(player.currentItem === current)

        await waitUntil { engine.preparedNextItemState.phase == .ready }
        XCTAssertFalse(didAdvance)
        XCTAssertTrue(player.currentItem === current)
        engine.advanceToNextItem()

        XCTAssertTrue(didAdvance)
        XCTAssertTrue(player.currentItem === next)
        XCTAssertTrue(engine.hasCurrentItem)
    }

    func testFoundationEngineReusesRecentlyPlayedItemForPrevious()
        async throws
    {
        let player = AVQueuePlayer()
        let engine = AVFoundationAudioPlayerEngine(player: player)
        let previousIdentity = testQueueIdentity("previous")
        let currentIdentity = testQueueIdentity("current")
        let previousURL = try await DemoToneFactory.makeURL()
        let currentURL = try await DemoToneFactory.makeURL()
        let previous = AVPlayerItem(url: previousURL)
        let current = AVPlayerItem(url: currentURL)
        let newlyResolvedPrevious = AVPlayerItem(url: previousURL)

        engine.load(previous, identity: previousIdentity)
        engine.load(current, identity: currentIdentity)
        engine.preload(newlyResolvedPrevious, identity: previousIdentity)

        XCTAssertEqual(player.items().count, 2)
        XCTAssertTrue(player.items()[1] === previous)
        XCTAssertFalse(player.items()[1] === newlyResolvedPrevious)
        engine.stop()
    }

    func testFoundationEngineReplacesRemotePlayedItemWithoutCachingIt()
        async throws
    {
        let player = AVQueuePlayer()
        let engine = AVFoundationAudioPlayerEngine(player: player)
        let remoteIdentity = testQueueIdentity("remote")
        let localIdentity = testQueueIdentity("local")
        let remoteURL = try XCTUnwrap(
            URL(string: "https://example.com/audio/remote.flac")
        )
        let localURL = try await DemoToneFactory.makeURL()

        engine.load(AVPlayerItem(url: remoteURL), identity: remoteIdentity)
        engine.load(AVPlayerItem(url: localURL), identity: localIdentity)

        let newlyResolvedRemote = AVPlayerItem(url: remoteURL)
        engine.preload(newlyResolvedRemote, identity: remoteIdentity)

        XCTAssertEqual(player.items().count, 2)
        XCTAssertTrue(player.items()[1] === newlyResolvedRemote)
        engine.stop()
    }

    func testFoundationEngineDoesNotAccumulateRemotePlayedItemsAcrossReplacements()
        async throws
    {
        let player = AVQueuePlayer()
        let engine = AVFoundationAudioPlayerEngine(player: player)
        let remoteURL = try XCTUnwrap(
            URL(string: "https://example.com/audio/replacement.flac")
        )
        let localURL = try await DemoToneFactory.makeURL()
        for index in 0..<3 {
            let remoteIdentity = testQueueIdentity("remote-\(index)")
            engine.load(AVPlayerItem(url: remoteURL), identity: remoteIdentity)
            engine.load(
                AVPlayerItem(url: localURL),
                identity: testQueueIdentity("local-\(index)")
            )
            let newlyResolvedRemote = AVPlayerItem(url: remoteURL)
            engine.preload(newlyResolvedRemote, identity: remoteIdentity)

            XCTAssertEqual(player.items().count, 2)
            XCTAssertTrue(player.items()[1] === newlyResolvedRemote)
        }
        engine.stop()
    }

    func testFoundationEngineRejectsAdvanceUntilSuccessorIsReady()
        async throws
    {
        let engine = AVFoundationAudioPlayerEngine(player: AVQueuePlayer())
        let url = try await DemoToneFactory.makeURL()
        let current = AVPlayerItem(url: url)
        let next = AlwaysUnknownPlayerItem(asset: AVURLAsset(url: url))
        var didAdvance = false
        engine.eventHandler = { event in
            if event == .advancedToNextItem {
                didAdvance = true
            }
        }

        engine.load(current, identity: testQueueIdentity("current"))
        engine.play()
        engine.preload(next, identity: testQueueIdentity("next"))

        XCTAssertEqual(engine.preparedNextItemState.phase, .preparing)
        XCTAssertFalse(didAdvance)

        engine.advanceToNextItem()

        await Task.yield()
        XCTAssertFalse(didAdvance)
        XCTAssertTrue(engine.hasCurrentItem)

        XCTAssertEqual(engine.preparedNextItemState.phase, .preparing)
        XCTAssertFalse(didAdvance)
        XCTAssertTrue(engine.hasCurrentItem)
    }

    func testFoundationEngineReadinessGatesFirstItemAfterQueueRestore()
        async throws
    {
        let engine = AVFoundationAudioPlayerEngine(player: AVQueuePlayer())
        let url = try await DemoToneFactory.makeURL()
        let restoredSelection = AlwaysReadyPlayerItem(
            asset: AVURLAsset(url: url)
        )
        var didAdvance = false
        engine.eventHandler = { event in
            if event == .advancedToNextItem {
                didAdvance = true
            }
        }

        engine.preload(
            restoredSelection,
            identity: testQueueIdentity("restored")
        )
        await waitUntil { engine.preparedNextItemState.phase == .ready }
        XCTAssertFalse(didAdvance)
        engine.advanceToNextItem()

        XCTAssertTrue(didAdvance)
        XCTAssertTrue(engine.hasCurrentItem)
    }

    func testFoundationEngineNeverPromotesUnknownSuccessorAsReadinessProbe()
        async throws
    {
        let player = AVQueuePlayer()
        let engine = AVFoundationAudioPlayerEngine(player: player)
        let url = try await DemoToneFactory.makeURL()
        let current = AVPlayerItem(url: url)
        let next = AlwaysUnknownPlayerItem(asset: AVURLAsset(url: url))
        var didAdvance = false
        engine.eventHandler = { event in
            if event == .advancedToNextItem {
                didAdvance = true
            }
        }

        engine.load(current, identity: testQueueIdentity("current"))
        engine.preload(next, identity: testQueueIdentity("next"))
        let isPlayable = try await next.asset.load(.isPlayable)
        XCTAssertTrue(isPlayable)
        try await Task.sleep(for: .milliseconds(100))
        engine.advanceToNextItem()
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(player.currentItem === current)
        XCTAssertEqual(engine.currentGeneration, 1)
        XCTAssertFalse(didAdvance)
        XCTAssertTrue(engine.hasCurrentItem)
    }

    func testRecreatedCoordinatorKeepsPersistedCursorUntilPlayerItemIsReady()
        async throws
    {
        let playerItemURL = try await DemoToneFactory.makeURL()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let accountScope = "server|user"
        let current = PlaybackItem(
            id: "restored-current",
            title: "Restored Current",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let next = PlaybackItem(
            id: "restored-next",
            title: "Restored Next",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let stateStore = RecordingNowPlayingStateStore()
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [current, next],
                currentItemID: current.id,
                context: .songs
            ),
            elapsed: 12,
            account: account,
            savedAt: .now
        )
        let engine = AVFoundationAudioPlayerEngine(player: AVQueuePlayer())
        let recreated = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        recreated.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    playerItemFactory: {
                        AlwaysUnknownPlayerItem(
                            asset: AVURLAsset(url: playerItemURL)
                        )
                    }
                ),
                transportKind: .directStream
            )
        }

        recreated.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        recreated.nextTrack()

        await waitUntil(attempts: 500) { engine.currentGeneration > 0 }

        XCTAssertEqual(recreated.currentItem, current)
        XCTAssertEqual(recreated.queue?.currentItem, current)
        XCTAssertEqual(engine.currentGeneration, 1)
        XCTAssertEqual(engine.preparedNextItemState.phase, .absent)
        XCTAssertEqual(recreated.playbackState, .loading)
    }

    func testFoundationEngineCancellingColdSelectionRemovesStagedCurrentItem()
        async throws
    {
        let engine = AVFoundationAudioPlayerEngine(player: AVQueuePlayer())
        let url = try await DemoToneFactory.makeURL()

        engine.preload(
            AVPlayerItem(url: url),
            identity: testQueueIdentity("cold-selection")
        )

        XCTAssertTrue(engine.hasCurrentItem)
        engine.preload(nil, identity: nil)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(engine.preparedNextItemState.phase, .absent)
    }

    func testFoundationEngineSafelyClassifiesUnavailableAccessMetrics() {
        XCTAssertEqual(
            AVFoundationAudioPlayerEngine.diagnosticMetricInteger(.nan),
            -1
        )
        XCTAssertEqual(
            AVFoundationAudioPlayerEngine.diagnosticMetricInteger(.infinity),
            -1
        )
        XCTAssertEqual(
            AVFoundationAudioPlayerEngine.diagnosticMetricInteger(1_234.4),
            1_234
        )
    }

    func testPlaybackMetricFormatterContainsOnlyPrivacySafeFields() throws {
        let origin = Date(timeIntervalSinceReferenceDate: 100)
        let claim = PlaybackMediaMetricClaim(
            generation: 7,
            role: .staged,
            requestOrdinal: 2,
            itemStartedAt: origin
        )
        let network = PlaybackNetworkMetricSnapshot(
            totalMilliseconds: 900,
            fetchMilliseconds: 850,
            dnsMilliseconds: 20,
            connectMilliseconds: 40,
            tlsMilliseconds: 30,
            requestMilliseconds: 10,
            timeToFirstByteMilliseconds: 700,
            responseMilliseconds: 50,
            transactionCount: 1,
            statusCode: 206,
            networkProtocol: PlaybackNetworkMetricProtocol(
                nativeValue:
                    "https://private.example/music/item?token=credential"
            ),
            fetchType: .network,
            reusedConnection: false,
            proxyConnection: true,
            cellular: false,
            constrained: true,
            expensive: true
        )
        let event = PlaybackMetricJournalFormatter.mediaResource(
            claim: claim,
            snapshot: PlaybackMediaResourceMetricSnapshot(
                eventMilliseconds: 901,
                requestStartMilliseconds: 1,
                requestEndMilliseconds: 11,
                responseStartMilliseconds: 711,
                responseEndMilliseconds: 761,
                byteRangeLocation: 0,
                byteRangeLength: 65_536,
                readFromCache: false,
                result: .succeeded,
                network: network
            )
        )

        XCTAssertTrue(event.contains("generation=7 role=staged request=2"))
        XCTAssertTrue(event.contains("byte-range-length=65536"))
        XCTAssertTrue(event.contains("status=206 protocol=other"))
        for prohibited in [
            "https", "private.example", "/music", "item", "token",
            "credential",
        ] {
            XCTAssertFalse(event.contains(prohibited))
        }

        let request = URLRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://private.example/Items/media-id/PlaybackInfo?api_key=credential"
                )
            )
        )
        XCTAssertEqual(
            VelacantoNetworkMetricsDelegate.diagnosticRequestKind(for: request),
            .playbackInfo
        )
        let appEvent = PlaybackMetricJournalFormatter.appNetwork(
            kind: .playbackInfo,
            ordinal: 4,
            snapshot: network
        )
        XCTAssertTrue(appEvent.contains("kind=playback-info ordinal=4"))
        XCTAssertFalse(appEvent.contains("private.example"))
        XCTAssertFalse(appEvent.contains("media-id"))
        XCTAssertFalse(appEvent.contains("credential"))
    }

    func testPlaybackMetricOwnershipPreservesOrdinalAcrossStagedPromotion() {
        let startedAt = Date(timeIntervalSinceReferenceDate: 200)
        let owner = PlaybackMediaMetricContextOwner(
            generation: 3,
            role: .staged,
            itemStartedAt: startedAt
        )

        XCTAssertEqual(
            owner.claimNextRequest(),
            PlaybackMediaMetricClaim(
                generation: 3,
                role: .staged,
                requestOrdinal: 1,
                itemStartedAt: startedAt
            )
        )
        owner.update(generation: 4, role: .current)
        XCTAssertEqual(
            owner.claimNextRequest(),
            PlaybackMediaMetricClaim(
                generation: 4,
                role: .current,
                requestOrdinal: 2,
                itemStartedAt: startedAt
            )
        )
    }

    func testPlaybackMetricOwnershipRejectsEventsAfterRemoval() {
        let owner = PlaybackMediaMetricContextOwner(
            generation: 5,
            role: .staged
        )

        XCTAssertNotNil(owner.claimNextRequest())
        owner.deactivate()
        XCTAssertNil(owner.claimNextRequest())
        owner.update(generation: 6, role: .current)
        XCTAssertNil(owner.claimNextRequest())
    }

    func testPlaybackMetricAvailabilityFallbackIsDeterministic() {
        XCTAssertEqual(
            PlaybackMediaMetricCollectionStatus.availability(
                nativeAPIAvailable: false
            ),
            .apiUnavailable
        )
        XCTAssertEqual(
            PlaybackMediaMetricCollectionStatus.availability(
                nativeAPIAvailable: true
            ),
            .active
        )
    }

    func testPlaybackMetricItemProvenanceRequiresExactStagedInstance() {
        let staged = AVPlayerItem(
            url: URL(fileURLWithPath: "/tmp/staged.caf")
        )
        let replacement = AVPlayerItem(
            url: URL(fileURLWithPath: "/tmp/replacement.caf")
        )

        XCTAssertEqual(
            AVFoundationAudioPlayerEngine.itemInstallationProvenance(
                item: staged,
                stagedItem: staged
            ),
            .stagedReused
        )
        XCTAssertEqual(
            AVFoundationAudioPlayerEngine.itemInstallationProvenance(
                item: replacement,
                stagedItem: staged
            ),
            .created
        )
    }

    func testPlaybackBufferJournalThrottleEmitsOnlyDiagnosticMilestones() {
        var throttle = PlaybackBufferJournalThrottle()

        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 0,
                    isEmpty: true,
                    isLikelyToKeepUp: false
                )
            ),
            "The initial sample must be journaled."
        )
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 0.25,
                    isEmpty: true,
                    isLikelyToKeepUp: false
                )
            ),
            "The first positive loaded data must be journaled."
        )
        for loadedThrough in [0.5, 1, 10, 29.99] {
            XCTAssertFalse(
                throttle.shouldJournal(
                    PlaybackBufferState(
                        loadedThrough: loadedThrough,
                        isEmpty: true,
                        isLikelyToKeepUp: false
                    )
                ),
                "Small loaded-through increments must remain suppressed."
            )
        }
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 29.99,
                    isEmpty: false,
                    isLikelyToKeepUp: false
                )
            ),
            "Buffer-empty transitions must be journaled."
        )
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 29.99,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            ),
            "Likely-to-keep-up transitions must be journaled."
        )
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 30,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            ),
            "Coarse loaded-through milestones must be journaled."
        )
        XCTAssertFalse(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 30.5,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 60,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )

        throttle.reset()
        XCTAssertTrue(
            throttle.shouldJournal(
                PlaybackBufferState(
                    loadedThrough: 1,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            ),
            "Reset must restore initial-sample emission for a new item."
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

        makePlaybackStable(coordinator: coordinator, engine: engine)
        XCTAssertTrue(coordinator.isPlaying)

        coordinator.pausePlayback()
        XCTAssertEqual(engine.pauseCallCount, 1)
        engine.send(.stateChanged(.paused))
        XCTAssertFalse(coordinator.isPlaying)

        coordinator.resumePlayback()
        await waitUntil { engine.playCallCount == 2 }
        XCTAssertEqual(engine.playCallCount, 2)
        makePlaybackStable(coordinator: coordinator, engine: engine)

        coordinator.seek(toTime: 2.5)
        XCTAssertEqual(engine.seekTimes.last, 2.5)
        XCTAssertEqual(coordinator.elapsed, 2.5, accuracy: 0.001)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 60,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
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

    func testPreviousRestartsCurrentTrackAfterThreeSeconds() async throws {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let request = try await makePlaybackRequest()
        coordinator.play(request)
        engine.send(
            .timeChangedForGeneration(
                elapsed: 4,
                duration: 60,
                generation: engine.currentGeneration
            )
        )

        XCTAssertTrue(coordinator.canGoPrevious)
        coordinator.previousTrack()

        XCTAssertEqual(engine.seekTimes, [0])
        XCTAssertEqual(coordinator.currentItem, request.item)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testPreviousAtBeginningCommitsLivePriorOnlyAfterEngineReadiness()
        async
    {
        let previous = PlaybackItem(
            id: "previous-live",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current-live",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current],
            context: .songs
        )

        coordinator.previousTrack()
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, previous)
        XCTAssertEqual(coordinator.upcomingItems, [current])
        XCTAssertEqual(engine.advanceCallCount, 0)
    }

    func testStartingNewContextPreservesTimelineHistoryForPrevious()
        async
    {
        let older = PlaybackItem(
            id: "history-older",
            title: "Older",
            artist: "Velacanto",
            source: .jellyfin
        )
        let recent = PlaybackItem(
            id: "history-recent",
            title: "Recent",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "replacement-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let upcoming = PlaybackItem(
            id: "replacement-upcoming",
            title: "Upcoming",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: recent, transportKind: .directPlay),
            queueItems: [older, recent],
            context: .songs
        )
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, upcoming],
            context: .songs
        )

        XCTAssertEqual(
            coordinator.queue?.items,
            [older, recent, current, upcoming]
        )
        XCTAssertEqual(coordinator.historyItems, [older, recent])
        XCTAssertTrue(coordinator.canGoPrevious)
        coordinator.previousTrack()
        await waitUntil { engine.loadCallCount == 3 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(
            coordinator.queue?.items,
            [older, recent, current, upcoming]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, recent)
        XCTAssertEqual(
            coordinator.queue?.items,
            [older, recent, current, upcoming]
        )
        XCTAssertEqual(coordinator.playedQueueItems, [older])
        XCTAssertEqual(coordinator.upcomingItems, [current, upcoming])

        coordinator.previousTrack()
        await waitUntil { engine.loadCallCount == 4 }
        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, older)
        XCTAssertEqual(coordinator.upcomingItems, [recent, current, upcoming])
        XCTAssertNil(coordinator.queue?.previousItem)
        XCTAssertTrue(coordinator.canGoPrevious)
    }

    func testFailedPreviousCandidatePreservesCurrentAndQueue() async {
        let previous = PlaybackItem(
            id: "failed-previous",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "preserved-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { _ in
            throw JellyfinAPIError.unreachable
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current],
            context: .songs
        )

        coordinator.previousTrack()
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [previous, current])
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.advanceCallCount, 0)
    }

    func testRapidPreviousResolvesOnlyFinalTimelineDestination() async {
        let items = (0..<3).map {
            PlaybackItem(
                id: "rapid-previous-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: items[2], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )

        coordinator.previousTrack()
        coordinator.previousTrack()

        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == items[0] }
        XCTAssertEqual(resolvedItems, [items[0]])
        XCTAssertEqual(coordinator.queue?.items, items)
        XCTAssertEqual(coordinator.historyItems, [])
        XCTAssertEqual(coordinator.upcomingItems, [items[1], items[2]])
        XCTAssertEqual(engine.advanceCallCount, 0)
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
        engine.send(
            .timeChangedForGeneration(
                elapsed: 10,
                duration: 90,
                generation: engine.currentGeneration
            )
        )
        XCTAssertEqual(coordinator.duration, 90)
    }

    func testPlaybackLifecycleReportsCoalesceStaleProgressAndStaySerialized()
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
        makePlaybackStable(coordinator: coordinator, engine: engine)
        engine.send(.stateChanged(.playing))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 10,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 15,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        coordinator.pausePlayback()
        coordinator.stop()
        coordinator.stop()

        await waitUntilAsync {
            await recorder.snapshot().count == 3
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(
            events,
            [
                .started(session: "session", position: 0),
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
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 10,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
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

    func testFailedDirectFileForcesPlaybackInfoExactlyOnce()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let firstReporter = RecordingPlaybackLifecycleReporter(
            id: "first-session",
            recorder: recorder
        )
        let recoveryReporter = RecordingPlaybackLifecycleReporter(
            id: "recovery-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
        )
        let recoveryRequest = try makeJellyfinPlaybackRequest(
            reporter: recoveryReporter
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            return try self.makeJellyfinPlaybackRequest(
                reporter: recoveryReporter
            )
        }

        coordinator.play(
            try makeJellyfinPlaybackRequest(
                reporter: firstReporter,
                forcedPlaybackInfoFallback: { recoveryRequest }
            )
        )
        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(
            engine: engine,
            startingAt: 0,
            duration: 60
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 12,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        engine.send(.stateChanged(.failed("Connection lost")))

        await waitUntil {
            engine.loadCallCount == 2
        }
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertEqual(engine.seekTimes.last, 12)

        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(
            engine: engine,
            startingAt: 12,
            duration: 60
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 20,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        engine.send(.stateChanged(.failed("Connection lost again")))
        coordinator.stop()

        await waitUntilAsync {
            await recorder.snapshot().count == 6
        }
        let events = await recorder.snapshot()

        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(resolverCallCount, 0)
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
                .started(session: "recovery-session", position: 12),
                .progress(
                    session: "recovery-session",
                    position: 20,
                    isPaused: false
                ),
                .stopped(session: "recovery-session", position: 20),
            ]
        )
    }

    func testRecreatedPlaybackReleasesStalledPlayerBeforeFallbackResolution()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "restored-stall",
            title: "Restored Stall",
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
        let fallbackProbe = PlaybackRecoveryFallbackProbe()
        let recoveredRequest = playbackRequest(
            for: item,
            transportKind: .transcoding
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50)
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(
                for: item,
                transportKind: .localFile,
                forcedPlaybackInfoFallback: {
                    await fallbackProbe.waitForResolution()
                }
            )
        }

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }
        engine.send(.stateChanged(.waiting))
        await waitUntilAsync { await fallbackProbe.hasStarted }

        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, item)
        XCTAssertEqual(coordinator.queue?.currentItem, item)
        XCTAssertEqual(coordinator.elapsed, 42)

        await fallbackProbe.resolve(with: recoveredRequest)
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))

        XCTAssertEqual(coordinator.currentItem, item)
        XCTAssertEqual(coordinator.queue?.currentItem, item)
        XCTAssertEqual(engine.seekTimes.last, 42)
    }

    func testRecreatedPlaybackFallbackReclaimsNetworkDemandAfterPlayerStops()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "restored-network-demand",
            title: "Restored Network Demand",
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
        let engine = RecordingAudioPlayerEngine(
            stopStateDelivery: .deferredPaused
        )
        let fallbackProbe = PlaybackRecoveryFallbackProbe()
        let recoveredRequest = playbackRequest(
            for: item,
            transportKind: .transcoding
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50)
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(
                for: item,
                transportKind: .directPlay,
                forcedPlaybackInfoFallback: {
                    await fallbackProbe.waitForResolution()
                }
            )
        }

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }
        engine.send(.stateChanged(.waiting))
        await waitUntilAsync { await fallbackProbe.hasStarted }
        await waitUntil { engine.deferredStopStateDeliveryCount == 1 }

        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertEqual(coordinator.playbackState, .loading)

        await fallbackProbe.resolve(with: recoveredRequest)
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testRepeatedPlayKeepsRecreatedPlaybackFallbackInFlight() async {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "restored-repeat-play",
            title: "Restored Repeat Play",
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
        let engine = RecordingAudioPlayerEngine(
            stopStateDelivery: .deferredPaused
        )
        let fallbackProbe = PlaybackFallbackCancellationProbe()
        let recoveredRequest = playbackRequest(
            for: item,
            transportKind: .transcoding
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50)
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            resolverCallCount += 1
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay,
                forcedPlaybackInfoFallback: {
                    try await fallbackProbe.waitForCancellation()
                }
            )
        }

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }
        engine.send(.stateChanged(.waiting))
        await waitUntilAsync { await fallbackProbe.hasStarted }
        await waitUntil { engine.deferredStopStateDeliveryCount == 1 }

        coordinator.resumePlayback()
        await Task.yield()

        let fallbackWasCancelled = await fallbackProbe.wasCancelled
        XCTAssertFalse(fallbackWasCancelled)
        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertEqual(engine.loadCallCount, 1)

        await fallbackProbe.resolve(with: recoveredRequest)
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))
    }

    func testRecreatedRapidNextReleasesCurrentPlayerBeforeFallbackResolution()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let current = PlaybackItem(
            id: "restored-current",
            title: "Restored Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "restored-next",
            title: "Restored Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [current, next],
                currentItemID: current.id,
                context: .songs
            ),
            elapsed: 42,
            duration: 180,
            account: account,
            savedAt: Date()
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let fallbackProbe = PlaybackRecoveryFallbackProbe()
        let recoveredRequest = playbackRequest(
            for: next,
            transportKind: .transcoding
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            if item == next {
                return self.playbackRequest(
                    for: item,
                    transportKind: .localFile,
                    forcedPlaybackInfoFallback: {
                        await fallbackProbe.waitForResolution()
                    }
                )
            }
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }
        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine, startingAt: 41.75)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        XCTAssertEqual(engine.advanceCallCount, 1)
        engine.send(.failedToAdvanceToNextItem(.timeout))
        await waitUntilAsync { await fallbackProbe.hasStarted }

        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.elapsed, 42)

        await fallbackProbe.resolve(with: recoveredRequest)
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testStaleStoppedPlayerStateCannotAlterNewerGeneration() async {
        let first = PlaybackItem(
            id: "stale-state-first",
            title: "Stale State First",
            artist: "Velacanto",
            source: .jellyfin
        )
        let second = PlaybackItem(
            id: "stale-state-second",
            title: "Stale State Second",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(playbackRequest(for: first, transportKind: .directPlay))
        let firstGeneration = engine.currentGeneration
        engine.send(.stateChanged(.playing))

        coordinator.play(playbackRequest(for: second, transportKind: .directPlay))
        XCTAssertGreaterThan(engine.currentGeneration, firstGeneration)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .stateChangedForGeneration(
                .paused,
                generation: firstGeneration
            )
        )

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testGenuineStopAcceptsDeferredIdleAndReleasesNetworkDemand() async {
        let item = PlaybackItem(
            id: "genuine-stop",
            title: "Genuine Stop",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            stopStateDelivery: .deferredPaused
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(playbackRequest(for: item, transportKind: .directPlay))
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        coordinator.stop()
        await waitUntil { engine.deferredStopStateDeliveryCount == 1 }

        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertNil(coordinator.currentItem)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testNativePlayingAndLikelyBufferWaitForForwardTimeProgress() async {
        let items = (0..<2).map {
            PlaybackItem(
                id: "progress-gate-\($0)",
                title: "Progress Gate \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "progress-gate-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        let request = PlaybackRequest(
            item: items[0],
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/progress-gate.caf")
            ),
            transportKind: .directPlay,
            reporter: reporter
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(request, queueItems: items, context: .songs)
        let generation = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        engine.send(.bufferStateChanged(stableBuffer))
        await Task.yield()

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertTrue(resolvedItems.isEmpty)
        let eventsBeforeTime = await recorder.snapshot()
        XCTAssertTrue(eventsBeforeTime.isEmpty)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 42,
                duration: 180,
                generation: generation
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertTrue(resolvedItems.isEmpty)
        let eventsAfterBaseline = await recorder.snapshot()
        XCTAssertTrue(eventsAfterBaseline.isEmpty)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 42.25,
                duration: 180,
                generation: generation
            )
        )

        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
        await waitUntil { resolvedItems == [items[1]] }
        await waitUntilAsync { await recorder.snapshot().count == 1 }

        engine.send(
            .timeChangedForGeneration(
                elapsed: 42.5,
                duration: 180,
                generation: generation
            )
        )
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        await Task.yield()
        let eventsAfterRepeatedPlaying = await recorder.snapshot()
        XCTAssertEqual(eventsAfterRepeatedPlaying.count, 1)
    }

    func testRestoredSeekJumpRequiresASecondAdvancingTimeSample() async {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "restored-progress",
            title: "Restored Progress",
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
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .localFile)
        }

        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }
        XCTAssertEqual(engine.seekTimes.last, 42)
        let generation = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 42,
                duration: 180,
                generation: generation
            )
        )

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 42.25,
                duration: 180,
                generation: generation
            )
        )

        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testWaitingPlayingLoopsRequireRenewedForwardProgress() async {
        let item = PlaybackItem(
            id: "rebuffer-progress",
            title: "Rebuffer Progress",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )
        let emptyBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: true,
            isLikelyToKeepUp: false
        )

        coordinator.play(playbackRequest(for: item, transportKind: .directPlay))
        let generation = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 10,
                duration: 180,
                generation: generation
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 10.25,
                duration: 180,
                generation: generation
            )
        )
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(.bufferStateChanged(emptyBuffer))
        engine.send(
            .stateChangedForGeneration(.waiting, generation: generation)
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        engine.send(
            .stateChangedForGeneration(.waiting, generation: generation)
        )
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        await Task.yield()

        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 10.25,
                duration: 180,
                generation: generation
            )
        )
        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 10.5,
                duration: 180,
                generation: generation
            )
        )
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testOwnedReplacementCommitsOnlyAfterExactGenerationProgress() async {
        let items = (0..<2).map {
            PlaybackItem(
                id: "owned-progress-\($0)",
                title: "Owned Progress \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        let firstGeneration = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(.playing, generation: firstGeneration)
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 180,
                generation: firstGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0.25,
                duration: 180,
                generation: firstGeneration
            )
        )

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        let replacementGeneration = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: replacementGeneration
            )
        )
        engine.send(.bufferStateChanged(stableBuffer))

        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertEqual(coordinator.queue?.currentItem, items[0])
        XCTAssertNotEqual(coordinator.playbackState, .playing)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 180,
                generation: replacementGeneration
            )
        )
        XCTAssertEqual(coordinator.currentItem, items[0])

        engine.send(
            .timeChangedForGeneration(
                elapsed: 0.25,
                duration: 180,
                generation: replacementGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, items[1])
        XCTAssertEqual(coordinator.queue?.currentItem, items[1])
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testStaleGenerationTimeCannotProveCurrentGenerationProgress() async {
        let first = PlaybackItem(
            id: "stale-progress-first",
            title: "Stale Progress First",
            artist: "Velacanto",
            source: .jellyfin
        )
        let second = PlaybackItem(
            id: "stale-progress-second",
            title: "Stale Progress Second",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(playbackRequest(for: first, transportKind: .directPlay))
        let staleGeneration = engine.currentGeneration
        coordinator.play(playbackRequest(for: second, transportKind: .directPlay))
        let currentGeneration = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(.playing, generation: currentGeneration)
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 5,
                duration: 180,
                generation: currentGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 100,
                duration: 180,
                generation: staleGeneration
            )
        )

        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 5.25,
                duration: 180,
                generation: currentGeneration
            )
        )
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testStablePauseResumeReusesProvenGenerationProgress() async {
        let item = PlaybackItem(
            id: "stable-resume-progress",
            title: "Stable Resume Progress",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let generation = engine.currentGeneration + 1

        coordinator.play(playbackRequest(for: item, transportKind: .directPlay))
        XCTAssertEqual(engine.currentGeneration, generation)
        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 180,
                generation: generation
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0.25,
                duration: 180,
                generation: generation
            )
        )
        XCTAssertEqual(coordinator.playbackState, .playing)

        coordinator.pausePlayback()
        XCTAssertEqual(coordinator.playbackState, .paused)
        coordinator.resumePlayback()
        XCTAssertEqual(coordinator.playbackState, .waiting)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .stateChangedForGeneration(.playing, generation: generation)
        )

        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testNewGenerationPlayingWaitsForFreshBufferBeforeAdmissionRelease()
        async
    {
        let items = (0..<3).map {
            PlaybackItem(
                id: "stability-\($0)",
                title: "Stability \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [items[1]] }

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: engine.currentGeneration
            )
        )

        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 180,
                generation: engine.currentGeneration
            )
        )
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .timeChangedForGeneration(
                elapsed: 0.25,
                duration: 180,
                generation: engine.currentGeneration
            )
        )
        await waitUntil { !coordinator.hasPlaybackNetworkStartupDemand }

        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testSupersededLoadedGenerationCannotReleaseNewerTransitionAdmission()
        async
    {
        let items = (0..<3).map {
            PlaybackItem(
                id: "superseded-loaded-\($0)",
                title: "Superseded Loaded \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "superseded-loaded-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var finalContinuation: CheckedContinuation<PlaybackRequest, Never>?
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            if item == items[2] {
                return await withCheckedContinuation { continuation in
                    finalContinuation = continuation
                }
            }
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        let initialRequest = PlaybackRequest(
            item: items[0],
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/superseded-loaded-0.caf")
            ),
            transportKind: .directPlay,
            reporter: reporter
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            initialRequest,
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntilAsync { await recorder.snapshot().count == 1 }
        engine.send(
            .timeChangedForGeneration(
                elapsed: 12,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        await waitUntilAsync { await recorder.snapshot().count == 2 }
        await waitUntil { resolvedItems == [items[1]] }

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        let intermediateGeneration = engine.currentGeneration

        coordinator.nextTrack()
        await waitUntil { finalContinuation != nil }
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: intermediateGeneration
            )
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 25,
                duration: 60,
                generation: intermediateGeneration
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertEqual(coordinator.queue?.currentItem, items[0])
        XCTAssertEqual(coordinator.elapsed, 12)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertTrue(engine.preloadedURLs.isEmpty)
        let eventsBeforeFinalTarget = await recorder.snapshot()
        XCTAssertEqual(
            eventsBeforeFinalTarget,
            [
                .started(
                    session: "superseded-loaded-session",
                    position: 0
                ),
                .progress(
                    session: "superseded-loaded-session",
                    position: 12,
                    isPaused: false
                ),
                .stopped(
                    session: "superseded-loaded-session",
                    position: 12
                ),
            ]
        )

        finalContinuation?.resume(
            returning: playbackRequest(
                for: items[2],
                transportKind: .directPlay
            )
        )
        await waitUntil { engine.loadCallCount == 3 }
        let finalGeneration = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: finalGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, items[2])
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(.bufferStateChanged(stableBuffer))
        await waitUntil { !coordinator.hasPlaybackNetworkStartupDemand }

        XCTAssertEqual(coordinator.queue?.currentItem, items[2])
        XCTAssertEqual(engine.loadedIdentities, items.map(\.queueIdentity))
    }

    func testTimedOutLoadedQueueSelectionStopsGenerationAndIgnoresLateEvents()
        async
    {
        let current = PlaybackItem(
            id: "timeout-current",
            title: "Timeout Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "timeout-next",
            title: "Timeout Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "timeout-current-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(100),
            networkPolicy: VelacantoNetworkPolicy()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        let initialRequest = PlaybackRequest(
            item: current,
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/timeout-current.caf")
            ),
            transportKind: .directPlay,
            reporter: reporter
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            initialRequest,
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntilAsync { await recorder.snapshot().count == 1 }
        let initialGeneration = engine.currentGeneration
        engine.send(
            .timeChangedForGeneration(
                elapsed: 12,
                duration: 60,
                generation: initialGeneration
            )
        )
        await waitUntilAsync { await recorder.snapshot().count == 2 }
        await waitUntil { resolvedItems == [next] }

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        let rejectedGeneration = engine.currentGeneration
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.elapsed, 12)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
        if case .failed = coordinator.playbackState {
            // Expected clean retryable terminal state.
        } else {
            XCTFail("Expected a failed queue-selection state")
        }
        await waitUntilAsync { await recorder.snapshot().count == 3 }
        let settledEvents = await recorder.snapshot()
        XCTAssertEqual(
            settledEvents,
            [
                .started(session: "timeout-current-session", position: 0),
                .progress(
                    session: "timeout-current-session",
                    position: 12,
                    isPaused: false
                ),
                .stopped(
                    session: "timeout-current-session",
                    position: 12
                ),
            ]
        )

        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: rejectedGeneration
            )
        )
        engine.send(.bufferStateChanged(stableBuffer))
        engine.send(
            .timeChangedForGeneration(
                elapsed: 30,
                duration: 60,
                generation: rejectedGeneration
            )
        )
        await Task.yield()

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.elapsed, 12)
        let eventsAfterLateCallbacks = await recorder.snapshot()
        XCTAssertEqual(eventsAfterLateCallbacks, settledEvents)

        let settledLoadCount = engine.loadCallCount
        coordinator.nextTrack()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(engine.loadCallCount, settledLoadCount)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.elapsed, 12)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testOwnedDelayedQueueSelectionProgressCommitsAudibleItem()
        async
    {
        let current = PlaybackItem(
            id: "owned-delayed-current",
            title: "Owned Delayed Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "owned-delayed-next",
            title: "Owned Delayed Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .seconds(1)
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }

        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        let ownedGeneration = engine.currentGeneration
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: ownedGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.playbackState, .loading)

        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(engine.stopCallCount, 0)
    }

    func testDestructiveQueueReplacementStopsOldLifecycleBeforeStartingNew()
        async
    {
        let current = PlaybackItem(
            id: "lifecycle-current",
            title: "Lifecycle Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "lifecycle-next",
            title: "Lifecycle Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let recorder = PlaybackLifecycleEventRecorder()
        let currentReporter = RecordingPlaybackLifecycleReporter(
            id: "lifecycle-current-session",
            recorder: recorder
        )
        let nextReporter = RecordingPlaybackLifecycleReporter(
            id: "lifecycle-next-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/lifecycle-next.caf")
                ),
                transportKind: .directPlay,
                reporter: nextReporter
            )
        }
        let initialRequest = PlaybackRequest(
            item: current,
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/lifecycle-current.caf")
            ),
            transportKind: .directPlay,
            reporter: currentReporter
        )
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            initialRequest,
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntilAsync { await recorder.snapshot().count == 1 }
        engine.send(
            .timeChangedForGeneration(
                elapsed: 12,
                duration: 60,
                generation: engine.currentGeneration
            )
        )
        await waitUntilAsync { await recorder.snapshot().count == 2 }
        await waitUntil { resolvedItems == [next] }

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }
        await waitUntilAsync { await recorder.snapshot().count == 3 }
        let eventsAtDestructiveBoundary = await recorder.snapshot()
        XCTAssertEqual(
            eventsAtDestructiveBoundary,
            [
                .started(session: "lifecycle-current-session", position: 0),
                .progress(
                    session: "lifecycle-current-session",
                    position: 12,
                    isPaused: false
                ),
                .stopped(
                    session: "lifecycle-current-session",
                    position: 12
                ),
            ]
        )

        engine.send(.stateChanged(.playing))
        engine.send(.bufferStateChanged(stableBuffer))
        proveForwardProgress(engine: engine)
        await waitUntilAsync { await recorder.snapshot().count >= 5 }
        let eventsAfterReplacementStarted = await recorder.snapshot()
        XCTAssertEqual(
            eventsAfterReplacementStarted,
            [
                .started(session: "lifecycle-current-session", position: 0),
                .progress(
                    session: "lifecycle-current-session",
                    position: 12,
                    isPaused: false
                ),
                .stopped(
                    session: "lifecycle-current-session",
                    position: 12
                ),
                .started(session: "lifecycle-next-session", position: 0),
                .progress(
                    session: "lifecycle-next-session",
                    position: 0.25,
                    isPaused: false
                ),
            ]
        )
    }

    func testExplicitPreparedSuccessorCommitsOnlyOnExactGenerationPlaying()
        async
    {
        let items = (0..<3).map {
            PlaybackItem(
                id: "prepared-playing-\($0)",
                title: "Prepared Playing \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .localFile)
        }
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        engine.send(.advancedToNextItem)
        let successorGeneration = engine.currentGeneration

        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertEqual(coordinator.queue?.currentItem, items[0])
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertEqual(engine.preloadedURLs.count, 1)

        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: successorGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertEqual(coordinator.queue?.currentItem, items[0])
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertEqual(engine.preloadedURLs.count, 1)

        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, items[1])
        XCTAssertEqual(coordinator.queue?.currentItem, items[1])
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(.bufferStateChanged(stableBuffer))
        await waitUntil { !coordinator.hasPlaybackNetworkStartupDemand }
        await waitUntil { engine.preloadedURLs.count == 2 }

        XCTAssertEqual(coordinator.upcomingItems, [items[2]])
    }

    func testExplicitPreparedSuccessorFailurePreservesCursorAndQuarantinesRetry()
        async
    {
        let current = PlaybackItem(
            id: "prepared-failure-current",
            title: "Prepared Failure Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "prepared-failure-next",
            title: "Prepared Failure Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let fallbackRecorder = AsyncInvocationRecorder()
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        let fallbackRequest = playbackRequest(
            for: next,
            transportKind: .transcoding
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(
                for: item,
                transportKind: .localFile,
                forcedPlaybackInfoFallback: {
                    await fallbackRecorder.record()
                    return fallbackRequest
                }
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        engine.send(.advancedToNextItem)
        let failedGeneration = engine.currentGeneration
        engine.send(
            .stateChangedForGeneration(
                .failed("prepared successor failed"),
                generation: failedGeneration
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertEqual(engine.loadCallCount, 1)
        let fallbackCountAfterFailure = await fallbackRecorder.snapshot()
        XCTAssertEqual(fallbackCountAfterFailure, 0)

        coordinator.nextTrack()
        await Task.yield()

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        let finalFallbackCount = await fallbackRecorder.snapshot()
        XCTAssertEqual(finalFallbackCount, 0)
    }

    func testStableGenerationResumeReleasesAdmissionButReportsStartOnce()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let recorder = PlaybackLifecycleEventRecorder()
        let reporter = RecordingPlaybackLifecycleReporter(
            id: "resume-session",
            recorder: recorder
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )

        coordinator.play(
            try makeJellyfinPlaybackRequest(reporter: reporter)
        )
        engine.send(.stateChanged(.playing))
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine)
        await waitUntilAsync { await recorder.snapshot().count == 1 }
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)

        coordinator.pausePlayback()
        coordinator.resumePlayback()
        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        engine.send(.stateChanged(.playing))
        await Task.yield()

        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
        let events = await recorder.snapshot()
        XCTAssertEqual(
            events.filter {
                if case .started = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testTransportSecurityFailureDoesNotReloadRejectedStream() async {
        let item = PlaybackItem(
            id: "tls-failure",
            title: "TLS Failure",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        coordinator.play(
            playbackRequest(for: item, transportKind: .directPlay)
        )

        engine.terminalFailureKind = .transportSecurity
        engine.send(.stateChanged(.failed("certificate rejected")))
        await Task.yield()

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertTrue(
            coordinator.errorMessage?.contains("secure connection") == true
        )
    }

    func testRestoredRemoteDeadlineFailsClosedBeforeQueuedCatalogAdmission()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let item = PlaybackItem(
            id: "contained-restored",
            title: "Contained Restored",
            artist: "Velacanto",
            source: .jellyfin,
            container: "flac"
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
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50),
            networkPolicy: policy
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            resolverCallCount += 1
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        coordinator.resumePlayback()
        await waitUntil { engine.loadCallCount == 1 }

        let catalogStart = AsyncInvocationRecorder()
        let catalog = Task {
            do {
                try await policy.perform(
                    priority: .catalog,
                    key: "contained-catalog"
                ) {
                    await catalogStart.record()
                }
                return true
            } catch {
                return false
            }
        }
        await waitUntil { policy.hasQueuedRequest(key: "contained-catalog") }
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.quarantineCount, 1)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, item)
        XCTAssertEqual(coordinator.queue?.currentItem, item)
        XCTAssertEqual(coordinator.elapsed, 42)
        XCTAssertEqual(resolverCallCount, 1)
        let catalogWasAdmitted = await catalog.value
        let catalogStartCount = await catalogStart.snapshot()
        XCTAssertFalse(catalogWasAdmitted)
        XCTAssertEqual(catalogStartCount, 0)

        coordinator.resumePlayback()
        coordinator.resumePlayback()
        coordinator.play(item, account: account)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(resolverCallCount, 1)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, item)
        XCTAssertEqual(coordinator.queue?.currentItem, item)
        XCTAssertEqual(coordinator.elapsed, 42)
    }

    func testTerminalRemoteContainmentCancelsLifecycleAndRejectsLateGeneration()
        async
    {
        let lifecycleEvents = PlaybackLifecycleEventRecorder()
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        let item = PlaybackItem(
            id: "contained-lifecycle",
            title: "Contained Lifecycle",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50),
            networkPolicy: policy
        )
        coordinator.play(
            playbackRequest(
                for: item,
                transportKind: .directPlay,
                reporter: RecordingPlaybackLifecycleReporter(
                    id: "contained",
                    recorder: lifecycleEvents,
                    startDelay: .seconds(30)
                )
            )
        )
        let failedGeneration = engine.currentGeneration
        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertFalse(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.quarantineCount, 0)

        engine.send(
            .stateChangedForGeneration(
                .waiting,
                generation: failedGeneration
            )
        )
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.quarantineCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)

        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: failedGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: 12,
                duration: 180,
                generation: failedGeneration
            )
        )
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        await Task.yield()

        if case .failed = coordinator.playbackState {
            // Expected terminal state remains authoritative.
        } else {
            XCTFail("Late removed-generation events must stay rejected.")
        }
        let events = await lifecycleEvents.snapshot()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
    }

    func testTerminalRemoteQuarantineLeavesLocalPlaybackUsableWithoutReopen() {
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        policy.enterTerminalRemoteQuarantine()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: policy
        )
        let local = PlaybackItem(
            id: "contained-local",
            title: "Contained Local",
            artist: "Velacanto",
            source: .localFiles
        )

        coordinator.play(
            playbackRequest(for: local, transportKind: .localFile)
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.quarantineCount, 1)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, local)
        XCTAssertEqual(coordinator.playbackState, .playing)
    }

    func testNaturalAdvanceCannotReopenOrResolveAfterTerminalQuarantine()
        async
    {
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        let current = PlaybackItem(
            id: "contained-natural-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "contained-natural-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(50),
            networkPolicy: policy
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            resolverCallCount += 1
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .album(id: "contained-natural")
        )
        await waitUntil { engine.loadCallCount == 1 }
        await waitUntil { coordinator.errorMessage != nil }

        coordinator.nextTrack(cancellingPendingPlaybackRequest: false)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
    }

    func testExplicitRemoteGesturesStayQuarantinedWithoutSecondLoadOrResolver()
        async
    {
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        let previous = PlaybackItem(
            id: "contained-previous",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "contained-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "contained-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: policy
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            resolverCallCount += 1
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current, next]
        )
        engine.send(.stateChanged(.failed("terminal")))
        await waitUntil { policy.isTerminalRemoteQuarantined }

        coordinator.resumePlayback()
        coordinator.nextTrack()
        coordinator.previousTrack()
        coordinator.playHistoryItem(previous)
        coordinator.playQueueItem(next)
        coordinator.play(current)
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.currentGeneration, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [previous, current, next])
    }

    func testStaleInterruptionEndCannotReopenTerminalRemoteQuarantine() {
        let transportLifecycle = NetworkContainmentLifecycleRecorder()
        let policy = VelacantoNetworkPolicy(
            quarantineTransport: transportLifecycle.recordQuarantine
        )
        let platformEvents = RecordingPlaybackPlatformEventObserver()
        let item = PlaybackItem(
            id: "contained-interruption",
            title: "Contained Interruption",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            platformEventObserver: platformEvents,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: policy
        )
        coordinator.play(
            playbackRequest(for: item, transportKind: .directPlay)
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)

        platformEvents.sendInterruption(.began)
        engine.send(
            .stateChangedForGeneration(
                .failed("terminal"),
                generation: engine.currentGeneration
            )
        )
        platformEvents.sendInterruption(.ended(shouldResume: true))

        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
        XCTAssertEqual(transportLifecycle.quarantineCount, 1)
        XCTAssertEqual(transportLifecycle.reopenCount, 0)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
    }

    func testRecoveryDeadlineDoesNotRetainAbandonedCoordinator() async {
        let engine = RecordingAudioPlayerEngine()
        weak var releasedCoordinator: AudioPlaybackCoordinator?
        #if os(iOS)
            let initialPlaybackStartupCount =
                VelacantoNetworkPolicy.shared.playbackStartupCount
        #endif

        do {
            let coordinator = AudioPlaybackCoordinator(
                engine: engine,
                audioSessionController: ImmediateAudioSessionController(),
                itemRecoveryDeadline: .seconds(30)
            )
            releasedCoordinator = coordinator
            coordinator.play(
                playbackRequest(
                    for: PlaybackItem(
                        id: "release",
                        title: "Release",
                        artist: "Velacanto",
                        source: .jellyfin
                    ),
                    transportKind: .directPlay
                )
            )
        }

        await Task.yield()
        XCTAssertNil(releasedCoordinator)
        #if os(iOS)
            XCTAssertEqual(
                VelacantoNetworkPolicy.shared.playbackStartupCount,
                initialPlaybackStartupCount
            )
        #endif
    }

    func testExplicitResumeAfterFailedFreshRecoveryStaysQuarantined()
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

        coordinator.play(
            try makeJellyfinPlaybackRequest(
                forcedPlaybackInfoFallback: { retryRequest }
            )
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
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
        await Task.yield()

        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(
            coordinator.playbackState,
            .failed(
                "The Jellyfin stream stopped unexpectedly. Try playing the track again."
            )
        )
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
        makePlaybackStable(coordinator: coordinator, engine: engine)
        platformEvents.sendInterruption(.began)
        engine.send(.stateChanged(.paused))

        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertNotNil(stateStore.state)

        platformEvents.sendInterruption(.ended(shouldResume: false))
        XCTAssertEqual(engine.playCallCount, 1)

        coordinator.resumePlayback()
        await waitUntil { engine.playCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
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

        makePlaybackStable(coordinator: coordinator, engine: engine)
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

    func testFailedStreamResolutionIsSafeAndRemainsQuarantined()
        async throws
    {
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            throw JellyfinAPIError.unreachable
        }

        coordinator.play(try makeJellyfinPlaybackRequest())
        makePlaybackStable(coordinator: coordinator, engine: engine)
        engine.send(
            .stateChanged(
                .failed(
                    "Failed https://example.com/audio?api_key=secret-token"
                )
            )
        )

        await waitUntil { resolverCallCount == 1 }
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(
            coordinator.playbackState,
            .failed(
                "The Jellyfin stream stopped unexpectedly. Try playing the track again."
            )
        )
        XCTAssertFalse(coordinator.errorMessage?.contains("secret-token") == true)
        XCTAssertFalse(coordinator.errorMessage?.contains("https://") == true)

        coordinator.play(try makeJellyfinPlaybackRequest())
        await Task.yield()

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(
            coordinator.playbackState,
            .failed(
                "The Jellyfin stream stopped unexpectedly. Try playing the track again."
            )
        )
        XCTAssertNotNil(coordinator.errorMessage)
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

    func testPlaybackHistoryNormalizesPersistedDuplicateQueueIdentities() {
        let item = PlaybackItem(
            id: "duplicate-history",
            title: "Duplicate History",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server|user"
        )
        let history = RecordingPlaybackHistoryStore(loadedItems: [item, item])

        let coordinator = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
            historyStore: history
        )

        XCTAssertEqual(coordinator.recentItems, [item])
        XCTAssertEqual(history.savedItems, [item])
    }

    func testRecentlyPlayedDeduplicatesLegacyAndScopedProviderIdentity() {
        let scoped = PlaybackItem(
            id: "shared-provider-id",
            title: "Scoped",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server|user"
        )
        let legacy = PlaybackItem(
            id: "shared-provider-id",
            title: "Legacy",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server|user"
        )
        let history = RecordingPlaybackHistoryStore(
            loadedItems: [scoped, legacy]
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
            historyStore: history
        )

        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            account: PlaybackAccount(serverID: "server", userID: "user")
        )

        XCTAssertEqual(coordinator.recentlyPlayedItems, [scoped])
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
            engine.send(
                .timeChangedForGeneration(
                    elapsed: 12,
                    duration: 120,
                    generation: engine.currentGeneration
                )
            )
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

    func testStaleHistoryResolutionCannotReplaceNewPlayback() async {
        let historyItem = PlaybackItem(
            id: "history",
            title: "History",
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
            engine: RecordingAudioPlayerEngine()
        )
        var historyContinuation: CheckedContinuation<PlaybackRequest, Never>?
        coordinator.configureRequestResolver { item in
            await withCheckedContinuation { continuation in
                XCTAssertEqual(item, historyItem)
                historyContinuation = continuation
            }
        }

        coordinator.play(historyItem)
        await waitUntil { historyContinuation != nil }
        coordinator.play(
            PlaybackRequest(
                item: replacement,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/replacement.caf")
                ),
                transportKind: .directStream
            )
        )
        historyContinuation?.resume(
            returning: PlaybackRequest(
                item: historyItem,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/history.caf")
                ),
                transportKind: .directPlay
            )
        )
        await Task.yield()

        XCTAssertEqual(coordinator.currentItem, replacement)
        XCTAssertEqual(coordinator.transportKind, .directStream)
    }

    func testRapidNextCommandsAccumulateWhileCancelledRequestsFinish() async {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let queued = (1...3).map { index in
            PlaybackItem(
                id: "next-\(index)",
                title: "Next \(index)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        coordinator.play(
            PlaybackRequest(
                item: current,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/current.caf")
                ),
                transportKind: .directPlay
            ),
            queueItems: [current] + queued,
            context: .songs
        )

        var continuations: [CheckedContinuation<PlaybackRequest, Never>] = []
        var requestedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            requestedItems.append(item)
            return await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }

        coordinator.nextTrack()
        await waitUntil { continuations.count == 1 }
        coordinator.nextTrack()
        await waitUntil { continuations.count == 2 }

        continuations[0].resume(
            returning: playbackRequest(
                for: queued[0],
                transportKind: .directPlay
            )
        )
        await Task.yield()

        coordinator.nextTrack()
        await waitUntil { continuations.count == 3 }
        continuations[1].resume(
            returning: playbackRequest(
                for: queued[1],
                transportKind: .directStream
            )
        )
        await Task.yield()
        continuations[2].resume(
            returning: playbackRequest(
                for: queued[2],
                transportKind: .transcoding
            )
        )
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))
        proveForwardProgress(engine: engine)

        XCTAssertEqual(requestedItems, queued)
        XCTAssertEqual(coordinator.currentItem, queued[2])
        XCTAssertEqual(
            coordinator.playedQueueItems,
            [current] + Array(queued.prefix(2))
        )
        XCTAssertEqual(coordinator.transportKind, .transcoding)
    }

    func testFailedStreamRecoveryNegotiatesFreshWithoutReloadingStaleURL()
        async
    {
        let item = PlaybackItem(
            id: "network-recovery",
            title: "Network Recovery",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        var resolutionAttempts = 0
        coordinator.configureRequestResolver { _ in
            resolutionAttempts += 1
            throw JellyfinAPIError.unreachable
        }
        coordinator.play(
            playbackRequest(for: item, transportKind: .directPlay)
        )

        engine.send(.stateChanged(.failed("stream failed")))
        await waitUntilAsync { resolutionAttempts == 1 }

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, item)
    }

    func testFailedStreamHistorySelectionRequiresFreshPlaybackSession()
        async
    {
        let history = PlaybackItem(
            id: "cached-history",
            title: "Cached History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "failed-current",
            title: "Failed Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            throw JellyfinAPIError.unreachable
        }
        coordinator.play(
            playbackRequest(for: history, transportKind: .directPlay)
        )
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay)
        )

        engine.send(.stateChanged(.failed("stream failed")))
        await waitUntil { resolverCallCount == 1 }
        coordinator.playQueueItem(history)
        await waitUntil { resolverCallCount == 2 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(coordinator.queue?.items, [history, current])
    }

    func testFailedUpcomingResolutionPreservesAudibleItemAndQueue() async {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let upcoming = PlaybackItem(
            id: "upcoming",
            title: "Upcoming",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        coordinator.configureRequestResolver { item in
            XCTAssertEqual(item, upcoming)
            throw JellyfinAPIError.transportSecurity
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, upcoming],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)

        coordinator.nextTrack()
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [upcoming])
        XCTAssertEqual(coordinator.playbackState, .playing)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testUnsupportedUpcomingItemDoesNotTriggerAutomaticNegotiationLoop()
        async
    {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let upcoming = PlaybackItem(
            id: "upcoming",
            title: "Upcoming",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        var resolverCallCount = 0
        coordinator.configureRequestResolver { _ in
            resolverCallCount += 1
            throw JellyfinAPIError.unsupportedMedia
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, upcoming],
            context: .songs
        )
        engine.send(.stateChanged(.playing))
        let stableBuffer = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )
        engine.send(.bufferStateChanged(stableBuffer))
        proveForwardProgress(engine: engine)
        await waitUntil { resolverCallCount == 1 }

        for _ in 0..<3 {
            engine.send(.stateChanged(.playing))
            engine.send(.bufferStateChanged(stableBuffer))
        }
        await Task.yield()
        XCTAssertEqual(resolverCallCount, 1)

        coordinator.nextTrack()
        await waitUntil { resolverCallCount == 2 }
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [upcoming])
    }

    func testHistorySelectionDoesNotLayerRetryAboveTransport() async {
        let history = PlaybackItem(
            id: "history",
            title: "History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        var requestedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            requestedItems.append(item)
            throw JellyfinAPIError.offline
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [history, current],
            context: .songs
        )

        coordinator.playQueueItem(history)
        await waitUntil { requestedItems == [history] }
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertEqual(requestedItems, [history])
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testPlaybackResolutionBeginsNetworkDemandBeforeResolverRuns() async {
        let item = PlaybackItem(
            id: "network-demand",
            title: "Network Demand",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        let initialStartupCount =
            VelacantoNetworkPolicy.shared.playbackStartupCount
        var observedPlaybackDemand = false
        coordinator.configureRequestResolver { item in
            observedPlaybackDemand =
                VelacantoNetworkPolicy.shared.playbackStartupCount
                > initialStartupCount
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }

        coordinator.play(item)
        await waitUntil { coordinator.currentItem == item }

        XCTAssertTrue(observedPlaybackDemand)
        engine.send(.stateChanged(.playing))
        await waitUntil {
            VelacantoNetworkPolicy.shared.playbackStartupCount
                == initialStartupCount
        }
    }

    func testHistorySelectionDoesNotRetryUnreachableTimeout() async {
        let history = PlaybackItem(
            id: "history-timeout",
            title: "History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        var requestCount = 0
        coordinator.configureRequestResolver { _ in
            requestCount += 1
            throw JellyfinAPIError.unreachable
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [history, current],
            context: .songs
        )

        coordinator.playQueueItem(history)
        await waitUntil { coordinator.errorMessage != nil }

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testNewContextPreservesHistoryAsPartOfPlaybackTimeline()
        async
    {
        let history = PlaybackItem(
            id: "history-outside-live-queue",
            title: "History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let albumTrack = PlaybackItem(
            id: "replacement-album-track",
            title: "Album Track",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var requestedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            requestedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.play(
            playbackRequest(for: history, transportKind: .directPlay)
        )
        coordinator.play(
            playbackRequest(for: albumTrack, transportKind: .directPlay),
            queueItems: [albumTrack],
            context: .album(id: "replacement-album")
        )

        XCTAssertEqual(coordinator.historyItems, [history])

        coordinator.playQueueItem(history)

        await waitUntil { engine.loadCallCount == 3 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == history }
        XCTAssertEqual(requestedItems, [history])
        XCTAssertEqual(coordinator.queue?.items, [history, albumTrack])
        XCTAssertEqual(coordinator.playedQueueItems, [])
        XCTAssertEqual(coordinator.upcomingItems, [albumTrack])
        XCTAssertEqual(engine.loadCallCount, 3)
    }

    func testLegacyHistorySelectionPersistsNegotiatedContainerOnce()
        async
    {
        let current = PlaybackItem(
            id: "legacy-history-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin,
            container: "flac"
        )
        let legacyHistory = PlaybackItem(
            id: "legacy-history-selection",
            title: "Legacy History",
            artist: "Velacanto",
            source: .jellyfin,
            container: nil
        )
        let enrichedHistory = legacyHistory.replacingContainer("flac")
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let stateStore = RecordingNowPlayingStateStore()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            let resolvedItem = item == legacyHistory ? enrichedHistory : item
            return self.playbackRequest(for: resolvedItem, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [legacyHistory, current],
            context: .songs,
            account: account
        )

        coordinator.playHistoryItem(legacyHistory)
        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == enrichedHistory }
        await waitUntil { resolvedItems.count == 2 }

        XCTAssertEqual(resolvedItems, [legacyHistory, current])
        XCTAssertEqual(coordinator.currentItem?.container, "flac")
        XCTAssertEqual(stateStore.state?.queue.currentItem?.container, "flac")
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testHistorySuccessDoesNotRestoreDisplacedPreparedSuccessor()
        async
    {
        let history = PlaybackItem(
            id: "history",
            title: "History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let firstPlayNext = PlaybackItem(
            id: "first-play-next",
            title: "First Play Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let secondPlayNext = PlaybackItem(
            id: "second-play-next",
            title: "Second Play Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(playbackRequest(for: history, transportKind: .directPlay))
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, firstPlayNext, secondPlayNext],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.playQueueItem(history)
        await waitUntil { engine.loadCallCount == 3 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(
            coordinator.upcomingItems,
            [firstPlayNext, secondPlayNext]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, history)
        XCTAssertEqual(coordinator.playedQueueItems, [])
        XCTAssertEqual(
            coordinator.upcomingItems,
            [current, firstPlayNext, secondPlayNext]
        )
        XCTAssertEqual(resolvedItems, [firstPlayNext, history])
        XCTAssertEqual(engine.preloadedURLs.count, 1)
        XCTAssertEqual(engine.loadCallCount, 3)

        await waitUntil { engine.preloadedURLs.count == 2 }
        XCTAssertEqual(
            resolvedItems,
            [firstPlayNext, history, current]
        )
    }

    func testHistorySelectionAfterColdRestorePreservesQueueUntilReady()
        async
    {
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let current = PlaybackItem(
            id: "restored-current",
            title: "Restored Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let upcoming = PlaybackItem(
            id: "restored-upcoming",
            title: "Restored Upcoming",
            artist: "Velacanto",
            source: .jellyfin
        )
        let history = PlaybackItem(
            id: "cold-history",
            title: "Cold History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let stateStore = RecordingNowPlayingStateStore()
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [history, current, upcoming],
                currentItemID: current.id,
                context: .songs
            ),
            elapsed: 12,
            duration: 180,
            account: account,
            savedAt: Date()
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )

        coordinator.playQueueItem(history)
        await waitUntil { engine.loadCallCount == 1 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [history, current, upcoming])
        XCTAssertEqual(engine.loadCallCount, 1)

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, history)
        XCTAssertEqual(
            coordinator.queue?.items,
            [history, current, upcoming]
        )
        XCTAssertEqual(coordinator.playedQueueItems, [])
        XCTAssertEqual(coordinator.upcomingItems, [current, upcoming])
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testFailedHistoryCandidateQuiescesDisplacedSuccessor()
        async
    {
        let history = PlaybackItem(
            id: "history-failure",
            title: "History Failure",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let playNext = PlaybackItem(
            id: "play-next",
            title: "Play Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(playbackRequest(for: history, transportKind: .directPlay))
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, playNext],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.playQueueItem(history)
        await waitUntil { engine.loadCallCount == 3 }
        engine.send(
            .stateChangedForGeneration(
                .failed("history selection failed"),
                generation: engine.currentGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [history, current, playNext])
        XCTAssertEqual(coordinator.upcomingItems, [playNext])
        XCTAssertEqual(resolvedItems, [playNext, history])
        XCTAssertEqual(engine.preloadedURLs.count, 1)
        XCTAssertEqual(engine.loadCallCount, 3)
        XCTAssertNotNil(coordinator.errorMessage)

        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        await Task.yield()
        XCTAssertEqual(engine.preloadedURLs.count, 1)
    }

    func testExplicitHistorySelectionKeepsHistorySemanticsWhenItemIsLive()
        async
    {
        let history = PlaybackItem(
            id: "history-also-live",
            title: "History Also Live",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let beforeHistory = PlaybackItem(
            id: "before-history",
            title: "Before History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let afterHistory = PlaybackItem(
            id: "after-history",
            title: "After History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [beforeHistory, history, current, afterHistory],
            context: .songs
        )

        coordinator.playHistoryItem(history)
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(
            coordinator.upcomingItems,
            [afterHistory]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, history)
        XCTAssertEqual(coordinator.playedQueueItems, [beforeHistory])
        XCTAssertEqual(coordinator.upcomingItems, [current, afterHistory])
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testFailedLiveQueueCandidatePreservesCurrentAndPreparedSuccessor()
        async
    {
        let current = PlaybackItem(
            id: "live-current",
            title: "Live Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let immediate = PlaybackItem(
            id: "live-immediate",
            title: "Live Immediate",
            artist: "Velacanto",
            source: .jellyfin
        )
        let selected = PlaybackItem(
            id: "live-selected",
            title: "Live Selected",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, immediate, selected],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.playQueueItem(selected)
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(
            coordinator.queue?.items,
            [current, immediate, selected]
        )

        engine.send(
            .stateChangedForGeneration(
                .failed("live selection failed"),
                generation: engine.currentGeneration
            )
        )

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(
            coordinator.queue?.items,
            [current, immediate, selected]
        )
        XCTAssertEqual(coordinator.upcomingItems, [immediate, selected])
        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(engine.preloadedURLs.count, 1)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testPlaybackHistoryKeepsFiftyMostRecentUniqueTracks() {
        let coordinator = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine()
        )
        for index in 0..<60 {
            let item = PlaybackItem(
                id: "history-\(index)",
                title: "History \(index)",
                artist: "Velacanto",
                source: .jellyfin
            )
            coordinator.play(
                playbackRequest(for: item, transportKind: .directPlay)
            )
        }

        XCTAssertEqual(coordinator.recentItems.count, 50)
        XCTAssertEqual(coordinator.recentItems.first?.id, "history-59")
        XCTAssertEqual(coordinator.recentItems.last?.id, "history-10")
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

    func testPlaybackTimelineSelectionMovesOnlyItsCursor() {
        let items = (0..<6).map {
            PlaybackItem(
                id: "timeline-\($0)",
                title: "Timeline \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        var queue = PlaybackQueue(
            items: items,
            currentItemID: items[3].id,
            context: .songs
        )

        XCTAssertTrue(queue.select(items[1]))
        XCTAssertEqual(queue.items, items)
        XCTAssertEqual(queue.playedItems, [items[0]])
        XCTAssertEqual(queue.currentItem, items[1])
        XCTAssertEqual(queue.upcomingItems, Array(items[2...]))

        XCTAssertTrue(queue.select(items[4]))
        XCTAssertEqual(queue.items, items)
        XCTAssertEqual(queue.playedItems, Array(items[0...3]))
        XCTAssertEqual(queue.currentItem, items[4])
        XCTAssertEqual(queue.upcomingItems, [items[5]])
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

    func testQueueIdentityScopesJellyfinIDsToTheirOwningAccount() {
        let firstAccount = PlaybackItem(
            id: "same-provider-id",
            title: "First Account",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server-a|user-a"
        )
        let secondAccount = PlaybackItem(
            id: "same-provider-id",
            title: "Second Account",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server-b|user-b"
        )

        let queue = PlaybackQueue(
            items: [firstAccount, secondAccount],
            currentItemID: firstAccount.id,
            context: .songs
        )

        XCTAssertEqual(queue.items, [firstAccount, secondAccount])
        XCTAssertNotEqual(firstAccount.queueIdentity, secondAccount.queueIdentity)
    }

    func testSelectingUpcomingItemMovesTimelineCursorWithoutReordering()
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

        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == selectedUpcoming }
        XCTAssertEqual(coordinator.playedQueueItems, [current, firstUpcoming])
        XCTAssertEqual(coordinator.upcomingItems, [])
        XCTAssertEqual(
            coordinator.queue?.items,
            [current, firstUpcoming, selectedUpcoming]
        )
        XCTAssertEqual(engine.playCallCount, 1)
    }

    func testRemotePreloadRetainsMetadataWithoutCreatingPlayerItem() async {
        let current = PlaybackItem(
            id: "metadata-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        await Task.yield()

        XCTAssertEqual(factoryProbe.creationCount, 0)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(engine.preloadNilCallCount, 0)
        XCTAssertTrue(engine.preloadedURLs.isEmpty)
        XCTAssertEqual(engine.loadCallCount, 1)
    }

    func testRemoteMetadataNextReusesResolutionAndLoadsOneOwnedItem() async {
        let current = PlaybackItem(
            id: "metadata-next-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-next-target",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }

        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [next])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(engine.preloadNilCallCount, 0)
        XCTAssertEqual(
            engine.loadedIdentities,
            [current.queueIdentity, next.queueIdentity]
        )
        XCTAssertEqual(coordinator.currentItem, current)

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
    }

    func testPausedRemoteItemChangingSelectionsStartReplacementPlayback()
        async
    {
        for selection in PausedRemoteQueueSelection.allCases {
            await assertPausedRemoteQueueSelectionStartsPlayback(selection)
        }
    }

    func testPausedRemoteNextStillReachesTheSingleReplacementDeadline()
        async
    {
        let current = PlaybackItem(
            id: "paused-deadline-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "paused-deadline-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let policy = VelacantoNetworkPolicy()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(20),
            networkPolicy: policy
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        coordinator.pausePlayback()

        coordinator.nextTrack()

        await waitUntil { engine.loadCallCount == 2 }
        await waitUntil { engine.playCallCount == 2 }
        await waitUntil {
            if case .failed = coordinator.playbackState { return true }
            return false
        }

        XCTAssertEqual(engine.playCallCount, 2)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertTrue(policy.isTerminalRemoteQuarantined)
    }

    func testPausedSelectionResolutionFailurePreservesPausedCurrentItem()
        async
    {
        let current = PlaybackItem(
            id: "paused-resolution-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "paused-resolution-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: VelacantoNetworkPolicy()
        )
        var resolutionAttempts = 0
        coordinator.configureRequestResolver { _ in
            resolutionAttempts += 1
            throw JellyfinAPIError.unreachable
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolutionAttempts == 1 }
        coordinator.pausePlayback()

        coordinator.nextTrack()

        await waitUntil { resolutionAttempts == 2 }
        await waitUntil { !coordinator.isPreparingQueueTransition }
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(engine.pauseCallCount, 1)
        XCTAssertTrue(engine.hasCurrentItem)
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
    }

    func testPauseDuringReplacementActivationStillPreventsPlayback() async {
        let current = PlaybackItem(
            id: "activation-pause-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "activation-pause-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let audioSession = ControlledAudioSessionController()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: audioSession,
            networkPolicy: VelacantoNetworkPolicy()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        await waitUntilAsync { await audioSession.activationCount() == 1 }
        await audioSession.completeNextActivation()
        await waitUntil { engine.playCallCount == 1 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        coordinator.pausePlayback()

        coordinator.nextTrack()

        await waitUntil { engine.loadCallCount == 2 }
        await waitUntilAsync { await audioSession.activationCount() == 2 }
        coordinator.pausePlayback()
        await audioSession.completeNextActivation()
        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertEqual(engine.playCallCount, 1)
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
    }

    func testRemoteMetadataRapidNextCommitsOnlyFinalCommandedTarget() async {
        let items = (0..<3).map {
            PlaybackItem(
                id: "metadata-rapid-next-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [items[1]] }

        coordinator.nextTrack()
        coordinator.nextTrack()
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [items[1], items[2]])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(
            engine.loadedIdentities,
            [items[0].queueIdentity, items[2].queueIdentity]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, items[2])
        XCTAssertEqual(coordinator.playedQueueItems, [items[0], items[1]])
        XCTAssertTrue(coordinator.upcomingItems.isEmpty)
    }

    func testRemoteMetadataPreviousTimeoutPreservesCommittedCursor() async {
        let previous = PlaybackItem(
            id: "metadata-previous-target",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "metadata-previous-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-previous-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(20),
            networkPolicy: VelacantoNetworkPolicy()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        engine.send(
            .timeChangedForGeneration(
                elapsed: 6,
                duration: 180,
                generation: engine.currentGeneration
            )
        )

        coordinator.previousTrack()
        XCTAssertEqual(engine.seekTimes, [0])
        coordinator.previousTrack()
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(engine.preloadNilCallCount, 0)

        await waitUntil {
            if case .failed = coordinator.playbackState { return true }
            return false
        }

        XCTAssertEqual(resolvedItems, [next, previous])
        XCTAssertEqual(
            engine.loadedIdentities,
            [current.queueIdentity, previous.queueIdentity]
        )
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testRemoteMetadataPreviousResolvesAndCommitsExactlyOnceAfterPlaying()
        async
    {
        let previous = PlaybackItem(
            id: "metadata-previous-ready-target",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "metadata-previous-ready-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-previous-ready-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        engine.send(
            .timeChangedForGeneration(
                elapsed: 6,
                duration: 180,
                generation: engine.currentGeneration
            )
        )

        coordinator.previousTrack()
        XCTAssertEqual(engine.seekTimes, [0])
        coordinator.previousTrack()
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [next, previous])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(
            engine.loadedIdentities,
            [current.queueIdentity, previous.queueIdentity]
        )
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, previous)
        XCTAssertEqual(coordinator.queue?.currentItem, previous)
    }

    func testRemoteMetadataHistorySupersedesWithoutNativeStagedWork() async {
        let history = PlaybackItem(
            id: "metadata-history-target",
            title: "History",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "metadata-history-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-history-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [history, current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }

        coordinator.playHistoryItem(history)
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [next, history])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(engine.preloadNilCallCount, 0)
        XCTAssertEqual(
            engine.loadedIdentities,
            [current.queueIdentity, history.queueIdentity]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, history)
        XCTAssertEqual(coordinator.queue?.currentItem, history)
    }

    func testRemoteMetadataDirectQueueSelectionReusesResolution() async {
        let current = PlaybackItem(
            id: "metadata-direct-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-direct-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }

        coordinator.playQueueItem(next)
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [next])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(engine.preloadNilCallCount, 0)

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
    }

    func testRemoteMetadataNaturalEndUsesDirectCurrentSelection() async {
        let current = PlaybackItem(
            id: "metadata-natural-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "metadata-natural-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }

        engine.send(
            .stateChangedForGeneration(
                .ended,
                generation: engine.currentGeneration
            )
        )
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(resolvedItems, [next])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.advanceCallCount, 0)
        XCTAssertEqual(engine.preloadNonNilCallCount, 0)
        XCTAssertEqual(
            engine.loadedIdentities,
            [current.queueIdentity, next.queueIdentity]
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
    }

    func testLocalFileSpeculativePreparationStillStagesNativeItem() async {
        let current = PlaybackItem(
            id: "local-stage-current",
            title: "Current",
            artist: "Velacanto",
            source: .localFiles
        )
        let next = PlaybackItem(
            id: "local-stage-next",
            title: "Next",
            artist: "Velacanto",
            source: .localFiles
        )
        let factoryProbe = PlaybackPlayerItemFactoryProbe()
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return factoryProbe.request(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .localFile),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadNonNilCallCount == 1 }

        XCTAssertEqual(resolvedItems, [next])
        XCTAssertEqual(factoryProbe.creationCount, 1)
        XCTAssertEqual(engine.preloadedURLs.count, 1)

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: engine.currentGeneration
            )
        )
        proveForwardProgress(engine: engine)

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, next)
    }

    func testPausedLocalPreparedNextStartsAdvancedItemPlayback() async {
        let current = PlaybackItem(
            id: "paused-local-current",
            title: "Current",
            artist: "Velacanto",
            source: .localFiles
        )
        let next = PlaybackItem(
            id: "paused-local-next",
            title: "Next",
            artist: "Velacanto",
            source: .localFiles
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: VelacantoNetworkPolicy()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .localFile),
            queueItems: [current, next],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadNonNilCallCount == 1 }
        coordinator.pausePlayback()

        coordinator.nextTrack()

        await waitUntil { engine.advanceCallCount == 1 }
        await waitUntil { engine.playCallCount == 2 }
        XCTAssertEqual(engine.playCallCount, 2)
        XCTAssertEqual(coordinator.currentItem, current)
        makePlaybackStable(coordinator: coordinator, engine: engine)
        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertEqual(coordinator.queue?.currentItem, next)
    }

    func testTappingPreloadedNextQueueItemUsesTheExistingPlaybackRequest()
        async throws
    {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directStream
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )

        // Speculative PlaybackInfo must not compete with current-item startup.
        XCTAssertTrue(resolvedItems.isEmpty)
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        coordinator.playQueueItem(next)

        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == next }
        XCTAssertEqual(resolvedItems, [next])
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testStablePlaybackPreparesOnlyImmediateSuccessor()
        async throws
    {
        let items = (0..<4).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directStream
            )
        }
        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems.count == 1 }

        XCTAssertEqual(resolvedItems, [items[1]])
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        coordinator.playQueueItem(items[3])

        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == items[3] }
        XCTAssertEqual(resolvedItems, [items[1], items[3]])
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testAppendingToQueuePreservesPreparedImmediateSuccessor()
        async throws
    {
        let items = (0..<3).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let appended = PlaybackItem(
            id: "appended",
            title: "Appended",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directStream
            )
        }
        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [items[1]] }

        coordinator.playLast(appended)
        await Task.yield()

        XCTAssertEqual(resolvedItems, [items[1]])
        XCTAssertTrue(engine.preloadedURLs.isEmpty)
        XCTAssertEqual(coordinator.upcomingItems, [items[1], items[2], appended])
    }

    func testPlayNextCommitsLocallyAndPreparesOnlyInsertedSuccessor()
        async throws
    {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let inserted = PlaybackItem(
            id: "inserted",
            title: "Inserted",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directStream)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)

        coordinator.playNext(inserted)
        await waitUntil { resolvedItems == [inserted] }

        XCTAssertEqual(coordinator.upcomingItems, [inserted])
        XCTAssertEqual(resolvedItems, [inserted])
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        coordinator.nextTrack()

        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == inserted }
        XCTAssertEqual(resolvedItems, [inserted])
        XCTAssertEqual(coordinator.playbackState, .playing)
    }

    func testFailedStagedNextPreservesCurrentItemAndQueueCursor() async {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        XCTAssertEqual(engine.advanceCallCount, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])

        engine.send(.failedToAdvanceToNextItem(.timeout))

        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(resolvedItems, [next])
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testTwoConsecutiveSuccessorsRequireFreshGenerationStability()
        async
    {
        let items = (0..<3).map {
            PlaybackItem(
                id: "consecutive-\($0)",
                title: "Consecutive \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        XCTAssertEqual(engine.advanceCallCount, 1)
        engine.send(.advancedToNextItem)
        await Task.yield()
        XCTAssertEqual(coordinator.currentItem, items[0])
        engine.send(.stateChanged(.playing))
        proveForwardProgress(engine: engine)
        await waitUntil { coordinator.currentItem == items[1] }

        await Task.yield()
        XCTAssertEqual(resolvedItems, [items[1]])
        XCTAssertEqual(engine.preloadedURLs.count, 1)

        await Task.yield()
        XCTAssertEqual(engine.preloadedURLs.count, 1)

        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        await waitUntil { engine.preloadedURLs.count == 2 }
        XCTAssertEqual(resolvedItems, [items[1], items[2]])

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 2 }
        XCTAssertEqual(engine.advanceCallCount, 2)
        engine.send(.advancedToNextItem)
        await Task.yield()
        XCTAssertEqual(coordinator.currentItem, items[1])
        engine.send(.stateChanged(.playing))
        proveForwardProgress(engine: engine)
        await waitUntil { coordinator.currentItem == items[2] }

        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(coordinator.playedQueueItems, [items[0], items[1]])
        XCTAssertTrue(coordinator.upcomingItems.isEmpty)
    }

    func testFailedPreparedSuccessorUsesForcedPlaybackInfoFallbackOnce()
        async
    {
        let current = PlaybackItem(
            id: "fallback-current",
            title: "Fallback Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "fallback-next",
            title: "Fallback Next",
            artist: "Velacanto",
            source: .jellyfin,
            container: "flac"
        )
        let fallbackRequest = PlaybackRequest(
            item: next,
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/fallback-playback-info.caf")
            ),
            transportKind: .directStream
        )
        let fallbackRecorder = AsyncInvocationRecorder()
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            PlaybackRequest(
                item: item,
                asset: PlaybackAsset(
                    url: URL(fileURLWithPath: "/tmp/direct-file.caf")
                ),
                transportKind: .localFile,
                forcedPlaybackInfoFallback: {
                    await fallbackRecorder.record()
                    return fallbackRequest
                }
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        XCTAssertEqual(engine.advanceCallCount, 1)
        engine.send(.failedToAdvanceToNextItem(.timeout))

        await waitUntilAsync {
            await fallbackRecorder.snapshot() == 1
                && engine.loadCallCount == 2
        }
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])

        engine.send(.stateChanged(.failed("fallback failed")))
        await Task.yield()

        let fallbackInvocationCount = await fallbackRecorder.snapshot()
        XCTAssertEqual(fallbackInvocationCount, 1)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testPreparedSuccessorFallbackReclaimsNetworkDemandAfterPlayerStops()
        async
    {
        let current = PlaybackItem(
            id: "fallback-demand-current",
            title: "Fallback Demand Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "fallback-demand-next",
            title: "Fallback Demand Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let fallbackProbe = PlaybackRecoveryFallbackProbe()
        let fallbackRequest = playbackRequest(
            for: next,
            transportKind: .transcoding
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            stopStateDelivery: .deferredPaused
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(
                for: item,
                transportKind: .localFile,
                forcedPlaybackInfoFallback: {
                    await fallbackProbe.waitForResolution()
                }
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        await waitUntil { engine.advanceCallCount == 1 }
        engine.send(.failedToAdvanceToNextItem(.timeout))
        await waitUntilAsync { await fallbackProbe.hasStarted }
        await waitUntil { engine.deferredStopStateDeliveryCount == 1 }

        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertEqual(coordinator.currentItem, current)

        await fallbackProbe.resolve(with: fallbackRequest)
        await waitUntil { engine.loadCallCount == 2 }
        engine.send(.stateChanged(.playing))
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, next)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)
    }

    func testRapidNextLoadsAndCommitsOnlyTheFinalTarget() async {
        let items = (0..<3).map {
            PlaybackItem(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Velacanto",
                source: .jellyfin
            )
        }
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false,
            automaticallyMarksPreparedReady: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: items[0], transportKind: .directPlay),
            queueItems: items,
            context: .songs
        )
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { engine.preloadedURLs.count == 1 }

        coordinator.nextTrack()
        coordinator.nextTrack()

        await waitUntil { engine.loadCallCount == 2 }
        XCTAssertEqual(coordinator.currentItem, items[0])
        XCTAssertEqual(coordinator.upcomingItems, [items[1], items[2]])
        XCTAssertEqual(engine.advanceCallCount, 0)
        XCTAssertEqual(
            engine.loadedIdentities,
            [items[0].queueIdentity, items[2].queueIdentity]
        )

        engine.send(.stateChanged(.playing))
        proveForwardProgress(engine: engine)

        XCTAssertEqual(coordinator.currentItem, items[2])
        XCTAssertEqual(coordinator.playedQueueItems, [items[0], items[1]])
        XCTAssertTrue(engine.preloadReceivedNil)
        XCTAssertEqual(engine.loadCallCount, 2)
    }

    func testNaturalEndDoesNotSupersedeInFlightUserSelection() async throws {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let automaticNext = PlaybackItem(
            id: "automatic-next",
            title: "Automatic Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let selected = PlaybackItem(
            id: "selected",
            title: "Selected",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var requestedItem: PlaybackItem?
        var continuation: CheckedContinuation<PlaybackRequest, Never>?
        coordinator.configureRequestResolver { item in
            requestedItem = item
            return await withCheckedContinuation { pending in
                continuation = pending
            }
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, automaticNext, selected],
            context: .songs
        )

        coordinator.playQueueItem(selected)
        await waitUntil { continuation != nil }
        engine.send(.stateChanged(.ended))

        XCTAssertEqual(requestedItem, selected)
        XCTAssertEqual(coordinator.currentItem, current)
        continuation?.resume(
            returning: playbackRequest(
                for: selected,
                transportKind: .directStream
            )
        )

        await waitUntil { coordinator.currentItem == selected }
        XCTAssertEqual(
            coordinator.queue?.items,
            [current, automaticNext, selected]
        )
    }

    func testHistoryQueueReplacementCanImmediatelyReturnToDisplacedTrack()
        async throws
    {
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let first = PlaybackItem(
            id: "first",
            title: "First",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server|user"
        )
        let second = PlaybackItem(
            id: "second",
            title: "Second",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: "server|user"
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolverCallCount = 0
        coordinator.configureRequestResolver { item in
            resolverCallCount += 1
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }

        coordinator.play(
            playbackRequest(for: first, transportKind: .directPlay),
            account: account
        )
        coordinator.play(
            playbackRequest(for: second, transportKind: .directPlay),
            account: account
        )

        XCTAssertEqual(coordinator.historyItems, [first])
        coordinator.playQueueItem(first)
        await waitUntil { engine.loadCallCount == 3 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == first }

        XCTAssertEqual(coordinator.historyItems, [])
        XCTAssertEqual(coordinator.upcomingItems, [second])
        coordinator.playQueueItem(second)
        await waitUntil { engine.loadCallCount == 4 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == second }

        XCTAssertEqual(resolverCallCount, 2)
        XCTAssertEqual(coordinator.queue?.items, [first, second])
        XCTAssertEqual(coordinator.historyItems, [first])
        XCTAssertEqual(engine.loadCallCount, 4)
    }

    func testStalledItemIsAbandonedAndAQueuedSelectionCanReplaceIt()
        async throws
    {
        let stalled = PlaybackItem(
            id: "stalled",
            title: "Stalled",
            artist: "Velacanto",
            source: .jellyfin
        )
        let replacement = PlaybackItem(
            id: "replacement",
            title: "Replacement",
            artist: "Velacanto",
            source: .localFiles
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(5)
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .localFile)
        }
        coordinator.play(
            playbackRequest(for: stalled, transportKind: .directPlay),
            queueItems: [stalled, replacement],
            context: .songs
        )

        await waitUntilAsync {
            if case .failed = coordinator.playbackState {
                return !engine.hasCurrentItem
            }
            return false
        }

        XCTAssertEqual(coordinator.currentItem, stalled)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)

        coordinator.play(
            playbackRequest(for: replacement, transportKind: .localFile)
        )
        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == replacement }

        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertTrue(engine.hasCurrentItem)
    }

    func testKnownNativeStartupDeadlineFailsOnceWithoutPlaybackInfoFallback()
        async
    {
        let current = PlaybackItem(
            id: "direct-file-stalled",
            title: "Direct File Stalled",
            artist: "Velacanto",
            source: .jellyfin,
            duration: 180,
            container: "flac"
        )
        let next = PlaybackItem(
            id: "direct-file-next",
            title: "Direct File Next",
            artist: "Velacanto",
            source: .jellyfin,
            duration: 180,
            container: "flac"
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(20)
        )
        var playbackInfoCallCount = 0
        coordinator.configureRequestResolver { item in
            playbackInfoCallCount += 1
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, next],
            context: .songs
        )
        coordinator.seek(toTime: 42)

        XCTAssertTrue(coordinator.hasPlaybackNetworkStartupDemand)

        await waitUntilAsync {
            if case .failed = coordinator.playbackState {
                return !engine.hasCurrentItem
            }
            return false
        }

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(playbackInfoCallCount, 0)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.currentItem, current)
        XCTAssertEqual(coordinator.upcomingItems, [next])
        XCTAssertEqual(coordinator.elapsed, 42)
        XCTAssertFalse(coordinator.hasPlaybackNetworkStartupDemand)

        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(playbackInfoCallCount, 0)
    }

    func testPostStartWaitingStateRearmsStalledItemRecovery() async {
        let item = PlaybackItem(
            id: "post-start-stall",
            title: "Post-start Stall",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            itemRecoveryDeadline: .milliseconds(5)
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(playbackRequest(for: item, transportKind: .directPlay))
        await waitUntil { engine.playCallCount == 1 }
        engine.send(.stateChanged(.playing))

        engine.send(.stateChanged(.waiting))

        await waitUntilAsync {
            if case .failed = coordinator.playbackState {
                return !engine.hasCurrentItem
            }
            return false
        }
        XCTAssertEqual(engine.loadCallCount, 1)
        XCTAssertEqual(engine.stopCallCount, 1)
    }

    func testDistantQueueSelectionPublishesPreparingRowUntilCommit() async {
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let selected = PlaybackItem(
            id: "selected",
            title: "Selected",
            artist: "Velacanto",
            source: .jellyfin
        )
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(engine: engine)
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current, selected],
            context: .songs
        )

        coordinator.playQueueItem(selected)
        await waitUntil { engine.loadCallCount == 2 }

        XCTAssertEqual(
            coordinator.preparingQueueItemIdentity,
            selected.queueIdentity
        )
        XCTAssertEqual(coordinator.preparingQueueItem, selected)
        XCTAssertTrue(coordinator.isPreparingQueueTransition)
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == selected }
        XCTAssertNil(coordinator.preparingQueueItemIdentity)
        XCTAssertNil(coordinator.preparingQueueItem)
        XCTAssertFalse(coordinator.isPreparingQueueTransition)
    }

    func testColdQueueSelectionFailureSettlesWithoutReplacingQueue()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let current = PlaybackItem(
            id: "restored-current",
            title: "Restored Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let selected = PlaybackItem(
            id: "restored-selected",
            title: "Restored Selected",
            artist: "Velacanto",
            source: .jellyfin
        )
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [current, selected],
                currentItemID: current.id,
                context: .songs
            ),
            elapsed: 12,
            duration: 180,
            account: account,
            savedAt: Date()
        )
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            self.playbackRequest(for: item, transportKind: .directPlay)
        }
        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )

        coordinator.playQueueItem(selected)
        await waitUntil { engine.loadCallCount == 1 }
        XCTAssertEqual(coordinator.playbackState, .loading)
        XCTAssertEqual(coordinator.preparingQueueItem, selected)

        engine.send(.stateChanged(.failed("selection failed")))

        if case .failed = coordinator.playbackState {
            // Expected clean terminal presentation.
        } else {
            XCTFail("Expected a cold selection failure to settle as failed.")
        }
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [current, selected])
        XCTAssertNil(coordinator.preparingQueueItem)
        XCTAssertFalse(engine.hasCurrentItem)
        XCTAssertEqual(engine.stopCallCount, 1)
        XCTAssertEqual(engine.advanceCallCount, 0)

        XCTAssertEqual(coordinator.queue?.items, [current, selected])
        XCTAssertEqual(coordinator.historyItems, [])
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testSupersedingColdHistorySelectionCancelsForcedFallback() async {
        let history = PlaybackItem(
            id: "cold-history",
            title: "Cold History",
            artist: "Velacanto",
            source: .jellyfin,
            container: "flac"
        )
        let current = PlaybackItem(
            id: "cold-current",
            title: "Cold Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let final = PlaybackItem(
            id: "cold-final",
            title: "Cold Final",
            artist: "Velacanto",
            source: .jellyfin
        )
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let stateStore = RecordingNowPlayingStateStore()
        stateStore.state = SavedNowPlayingState(
            queue: PlaybackQueue(
                items: [history, current, final],
                currentItemID: current.id,
                context: .songs
            ),
            elapsed: 0,
            duration: 180,
            account: account,
            savedAt: Date()
        )
        let fallbackProbe = PlaybackFallbackCancellationProbe()
        let engine = RecordingAudioPlayerEngine(
            automaticallyCompletesAdvance: false
        )
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        coordinator.configureRequestResolver { item in
            if item == history {
                return self.playbackRequest(
                    for: item,
                    transportKind: .directPlay,
                    forcedPlaybackInfoFallback: {
                        try await fallbackProbe.waitForCancellation()
                    }
                )
            }
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )

        coordinator.playHistoryItem(history)
        await waitUntil { engine.loadCallCount == 1 }
        engine.send(
            .stateChangedForGeneration(
                .failed("cold history failed"),
                generation: engine.currentGeneration
            )
        )
        await waitUntilAsync { await fallbackProbe.hasStarted }

        coordinator.playQueueItem(final)

        await waitUntilAsync { await fallbackProbe.wasCancelled }
        XCTAssertNil(coordinator.preparingQueueItem)
        XCTAssertEqual(coordinator.currentItem, current)
        XCTAssertEqual(coordinator.queue?.items, [history, current, final])
        XCTAssertEqual(engine.loadCallCount, 1)
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

    func testRepeatedPlayNextRestoresAndPlaysLatestSuccessorAfterRelaunch()
        async
    {
        let stateStore = RecordingNowPlayingStateStore()
        let account = PlaybackAccount(serverID: "server", userID: "user")
        let accountScope = "server|user"
        let current = PlaybackItem(
            id: "current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let first = PlaybackItem(
            id: "first",
            title: "First",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let second = PlaybackItem(
            id: "second",
            title: "Second",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let third = PlaybackItem(
            id: "third",
            title: "Third",
            artist: "Velacanto",
            source: .jellyfin,
            accountScope: accountScope
        )
        let initial = AudioPlaybackCoordinator(
            engine: RecordingAudioPlayerEngine(),
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        initial.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [current],
            context: .songs,
            account: account
        )
        initial.playNext(first)
        initial.playNext(second)

        XCTAssertEqual(stateStore.state?.queue.upcomingItems, [second, first])

        let restoredEngine = RecordingAudioPlayerEngine()
        let restored = AudioPlaybackCoordinator(
            engine: restoredEngine,
            nowPlayingStateStore: stateStore,
            audioSessionController: ImmediateAudioSessionController()
        )
        var resolvedItems: [PlaybackItem] = []
        restored.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(for: item, transportKind: .directStream)
        }
        restored.restoreSavedState(
            serverID: account.serverID,
            userID: account.userID
        )
        restored.resumePlayback()
        await waitUntil { restoredEngine.loadCallCount == 1 }
        makePlaybackStable(coordinator: restored, engine: restoredEngine)
        await waitUntil {
            let resolvedIDs = Set(resolvedItems.map(\.id))
            return resolvedIDs.isSuperset(of: [current.id, second.id])
        }
        XCTAssertTrue(restoredEngine.preloadedURLs.isEmpty)

        restored.nextTrack()
        await waitUntil { restoredEngine.loadCallCount == 2 }
        makePlaybackStable(coordinator: restored, engine: restoredEngine)
        await waitUntil { restored.currentItem == second }
        XCTAssertEqual(restored.playbackState, .playing)

        restored.playNext(third)
        await waitUntil { resolvedItems.contains(third) }
        XCTAssertTrue(restoredEngine.preloadedURLs.isEmpty)
        restored.nextTrack()
        await waitUntil { restoredEngine.loadCallCount == 3 }
        makePlaybackStable(coordinator: restored, engine: restoredEngine)
        await waitUntil { restored.currentItem == third }

        XCTAssertEqual(
            Set(resolvedItems.map(\.id)),
            [current.id, second.id, third.id]
        )
        XCTAssertEqual(restored.upcomingItems, [first])
        XCTAssertEqual(restored.playbackState, .playing)
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
        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
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
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { expansionContinuation != nil }

        engine.send(.stateChanged(.ended))
        expansionContinuation?.resume(returning: [pagedItem])
        await waitUntil { engine.loadCallCount == 2 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { coordinator.currentItem == pagedItem }

        XCTAssertEqual(coordinator.currentItem, pagedItem)
        XCTAssertEqual(engine.loadCallCount, 2)
        XCTAssertEqual(engine.advanceCallCount, 0)
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
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { expansionContinuation != nil }

        coordinator.playNext(originalNext)
        await Task.yield()
        XCTAssertTrue(engine.preloadedURLs.isEmpty)

        coordinator.playNext(explicitNext)
        await Task.yield()
        XCTAssertTrue(engine.preloadedURLs.isEmpty)
        coordinator.removeUpcomingItem(originalNext)
        expansionContinuation?.resume(returning: [latePage])
        await Task.yield()

        XCTAssertEqual(coordinator.upcomingItems, [explicitNext])
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

    func testPlaybackDiagnosticJournalSurvivesRelaunchAndStaysBounded() throws {
        let fileURL = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoPlaybackJournal-\(UUID().uuidString).log"
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let firstLaunch = PlaybackDiagnosticJournal(
            fileURL: fileURL,
            maximumByteCount: 1_024
        )
        firstLaunch.record("queue-edit phase=committed revision=1")

        let nextLaunch = PlaybackDiagnosticJournal(
            fileURL: fileURL,
            maximumByteCount: 1_024
        )
        XCTAssertTrue(
            nextLaunch.entries(limit: 10).contains {
                $0.contains("queue-edit phase=committed revision=1")
            }
        )

        for revision in 2...100 {
            nextLaunch.record(
                "queue-edit phase=committed revision=\(revision) padding=diagnostic"
            )
        }
        let data = try Data(contentsOf: fileURL)
        XCTAssertLessThanOrEqual(data.count, 1_024)
        XCTAssertTrue(
            nextLaunch.entries(limit: 10).last?.contains("revision=100") == true
        )
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
        let item = PlaybackItem(
            id: "buffer-state",
            title: "Buffer State",
            artist: "Velacanto",
            source: .localFiles
        )
        let state = PlaybackBufferState(
            loadedThrough: 20,
            isEmpty: false,
            isLikelyToKeepUp: true
        )

        coordinator.play(
            playbackRequest(for: item, transportKind: .localFile)
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

    func testVisibleArtworkDoesNotAmplifyTransientFailure() async throws {
        RecoveringArtworkURLProtocol.requestCount = 0
        RecoveringArtworkURLProtocol.firstFailureCode = .networkConnectionLost
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveringArtworkURLProtocol.self]
        let repository = ArtworkRepository(
            session: URLSession(configuration: configuration)
        )
        let key = ArtworkKey(
            serverID: UUID().uuidString,
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )
        let url = try XCTUnwrap(URL(string: "https://artwork.test/recover"))

        let image = await repository.image(for: key, intent: .visible) {
            URLRequest(url: url)
        }

        XCTAssertNil(image)
        XCTAssertEqual(RecoveringArtworkURLProtocol.requestCount, 1)
    }

    func testVisibleArtworkTimeoutDoesNotRetryAndAmplifyLoad() async throws {
        RecoveringArtworkURLProtocol.requestCount = 0
        RecoveringArtworkURLProtocol.firstFailureCode = .timedOut
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveringArtworkURLProtocol.self]
        let repository = ArtworkRepository(
            session: URLSession(configuration: configuration)
        )
        let key = ArtworkKey(
            serverID: UUID().uuidString,
            userID: "user",
            itemID: "item",
            imageTag: "tag",
            sizeBucket: 128
        )
        let url = try XCTUnwrap(URL(string: "https://artwork.test/timeout"))

        let image = await repository.image(for: key, intent: .visible) {
            URLRequest(url: url)
        }

        XCTAssertNil(image)
        XCTAssertEqual(RecoveringArtworkURLProtocol.requestCount, 1)
    }

    func testProductionArtworkTransportKeepsFailureLocalToArtwork() async throws {
        RecoveringArtworkURLProtocol.requestCount = 0
        RecoveringArtworkURLProtocol.firstFailureCode = .timedOut
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveringArtworkURLProtocol.self]
        let transport = VelacantoNetworkTransport(
            makeSession: { URLSession(configuration: configuration) }
        )
        let repository = ArtworkRepository(transport: transport)
        let serverID = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://artwork.test/production"))

        let firstImage = await repository.image(
            for: ArtworkKey(
                serverID: serverID,
                userID: "user",
                itemID: "first",
                imageTag: "tag",
                sizeBucket: 128
            ),
            intent: .visible
        ) {
            URLRequest(url: url)
        }
        let locallySuppressedImage = await repository.image(
            for: ArtworkKey(
                serverID: serverID,
                userID: "user",
                itemID: "second",
                imageTag: "tag",
                sizeBucket: 128
            ),
            intent: .visible
        ) {
            URLRequest(url: url)
        }

        XCTAssertNil(firstImage)
        XCTAssertNil(locallySuppressedImage)
        XCTAssertEqual(RecoveringArtworkURLProtocol.requestCount, 1)

        // The same origin transport remains available to a playback request;
        // the failed artwork load did not open its circuit breaker.
        _ = try await transport.data(for: URLRequest(url: url))
        XCTAssertEqual(RecoveringArtworkURLProtocol.requestCount, 2)
    }

    func testArtworkSecurityFailureSuppressesQueuedHandshakeCascade() async throws {
        RecoveringArtworkURLProtocol.requestCount = 0
        RecoveringArtworkURLProtocol.firstFailureCode = .secureConnectionFailed
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveringArtworkURLProtocol.self]
        let repository = ArtworkRepository(
            session: URLSession(configuration: configuration)
        )
        let serverID = UUID().uuidString
        let url = try XCTUnwrap(URL(string: "https://artwork.test/security"))

        let tasks = (0..<4).map { index in
            Task { @MainActor in
                await repository.image(
                    for: ArtworkKey(
                        serverID: serverID,
                        userID: "user",
                        itemID: "item-\(index)",
                        imageTag: "tag",
                        sizeBucket: 128
                    ),
                    intent: .visible
                ) {
                    URLRequest(url: url)
                }
            }
        }

        for task in tasks {
            let image = await task.value
            XCTAssertNil(image)
        }
        XCTAssertEqual(RecoveringArtworkURLProtocol.requestCount, 1)
    }

    func testVisibleArtworkPromotesAheadOfSpeculativeWork() async {
        let policy = VelacantoNetworkPolicy()
        let gate = NetworkPolicyGate()
        let held = Task {
            try? await policy.perform(priority: .catalog, key: "held") {
                await gate.wait()
            }
        }
        await waitUntilAsync { await gate.hasStarted }

        let (order, continuation) = AsyncStream<String>.makeStream()
        let speculative = Task {
            try? await policy.perform(
                priority: .speculative,
                key: "speculative"
            ) {
                continuation.yield("speculative")
            }
        }
        while !policy.hasQueuedRequest(key: "speculative") {
            await Task.yield()
        }
        let visible = Task {
            try? await policy.perform(priority: .artwork, key: "visible") {
                continuation.yield("visible")
            }
        }
        while !policy.hasQueuedRequest(key: "visible") {
            await Task.yield()
        }
        await gate.open()

        var iterator = order.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, "visible")
        let second = await iterator.next()
        XCTAssertEqual(second, "speculative")
        _ = await (held.value, speculative.value, visible.value)
    }

    func testPlaybackStartupWaitsForCancelledBackgroundPermitToQuiesce()
        async
    {
        let policy = VelacantoNetworkPolicy()
        let backgroundGate = NetworkPolicyGate()
        let transitionRecorder = AsyncInvocationRecorder()
        let background = Task {
            try? await policy.perform(priority: .reporting) {
                await backgroundGate.wait()
            }
        }
        await waitUntilAsync { await backgroundGate.hasStarted }

        let startupToken = UUID()
        policy.beginPlaybackStartup(startupToken)
        let transition = Task {
            try? await policy.waitUntilPlaybackStartupQuiescent(startupToken)
            await transitionRecorder.record()
        }

        for _ in 0..<100 {
            await Task.yield()
        }
        let transitionCountBeforeRelease =
            await transitionRecorder.snapshot()
        XCTAssertEqual(transitionCountBeforeRelease, 0)

        await backgroundGate.open()
        await waitUntilAsync { await transitionRecorder.snapshot() == 1 }
        _ = await (background.value, transition.value)
        policy.endPlaybackStartup(startupToken)
    }

    func testCancelledNetworkWaiterDoesNotInflatePermits() async {
        let policy = VelacantoNetworkPolicy()
        let gate = NetworkPolicyGate()
        let first = Task {
            try? await policy.perform(priority: .catalog, key: "first") {
                await gate.wait()
            }
        }
        await waitUntilAsync { await gate.hasStarted }
        let cancelledTask = Task {
            do {
                try await policy.perform(priority: .artwork, key: "cancelled") {}
                return true
            } catch {
                return false
            }
        }
        await waitUntil {
            policy.hasQueuedRequest(key: "cancelled")
        }
        cancelledTask.cancel()
        let acquiredCancelled = await cancelledTask.value
        XCTAssertFalse(acquiredCancelled)

        let finalTask = Task {
            do {
                try await policy.perform(priority: .artwork, key: "final") {}
                return true
            } catch {
                return false
            }
        }
        await waitUntil {
            policy.hasQueuedRequest(key: "final")
        }
        await gate.open()
        let acquiredFinal = await finalTask.value
        XCTAssertTrue(acquiredFinal)
        _ = await first.value
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

    func testCancelledNetworkWaiterIsRemovedBeforeRelease() async {
        let policy = VelacantoNetworkPolicy()
        let gate = NetworkPolicyGate()
        let held = Task {
            try? await policy.perform(priority: .catalog, key: "held") {
                await gate.wait()
            }
        }
        await waitUntilAsync { await gate.hasStarted }
        let queued = Task {
            try? await policy.perform(priority: .speculative, key: "queued") {}
        }
        while !policy.hasQueuedRequest(key: "queued") {
            await Task.yield()
        }

        queued.cancel()
        _ = await queued.value
        while policy.hasQueuedRequest(key: "queued") {
            await Task.yield()
        }

        await gate.open()
        _ = await held.value
    }

    func testImmediatelyCancelledNetworkWaitersCannotStrandAdmission() async {
        let policy = VelacantoNetworkPolicy()
        let gate = NetworkPolicyGate()
        let held = Task {
            try? await policy.perform(priority: .catalog, key: "held") {
                await gate.wait()
            }
        }
        await waitUntilAsync { await gate.hasStarted }

        let cancelledTasks = (0..<100).map { index in
            let task = Task {
                try? await policy.perform(
                    priority: .speculative,
                    key: "cancelled-\(index)"
                ) {}
            }
            task.cancel()
            return task
        }
        for task in cancelledTasks {
            _ = await task.value
        }

        let final = Task {
            do {
                try await policy.perform(priority: .artwork, key: "final") {}
                return true
            } catch {
                return false
            }
        }
        await gate.open()

        let finalAcquired = await final.value
        XCTAssertTrue(finalAcquired)
        _ = await held.value
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

    private enum PausedRemoteQueueSelection: String, CaseIterable {
        case next
        case previous
        case history
        case live
    }

    private func assertPausedRemoteQueueSelectionStartsPlayback(
        _ selection: PausedRemoteQueueSelection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let previous = PlaybackItem(
            id: "paused-\(selection.rawValue)-previous",
            title: "Previous",
            artist: "Velacanto",
            source: .jellyfin
        )
        let current = PlaybackItem(
            id: "paused-\(selection.rawValue)-current",
            title: "Current",
            artist: "Velacanto",
            source: .jellyfin
        )
        let next = PlaybackItem(
            id: "paused-\(selection.rawValue)-next",
            title: "Next",
            artist: "Velacanto",
            source: .jellyfin
        )
        let target: PlaybackItem
        switch selection {
        case .next, .live:
            target = next
        case .previous, .history:
            target = previous
        }
        let engine = RecordingAudioPlayerEngine()
        let coordinator = AudioPlaybackCoordinator(
            engine: engine,
            audioSessionController: ImmediateAudioSessionController(),
            networkPolicy: VelacantoNetworkPolicy()
        )
        var resolvedItems: [PlaybackItem] = []
        coordinator.configureRequestResolver { item in
            resolvedItems.append(item)
            return self.playbackRequest(
                for: item,
                transportKind: .directPlay
            )
        }
        coordinator.play(
            playbackRequest(for: current, transportKind: .directPlay),
            queueItems: [previous, current, next],
            context: .songs
        )
        await waitUntil { engine.playCallCount == 1 }
        makePlaybackStable(coordinator: coordinator, engine: engine)
        await waitUntil { resolvedItems == [next] }
        coordinator.pausePlayback()
        XCTAssertEqual(
            coordinator.playbackState,
            .paused,
            selection.rawValue,
            file: file,
            line: line
        )

        switch selection {
        case .next:
            coordinator.nextTrack()
        case .previous:
            coordinator.previousTrack()
        case .history:
            coordinator.playHistoryItem(previous)
        case .live:
            coordinator.playQueueItem(next)
        }

        await waitUntil { engine.loadCallCount == 2 }
        await waitUntil { engine.playCallCount == 2 }
        XCTAssertEqual(
            engine.playCallCount,
            2,
            selection.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            coordinator.currentItem,
            current,
            selection.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            coordinator.queue?.currentItem,
            current,
            selection.rawValue,
            file: file,
            line: line
        )

        makePlaybackStable(coordinator: coordinator, engine: engine)

        XCTAssertEqual(
            coordinator.currentItem,
            target,
            selection.rawValue,
            file: file,
            line: line
        )
        XCTAssertEqual(
            coordinator.queue?.currentItem,
            target,
            selection.rawValue,
            file: file,
            line: line
        )
    }

    private func playbackRequest(
        for item: PlaybackItem,
        transportKind: PlaybackTransportKind,
        forcedPlaybackInfoFallback:
            (@Sendable () async throws -> PlaybackRequest)? = nil,
        reporter: (any PlaybackLifecycleReporting)? = nil
    ) -> PlaybackRequest {
        PlaybackRequest(
            item: item,
            asset: PlaybackAsset(
                url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
            ),
            transportKind: transportKind,
            reporter: reporter,
            forcedPlaybackInfoFallback: forcedPlaybackInfoFallback
        )
    }

    private func makePlaybackStable(
        coordinator: AudioPlaybackCoordinator,
        engine: RecordingAudioPlayerEngine
    ) {
        engine.send(
            .stateChangedForGeneration(
                .playing,
                generation: engine.currentGeneration
            )
        )
        engine.send(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: 20,
                    isEmpty: false,
                    isLikelyToKeepUp: true
                )
            )
        )
        proveForwardProgress(engine: engine)
    }

    private func proveForwardProgress(
        engine: RecordingAudioPlayerEngine,
        startingAt baseline: TimeInterval = 0,
        duration: TimeInterval = 180
    ) {
        engine.send(
            .timeChangedForGeneration(
                elapsed: baseline,
                duration: duration,
                generation: engine.currentGeneration
            )
        )
        engine.send(
            .timeChangedForGeneration(
                elapsed: baseline + 0.25,
                duration: duration,
                generation: engine.currentGeneration
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
        reporter: (any PlaybackLifecycleReporting)? = nil,
        forcedPlaybackInfoFallback:
            (@Sendable () async throws -> PlaybackRequest)? = nil
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
            reporter: reporter,
            forcedPlaybackInfoFallback: forcedPlaybackInfoFallback
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
    attempts: Int = 1_000,
    condition: () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

private func testQueueIdentity(
    _ itemID: String
) -> PlaybackItemQueueIdentity {
    PlaybackItemQueueIdentity(
        source: .jellyfin,
        accountScope: nil,
        itemID: itemID
    )
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

private final class AlwaysUnknownPlayerItem: AVPlayerItem {
    override var status: AVPlayerItem.Status { .unknown }
}

private final class AlwaysReadyPlayerItem: AVPlayerItem {
    override var status: AVPlayerItem.Status { .readyToPlay }
}

@MainActor
private final class PlaybackPlayerItemFactoryProbe {
    private(set) var creationCount = 0

    func request(
        for item: PlaybackItem,
        transportKind: PlaybackTransportKind
    ) -> PlaybackRequest {
        PlaybackRequest(
            item: item,
            asset: PlaybackAsset(
                playerItemFactory: { [weak self] in
                    self?.creationCount += 1
                    return AVPlayerItem(
                        url: URL(fileURLWithPath: "/tmp/\(item.id).caf")
                    )
                }
            ),
            transportKind: transportKind
        )
    }
}

@MainActor
private final class RecordingAudioPlayerEngine: AudioPlayerEngine {
    enum StopStateDelivery {
        case none
        case deferredPaused
    }

    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)?
    var terminalFailureKind: AudioPlayerTerminalFailureKind?
    private(set) var currentGeneration = 0
    private(set) var preparedNextItemState = AudioPlayerPreparedItemState(
        identity: nil,
        generation: 0,
        phase: .absent
    )
    private(set) var hasCurrentItem = false
    private(set) var loadCallCount = 0
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var advanceCallCount = 0
    private(set) var loadedIdentities: [PlaybackItemQueueIdentity] = []
    private(set) var seekTimes: [TimeInterval] = []
    private(set) var preloadedURLs: [URL] = []
    private(set) var preloadNonNilCallCount = 0
    private(set) var preloadNilCallCount = 0
    private(set) var preloadReceivedNil = false
    private(set) var deferredStopStateDeliveryCount = 0
    var automaticallyCompletesAdvance: Bool
    var automaticallyMarksPreparedReady: Bool
    var stopStateDelivery: StopStateDelivery

    init(
        automaticallyCompletesAdvance: Bool = true,
        automaticallyMarksPreparedReady: Bool = true,
        stopStateDelivery: StopStateDelivery = .none
    ) {
        self.automaticallyCompletesAdvance = automaticallyCompletesAdvance
        self.automaticallyMarksPreparedReady = automaticallyMarksPreparedReady
        self.stopStateDelivery = stopStateDelivery
    }

    func load(
        _ item: AVPlayerItem,
        identity: PlaybackItemQueueIdentity
    ) {
        currentGeneration += 1
        hasCurrentItem = true
        loadCallCount += 1
        loadedIdentities.append(identity)
    }

    func preload(
        _ item: AVPlayerItem?,
        identity: PlaybackItemQueueIdentity?
    ) {
        guard let item else {
            preloadNilCallCount += 1
            preloadReceivedNil = true
            preparedNextItemState = AudioPlayerPreparedItemState(
                identity: nil,
                generation: currentGeneration,
                phase: .absent
            )
            eventHandler?(.preparedNextItemStateChanged(preparedNextItemState))
            return
        }
        preloadNonNilCallCount += 1
        if let asset = item.asset as? AVURLAsset {
            preloadedURLs.append(asset.url)
        }
        preparedNextItemState = AudioPlayerPreparedItemState(
            identity: identity,
            generation: currentGeneration,
            phase: automaticallyMarksPreparedReady ? .ready : .preparing
        )
        eventHandler?(.preparedNextItemStateChanged(preparedNextItemState))
    }

    func advanceToNextItem() {
        advanceCallCount += 1
        if automaticallyCompletesAdvance {
            currentGeneration += 1
            preparedNextItemState = AudioPlayerPreparedItemState(
                identity: nil,
                generation: currentGeneration,
                phase: .absent
            )
            hasCurrentItem = true
            eventHandler?(.advancedToNextItem)
        }
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
        let stoppedGeneration = currentGeneration
        hasCurrentItem = false
        stopCallCount += 1
        if stopStateDelivery == .deferredPaused {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                deferredStopStateDeliveryCount += 1
                eventHandler?(
                    .stateChangedForGeneration(
                        .paused,
                        generation: stoppedGeneration
                    )
                )
            }
        }
    }

    func send(_ event: AudioPlayerEngineEvent) {
        if event == .advancedToNextItem {
            currentGeneration += 1
            hasCurrentItem = true
            preparedNextItemState = AudioPlayerPreparedItemState(
                identity: nil,
                generation: currentGeneration,
                phase: .absent
            )
        }
        eventHandler?(event)
    }

    func sendPreparedPhase(_ phase: AudioPlayerPreparedItemPhase) {
        preparedNextItemState = AudioPlayerPreparedItemState(
            identity: preparedNextItemState.identity,
            generation: currentGeneration,
            phase: phase
        )
        eventHandler?(.preparedNextItemStateChanged(preparedNextItemState))
    }
}

private actor PlaybackFallbackCancellationProbe {
    private(set) var hasStarted = false
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<PlaybackRequest, Error>?

    func waitForCancellation() async throws -> PlaybackRequest {
        hasStarted = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if wasCancelled || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        wasCancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func resolve(with request: PlaybackRequest) {
        continuation?.resume(returning: request)
        continuation = nil
    }
}

private actor PlaybackRecoveryFallbackProbe {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<PlaybackRequest, Never>?

    func waitForResolution() async -> PlaybackRequest {
        hasStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(with request: PlaybackRequest) {
        continuation?.resume(returning: request)
        continuation = nil
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

private actor AsyncInvocationRecorder {
    private var count = 0

    func record() {
        count += 1
    }

    func snapshot() -> Int {
        count
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
    private let loadedItems: [PlaybackItem]

    init(loadedItems: [PlaybackItem] = []) {
        self.loadedItems = loadedItems
    }

    func loadItems() -> [PlaybackItem] {
        loadedItems
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

private actor NetworkPolicyGate {
    private(set) var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        hasStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private final class NetworkContainmentLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedQuarantineCount = 0
    private var storedReopenCount = 0

    var quarantineCount: Int {
        lock.withLock { storedQuarantineCount }
    }

    var reopenCount: Int {
        lock.withLock { storedReopenCount }
    }

    func recordQuarantine() {
        lock.withLock {
            storedQuarantineCount += 1
        }
    }

    func recordReopen() {
        lock.withLock {
            storedReopenCount += 1
        }
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

private final class RecoveringArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var firstFailureCode = URLError.Code.networkConnectionLost

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        if Self.requestCount == 1 {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(Self.firstFailureCode)
            )
            return
        }
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
