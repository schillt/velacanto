import AVFoundation
import Foundation
import os

enum PlaybackState: Equatable, Sendable {
    case idle
    case loading
    case waiting
    case playing
    case paused
    case ended
    case failed(String)
}

struct PlaybackBufferState: Equatable, Sendable {
    let loadedThrough: TimeInterval
    let isEmpty: Bool
    let isLikelyToKeepUp: Bool

    static let empty = PlaybackBufferState(
        loadedThrough: 0,
        isEmpty: true,
        isLikelyToKeepUp: false
    )
}

struct PlaybackBufferJournalThrottle: Equatable, Sendable {
    static let loadedThroughMilestoneSeconds: TimeInterval = 30

    private var lastObservedState: PlaybackBufferState?
    private var hasObservedPositiveLoadedData = false
    private var highestJournaledLoadedThroughMilestone = 0

    mutating func shouldJournal(_ state: PlaybackBufferState) -> Bool {
        let previousState = lastObservedState
        let hasPositiveLoadedData = state.loadedThrough > 0
        let milestone = Self.loadedThroughMilestone(for: state.loadedThrough)
        let isInitialSample = previousState == nil
        let hasBooleanTransition =
            previousState.map {
                $0.isEmpty != state.isEmpty
                    || $0.isLikelyToKeepUp != state.isLikelyToKeepUp
            } ?? false
        let hasFirstPositiveLoadedData =
            !hasObservedPositiveLoadedData && hasPositiveLoadedData
        let hasReachedNewMilestone =
            milestone > highestJournaledLoadedThroughMilestone

        lastObservedState = state
        hasObservedPositiveLoadedData =
            hasObservedPositiveLoadedData || hasPositiveLoadedData
        highestJournaledLoadedThroughMilestone = max(
            highestJournaledLoadedThroughMilestone,
            milestone
        )

        return isInitialSample
            || hasBooleanTransition
            || hasFirstPositiveLoadedData
            || hasReachedNewMilestone
    }

    mutating func reset() {
        self = Self()
    }

    private static func loadedThroughMilestone(
        for loadedThrough: TimeInterval
    ) -> Int {
        guard loadedThrough.isFinite, loadedThrough > 0 else { return 0 }
        let milestone = floor(
            loadedThrough / loadedThroughMilestoneSeconds
        )
        guard milestone < TimeInterval(Int.max) else { return Int.max }
        return Int(milestone)
    }
}

enum AudioPlayerEngineEvent: Equatable, Sendable {
    case timeChangedForGeneration(
        elapsed: TimeInterval,
        duration: TimeInterval,
        generation: Int
    )
    case stateChanged(PlaybackState)
    case stateChangedForGeneration(PlaybackState, generation: Int)
    case advancedToNextItem
    case failedToAdvanceToNextItem(AudioPlayerReplacementFailureKind)
    case bufferStateChanged(PlaybackBufferState)
    case preparedNextItemStateChanged(AudioPlayerPreparedItemState)
}

enum AudioPlayerReplacementFailureKind: Equatable, Sendable {
    case timeout
    case offline
    case dns
    case transportSecurity
    case other
}

enum AudioPlayerPreparedItemPhase: Equatable, Sendable {
    case absent
    case preparing
    case ready
    case failed(AudioPlayerReplacementFailureKind)
}

struct AudioPlayerPreparedItemState: Equatable, Sendable {
    let identity: PlaybackItemQueueIdentity?
    let generation: Int
    let phase: AudioPlayerPreparedItemPhase
}

enum AudioPlayerTerminalFailureKind: Equatable, Sendable {
    case transportSecurity
    case other
}

/// Main-actor bridge to the platform player.
///
/// The coordinator owns command ordering. Engine implementations must publish
/// events synchronously on the main actor in the order observed from the
/// platform, including terminal `.failed` and `.ended` states, and must replace
/// the current item before reporting its initial loading state. Commands do not
/// throw; platform failures belong in `eventHandler`, which is replaced rather
/// than accumulated by the coordinator.
@MainActor
protocol AudioPlayerEngine: AnyObject {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)? { get set }
    var hasCurrentItem: Bool { get }
    var terminalFailureKind: AudioPlayerTerminalFailureKind? { get }
    var currentGeneration: Int { get }
    var preparedNextItemState: AudioPlayerPreparedItemState { get }

    func load(_ item: AVPlayerItem, identity: PlaybackItemQueueIdentity)
    func preload(
        _ item: AVPlayerItem?,
        identity: PlaybackItemQueueIdentity?
    )
    func advanceToNextItem()
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

enum PlaybackMediaMetricCollectionStatus: String, Equatable, Sendable {
    case active
    case apiUnavailable = "api-unavailable"
    case publisherRejected = "publisher-rejected"
    case subscriberRejected = "subscriber-rejected"

    static func availability(nativeAPIAvailable: Bool) -> Self {
        nativeAPIAvailable ? .active : .apiUnavailable
    }
}

enum PlaybackMetricItemInstallationProvenance: String, Equatable, Sendable {
    case created
    case stagedReused = "staged-reused"
}

private enum PlaybackMetricItemRemovalReason: String {
    case loadReplaced = "load-replaced"
    case preloadReplaced = "preload-replaced"
    case preloadRejected = "preload-rejected"
    case advanceFailed = "advance-failed"
    case advanced = "advanced"
    case playbackEnded = "playback-ended"
    case stopped
}

