import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#endif

@main
struct VelacantoApp: App {
    @StateObject private var playback = AudioPlaybackCoordinator(
        historyStore: UserDefaultsPlaybackHistoryStore(),
        nowPlayingStateStore: UserDefaultsNowPlayingStateStore()
    )
    @StateObject private var jellyfin: JellyfinSessionController
    @StateObject private var systemMediaSession: PlaybackSystemMediaSession

    init() {
        let playback = AudioPlaybackCoordinator(
            historyStore: UserDefaultsPlaybackHistoryStore(),
            nowPlayingStateStore: UserDefaultsNowPlayingStateStore()
        )
        _playback = StateObject(wrappedValue: playback)
        _systemMediaSession = StateObject(
            wrappedValue: PlaybackSystemMediaSession(playback: playback)
        )
        _jellyfin = StateObject(
            wrappedValue: JellyfinSessionController(
                autoRestore: !ProcessInfo.processInfo.arguments.contains("-uiTesting")
            )
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
