import SwiftUI

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
        #endif
    }
}
