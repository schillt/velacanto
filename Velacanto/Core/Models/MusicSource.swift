import AVFoundation
import Foundation
import os

/// A small privacy-safe journal for diagnosing playback across process exits.
///
/// Xcode's attached console ends with the debugged process. This journal keeps
/// only bounded, caller-supplied state-machine events and replays the prior
/// launch tail into unified logging when the next process starts. Callers must
/// record categories, counts, revisions, booleans, and correlation UUIDs only;
/// provider IDs, media metadata, accounts, hosts, and URLs are prohibited.
final class PlaybackDiagnosticJournal: @unchecked Sendable {
    static let shared = PlaybackDiagnosticJournal()

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "PlaybackJournal"
    )

    private let lock = NSLock()
    private let fileURL: URL
    private let maximumByteCount: Int
    private let launchID = UUID().uuidString

    init(
        fileURL: URL? = nil,
        maximumByteCount: Int = 64 * 1_024,
        fileManager: FileManager = .default
    ) {
        self.maximumByteCount = max(maximumByteCount, 1_024)
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory =
                fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first?
                .appending(
                    path: "VelacantoDiagnostics",
                    directoryHint: .isDirectory
                )
                ?? fileManager.temporaryDirectory.appending(
                    path: "VelacantoDiagnostics",
                    directoryHint: .isDirectory
                )
            try? fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.fileURL = directory.appending(
                path: "playback-journal.log",
                directoryHint: .notDirectory
            )
        }
    }

    /// Replays the retained tail before writing this launch marker, so a new
    /// Xcode attachment can inspect the process that just terminated.
    func beginLaunch() {
        let previousEntries = entries(limit: 160)
        if !previousEntries.isEmpty {
            Self.logger.notice(
                "Previous playback journal entries=\(previousEntries.count, privacy: .public)"
            )
            for entry in previousEntries {
                Self.logger.notice("\(entry, privacy: .public)")
            }
        }
        record("process phase=started")
    }

    func record(_ event: String) {
        // Newlines could forge multiple records; URL punctuation is excluded
        // so an accidental URL cannot be retained as a usable address.
        let safeEvent =
            event
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "&", with: "-")
        let timestamp = Int(Date().timeIntervalSince1970 * 1_000)
        let line = "time_ms=\(timestamp) launch=\(launchID) \(safeEvent)\n"
        guard let lineData = line.data(using: .utf8) else { return }

        lock.withLock {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                _ = FileManager.default.createFile(
                    atPath: fileURL.path,
                    contents: nil
                )
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else {
                return
            }
            defer { try? handle.close() }
            let previousByteCount = (try? handle.seekToEnd()) ?? 0
            try? handle.write(contentsOf: lineData)
            guard previousByteCount + UInt64(lineData.count) > maximumByteCount
            else {
                return
            }

            var data = (try? Data(contentsOf: fileURL)) ?? Data()
            data = Data(data.suffix(maximumByteCount))
            if let newline = data.firstIndex(of: 0x0A),
                newline < data.endIndex
            {
                data = Data(data[data.index(after: newline)...])
            }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func entries(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return lock.withLock {
            guard
                let data = try? Data(contentsOf: fileURL),
                let contents = String(data: data, encoding: .utf8)
            else {
                return []
            }
            return Array(
                contents.split(separator: "\n", omittingEmptySubsequences: true)
                    .suffix(limit)
                    .map(String.init)
            )
        }
    }
}

enum PlaybackMediaMetricRole: String, Equatable, Sendable {
    case current
    case staged
}

struct PlaybackMediaMetricClaim: Equatable, Sendable {
    let generation: Int
    let role: PlaybackMediaMetricRole
    let requestOrdinal: Int
    let itemStartedAt: Date
}

/// Thread-safe ownership for one AVPlayerItem's metric events.
///
/// Native metric callbacks may arrive after the main-actor player has promoted
/// or removed an item. Claiming an event atomically snapshots its current role
/// and generation, while deactivation rejects callbacks after removal.
final class PlaybackMediaMetricContextOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int
    private var role: PlaybackMediaMetricRole
    private var nextRequestOrdinal = 1
    private var isActive = true
    private let itemStartedAt: Date

    init(
        generation: Int,
        role: PlaybackMediaMetricRole,
        itemStartedAt: Date = Date()
    ) {
        self.generation = generation
        self.role = role
        self.itemStartedAt = itemStartedAt
    }

    func update(generation: Int, role: PlaybackMediaMetricRole) {
        lock.withLock {
            guard isActive else { return }
            self.generation = generation
            self.role = role
        }
    }

    func claimNextRequest() -> PlaybackMediaMetricClaim? {
        lock.withLock {
            guard isActive else { return nil }
            let claim = PlaybackMediaMetricClaim(
                generation: generation,
                role: role,
                requestOrdinal: nextRequestOrdinal,
                itemStartedAt: itemStartedAt
            )
            nextRequestOrdinal += 1
            return claim
        }
    }

    func deactivate() {
        lock.withLock {
            isActive = false
        }
    }
}

