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

enum PlaybackQueueContext: Equatable, Codable, Sendable {
    case album(id: String)
    case playlist(id: String)
    case songs
    case search
    case single
}

struct PlaybackQueue: Equatable, Codable, Sendable {
    private(set) var items: [PlaybackItem]
    private(set) var currentIndex: Int
    let context: PlaybackQueueContext

    init(
        items: [PlaybackItem],
        currentItemID: String,
        context: PlaybackQueueContext
    ) {
        var seen = Set<String>()
        let uniqueItems = items.filter {
            seen.insert("\($0.source.rawValue)|\($0.id)").inserted
        }
        self.items = uniqueItems
        currentIndex =
            uniqueItems.firstIndex(where: {
                $0.id == currentItemID
            }) ?? 0
        self.context = context
    }

    var currentItem: PlaybackItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var previousItem: PlaybackItem? {
        let index = currentIndex - 1
        return items.indices.contains(index) ? items[index] : nil
    }

    var nextItem: PlaybackItem? {
        let index = currentIndex + 1
        return items.indices.contains(index) ? items[index] : nil
    }

    var canGoPrevious: Bool {
        previousItem != nil
    }

    var canGoNext: Bool {
        nextItem != nil
    }

    mutating func movePrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    mutating func moveNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    mutating func append(_ newItems: [PlaybackItem]) {
        var seen = Set(items.map { "\($0.source.rawValue)|\($0.id)" })
        items.append(
            contentsOf: newItems.filter {
                seen.insert("\($0.source.rawValue)|\($0.id)").inserted
            }
        )
    }

    func persistenceWindow() -> PlaybackQueue {
        let lowerBound = max(currentIndex - 25, 0)
        let upperBound = min(currentIndex + 50, items.count - 1)
        guard lowerBound <= upperBound else { return self }
        return PlaybackQueue(
            items: Array(items[lowerBound...upperBound]),
            currentItemID: items[currentIndex].id,
            context: context
        )
    }
}

struct PlaybackAccount: Equatable, Codable, Sendable {
    let serverID: String
    let userID: String
}

struct SavedNowPlayingState: Equatable, Codable, Sendable {
    let queue: PlaybackQueue
    let elapsed: TimeInterval
    let account: PlaybackAccount?
    let savedAt: Date
}

protocol NowPlayingStateStoring {
    func loadState() -> SavedNowPlayingState?
    func saveState(_ state: SavedNowPlayingState)
    func clearState()
}

struct UserDefaultsNowPlayingStateStore: NowPlayingStateStoring {
    private let defaults: UserDefaults
    private let key = "velacanto.now-playing-state-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadState() -> SavedNowPlayingState? {
        guard
            let data = defaults.data(forKey: key),
            let state = try? JSONDecoder().decode(
                SavedNowPlayingState.self,
                from: data
            )
        else {
            return nil
        }
        return state
    }

    func saveState(_ state: SavedNowPlayingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clearState() {
        defaults.removeObject(forKey: key)
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
            let item = AVPlayerItem(url: url)
            if !url.isFileURL {
                item.preferredForwardBufferDuration = 20
            }
            return item
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

protocol PlaybackLifecycleReporting: Sendable {
    func reportStarted(at position: TimeInterval) async
    func reportProgress(at position: TimeInterval, isPaused: Bool) async
    func reportStopped(at position: TimeInterval) async
}

struct PlaybackRequest: Sendable {
    let item: PlaybackItem
    let asset: PlaybackAsset
    let recordsHistory: Bool
    let reporter: (any PlaybackLifecycleReporting)?

    init(
        item: PlaybackItem,
        asset: PlaybackAsset,
        recordsHistory: Bool = true,
        reporter: (any PlaybackLifecycleReporting)? = nil
    ) {
        self.item = item
        self.asset = asset
        self.recordsHistory = recordsHistory
        self.reporter = reporter
    }
}

protocol PlaybackSourceAdapter: Sendable {
    associatedtype Selection: Sendable

    var source: MusicSourceID { get }
    func playbackRequest(for selection: Selection) async throws -> PlaybackRequest
}