private enum PlaybackAssetReadinessProbeOutcome: String {
    case playable
    case notPlayable = "not-playable"
    case timeout
    case offline
    case dns
    case tls
    case other

    init(_ failureKind: AudioPlayerReplacementFailureKind) {
        switch failureKind {
        case .timeout: self = .timeout
        case .offline: self = .offline
        case .dns: self = .dns
        case .transportSecurity: self = .tls
        case .other: self = .other
        }
    }
}

final class AVPlayerItemMediaMetricCollector: NSObject,
    __AVMetricEventStreamSubscriber, @unchecked Sendable
{
    private let contextOwner: PlaybackMediaMetricContextOwner
    private let record: @Sendable (String) -> Void
    private var eventStream: __AVMetricEventStream?

    private init(
        contextOwner: PlaybackMediaMetricContextOwner,
        record: @escaping @Sendable (String) -> Void
    ) {
        self.contextOwner = contextOwner
        self.record = record
        super.init()
    }

    static func make(
        item: AVPlayerItem,
        contextOwner: PlaybackMediaMetricContextOwner,
        record: @escaping @Sendable (String) -> Void
    ) -> (
        collector: AVPlayerItemMediaMetricCollector?,
        status: PlaybackMediaMetricCollectionStatus
    ) {
        guard #available(iOS 18, macOS 15, tvOS 18, watchOS 11, *) else {
            return (nil, .apiUnavailable)
        }
        let collector = AVPlayerItemMediaMetricCollector(
            contextOwner: contextOwner,
            record: record
        )
        let stream = __AVMetricEventStream()
        guard stream.add(item) else {
            return (nil, .publisherRejected)
        }
        guard stream.setSubscriber(collector, queue: nil) else {
            return (nil, .subscriberRejected)
        }
        stream.subscribe(
            toMetricEvent: AVMetricMediaResourceRequestEvent.self
        )
        collector.eventStream = stream
        return (collector, .active)
    }

    func update(generation: Int, role: PlaybackMediaMetricRole) {
        contextOwner.update(generation: generation, role: role)
    }

    func deactivate() {
        contextOwner.deactivate()
        eventStream = nil
    }

    nonisolated func publisher(
        _ publisher: any AVMetricEventStreamPublisher,
        didReceive event: AVMetricEvent
    ) {
        guard
            let event = event as? AVMetricMediaResourceRequestEvent,
            let claim = contextOwner.claimNextRequest()
        else {
            return
        }
        let range = event.byteRange
        let snapshot = PlaybackMediaResourceMetricSnapshot(
            eventMilliseconds:
                PlaybackNetworkMetricSnapshot
                .relativeMilliseconds(event.date, from: claim.itemStartedAt),
            requestStartMilliseconds:
                PlaybackNetworkMetricSnapshot
                .relativeMilliseconds(
                    event.requestStartTime,
                    from: claim.itemStartedAt
                ),
            requestEndMilliseconds:
                PlaybackNetworkMetricSnapshot
                .relativeMilliseconds(
                    event.requestEndTime,
                    from: claim.itemStartedAt
                ),
            responseStartMilliseconds:
                PlaybackNetworkMetricSnapshot
                .relativeMilliseconds(
                    event.responseStartTime,
                    from: claim.itemStartedAt
                ),
            responseEndMilliseconds:
                PlaybackNetworkMetricSnapshot
                .relativeMilliseconds(
                    event.responseEndTime,
                    from: claim.itemStartedAt
                ),
            byteRangeLocation: Self.metricRangeValue(range.location),
            byteRangeLength: Self.metricRangeValue(range.length),
            readFromCache: event.wasReadFromCache,
            result: event.errorEvent == nil ? .succeeded : .failed,
            network: PlaybackNetworkMetricSnapshot(
                metrics: event.networkTransactionMetrics
            )
        )
        record(
            PlaybackMetricJournalFormatter.mediaResource(
                claim: claim,
                snapshot: snapshot
            )
        )
    }

    private nonisolated static func metricRangeValue(_ value: Int) -> Int64 {
        guard value != NSNotFound, value >= 0 else { return -1 }
        return Int64(value)
    }
}

