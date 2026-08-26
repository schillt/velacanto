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
    let albumID: String?
    let artistID: String?
    let source: MusicSourceID
    /// Provider account that owns the opaque item ID. Older persisted items
    /// decode as nil and remain usable with the active account.
    let accountScope: String?
    let artworkItemID: String?
    let artworkTag: String?
    let duration: TimeInterval?
    /// Provider-reported file container used only to select a known native
    /// direct-file path. Missing or unknown values use server negotiation.
    let container: String?
    /// The catalog state when this item entered the playback queue.
    ///
    /// This remains optional so queues saved before favorites were supported
    /// continue to decode. The action owner takes precedence once it has
    /// reconciled a newer server value or an optimistic update.
    let isFavorite: Bool?

    /// Identifies an item within a queue without changing its opaque provider ID.
    var queueIdentity: PlaybackItemQueueIdentity {
        PlaybackItemQueueIdentity(
            source: source,
            accountScope: accountScope,
            itemID: id
        )
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        artist: String,
        albumTitle: String? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        source: MusicSourceID,
        accountScope: String? = nil,
        artworkItemID: String? = nil,
        artworkTag: String? = nil,
        duration: TimeInterval? = nil,
        container: String? = nil,
        isFavorite: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.artistID = artistID
        self.source = source
        self.accountScope = accountScope
        self.artworkItemID = artworkItemID
        self.artworkTag = artworkTag
        self.duration = duration
        self.container = container
        self.isFavorite = isFavorite
    }

    func replacingContainer(_ container: String?) -> PlaybackItem {
        PlaybackItem(
            id: id,
            title: title,
            artist: artist,
            albumTitle: albumTitle,
            albumID: albumID,
            artistID: artistID,
            source: source,
            accountScope: accountScope,
            artworkItemID: artworkItemID,
            artworkTag: artworkTag,
            duration: duration,
            container: container,
            isFavorite: isFavorite
        )
    }
}

struct PlaybackItemQueueIdentity: Hashable, Sendable {
    let source: MusicSourceID
    let accountScope: String?
    let itemID: String
}

enum PlaybackQueueContext: Equatable, Codable, Sendable {
    case album(id: String)
    case artist(id: String)
    case playlist(id: String)
    case songs
    case search
    case single
}

enum PlaybackRepeatMode: String, CaseIterable, Codable, Sendable {
    case off
    case all
    case one

