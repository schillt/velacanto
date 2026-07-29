import AVFoundation
import Foundation

struct MusicSourceID: RawRepresentable, Hashable, Identifiable, Codable, Sendable {
    let rawValue: String

    var id: Self { self }

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static let localFiles = MusicSourceID(rawValue: "local-files")
    static let jellyfin = MusicSourceID(rawValue: "jellyfin")
}

struct PlaybackItem: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let title: String
    let artist: String
    let albumTitle: String?
    let source: MusicSourceID
    let artworkItemID: String?
    let artworkTag: String?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        albumTitle: String? = nil,
        source: MusicSourceID,
        artworkItemID: String? = nil,
        artworkTag: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.source = source
        self.artworkItemID = artworkItemID
        self.artworkTag = artworkTag
    }
}

protocol PlaybackHistoryStoring {
    func loadItems() -> [PlaybackItem]
    func saveItems(_ items: [PlaybackItem])
}

struct UserDefaultsPlaybackHistoryStore: PlaybackHistoryStoring {
    private let defaults: UserDefaults
    private let key = "velacanto.playback-history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadItems() -> [PlaybackItem] {
        guard
            let data = defaults.data(forKey: key),
            let items = try? JSONDecoder().decode([PlaybackItem].self, from: data)
        else {
            return []
        }

        let cleanedItems = items.filter {
            !($0.source == .localFiles
                && $0.title == "Velacanto playback check"
                && $0.artist == "440 Hz local tone")
        }
        if cleanedItems.count != items.count {
            saveItems(cleanedItems)
        }
        return cleanedItems
    }

    func saveItems(_ items: [PlaybackItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: key)
    }
}

protocol PlaybackResourceLease: AnyObject, Sendable {}

struct PlaybackAsset: Sendable {
    let resourceLease: (any PlaybackResourceLease)?

    private let playerItemFactory: @MainActor @Sendable () -> AVPlayerItem

    init(
        url: URL,
        resourceLease: (any PlaybackResourceLease)? = nil
    ) {
        self.resourceLease = resourceLease
        playerItemFactory = {
            AVPlayerItem(url: url)
        }
    }

    init(
        resourceLease: (any PlaybackResourceLease)? = nil,
        playerItemFactory: @escaping @MainActor @Sendable () -> AVPlayerItem
    ) {
        self.resourceLease = resourceLease
        self.playerItemFactory = playerItemFactory
    }

    @MainActor
    func makePlayerItem() -> AVPlayerItem {
        playerItemFactory()
    }
}

struct PlaybackRequest: Sendable {
    let item: PlaybackItem
    let asset: PlaybackAsset
    let recordsHistory: Bool

    init(
        item: PlaybackItem,
        asset: PlaybackAsset,
        recordsHistory: Bool = true
    ) {
        self.item = item
        self.asset = asset
        self.recordsHistory = recordsHistory
    }
}

protocol PlaybackSourceAdapter: Sendable {
    associatedtype Selection: Sendable

    var source: MusicSourceID { get }
    func playbackRequest(for selection: Selection) async throws -> PlaybackRequest
}