@MainActor
final class AVFoundationAudioPlayerEngine: AudioPlayerEngine {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)?

    var hasCurrentItem: Bool {
        player.currentItem != nil
    }

    private(set) var terminalFailureKind: AudioPlayerTerminalFailureKind?

    private var player: AVQueuePlayer
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var bufferLikelyObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var currentItemDidEnd = false
    private var terminalFailureMessage: String?
    private var currentIdentity: PlaybackItemQueueIdentity?
    private var stagedNextItem: AVPlayerItem?
    private var stagedNextIdentity: PlaybackItemQueueIdentity?
    private var stagedNextStartsAtBeginning = false
    private var stagedAdvanceStatusObservation: NSKeyValueObservation?
    private var stagedAssetReadinessTask: Task<Void, Never>?
    private var stagedAssetReadinessProbeActive = false
    private var isStagedAdvanceRequested = false
    private var pendingSeekTime: TimeInterval?
    private var lastJournalState: String?
    private var lastJournalItemStatus: String?
    private var bufferJournalThrottle = PlaybackBufferJournalThrottle()
    private var itemGeneration = 0
    private var cachedPlayedItems: [PlaybackItemQueueIdentity: AVPlayerItem] = [:]
    private var cachedPlayedItemOrder: [PlaybackItemQueueIdentity] = []
    private var mediaMetricCollectors: [ObjectIdentifier: AVPlayerItemMediaMetricCollector] = [:]

    private static let maximumCachedPlayedItemCount = 8

    var currentGeneration: Int { itemGeneration }

    private(set) var preparedNextItemState = AudioPlayerPreparedItemState(
        identity: nil,
        generation: 0,
        phase: .absent
    )

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "AVPlayer"
    )

    init(player: AVQueuePlayer = AVQueuePlayer()) {
        self.player = player
        player.automaticallyWaitsToMinimizeStalling = true
        installTimeObserver()
        installTimeControlObservation(for: itemGeneration)
    }

    func load(
        _ item: AVPlayerItem,
        identity: PlaybackItemQueueIdentity
    ) {
        let previousCurrentItem = player.currentItem
        let installationProvenance = Self.itemInstallationProvenance(
            item: item,
            stagedItem: stagedNextItem
        )
        let reusedExactStagedItem = installationProvenance == .stagedReused
        cancelStagedAdvance(
            preservingMetricsFor: reusedExactStagedItem ? item : nil,
            removalReason: .loadReplaced
        )
        cacheCurrentItem()
        if let previousCurrentItem, previousCurrentItem !== item {
            stopMediaMetricCollection(
                for: previousCurrentItem,
                role: .current,
                generation: itemGeneration,
                reason: .loadReplaced
            )
        }
        itemGeneration += 1
        currentItemDidEnd = false
        terminalFailureMessage = nil
        terminalFailureKind = nil
        stagedNextItem = nil
        pendingSeekTime = nil
        lastJournalState = nil
        lastJournalItemStatus = nil
        bufferJournalThrottle.reset()
        removeCurrentItemObservers()
        player.pause()
        player.removeAllItems()
        startMediaMetricCollection(
            for: item,
            role: .current,
            generation: itemGeneration
        )
        player.insert(item, after: nil)
        currentIdentity = identity
        installTimeControlObservation(for: itemGeneration)
        Self.logger.notice(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=load"
        )
        journal(
            "role=current phase=item-installed provenance=\(installationProvenance.rawValue) cached-remote-items=\(cachedPlayedItems.count)"
        )
        journal("role=current phase=load")
        eventHandler?(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 0,
                generation: itemGeneration
            )
        )
        publishStateEvent(.loading, generation: itemGeneration)
        observe(item)
    }

    func preload(
        _ item: AVPlayerItem?,
        identity: PlaybackItemQueueIdentity?
    ) {
        cancelStagedAdvance(removalReason: .preloadReplaced)
        stagedNextIdentity = identity
        Self.logger.notice(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=preload staged=\(item != nil, privacy: .public) has_current=\(self.player.currentItem != nil, privacy: .public)"
        )
        guard
            let suppliedItem = item,
            let identity = stagedNextIdentity
        else { return }
        let cachedItem = takeCachedPlayedItem(for: identity)
        let item = cachedItem ?? suppliedItem
        stagedNextItem = item
        stagedNextStartsAtBeginning = cachedItem != nil
        if let currentItem = player.currentItem {
            guard player.canInsert(item, after: currentItem) else {
                stopMediaMetricCollection(
                    for: item,
                    role: .staged,
                    generation: itemGeneration,
                    reason: .preloadRejected
                )
                return
            }
            startMediaMetricCollection(
                for: item,
                role: .staged,
                generation: itemGeneration
            )
            player.insert(item, after: currentItem)
        } else {
            guard player.canInsert(item, after: nil) else {
                stopMediaMetricCollection(
                    for: item,
                    role: .staged,
                    generation: itemGeneration,
                    reason: .preloadRejected
                )
                return
            }
            startMediaMetricCollection(
                for: item,
                role: .staged,
                generation: itemGeneration
            )
            player.insert(item, after: nil)
        }
        journal(
            "role=staged phase=preload-inserted provenance=\(cachedItem == nil ? "created" : "cached-reused") cached-remote-items=\(cachedPlayedItems.count)"
        )
        publishPreparedNextItemState(.preparing)
        stagedAdvanceStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.handleStagedAdvanceStatus(for: item)
            }
        }
        stagedAssetReadinessProbeActive = true
        journal("role=staged phase=asset-readiness-probe status=started")
        stagedAssetReadinessTask = Task { [weak self, weak item] in
            guard let item else { return }
            do {
                let isPlayable = try await item.asset.load(.isPlayable)
                guard !Task.isCancelled, let self else { return }
                guard self.stagedNextItem === item else { return }
                self.finishStagedAssetReadinessProbe(
                    outcome: isPlayable ? .playable : .notPlayable
                )
                guard isPlayable else {
                    if self.isStagedAdvanceRequested {
                        self.failStagedAdvance(.other)
                    } else {
                        self.publishPreparedNextItemState(.failed(.other))
                    }
                    return
                }
                // Asset playability only proves that AVFoundation recognizes
                // the resource type. The player item can still be `.unknown`
                // while its remote media request is unresolved. Its status
                // observer is the sole readiness owner and commits only after
                // `.readyToPlay`.
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                guard self.stagedNextItem === item else { return }
                let failureKind = Self.replacementFailureKind(for: error)
                self.finishStagedAssetReadinessProbe(
                    outcome: PlaybackAssetReadinessProbeOutcome(failureKind)
                )
                if self.isStagedAdvanceRequested {
                    self.failStagedAdvance(failureKind)
                } else {
                    self.publishPreparedNextItemState(.failed(failureKind))
                }
            }
        }
        journal("role=staged phase=preload-preparing")
    }

    func advanceToNextItem() {
        guard let stagedNextItem else {
            Self.logger.error(
                "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=advance-rejected reason=no-staged-item has_current=\(self.player.currentItem != nil, privacy: .public)"
            )
            return
        }
        guard !isStagedAdvanceRequested else {
            journal("phase=advance-deferred reason=already-preparing")
            return
        }
        guard case .ready = preparedNextItemState.phase else {
            if case .failed(let failureKind) = preparedNextItemState.phase {
                isStagedAdvanceRequested = true
                failStagedAdvance(failureKind)
            } else {
                journal("phase=advance-rejected reason=candidate-not-ready")
            }
            return
        }
        isStagedAdvanceRequested = true
        Self.logger.notice(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=advance-preparing"
        )
        journal("phase=advance-preparing")
        handleStagedAdvanceStatus(for: stagedNextItem)
    }

    private func handleStagedAdvanceStatus(for item: AVPlayerItem) {
        guard
            stagedNextItem === item
        else {
            return
        }
        let statusName = Self.statusName(item.status)
        journal("phase=advance-candidate status=\(statusName)")
        switch item.status {
        case .unknown:
            publishPreparedNextItemState(.preparing)
            return
        case .readyToPlay:
            publishPreparedNextItemState(.ready)
            if isStagedAdvanceRequested {
                commitStagedAdvance(item)
            }
        case .failed:
            let failureKind = Self.replacementFailureKind(
                for: item.error ?? player.error
            )
            publishPreparedNextItemState(.failed(failureKind))
            if isStagedAdvanceRequested {
                failStagedAdvance(failureKind)
            }
        @unknown default:
            return
        }
    }

    private func commitStagedAdvance(_ item: AVPlayerItem) {
        guard
            isStagedAdvanceRequested,
            stagedNextItem === item
        else {
            return
        }
        let previousItem = player.currentItem
        let previousIdentity = currentIdentity
        let nextIdentity = stagedNextIdentity
        if player.currentItem !== item {
            if let previousItem, let previousIdentity {
                cachePlayedItem(previousItem, identity: previousIdentity)
                stopMediaMetricCollection(
                    for: previousItem,
                    role: .current,
                    generation: itemGeneration,
                    reason: .advanced
                )
            }
            player.advanceToNextItem()
        }
        guard player.currentItem === item else {
            failStagedAdvance(.other)
            return
        }
        currentIdentity = nextIdentity
        if stagedNextStartsAtBeginning {
            player.seek(to: .zero)
        }
        stagedAdvanceStatusObservation = nil
        cancelStagedAssetReadinessProbe()
        stagedNextItem = nil
        stagedNextIdentity = nil
        isStagedAdvanceRequested = false
        removeCurrentItemObservers()
        stagedNextStartsAtBeginning = false
        publishPreparedNextItemState(.absent)
        Self.logger.notice(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=advance-committed"
        )
        beginObservingAdvancedItem()
    }

    private func failStagedAdvance(
        _ failureKind: AudioPlayerReplacementFailureKind
    ) {
        guard isStagedAdvanceRequested else { return }
        stagedAdvanceStatusObservation = nil
        cancelStagedAssetReadinessProbe()
        let failedItem = stagedNextItem
        removeStagedItemAndRecacheIfPossible()
        if let failedItem {
            stopMediaMetricCollection(
                for: failedItem,
                role: .staged,
                generation: itemGeneration,
                reason: .advanceFailed
            )
        }
        publishPreparedNextItemState(.failed(failureKind))
        stagedNextItem = nil
        stagedNextIdentity = nil
        stagedNextStartsAtBeginning = false
        isStagedAdvanceRequested = false
        let category = Self.replacementFailureName(failureKind)
        Self.logger.error(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=advance-failed category=\(category, privacy: .public)"
        )
        journal("phase=advance-failed category=\(category)")
        eventHandler?(.failedToAdvanceToNextItem(failureKind))
    }

    private func cancelStagedAdvance(
        preservingMetricsFor preservedItem: AVPlayerItem? = nil,
        removalReason: PlaybackMetricItemRemovalReason = .preloadReplaced
    ) {
        stagedAdvanceStatusObservation = nil
        cancelStagedAssetReadinessProbe()
        let cancelledItem = stagedNextItem
        removeStagedItemAndRecacheIfPossible()
        if let cancelledItem, cancelledItem !== preservedItem {
            stopMediaMetricCollection(
                for: cancelledItem,
                role: .staged,
                generation: itemGeneration,
                reason: removalReason
            )
        }
        isStagedAdvanceRequested = false
        self.stagedNextItem = nil
        stagedNextIdentity = nil
        stagedNextStartsAtBeginning = false
        publishPreparedNextItemState(.absent)
    }

    private func removeStagedItemAndRecacheIfPossible() {
        guard let stagedNextItem else { return }
        if player.currentItem === stagedNextItem {
            // A cold staged item has no committed AVPlayerItem to preserve.
            // `preload` inserts it only so AVFoundation can evaluate status;
            // cancellation removes it without claiming a queue transition.
            removeCurrentItemObservers()
            player.pause()
            player.removeAllItems()
            currentIdentity = nil
        } else if player.currentItem !== stagedNextItem {
            player.remove(stagedNextItem)
        }
        if stagedNextStartsAtBeginning, let stagedNextIdentity {
            cachePlayedItem(stagedNextItem, identity: stagedNextIdentity)
        }
    }

    private func cacheCurrentItem() {
        guard let item = player.currentItem, let currentIdentity else { return }
        cachePlayedItem(item, identity: currentIdentity)
    }

    private func cachePlayedItem(
        _ item: AVPlayerItem,
        identity: PlaybackItemQueueIdentity
    ) {
        guard
            let asset = item.asset as? AVURLAsset,
            asset.url.isFileURL
        else {
            return
        }
        cachedPlayedItems[identity] = item
        cachedPlayedItemOrder.removeAll { $0 == identity }
        cachedPlayedItemOrder.append(identity)
        while cachedPlayedItemOrder.count > Self.maximumCachedPlayedItemCount {
            let removedIdentity = cachedPlayedItemOrder.removeFirst()
            cachedPlayedItems[removedIdentity] = nil
        }
        journal(
            "phase=cache-count local-items=\(cachedPlayedItems.count) cached-remote-items=0"
        )
    }

    private func takeCachedPlayedItem(
        for identity: PlaybackItemQueueIdentity
    ) -> AVPlayerItem? {
        cachedPlayedItemOrder.removeAll { $0 == identity }
        let item = cachedPlayedItems.removeValue(forKey: identity)
        if item != nil {
            journal(
                "phase=cache-count local-items=\(cachedPlayedItems.count) cached-remote-items=0"
            )
        }
        return item
    }

    private func publishPreparedNextItemState(
        _ phase: AudioPlayerPreparedItemPhase
    ) {
        let state = AudioPlayerPreparedItemState(
            identity: phase == .absent ? nil : stagedNextIdentity,
            generation: itemGeneration,
            phase: phase
        )
        guard state != preparedNextItemState else { return }
        preparedNextItemState = state
        eventHandler?(.preparedNextItemStateChanged(state))
    }

    func play() {
        guard player.currentItem != nil else { return }

        currentItemDidEnd = false
        terminalFailureMessage = nil
        terminalFailureKind = nil
        journal("phase=play-command")
        player.play()
    }

    func pause() {
        guard player.currentItem != nil else { return }
        player.pause()
    }

    func seek(to time: TimeInterval) {
        guard let item = player.currentItem, time.isFinite else { return }

        if currentItemDidEnd {
            currentItemDidEnd = false
            publishStateEvent(.paused, generation: itemGeneration)
        }

        let target = max(time, 0)
        switch item.status {
        case .unknown:
            // A restored remote item has not opened its stream yet. Starting a
            // byte-range seek concurrently with that initial request creates a
            // second transport demand and has proven unreliable through
            // constrained VPN routes. Keep only the latest requested position
            // and apply it once this exact item becomes ready.
            pendingSeekTime = target
            journal("phase=seek-deferred")
            return
        case .readyToPlay:
            pendingSeekTime = nil
        case .failed:
            journal("phase=seek-rejected reason=item-failed")
            return
        @unknown default:
            pendingSeekTime = target
            journal("phase=seek-deferred status=unknown-future")
            return
        }

        performSeek(to: target)
    }

    private func performSeek(to time: TimeInterval) {
        // A packet-exact seek is not available for every remote audio stream.
        // In particular, servers can expose audio with sparse byte-range
        // boundaries. Let AVFoundation select a nearby decodable boundary so a
        // manual scrub completes instead of remaining stalled at its old time.
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        journal("phase=seek-committed")
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func stop() {
        cancelStagedAdvance(removalReason: .stopped)
        if let currentItem = player.currentItem {
            stopMediaMetricCollection(
                for: currentItem,
                role: .current,
                generation: itemGeneration,
                reason: .stopped
            )
        }
        currentItemDidEnd = false
        terminalFailureMessage = nil
        terminalFailureKind = nil
        stagedNextItem = nil
        currentIdentity = nil
        cachedPlayedItems.removeAll()
        cachedPlayedItemOrder.removeAll()
        pendingSeekTime = nil
        lastJournalState = nil
        lastJournalItemStatus = nil
        bufferJournalThrottle.reset()
        player.pause()
        removeCurrentItemObservers()
        player.removeAllItems()
        journal("phase=cache-count remote-items=0")
        eventHandler?(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 0,
                generation: itemGeneration
            )
        )
        publishStateEvent(.idle, generation: itemGeneration)
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.publishTime(time)
            }
        }
    }

    private func installTimeControlObservation(for generation: Int) {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor [weak self] in
                self?.publishState(for: status, generation: generation)
            }
        }
    }

    private func uninstallPlayerObservers(from observedPlayer: AVQueuePlayer) {
        timeControlObservation = nil
        if let timeObserver {
            observedPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemStatusObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleStatusChange(for: item)
            }
        }
        bufferEmptyObservation = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.publishBufferState(for: item)
            }
        }
        bufferLikelyObservation = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.publishBufferState(for: item)
            }
        }
        loadedRangesObservation = item.observe(
            \.loadedTimeRanges,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.publishBufferState(for: item)
            }
        }

        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handlePlaybackEnded(item)
                }
            },
            center.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.publishFailure(item.error)
                }
            },
            center.addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logPlaybackStall(for: item)
                    self?.publishState(
                        for: .waitingToPlayAtSpecifiedRate,
                        generation: self?.itemGeneration
                    )
                }
            },
            center.addObserver(
                forName: AVPlayerItem.newErrorLogEntryNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logErrorMetrics(for: item)
                }
            },
            center.addObserver(
                forName: AVPlayerItem.newAccessLogEntryNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.logAccessMetrics(for: item)
                }
            },
        ]
    }

    private func handleStatusChange(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }

        let statusName = Self.statusName(item.status)
        if statusName != lastJournalItemStatus {
            lastJournalItemStatus = statusName
            journal("phase=item-status status=\(statusName)")
        }

        switch item.status {
        case .unknown:
            publishStateEvent(.loading, generation: itemGeneration)
        case .readyToPlay:
            if let pendingSeekTime {
                self.pendingSeekTime = nil
                performSeek(to: pendingSeekTime)
            }
            publishTime(player.currentTime())
            publishState(
                for: player.timeControlStatus,
                generation: itemGeneration
            )
        case .failed:
            publishFailure(item.error ?? player.error)
        @unknown default:
            publishStateEvent(.loading, generation: itemGeneration)
        }
    }

    private func publishState(
        for status: AVPlayer.TimeControlStatus,
        generation: Int? = nil
    ) {
        let generation = generation ?? itemGeneration
        guard !hasUncommittedStagedCurrent else { return }
        journalStateIfChanged(status)
        if let terminalFailureMessage {
            publishStateEvent(
                .failed(terminalFailureMessage),
                generation: generation
            )
            return
        }

        if currentItemDidEnd {
            publishStateEvent(.ended, generation: generation)
            return
        }

        guard let item = player.currentItem else {
            publishStateEvent(.idle, generation: generation)
            return
        }

        if item.status == .failed {
            publishFailure(item.error ?? player.error)
            return
        }

        if item.status == .unknown {
            publishStateEvent(.loading, generation: generation)
            return
        }

        switch status {
        case .paused:
            publishStateEvent(.paused, generation: generation)
        case .waitingToPlayAtSpecifiedRate:
            let reason = Self.waitingReasonName(player.reasonForWaitingToPlay)
            Self.logger.debug(
                "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=waiting reason=\(reason, privacy: .public)"
            )
            journal("role=current phase=waiting reason=\(reason)")
            publishStateEvent(.waiting, generation: generation)
        case .playing:
            publishStateEvent(.playing, generation: generation)
        @unknown default:
            publishStateEvent(.paused, generation: generation)
        }
    }

    private func publishStateEvent(
        _ state: PlaybackState,
        generation: Int
    ) {
        eventHandler?(
            .stateChangedForGeneration(state, generation: generation)
        )
    }

    private func publishTime(_ time: CMTime) {
        guard !hasUncommittedStagedCurrent else { return }
        let currentSeconds = time.seconds
        let elapsed = currentSeconds.isFinite ? max(currentSeconds, 0) : 0

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration =
            itemDuration.isFinite && itemDuration > 0
            ? itemDuration
            : 0

        eventHandler?(
            .timeChangedForGeneration(
                elapsed: elapsed,
                duration: duration,
                generation: itemGeneration
            )
        )
    }

    private func publishBufferState(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let loadedThrough =
            item.loadedTimeRanges
            .compactMap { $0.timeRangeValue.end.seconds }
            .filter(\.isFinite)
            .max() ?? 0
        let state = PlaybackBufferState(
            loadedThrough: max(loadedThrough, 0),
            isEmpty: item.isPlaybackBufferEmpty,
            isLikelyToKeepUp: item.isPlaybackLikelyToKeepUp
        )
        if bufferJournalThrottle.shouldJournal(state) {
            journal(
                "role=current phase=buffer empty=\(state.isEmpty) likely=\(state.isLikelyToKeepUp) loaded-through-ms=\(PlaybackNetworkMetricSnapshot.milliseconds(state.loadedThrough))"
            )
        }
        eventHandler?(
            .bufferStateChanged(state)
        )
    }

    private var hasUncommittedStagedCurrent: Bool {
        stagedNextItem != nil && player.currentItem === stagedNextItem
    }

    private func handlePlaybackEnded(_ endedItem: AVPlayerItem) {
        if player.currentItem !== endedItem {
            if let currentIdentity {
                cachePlayedItem(endedItem, identity: currentIdentity)
            }
            stopMediaMetricCollection(
                for: endedItem,
                role: .current,
                generation: itemGeneration,
                reason: .playbackEnded
            )
            currentIdentity = stagedNextIdentity
            beginObservingAdvancedItem()
            return
        }
        currentItemDidEnd = true
        terminalFailureMessage = nil

        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            eventHandler?(
                .timeChangedForGeneration(
                    elapsed: duration,
                    duration: duration,
                    generation: itemGeneration
                )
            )
        }
        publishStateEvent(.ended, generation: itemGeneration)
    }

    private func beginObservingAdvancedItem() {
        guard let currentItem = player.currentItem else {
            publishStateEvent(.ended, generation: itemGeneration)
            return
        }
        itemGeneration += 1
        installTimeControlObservation(for: itemGeneration)
        stagedAdvanceStatusObservation = nil
        cancelStagedAssetReadinessProbe()
        stagedNextItem = nil
        stagedNextIdentity = nil
        stagedNextStartsAtBeginning = false
        isStagedAdvanceRequested = false
        publishPreparedNextItemState(.absent)
        currentItemDidEnd = false
        terminalFailureMessage = nil
        terminalFailureKind = nil
        pendingSeekTime = nil
        lastJournalState = nil
        lastJournalItemStatus = nil
        bufferJournalThrottle.reset()
        startMediaMetricCollection(
            for: currentItem,
            role: .current,
            generation: itemGeneration
        )
        removeCurrentItemObservers()
        observe(currentItem)
        Self.logger.notice(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=advanced"
        )
        journal(
            "role=current phase=item-installed provenance=staged-reused cached-remote-items=\(cachedPlayedItems.count)"
        )
        journal("role=current phase=advanced")
        eventHandler?(
            .timeChangedForGeneration(
                elapsed: 0,
                duration: 0,
                generation: itemGeneration
            )
        )
        eventHandler?(.advancedToNextItem)
        publishState(
            for: player.timeControlStatus,
            generation: itemGeneration
        )
    }

    private func publishFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "The audio could not be played."
        let nsError = error as NSError?
        Self.logger.error(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=terminal-failure domain=\(nsError?.domain ?? "unknown", privacy: .public) code=\(nsError?.code ?? 0, privacy: .public)"
        )
        journal(
            "phase=terminal-failure domain=\(nsError?.domain ?? "unknown") code=\(nsError?.code ?? 0)"
        )
        currentItemDidEnd = false
        terminalFailureMessage = message
        terminalFailureKind = Self.failureKind(for: error)
        publishStateEvent(.failed(message), generation: itemGeneration)
    }

    private static func failureKind(
        for error: Error?
    ) -> AudioPlayerTerminalFailureKind {
        guard let nsError = error as NSError? else { return .other }
        if nsError.domain == NSURLErrorDomain,
            [
                NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorClientCertificateRejected,
                NSURLErrorClientCertificateRequired,
            ].contains(nsError.code)
        {
            return .transportSecurity
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return failureKind(for: underlying)
        }
        return .other
    }

    private static func replacementFailureKind(
        for error: Error?
    ) -> AudioPlayerReplacementFailureKind {
        guard let nsError = error as NSError? else { return .other }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorInternationalRoamingOff,
                NSURLErrorDataNotAllowed:
                return .offline
            case NSURLErrorDNSLookupFailed,
                NSURLErrorCannotFindHost:
                return .dns
            case NSURLErrorSecureConnectionFailed,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorClientCertificateRejected,
                NSURLErrorClientCertificateRequired:
                return .transportSecurity
            default:
                break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return replacementFailureKind(for: underlying)
        }
        return .other
    }

    private static func replacementFailureName(
        _ kind: AudioPlayerReplacementFailureKind
    ) -> String {
        switch kind {
        case .timeout: "timeout"
        case .offline: "offline"
        case .dns: "dns"
        case .transportSecurity: "tls"
        case .other: "other"
        }
    }

    private func logPlaybackStall(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let reason = Self.waitingReasonName(player.reasonForWaitingToPlay)
        Self.logger.error(
            "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=stalled likely_to_keep_up=\(item.isPlaybackLikelyToKeepUp, privacy: .public) buffer_empty=\(item.isPlaybackBufferEmpty, privacy: .public) waiting_reason=\(reason, privacy: .public)"
        )
        journal(
            "phase=stalled likely-to-keep-up=\(item.isPlaybackLikelyToKeepUp) buffer-empty=\(item.isPlaybackBufferEmpty) waiting-reason=\(reason)"
        )
    }

    private func logErrorMetrics(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        item.fetchErrorLog { [weak self, weak item] log in
            Task { @MainActor [weak self, weak item] in
                guard
                    let self,
                    let item,
                    item === self.player.currentItem,
                    let event = log?.events.last
                else {
                    return
                }
                Self.logger.error(
                    "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=error-log domain=\(event.errorDomain, privacy: .public) status=\(event.errorStatusCode, privacy: .public)"
                )
                self.journal(
                    "phase=error-log domain=\(event.errorDomain) status=\(event.errorStatusCode)"
                )
            }
        }
    }

    private func logAccessMetrics(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        item.fetchAccessLog { [weak self, weak item] log in
            Task { @MainActor [weak self, weak item] in
                guard
                    let self,
                    let item,
                    item === self.player.currentItem,
                    let event = log?.events.last
                else {
                    return
                }
                let observedBitrate = Self.diagnosticMetricInteger(
                    event.observedBitrate
                )
                let indicatedBitrate = Self.diagnosticMetricInteger(
                    event.indicatedBitrate
                )
                let startupMilliseconds =
                    PlaybackNetworkMetricSnapshot
                    .milliseconds(event.startupTime)
                let transferMilliseconds =
                    PlaybackNetworkMetricSnapshot
                    .milliseconds(event.transferDuration)
                Self.logger.debug(
                    "AVPlayer generation=\(self.itemGeneration, privacy: .public) phase=access-log observed_bps=\(observedBitrate, privacy: .public) indicated_bps=\(indicatedBitrate, privacy: .public) transfer_s=\(event.transferDuration, privacy: .public) bytes=\(event.numberOfBytesTransferred, privacy: .public) requests=\(event.numberOfMediaRequests, privacy: .public) stalls=\(event.numberOfStalls, privacy: .public)"
                )
                self.journal(
                    "role=current phase=access-log startup-ms=\(startupMilliseconds) observed-bps=\(observedBitrate) indicated-bps=\(indicatedBitrate) transfer-ms=\(transferMilliseconds) bytes=\(event.numberOfBytesTransferred) requests=\(event.numberOfMediaRequests) stalls=\(event.numberOfStalls)"
                )
            }
        }
    }

    private func startMediaMetricCollection(
        for item: AVPlayerItem,
        role: PlaybackMediaMetricRole,
        generation: Int
    ) {
        let key = ObjectIdentifier(item)
        if let collector = mediaMetricCollectors[key] {
            collector.update(generation: generation, role: role)
            journal(
                "role=\(role.rawValue) phase=media-metrics status=active ownership=updated"
            )
            return
        }
        let contextOwner = PlaybackMediaMetricContextOwner(
            generation: generation,
            role: role
        )
        let result = AVPlayerItemMediaMetricCollector.make(
            item: item,
            contextOwner: contextOwner
        ) { event in
            PlaybackDiagnosticJournal.shared.record(event)
        }
        if let collector = result.collector {
            mediaMetricCollectors[key] = collector
        } else {
            contextOwner.deactivate()
        }
        journal(
            "role=\(role.rawValue) phase=media-metrics status=\(result.status.rawValue) ownership=created"
        )
    }

    private func stopMediaMetricCollection(
        for item: AVPlayerItem,
        role: PlaybackMediaMetricRole,
        generation: Int,
        reason: PlaybackMetricItemRemovalReason
    ) {
        let collector = mediaMetricCollectors.removeValue(
            forKey: ObjectIdentifier(item)
        )
        collector?.deactivate()
        PlaybackDiagnosticJournal.shared.record(
            "avplayer generation=\(generation) role=\(role.rawValue) phase=item-removed reason=\(reason.rawValue) media-metrics=\(collector == nil ? "inactive" : "stopped") cached-remote-items=\(cachedPlayedItems.count)"
        )
    }

    private func cancelStagedAssetReadinessProbe() {
        if stagedAssetReadinessProbeActive {
            journal(
                "role=staged phase=asset-readiness-probe status=cancelled"
            )
        }
        stagedAssetReadinessProbeActive = false
        stagedAssetReadinessTask?.cancel()
        stagedAssetReadinessTask = nil
    }

    private func finishStagedAssetReadinessProbe(
        outcome: PlaybackAssetReadinessProbeOutcome
    ) {
        guard stagedAssetReadinessProbeActive else { return }
        stagedAssetReadinessProbeActive = false
        stagedAssetReadinessTask = nil
        journal(
            "role=staged phase=asset-readiness-probe status=completed outcome=\(outcome.rawValue)"
        )
    }

    private func journalStateIfChanged(_ status: AVPlayer.TimeControlStatus) {
        let name: String
        switch status {
        case .paused: name = "paused"
        case .waitingToPlayAtSpecifiedRate: name = "waiting"
        case .playing: name = "playing"
        @unknown default: name = "unknown-future"
        }
        guard name != lastJournalState else { return }
        lastJournalState = name
        journal("phase=time-control status=\(name)")
    }

    private func journal(_ event: String) {
        PlaybackDiagnosticJournal.shared.record(
            "avplayer generation=\(itemGeneration) \(event)"
        )
    }

    static func itemInstallationProvenance(
        item: AVPlayerItem,
        stagedItem: AVPlayerItem?
    ) -> PlaybackMetricItemInstallationProvenance {
        stagedItem === item ? .stagedReused : .created
    }

    private static func statusName(_ status: AVPlayerItem.Status) -> String {
        switch status {
        case .unknown: "unknown"
        case .readyToPlay: "ready"
        case .failed: "failed"
        @unknown default: "unknown-future"
        }
    }

    private static func waitingReasonName(
        _ reason: AVPlayer.WaitingReason?
    ) -> String {
        switch reason {
        case .toMinimizeStalls: "minimize-stalls"
        case .evaluatingBufferingRate: "evaluating-buffering-rate"
        case .noItemToPlay: "no-item"
        case .waitingForCoordinatedPlayback: "coordinated-playback"
        case nil: "unavailable"
        default: "other"
        }
    }

    nonisolated static func diagnosticMetricInteger(_ value: Double) -> Int64 {
        // AVPlayer access logs may use NaN or infinity when a request fails
        // before producing a measurement. Converting either directly to an
        // integer traps in Swift, so retain an explicit unavailable sentinel.
        guard
            value.isFinite,
            value >= 0,
            value <= Double(Int32.max)
        else {
            return -1
        }
        return Int64(value.rounded())
    }

    private func removeCurrentItemObservers() {
        itemStatusObservation = nil
        bufferEmptyObservation = nil
        bufferLikelyObservation = nil
        loadedRangesObservation = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    isolated deinit {
        uninstallPlayerObservers(from: player)
        for collector in mediaMetricCollectors.values {
            collector.deactivate()
        }
        mediaMetricCollectors.removeAll()
        stagedAdvanceStatusObservation = nil
        itemStatusObservation = nil
        bufferEmptyObservation = nil
        bufferLikelyObservation = nil
        loadedRangesObservation = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}