    var next: Self {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

enum PlaybackTransportKind: String, Equatable, Codable, Sendable {
    case localFile
    case directPlay
    case directStream
    case transcoding

    var displayName: String {
        switch self {
        case .localFile: "Local File"
        case .directPlay: "Direct Play"
        case .directStream: "Direct Stream"
        case .transcoding: "Transcoding"
        }
    }
}

struct PlaybackQueue: Equatable, Codable, Sendable {
    private(set) var items: [PlaybackItem]
    private(set) var currentIndex: Int
    let context: PlaybackQueueContext
    private(set) var repeatMode: PlaybackRepeatMode

    init(
        items: [PlaybackItem],
        currentItemID: String,
        context: PlaybackQueueContext,
        repeatMode: PlaybackRepeatMode = .off
    ) {
        var seen = Set<PlaybackItemQueueIdentity>()
        let uniqueItems = items.filter {
            seen.insert($0.queueIdentity).inserted
        }
        self.items = uniqueItems
        currentIndex =
            uniqueItems.firstIndex(where: {
                $0.id == currentItemID
            }) ?? 0
        self.context = context
        self.repeatMode = repeatMode
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case currentIndex
        case context
        case repeatMode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([PlaybackItem].self, forKey: .items)
        let decodedIndex = try container.decode(Int.self, forKey: .currentIndex)
        currentIndex = items.indices.contains(decodedIndex) ? decodedIndex : 0
        context = try container.decode(
            PlaybackQueueContext.self,
            forKey: .context
        )
        repeatMode =
            try container.decodeIfPresent(
                PlaybackRepeatMode.self,
                forKey: .repeatMode
            ) ?? .off
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

    func item(
        advancingBy distance: Int,
        wrapping: Bool
    ) -> PlaybackItem? {
        guard distance > 0, !items.isEmpty else { return nil }
        let requestedIndex = currentIndex + distance
        if items.indices.contains(requestedIndex) {
            return items[requestedIndex]
        }
        guard wrapping else { return nil }
        return items[requestedIndex % items.count]
    }

    func item(
        retreatingBy distance: Int,
        wrapping: Bool
    ) -> PlaybackItem? {
        guard distance > 0, !items.isEmpty else { return nil }
        let requestedIndex = currentIndex - distance
        if items.indices.contains(requestedIndex) {
            return items[requestedIndex]
        }
        guard wrapping else { return nil }
        let wrappedIndex =
            (requestedIndex % items.count + items.count)
            % items.count
        return items[wrappedIndex]
    }

    var upcomingItems: [PlaybackItem] {
        let start = currentIndex + 1
        guard items.indices.contains(start) else { return [] }
        return Array(items[start...])
    }

    var playedItems: [PlaybackItem] {
        guard currentIndex > items.startIndex else { return [] }
        return Array(items[..<currentIndex])
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

    mutating func movePrevious(wrapping: Bool) {
        if canGoPrevious {
            currentIndex -= 1
        } else if wrapping, !items.isEmpty {
            currentIndex = items.count - 1
        }
    }

    mutating func moveNext(wrapping: Bool) {
        if canGoNext {
            currentIndex += 1
        } else if wrapping, !items.isEmpty {
            currentIndex = 0
        }
    }

    mutating func moveNext(
        by distance: Int,
        wrapping: Bool
    ) {
        guard distance > 0, !items.isEmpty else { return }
        let requestedIndex = currentIndex + distance
        if items.indices.contains(requestedIndex) {
            currentIndex = requestedIndex
        } else if wrapping {
            currentIndex = requestedIndex % items.count
        }
    }

    @discardableResult
    mutating func select(_ item: PlaybackItem) -> Bool {
        guard
            let index = items.firstIndex(where: {
                $0.queueIdentity == item.queueIdentity
            }),
            index != currentIndex
        else {
            return false
        }

        // History, Now Playing, and Up Next are views of one ordered timeline.
        // Selecting any row moves only the cursor; it never copies or reorders
        // entries around the selected song.
        currentIndex = index
        return true
    }

    /// Starts a new listening context without discarding the playback session's
    /// past. The old current item becomes the newest history entry, while the
    /// old future is explicitly replaced by the newly selected context.
    func replacingFuture(
        with replacementItems: [PlaybackItem],
        current replacementCurrent: PlaybackItem,
        context replacementContext: PlaybackQueueContext
    ) -> PlaybackQueue {
        let replacementIdentities = Set(
            replacementItems.map(\.queueIdentity)
        )
        let preservedTimeline = Array(items[...currentIndex]).filter {
            !replacementIdentities.contains($0.queueIdentity)
        }
        var replacement = PlaybackQueue(
            items: preservedTimeline + replacementItems,
            currentItemID: replacementCurrent.id,
            context: replacementContext
        )
        if let selectedIndex = replacement.items.firstIndex(where: {
            $0.queueIdentity == replacementCurrent.queueIdentity
        }) {
            replacement.currentIndex = selectedIndex
        }
        return replacement
    }

    mutating func setRepeatMode(_ mode: PlaybackRepeatMode) {
        repeatMode = mode
    }

    mutating func replaceCurrentItem(with item: PlaybackItem) {
        guard currentItem?.queueIdentity == item.queueIdentity else { return }
        items[currentIndex] = item
    }

    @discardableResult
    mutating func playNext(_ item: PlaybackItem) -> Bool {
        insertUpcoming(item, at: currentIndex + 1)
    }

    @discardableResult
    mutating func playLast(_ item: PlaybackItem) -> Bool {
        insertUpcoming(item, at: items.endIndex)
    }

    @discardableResult
    mutating func removeUpcomingItem(_ item: PlaybackItem) -> Bool {
        guard
            let index = items.indices.first(where: {
                $0 > currentIndex
                    && items[$0].queueIdentity == item.queueIdentity
            })
        else {
            return false
        }
        items.remove(at: index)
        return true
    }

    @discardableResult
    mutating func moveUpcomingItem(from source: Int, to destination: Int) -> Bool {
        let start = currentIndex + 1
        let sourceIndex = start + source
        guard items.indices.contains(sourceIndex), destination >= 0 else {
            return false
        }
        let clampedDestination = min(destination, upcomingItems.count - 1)
        guard source != clampedDestination else { return false }
        let item = items.remove(at: sourceIndex)
        items.insert(item, at: start + clampedDestination)
        return true
    }

    /// Applies SwiftUI's native reorder result while keeping history and the
    /// currently playing item outside the editable collection.
    @discardableResult
    mutating func reorderUpcomingItems(
        withIDs sourceIDs: [PlaybackItemQueueIdentity],
        before destinationID: PlaybackItemQueueIdentity?
    ) -> Bool {
        let upcomingStart = currentIndex + 1
        guard items.indices.contains(upcomingStart), !sourceIDs.isEmpty else {
            return false
        }

        let sourceIDSet = Set(sourceIDs)
        let upcoming = Array(items[upcomingStart...])
        let movedItems = upcoming.filter { sourceIDSet.contains($0.queueIdentity) }
        guard movedItems.count == sourceIDSet.count else { return false }

        var reorderedItems = upcoming.filter { !sourceIDSet.contains($0.queueIdentity) }
        let destinationIndex =
            destinationID.flatMap { destinationID in
                reorderedItems.firstIndex { $0.queueIdentity == destinationID }
            } ?? reorderedItems.endIndex
        reorderedItems.insert(contentsOf: movedItems, at: destinationIndex)
        guard reorderedItems != upcoming else { return false }

        items.replaceSubrange(upcomingStart..., with: reorderedItems)
        return true
    }

    @discardableResult
    mutating func shuffleUpcoming(
        randomIndex: (Range<Int>) -> Int = { Int.random(in: $0) }
    ) -> Bool {
        let start = currentIndex + 1
        guard items.count - start > 1 else { return false }
        for upperBound in stride(from: items.count - 1, through: start + 1, by: -1) {
            let range = start..<upperBound + 1
            let candidate = randomIndex(range)
            let swapIndex = range.contains(candidate) ? candidate : range.lowerBound
            items.swapAt(upperBound, swapIndex)
        }
        return true
    }

    @discardableResult
    mutating func append(_ newItems: [PlaybackItem]) -> Bool {
        var seen = Set(items.map(\.queueIdentity))
        let uniqueItems = newItems.filter {
            seen.insert($0.queueIdentity).inserted
        }
        items.append(contentsOf: uniqueItems)
        return !uniqueItems.isEmpty
    }

    private mutating func insertUpcoming(
        _ item: PlaybackItem,
        at requestedIndex: Int
    ) -> Bool {
        if let existingIndex = items.firstIndex(where: {
            $0.queueIdentity == item.queueIdentity
        }) {
            guard existingIndex > currentIndex else { return false }
            let existingItem = items.remove(at: existingIndex)
            let insertionIndex = min(requestedIndex, items.endIndex)
            items.insert(existingItem, at: insertionIndex)
            return existingIndex != insertionIndex
        }

        items.insert(item, at: min(requestedIndex, items.endIndex))
        return true
    }

    func persistenceWindow() -> PlaybackQueue {
        let lowerBound = max(currentIndex - 25, 0)
        let upperBound = min(currentIndex + 50, items.count - 1)
        guard lowerBound <= upperBound else { return self }
        return PlaybackQueue(
            items: Array(items[lowerBound...upperBound]),
            currentItemID: items[currentIndex].id,
            context: context,
            repeatMode: repeatMode
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
    private static let remoteForwardBufferDuration: TimeInterval = 15

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
                // Active remote audio must leave route capacity for the staged
                // successor and user-visible catalog requests. The default
                // zero lets AVFoundation choose an effectively unbounded
                // forward buffer, which can monopolize a constrained VPN path
                // until playback is paused.
                item.preferredForwardBufferDuration =
                    Self.remoteForwardBufferDuration
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
    let transportKind: PlaybackTransportKind
    let recordsHistory: Bool
    let reporter: (any PlaybackLifecycleReporting)?
    /// One deliberate server-negotiated recovery for a known-container direct
    /// file. PlaybackInfo-derived requests omit this closure so a failed route
    /// cannot recursively negotiate the same strategy.
    let forcedPlaybackInfoFallback: (@Sendable () async throws -> PlaybackRequest)?

    init(
        item: PlaybackItem,
        asset: PlaybackAsset,
        transportKind: PlaybackTransportKind,
        recordsHistory: Bool = true,
        reporter: (any PlaybackLifecycleReporting)? = nil,
        forcedPlaybackInfoFallback:
            (@Sendable () async throws -> PlaybackRequest)? = nil
    ) {
        self.item = item
        self.asset = asset
        self.transportKind = transportKind
        self.recordsHistory = recordsHistory
        self.reporter = reporter
        self.forcedPlaybackInfoFallback = forcedPlaybackInfoFallback
    }
}

/// Converts source-specific selections into provider-neutral playback requests.
/// Implementations own source validation and may throw a user-presentable error.
protocol PlaybackSourceAdapter: Sendable {
    associatedtype Selection: Sendable

    var source: MusicSourceID { get }
    func playbackRequest(for selection: Selection) async throws -> PlaybackRequest
}
