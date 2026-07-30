import SwiftUI

@main
struct VelacantoApp: App {
    @StateObject private var playback = AudioPlaybackCoordinator(
        historyStore: UserDefaultsPlaybackHistoryStore()
    )
    @StateObject private var jellyfin = JellyfinSessionController()

    var body: some Scene {
        WindowGroup {
            VelacantoRootView(
                playback: playback,
                jellyfin: jellyfin
            )
        }
    }
}