enum PlaybackNetworkMetricProtocol: String, Equatable, Sendable {
    case unavailable
    case http1 = "http1"
    case http2 = "h2"
    case http3 = "h3"
    case quic
    case other

    init(nativeValue: String?) {
        switch nativeValue?.lowercased() {
        case nil, "": self = .unavailable
        case "http/1.0", "http/1.1": self = .http1
        case "h2": self = .http2
        case "h3": self = .http3
        case "quic": self = .quic
        default: self = .other
        }
    }
}

enum PlaybackNetworkMetricFetchType: String, Equatable, Sendable {
    case unavailable
    case unknown
    case network
    case cache
    case serverPush = "server-push"
    case future

    init(nativeValue: URLSessionTaskMetrics.ResourceFetchType?) {
        guard let nativeValue else {
            self = .unavailable
            return
        }
        switch nativeValue {
        case .unknown: self = .unknown
        case .networkLoad: self = .network
        case .localCache: self = .cache
        case .serverPush: self = .serverPush
        @unknown default: self = .future
        }
    }
}

struct PlaybackNetworkMetricSnapshot: Equatable, Sendable {
    let totalMilliseconds: Int64
    let fetchMilliseconds: Int64
    let dnsMilliseconds: Int64
    let connectMilliseconds: Int64
    let tlsMilliseconds: Int64
    let requestMilliseconds: Int64
    let timeToFirstByteMilliseconds: Int64
    let responseMilliseconds: Int64
    let transactionCount: Int
    let statusCode: Int
    let networkProtocol: PlaybackNetworkMetricProtocol
    let fetchType: PlaybackNetworkMetricFetchType
    let reusedConnection: Bool?
    let proxyConnection: Bool?
    let cellular: Bool?
    let constrained: Bool?
    let expensive: Bool?

    init(
        totalMilliseconds: Int64,
        fetchMilliseconds: Int64,
        dnsMilliseconds: Int64,
        connectMilliseconds: Int64,
        tlsMilliseconds: Int64,
        requestMilliseconds: Int64,
        timeToFirstByteMilliseconds: Int64,
        responseMilliseconds: Int64,
        transactionCount: Int,
        statusCode: Int,
        networkProtocol: PlaybackNetworkMetricProtocol,
        fetchType: PlaybackNetworkMetricFetchType,
        reusedConnection: Bool?,
        proxyConnection: Bool?,
        cellular: Bool?,
        constrained: Bool?,
        expensive: Bool?
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.fetchMilliseconds = fetchMilliseconds
        self.dnsMilliseconds = dnsMilliseconds
        self.connectMilliseconds = connectMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.requestMilliseconds = requestMilliseconds
        self.timeToFirstByteMilliseconds = timeToFirstByteMilliseconds
        self.responseMilliseconds = responseMilliseconds
        self.transactionCount = transactionCount
        self.statusCode = statusCode
        self.networkProtocol = networkProtocol
        self.fetchType = fetchType
        self.reusedConnection = reusedConnection
        self.proxyConnection = proxyConnection
        self.cellular = cellular
        self.constrained = constrained
        self.expensive = expensive
    }

    static let unavailable = PlaybackNetworkMetricSnapshot(
        totalMilliseconds: -1,
        fetchMilliseconds: -1,
        dnsMilliseconds: -1,
        connectMilliseconds: -1,
        tlsMilliseconds: -1,
        requestMilliseconds: -1,
        timeToFirstByteMilliseconds: -1,
        responseMilliseconds: -1,
        transactionCount: 0,
        statusCode: 0,
        networkProtocol: .unavailable,
        fetchType: .unavailable,
        reusedConnection: nil,
        proxyConnection: nil,
        cellular: nil,
        constrained: nil,
        expensive: nil
    )

