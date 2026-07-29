import SwiftUI

@main
struct VelacantoApp: App {
    @StateObject private var playback = AudioPlaybackCoordinator()
    @StateObject private var jellyfin = JellyfinSessionController()

    var body: some Scene {
        WindowGroup {
            PrototypeContentView(
                playback: playback,
                jellyfin: jellyfin
            )
        }
    }
}
