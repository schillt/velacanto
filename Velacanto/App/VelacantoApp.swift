import SwiftUI

@main
struct VelacantoApp: App {
    @StateObject private var playback = AudioPlaybackCoordinator()

    var body: some Scene {
        WindowGroup {
            PrototypeContentView(playback: playback)
        }
    }
}
