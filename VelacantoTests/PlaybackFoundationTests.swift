import AVFoundation
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
        XCTAssertEqual(coordinator.playbackState, .paused)
        XCTAssertFalse(engine.hasCurrentItem)
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

    func preload(_ item: AVPlayerItem?) {}

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

@MainActor
private final class RecordingSystemMediaController: SystemMediaControlling {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var play: (@MainActor () -> Void)?
    private(set) var pause: (@MainActor () -> Void)?
    private(set) var previous: (@MainActor () -> Void)?
    private(set) var next: (@MainActor () -> Void)?
    private(set) var togglePlayPause: (@MainActor () -> Void)?
    private(set) var seek: (@MainActor (TimeInterval) -> Void)?

    var latestSnapshot: NowPlayingSnapshot? {
        snapshots.last
    }

    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (TimeInterval) -> Void
    ) {
        self.play = play
        self.pause = pause
        self.previous = previous
        self.next = next
        self.togglePlayPause = togglePlayPause
        self.seek = seek
    }

    func update(_ snapshot: NowPlayingSnapshot) {
        snapshots.append(snapshot)
    }
}

private final class RecordingResourceLease: PlaybackResourceLease, @unchecked Sendable {}

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
