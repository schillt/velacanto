import AVFoundation
import MediaPlayer
import XCTest

@testable import Velacanto

@MainActor
final class PlaybackFoundationTests: XCTestCase {
    func testDurationFormatting() {
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: -1), "0:00")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: 197), "3:17")
        XCTAssertEqual(PlaybackTimeFormatter.format(seconds: 3_661), "61:01")
    }

    func testPlannedMusicSourcesRemainDistinct() {
        XCTAssertEqual(
            Set(MusicSourceKind.allCases),
            Set([.localFiles, .jellyfin, .navidrome])
        )
    }

    func testLocalAdapterPlaysTheSelectedURLWithoutCopyingIt() throws {
        let url = try DemoToneFactory.makeURL()
        let request = try LocalFilePlaybackAdapter().playbackRequest(
            for: LocalFileSelection(url: url)
        )

        XCTAssertEqual(request.mediaURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(request.item.source, .localFiles)
        XCTAssertEqual(request.item.title, "playback-test-tone-60s")
    }

    func testGeneratedPlaybackToneIsReadableAudio() throws {
        let url = try DemoToneFactory.makeURL()
        let file = try AVAudioFile(forReading: url)
        let measuredDuration = Double(file.length) / file.processingFormat.sampleRate

        XCTAssertEqual(
            measuredDuration,
            DemoToneFactory.duration,
            accuracy: 0.01
        )
    }

    func testPlaybackCoordinatorPublishesStateAndHandlesSystemCommands() throws {
        let systemMediaController = RecordingSystemMediaController()
        let coordinator = AudioPlaybackCoordinator(
            systemMediaController: systemMediaController
        )
        let url = try DemoToneFactory.makeURL()
        let request = try LocalFilePlaybackAdapter().playbackRequest(
            for: LocalFileSelection(
                url: url,
                title: "Control Center Test",
                artist: "Velacanto"
            )
        )

        coordinator.play(request)

        XCTAssertEqual(systemMediaController.latestSnapshot?.item, request.item)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, true)

        systemMediaController.pause?()
        XCTAssertFalse(coordinator.isPlaying)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, false)

        systemMediaController.play?()
        XCTAssertTrue(coordinator.isPlaying)
        XCTAssertEqual(systemMediaController.latestSnapshot?.isPlaying, true)

        systemMediaController.seek?(1.25)
        XCTAssertEqual(coordinator.elapsed, 1.25, accuracy: 0.001)

        systemMediaController.stop?()
        XCTAssertNil(coordinator.currentItem)
        XCTAssertEqual(systemMediaController.latestSnapshot, .empty)
    }

    func testNowPlayingMetadataContainsControlCenterFields() {
        let item = PlaybackItem(
            title: "Night Drive",
            artist: "Velacanto",
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
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Local Files")
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
