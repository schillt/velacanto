import AVFoundation
import MediaPlayer
import XCTest

@testable import Velacanto

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
        XCTAssertTrue(coordinator.showsPauseControl)

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

        systemMediaController.stop?()
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

    private func play(
        _ request: PlaybackRequest?,
        on coordinator: AudioPlaybackCoordinator
    ) throws {
        coordinator.play(try XCTUnwrap(request))
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
    private(set) var playCallCount = 0
    private(set) var pauseCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var seekTimes: [TimeInterval] = []

    func load(_ item: AVPlayerItem) {
        hasCurrentItem = true
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

@MainActor
private final class RecordingSystemMediaController: SystemMediaControlling {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var play: (@MainActor () -> Void)?
    private(set) var pause: (@MainActor () -> Void)?
    private(set) var stop: (@MainActor () -> Void)?
    private(set) var togglePlayPause: (@MainActor () -> Void)?
    private(set) var seek: (@MainActor (TimeInterval) -> Void)?

    var latestSnapshot: NowPlayingSnapshot? {
        snapshots.last
    }

    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (TimeInterval) -> Void
    ) {
        self.play = play
        self.pause = pause
        self.stop = stop
        self.togglePlayPause = togglePlayPause
        self.seek = seek
    }

    func update(_ snapshot: NowPlayingSnapshot) {
        snapshots.append(snapshot)
    }
}

private final class RecordingResourceLease: PlaybackResourceLease, @unchecked Sendable {}