    init(metrics: URLSessionTaskMetrics?) {
        guard let metrics else {
            self = .unavailable
            return
        }
        let transaction = metrics.transactionMetrics.last
        totalMilliseconds = Self.milliseconds(metrics.taskInterval.duration)
        fetchMilliseconds = Self.milliseconds(
            from: transaction?.fetchStartDate,
            to: transaction?.responseEndDate
        )
        dnsMilliseconds = Self.milliseconds(
            from: transaction?.domainLookupStartDate,
            to: transaction?.domainLookupEndDate
        )
        connectMilliseconds = Self.milliseconds(
            from: transaction?.connectStartDate,
            to: transaction?.connectEndDate
        )
        tlsMilliseconds = Self.milliseconds(
            from: transaction?.secureConnectionStartDate,
            to: transaction?.secureConnectionEndDate
        )
        requestMilliseconds = Self.milliseconds(
            from: transaction?.requestStartDate,
            to: transaction?.requestEndDate
        )
        timeToFirstByteMilliseconds = Self.milliseconds(
            from: transaction?.requestEndDate,
            to: transaction?.responseStartDate
        )
        responseMilliseconds = Self.milliseconds(
            from: transaction?.responseStartDate,
            to: transaction?.responseEndDate
        )
        transactionCount = metrics.transactionMetrics.count
        statusCode =
            (transaction?.response as? HTTPURLResponse)?.statusCode ?? 0
        networkProtocol = PlaybackNetworkMetricProtocol(
            nativeValue: transaction?.networkProtocolName
        )
        fetchType = PlaybackNetworkMetricFetchType(
            nativeValue: transaction?.resourceFetchType
        )
        reusedConnection = transaction?.isReusedConnection
        proxyConnection = transaction?.isProxyConnection
        cellular = transaction?.isCellular
        constrained = transaction?.isConstrained
        expensive = transaction?.isExpensive
    }

    static func milliseconds(from start: Date?, to end: Date?) -> Int64 {
        guard let start, let end else { return -1 }
        return milliseconds(end.timeIntervalSince(start))
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        let milliseconds = seconds * 1_000
        guard
            milliseconds.isFinite,
            milliseconds >= 0,
            milliseconds <= Double(Int32.max)
        else {
            return -1
        }
        return Int64(milliseconds.rounded())
    }

    static func relativeMilliseconds(_ date: Date, from origin: Date) -> Int64 {
        milliseconds(date.timeIntervalSince(origin))
    }
}

enum PlaybackMediaResourceMetricResult: String, Equatable, Sendable {
    case succeeded
    case failed
}

struct PlaybackMediaResourceMetricSnapshot: Equatable, Sendable {
    let eventMilliseconds: Int64
    let requestStartMilliseconds: Int64
    let requestEndMilliseconds: Int64
    let responseStartMilliseconds: Int64
    let responseEndMilliseconds: Int64
    let byteRangeLocation: Int64
    let byteRangeLength: Int64
    let readFromCache: Bool
    let result: PlaybackMediaResourceMetricResult
    let network: PlaybackNetworkMetricSnapshot
}

enum PlaybackNetworkRequestMetricKind: String, Equatable, Sendable {
    case playbackInfo = "playback-info"
    case sessionValidation = "session-validation"
    case artwork
    case playbackReport = "playback-report"
    case app
}

enum PlaybackMetricJournalFormatter {
    static func mediaResource(
        claim: PlaybackMediaMetricClaim,
        snapshot: PlaybackMediaResourceMetricSnapshot
    ) -> String {
        "av-resource generation=\(claim.generation) role=\(claim.role.rawValue) request=\(claim.requestOrdinal) event-ms=\(snapshot.eventMilliseconds) request-start-ms=\(snapshot.requestStartMilliseconds) request-end-ms=\(snapshot.requestEndMilliseconds) response-start-ms=\(snapshot.responseStartMilliseconds) response-end-ms=\(snapshot.responseEndMilliseconds) byte-range-location=\(snapshot.byteRangeLocation) byte-range-length=\(snapshot.byteRangeLength) result=\(snapshot.result.rawValue) read-from-cache=\(snapshot.readFromCache) \(networkFields(snapshot.network))"
    }

    static func appNetwork(
        kind: PlaybackNetworkRequestMetricKind,
        ordinal: Int,
        snapshot: PlaybackNetworkMetricSnapshot
    ) -> String {
        "network-metric kind=\(kind.rawValue) ordinal=\(ordinal) \(networkFields(snapshot))"
    }

    private static func networkFields(
        _ snapshot: PlaybackNetworkMetricSnapshot
    ) -> String {
        "total-ms=\(snapshot.totalMilliseconds) fetch-ms=\(snapshot.fetchMilliseconds) dns-ms=\(snapshot.dnsMilliseconds) connect-ms=\(snapshot.connectMilliseconds) tls-ms=\(snapshot.tlsMilliseconds) request-ms=\(snapshot.requestMilliseconds) ttfb-ms=\(snapshot.timeToFirstByteMilliseconds) response-ms=\(snapshot.responseMilliseconds) transactions=\(snapshot.transactionCount) status=\(snapshot.statusCode) protocol=\(snapshot.networkProtocol.rawValue) fetch=\(snapshot.fetchType.rawValue) reused=\(flag(snapshot.reusedConnection)) proxy=\(flag(snapshot.proxyConnection)) cellular=\(flag(snapshot.cellular)) constrained=\(flag(snapshot.constrained)) expensive=\(flag(snapshot.expensive))"
    }

    private static func flag(_ value: Bool?) -> String {
        switch value {
        case true: "true"
        case false: "false"
        case nil: "unavailable"
        }
    }
}

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
