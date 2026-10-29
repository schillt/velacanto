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
    static let current: [Self] = [
        .init(
            id: welcomeID, release: "0.6", title: "Welcome to VelaCanto",
            symbol: "music.note.house",
            detail:
                "Explore your music in Home, New, Library and Search. Your Jellyfin library stays yours."
        ),
        .init(
            id: "music.offline.v1", release: "0.6", title: "Take your music with you",
            symbol: "arrow.down.circle",
            detail:
                "Download music from its menu, then use Offline Mode in Settings to browse and play your downloads."
        ),
        .init(
            id: "music.song-credits.v1", release: "0.6", title: "Look behind the music",
            symbol: "person.text.rectangle",
            detail:
                "Open Song Credits from a song’s menu to see the credits available for that recording."
        ),
    ]
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
