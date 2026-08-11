import AVFoundation
import Foundation
import os

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
    let duration: TimeInterval?

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        albumTitle: String? = nil,
        source: MusicSourceID,
        artworkItemID: String? = nil,
        artworkTag: String? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.source = source
        self.artworkItemID = artworkItemID
        self.artworkTag = artworkTag
        self.duration = duration
    }
}

enum PlaybackQueueContext: Equatable, Codable, Sendable {
    case album(id: String)
    case artist(id: String)
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
    let duration: TimeInterval?
    let account: PlaybackAccount?
    let savedAt: Date

    init(
        queue: PlaybackQueue,
        elapsed: TimeInterval,
        duration: TimeInterval? = nil,
        account: PlaybackAccount?,
        savedAt: Date
    ) {
        self.queue = queue
        self.elapsed = elapsed
        self.duration = duration
        self.account = account
        self.savedAt = savedAt
    }
}

/// Persists the restorable playback snapshot. A missing or corrupt snapshot is
/// intentionally treated as no restoration state; playback itself remains usable.
protocol NowPlayingStateStoring {
    func loadState() -> SavedNowPlayingState?
    func saveState(_ state: SavedNowPlayingState)
    func clearState()
}

struct UserDefaultsNowPlayingStateStore: NowPlayingStateStoring {
    typealias StateEncoder = (SavedNowPlayingState) throws -> Data
    typealias DataWriter = (UserDefaults, Data, String) throws -> Void
    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "PlaybackPersistence"
    )
    private let defaults: UserDefaults
    private let key = "velacanto.now-playing-state-v1"
    private let encodeState: StateEncoder
    private let writeData: DataWriter

    init(
        defaults: UserDefaults = .standard,
        encodeState: @escaping StateEncoder = { try JSONEncoder().encode($0) },
        writeData: @escaping DataWriter = { defaults, data, key in
            defaults.set(data, forKey: key)
        }
    ) {
        self.defaults = defaults
        self.encodeState = encodeState
        self.writeData = writeData
    }

    func loadState() -> SavedNowPlayingState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(SavedNowPlayingState.self, from: data)
        } catch {
            // A snapshot cannot be trusted after a failed decode. Removing it
            // prevents the same failure from obscuring later launches.
            defaults.removeObject(forKey: key)
            Self.logger.error("Discarded corrupt now-playing state")
            return nil
        }
    }

    func saveState(_ state: SavedNowPlayingState) {
        do {
            try writeData(defaults, encodeState(state), key)
        } catch {
            // Restoration is best-effort and must not interrupt live playback.
            Self.logger.error("Could not encode now-playing state")
        }
    }

    func clearState() {
        defaults.removeObject(forKey: key)
    }
}

/// Stores a privacy-local recent-items list. A persistence failure never blocks
/// playback, but is recorded without including media metadata.
protocol PlaybackHistoryStoring {
    func loadItems() -> [PlaybackItem]
    func saveItems(_ items: [PlaybackItem])
}

struct UserDefaultsPlaybackHistoryStore: PlaybackHistoryStoring {
    typealias HistoryEncoder = ([PlaybackItem]) throws -> Data
    typealias DataWriter = (UserDefaults, Data, String) throws -> Void
    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "PlaybackPersistence"
    )
    private let defaults: UserDefaults
    private let key = "velacanto.playback-history"
    private let encodeItems: HistoryEncoder
    private let writeData: DataWriter

    init(
        defaults: UserDefaults = .standard,
        encodeItems: @escaping HistoryEncoder = { try JSONEncoder().encode($0) },
        writeData: @escaping DataWriter = { defaults, data, key in
            defaults.set(data, forKey: key)
        }
    ) {
        self.defaults = defaults
        self.encodeItems = encodeItems
        self.writeData = writeData
    }

    func loadItems() -> [PlaybackItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let items: [PlaybackItem]
        do {
            items = try JSONDecoder().decode([PlaybackItem].self, from: data)
        } catch {
            defaults.removeObject(forKey: key)
            Self.logger.error("Discarded corrupt playback history")
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
        do {
            try writeData(defaults, encodeItems(items), key)
        } catch {
            Self.logger.error("Could not encode playback history")
        }
    }
}

/// Keeps a source resource valid while its player item can still read it.
///
/// A request transfers lease ownership to `AudioPlaybackCoordinator`, which
/// retains the active lease until replacement or stop and retains a preloaded
/// request's lease until that request is consumed or discarded. Implementations
/// release their resource on deinitialization; for example, local files stop
/// security-scoped access there. The lease carries no playback controls or
/// source metadata.
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

/// Reports one negotiated Jellyfin play session in call order. The coordinator
/// serializes calls, suppresses duplicates, and keeps later reports flowing if
/// an individual best-effort network report fails.
protocol PlaybackLifecycleReporting: Sendable {
    func reportStarted(at position: TimeInterval) async throws
    func reportProgress(at position: TimeInterval, isPaused: Bool) async throws
    func reportStopped(at position: TimeInterval) async throws
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

/// Converts source-specific selections into provider-neutral playback requests.
/// Implementations own source validation and may throw a user-presentable error.
protocol PlaybackSourceAdapter: Sendable {
    associatedtype Selection: Sendable

    var source: MusicSourceID { get }
    func playbackRequest(for selection: Selection) async throws -> PlaybackRequest
}
