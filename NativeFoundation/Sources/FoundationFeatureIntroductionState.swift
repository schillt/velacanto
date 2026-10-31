import Combine
import Foundation

/// IDs describe shipped behavior, never a changing alpha build number.
struct FoundationIntroductionFeature: Identifiable, Equatable {
    let id: String
    let release: String
    let title: String
    let symbol: String
    let detail: String

    static let welcomeID = "welcome.navigation.v1"
    static let pinSyncID = "pins.icloud.opt-in.v1"
    static let systemStorageID = "music.system-storage.opt-in.v1"
    static let continuationID = "music.continue-listening.v1"
    private static let shared: [Self] = [
        .init(
            id: welcomeID, release: "0.6", title: "Welcome to VelaCanto",
            symbol: "music.note.house",
            detail:
                "Explore albums, artists and genres in a fresh home for your music."
        ),
        .init(
            id: "music.offline.v1", release: "0.6", title: "Take your music with you",
            symbol: "arrow.down.circle",
            detail:
                "Save your favorites and enjoy your downloaded music, even without a connection."
        ),
        .init(
            id: "music.queue.v1", release: "0.6", title: "Make the next song yours",
            symbol: "list.bullet",
            detail: "Artwork, history and quick swipe actions bring your queue into focus."
        ),
        .init(
            id: "music.lyrics.v1", release: "0.6", title: "Follow every word",
            symbol: "quote.bubble",
            detail: "Follow timed lyrics, jump to a line, or return to the words playing now."
        ),
        .init(
            id: "music.playlists.v1", release: "0.6", title: "Give every playlist a personality",
            symbol: "music.note.list",
            detail: "Create a cover, find songs and shape the order in one playlist editor."
        ),
        .init(
            id: continuationID, release: "0.6", title: "Pick up where you left off",
            symbol: "arrow.trianglehead.2.clockwise.rotate.90",
            detail: "Continue from another VelaCanto device or a compatible server player."
        ),
        .init(
            id: "music.song-credits.v1", release: "0.6", title: "Look behind the music",
            symbol: "person.text.rectangle",
            detail:
                "Discover the people behind a recording with Song Credits."
        ),
    ]

    static var current: [Self] {
        #if os(iOS)
            shared + [
                .init(
                    id: systemStorageID, release: "0.6", title: "Manage new downloads in Settings",
                    symbol: "internaldrive",
                    detail:
                        "Choose AAC quality to manage new downloads in your device’s storage settings. Existing downloads stay in VelaCanto."
                )
            ]
        #else
            shared
        #endif
    }
}

/// Device-local presentation history contains feature IDs only. Account consent
/// belongs exclusively to FoundationPinSync's existing scoped journal.
@MainActor
final class FoundationIntroductionHistory: ObservableObject {
    static let shared = FoundationIntroductionHistory()
    static let storageKey = "Velacanto.Foundation.Introduction.SeenFeatures.v1"
    private let defaults: UserDefaults
    @Published private(set) var seen: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        seen = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func pending(
        in catalog: [FoundationIntroductionFeature] = FoundationIntroductionFeature.current
    )
        -> [FoundationIntroductionFeature]
    {
        catalog.filter { !seen.contains($0.id) }
    }

    /// Only explicit Finish/Skip calls this. Appearance and dismissal do not.
    func acknowledge(_ ids: [String]) {
        seen.formUnion(ids)
        defaults.set(seen.sorted(), forKey: Self.storageKey)
    }

    func needsOffer(hasPendingPinChoice: Bool) -> Bool {
        !pending().isEmpty || hasPendingPinChoice
    }
}
