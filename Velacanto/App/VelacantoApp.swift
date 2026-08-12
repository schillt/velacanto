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
    @StateObject private var jellyfin = JellyfinSessionController()

    var body: some Scene {
        WindowGroup {
            VelacantoRootView(
                playback: playback,
                jellyfin: jellyfin
            )
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
