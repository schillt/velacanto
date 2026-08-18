import AVFoundation
import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct VelacantoApp: App {
    @StateObject private var playback: AudioPlaybackCoordinator
    @StateObject private var jellyfin: JellyfinSessionController
    @StateObject private var systemMediaSession: PlaybackSystemMediaSession

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let usesSignedInUITestFixture = arguments.contains("-uiTestingSignedIn")
        let playback =
            usesSignedInUITestFixture
            ? AudioPlaybackCoordinator(
                engine: UITestAudioPlayerEngine(),
                platformEventObserver: UITestPlaybackPlatformEventObserver(),
                audioSessionController: UITestAudioSessionController()
            )
            : AudioPlaybackCoordinator(
                historyStore: UserDefaultsPlaybackHistoryStore(),
                nowPlayingStateStore: UserDefaultsNowPlayingStateStore()
            )
        if usesSignedInUITestFixture {
            let current = PlaybackItem(
                id: "ui-test-track",
                title: "Test Track",
                artist: "Test Artist",
                albumTitle: "Test Album",
                albumID: "ui-test-album",
                artistID: "ui-test-artist",
                source: .jellyfin,
                duration: 180,
                isFavorite: false
            )
            let next = PlaybackItem(
                id: "ui-test-next-track",
                title: "Next Test Track",
                artist: "Test Artist",
                albumTitle: "Test Album",
                source: .jellyfin,
                duration: 180,
                isFavorite: false
            )
            playback.play(
                PlaybackRequest(
                    item: current,
                    asset: PlaybackAsset(
                        playerItemFactory: {
                            AVPlayerItem(
                                asset: AVURLAsset(
                                    url: URL(fileURLWithPath: "/dev/null")
                                )
                            )
                        }
                    ),
                    transportKind: .directPlay,
                    recordsHistory: false
                ),
                queueItems: [current, next],
                context: .album(id: "ui-test-album")
            )
        }
        _playback = StateObject(wrappedValue: playback)
        _systemMediaSession = StateObject(
            wrappedValue: PlaybackSystemMediaSession(playback: playback)
        )
        _jellyfin = StateObject(
            wrappedValue:
                usesSignedInUITestFixture
                ? JellyfinSessionController(uiTestingSignedIn: true)
                : JellyfinSessionController(autoRestore: !arguments.contains("-uiTesting"))
        )
    }

    var body: some Scene {
        WindowGroup {
            VelacantoRootView(
                playback: playback,
                jellyfin: jellyfin
            )
        }
        .onChange(of: systemMediaSession.id, initial: true) { _, _ in
            systemMediaSession.activate()
        }
        #if os(macOS)
            .windowToolbarStyle(.unified(showsTitle: true))
            .commands {
                CommandGroup(replacing: .sidebar) {
                    Button("Toggle Full Screen") {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                }
            }
        #endif
    }
}

@MainActor
private final class UITestAudioPlayerEngine: AudioPlayerEngine {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)?
    private(set) var hasCurrentItem = false

    func load(_: AVPlayerItem) {
        hasCurrentItem = true
        eventHandler?(.stateChanged(.paused))
    }
    func preload(_: AVPlayerItem?) {}
    func advanceToNextItem() {}
    func play() { eventHandler?(.stateChanged(.playing)) }
    func pause() { eventHandler?(.stateChanged(.paused)) }
    func seek(to _: TimeInterval) {}
    func stop() {
        hasCurrentItem = false
        eventHandler?(.stateChanged(.idle))
    }
}

private actor UITestAudioSessionController: PlaybackAudioSessionControlling {
    func activate() async throws {}
    func deactivate(notifyingOthers _: Bool) async {}
}

@MainActor
private final class UITestPlaybackPlatformEventObserver: PlaybackPlatformEventObserving {
    func start(
        interruption _: @escaping @MainActor (PlaybackAudioInterruption) -> Void,
        routeChange _: @escaping @MainActor (PlaybackAudioRouteChange) -> Void,
        didEnterBackground _: @escaping @MainActor () -> Void
    ) {}
}
