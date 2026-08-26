import AVFoundation
import Combine
import os

#if os(iOS)
    import UIKit
#endif

private enum PendingPlaybackLifecycleReport: Sendable {
    case started(any PlaybackLifecycleReporting, TimeInterval)
    case progress(any PlaybackLifecycleReporting, TimeInterval, isPaused: Bool)
    case stopped(any PlaybackLifecycleReporting, TimeInterval)

    func send() async throws {
        switch self {
        case .started(let reporter, let position):
            try await reporter.reportStarted(at: position)
        case .progress(let reporter, let position, let isPaused):
            try await reporter.reportProgress(at: position, isPaused: isPaused)
        case .stopped(let reporter, let position):
            try await reporter.reportStopped(at: position)
        }
    }

    var isProgress: Bool {
        if case .progress = self { return true }
        return false
    }
}

enum PlaybackAudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

enum PlaybackAudioRouteChange: Equatable, Sendable {
    case oldDeviceUnavailable
    case other
}

/// Serializes audio-session commands independently from playback presentation.
///
/// The coordinator creates a playback activation request only after it has
/// loaded an item. This boundary then performs category changes and session
/// activation away from the main actor, in command order. The coordinator must
/// still validate its request identifier after activation before it starts the
/// engine: a pause, stop, interruption, route loss, or replacement may have
/// superseded that request while the system was activating the session.
/// Deactivation is likewise ordered after the engine has stopped and retains
/// the `notifyOthersOnDeactivation` policy.
protocol PlaybackAudioSessionControlling: Sendable {
    func activate() async throws
    func deactivate(notifyingOthers: Bool) async
}

#if os(iOS)
    /// Owns the blocking AVAudioSession API on a dedicated serial actor.
    ///
    /// iOS 27 SDKs supply completion-handler activation APIs. Earlier SDKs and
    /// systems use the synchronous API, but the actor keeps that work off the
    /// main actor.
    /// The small in-actor queue remains non-reentrant while an asynchronous
    /// operation is outstanding, so a deactivation cannot overtake activation.
    actor AVAudioSessionBoundary: PlaybackAudioSessionControlling {
        private enum Operation {
            case activate(CheckedContinuation<Void, Error>)
            case deactivate(
                notifyingOthers: Bool,
                CheckedContinuation<Void, Never>
            )
        }

        private let session = AVAudioSession.sharedInstance()
        private var operations: [Operation] = []
        private var isPerformingOperation = false

        func activate() async throws {
            try await withCheckedThrowingContinuation { continuation in
                operations.append(.activate(continuation))
                performNextOperationIfNeeded()
            }
        }

        func deactivate(notifyingOthers: Bool) async {
            await withCheckedContinuation { continuation in
                operations.append(
                    .deactivate(
                        notifyingOthers: notifyingOthers,
                        continuation
                    )
                )
                performNextOperationIfNeeded()
            }
        }

        private func performNextOperationIfNeeded() {
            guard !isPerformingOperation, !operations.isEmpty else { return }

            isPerformingOperation = true
            let operation = operations.removeFirst()
            Task { [weak self] in
                guard let self else { return }
                await self.perform(operation)
            }
        }

        private func perform(_ operation: Operation) async {
            switch operation {
            case .activate(let continuation):
                do {
                    try session.setCategory(.playback, mode: .default)
                    try await activateSession()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            case .deactivate(let notifyingOthers, let continuation):
                await deactivateSession(notifyingOthers: notifyingOthers)
                continuation.resume()
            }

            isPerformingOperation = false
            performNextOperationIfNeeded()
        }

        private func activateSession() async throws {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                session.activate(options: []) { activated, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if activated {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: CocoaError(.fileWriteUnknown)
                        )
                    }
                }
            }
        }

        private func deactivateSession(notifyingOthers: Bool) async {
            await withCheckedContinuation { continuation in
                session.deactivate(
                    options: notifyingOthers
                        ? [.notifyOthersOnDeactivation] : []
                ) { _, _ in
                    continuation.resume()
                }
            }
        }
    }
#endif

/// Supplies platform lifecycle events to the playback coordinator.
///
/// `start` is called once for an observer instance. Implementations retain the
/// registrations for their own lifetime and invoke every callback on the main
/// actor without starting playback or performing network work themselves. This
/// keeps interruption, route, and background policy in one coordinator-owned
/// state machine.
@MainActor
protocol PlaybackPlatformEventObserving: AnyObject {
    func start(
        interruption: @escaping @MainActor (PlaybackAudioInterruption) -> Void,
        routeChange: @escaping @MainActor (PlaybackAudioRouteChange) -> Void,
        didEnterBackground: @escaping @MainActor () -> Void
    )
}

#if os(iOS)
    @MainActor
    private final class IOSPlaybackPlatformEventObserver:
        PlaybackPlatformEventObserving
    {
        private var observers: [NSObjectProtocol] = []

        func start(
            interruption:
                @escaping @MainActor (PlaybackAudioInterruption) -> Void,
            routeChange:
                @escaping @MainActor (PlaybackAudioRouteChange) -> Void,
            didEnterBackground: @escaping @MainActor () -> Void
        ) {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: AVAudioSession.didBecomeInactiveNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    let context =
                        notification.userInfo?[
                            AVAudioSession.deactivationContextKey
                        ] as? AVAudioSession.DeactivationContext
                    guard context?.source == .system else {
                        return
                    }
                    MainActor.assumeIsolated {
                        interruption(.began)
                    }
                },
                center.addObserver(
                    forName:
                        AVAudioSession.resumptionRecommendationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    let context =
                        notification.userInfo?[
                            AVAudioSession.resumptionContextKey
                        ] as? AVAudioSession.ResumptionContext
                    guard let context else { return }
                    MainActor.assumeIsolated {
                        interruption(
                            .ended(
                                shouldResume:
                                    context.recommendation == .shouldResume
                            )
                        )
                    }
                },
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    let rawReason =
                        notification.userInfo?[
                            AVAudioSessionRouteChangeReasonKey
                        ] as? UInt
                    let event: PlaybackAudioRouteChange =
                        rawReason.flatMap(
                            AVAudioSession.RouteChangeReason.init(rawValue:)
                        ) == .oldDeviceUnavailable
                        ? .oldDeviceUnavailable
                        : .other
                    MainActor.assumeIsolated {
                        routeChange(event)
                    }
                },
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        didEnterBackground()
                    }
                },
            ]
        }

        isolated deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
#endif

@MainActor
final class AudioPlaybackCoordinator: ObservableObject {
    private static let maximumHistoryItemCount = 50
    private enum ResiliencePolicy {
        // A short latest-command-wins window prevents rapid taps from opening
        // and cancelling a PlaybackInfo request for every intermediate item.
        static let networkIntentCoalescingDelay = Duration.milliseconds(120)
        // Resolve only the item that can become audible next. Preparing farther
        // ahead multiplies PlaybackInfo traffic during queue edits without
        // improving AVQueuePlayer readiness, and repeated cancel/restart churn
        // can exhaust a constrained Jellyfin connection path.
        static let queuePreparationWindowCount = 1
    }

    @Published private(set) var currentItem: PlaybackItem?
    @Published private(set) var playbackState = PlaybackState.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentItems: [PlaybackItem]
    @Published private(set) var queue: PlaybackQueue?
    @Published private(set) var bufferState = PlaybackBufferState.empty
    @Published private(set) var transportKind: PlaybackTransportKind?
    @Published private(set) var seekRequestID = UUID()
    @Published private(set) var preparingQueueItemIdentity: PlaybackItemQueueIdentity?

    private let engine: any AudioPlayerEngine
    private let historyStore: (any PlaybackHistoryStoring)?
    private let nowPlayingStateStore: (any NowPlayingStateStoring)?
    private let networkPolicy: VelacantoNetworkPolicy
    private var resourceLease: (any PlaybackResourceLease)?
    private var requestResolver: (@MainActor (PlaybackItem) async throws -> PlaybackRequest)?
    private var artworkResolver: (@MainActor (PlaybackItem) async -> ResolvedNowPlayingArtwork?)?
    private var queueExpansionHandler: (@MainActor () async -> [PlaybackItem])?
    private var playbackAccount: PlaybackAccount?
    private var restoredElapsed: TimeInterval?
    private var lastStateSaveTime = Date.distantPast
    /// The only lane allowed to resolve or replace audible playback. A newer
    /// direct user command cancels the prior intent before it can commit.
    private var playbackIntentTask: Task<Void, Never>?
    private var playbackIntentID: UUID?
    private var pendingNextAdvanceCount = 0
    private var pendingPreviousRetreatCount = 0
    private var preloadTask: Task<Void, Never>?
    private var preloadTaskID: UUID?
    private var preloadedRequest: PlaybackRequest?
    private enum QueueSelectionScope: String {
        case live
        case history
        case next
        case previous
    }
    private struct PendingQueueSelectionHandoff {
        let intentID: UUID
        let scope: QueueSelectionScope
        let request: PlaybackRequest?
        let proposedQueue: PlaybackQueue
        let preservesPlayableCurrent: Bool
        let forcedPlaybackInfoFallbackAttempted: Bool
        let expectedPlayerGeneration: Int?
    }
    private var pendingQueueSelectionHandoff: PendingQueueSelectionHandoff?
    private enum PlaybackRecoveryKind {
        case currentItem
        case preparedSuccessor
    }
    private struct PlaybackRecoveryIdentity {
        let target: PlaybackItemQueueIdentity
        let intentGeneration: UUID
        let stoppedPlayerGeneration: Int
        let kind: PlaybackRecoveryKind
        var replacementPlayerGeneration: Int?
    }
    private var activePlaybackRecovery: PlaybackRecoveryIdentity?
    private var forcedFallbackTask: Task<Void, Never>?
    private var forcedFallbackTaskID: UUID?
    private var preloadedFallbackAttempted = false
    private var automaticallyRejectedPreloadIdentity: PlaybackItemQueueIdentity?
    private var activeRequest: PlaybackRequest?
    private var queueEditRevision = 0
    private var advancesAfterQueueExpansion = false
    private var queueExpansionAdvanceIsExplicit = false
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID: UUID?
    private(set) var nowPlayingArtworkIdentifier: String?
    private(set) var nowPlayingArtwork: PlatformImage?
    private var wasPlayingBeforeInterruption = false
    private var isAudioSessionInterrupted = false
    // Keep delayed AVPlayer state observations from undoing an intentional pause
    // while an output route or audio session is reconfiguring.
    private var hasExplicitPlaybackPause = false
    private var requiresRouteRecovery = false
    private var playbackActivationTask: Task<Void, Never>?
    private var playbackActivationID: UUID?
    private var itemRecoveryTask: Task<Void, Never>?
    private var itemRecoveryID: UUID?
    private let itemRecoveryDeadline: Duration
    private let audioSessionController: (any PlaybackAudioSessionControlling)?
    private let platformEventObserver: (any PlaybackPlatformEventObserving)?
    private var hasRetriedCurrentItem = false
    private var lifecycleReporter: (any PlaybackLifecycleReporting)?
    private var didReportPlaybackStart = false
    private var didReportPlaybackStop = false
    private var lastProgressReportBucket = -1
    private var lifecycleReportTask: Task<Void, Never>?
    private var lifecycleReportTaskID: UUID?
    private var pendingProgressReport: PendingPlaybackLifecycleReport?
    /// Binds the logical `currentItem` to the AVFoundation generation that is
    /// allowed to publish transport state when no replacement handoff owns it.
    private var currentItemPlayerGeneration: Int?
    private var playingGeneration: Int?
    private var bufferGeneration: Int?
    private var progressBaselineGeneration: Int?
    private var progressBaselineElapsed: TimeInterval?
    private var forwardProgressGeneration: Int?
    private var stablePlaybackGeneration: Int?
    private var playbackStartupSignpostID: OSSignpostID?
    private var playbackNetworkStartupToken: UUID?

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Playback"
    )
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )

    init(
        engine: any AudioPlayerEngine = AVFoundationAudioPlayerEngine(),
        historyStore: (any PlaybackHistoryStoring)? = nil,
        nowPlayingStateStore: (any NowPlayingStateStoring)? = nil,
        platformEventObserver: (any PlaybackPlatformEventObserving)? = nil,
        audioSessionController: (any PlaybackAudioSessionControlling)? = nil,
        itemRecoveryDeadline: Duration = .seconds(12),
        networkPolicy: VelacantoNetworkPolicy = .shared
    ) {
        self.engine = engine
        self.historyStore = historyStore
        self.nowPlayingStateStore = nowPlayingStateStore
        self.itemRecoveryDeadline = itemRecoveryDeadline
        self.networkPolicy = networkPolicy
        #if os(iOS)
            self.audioSessionController =
                audioSessionController ?? AVAudioSessionBoundary()
        #else
            self.audioSessionController = audioSessionController
        #endif
        #if os(iOS)
            self.platformEventObserver =
                platformEventObserver ?? IOSPlaybackPlatformEventObserver()
        #else
            self.platformEventObserver = platformEventObserver
        #endif
        let loadedHistory = historyStore?.loadItems() ?? []
        recentItems = Self.normalizedHistory(loadedHistory)
        if recentItems != loadedHistory {
            historyStore?.saveItems(recentItems)
        }
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        installPlatformEventObserver()
    }

    isolated deinit {
        playbackIntentTask?.cancel()
        preloadTask?.cancel()
        artworkTask?.cancel()
        playbackActivationTask?.cancel()
        itemRecoveryTask?.cancel()
        lifecycleReportTask?.cancel()
        forcedFallbackTask?.cancel()
        if let networkToken = playbackNetworkStartupToken {
            networkPolicy.endPlaybackStartup(networkToken)
        }
    }

    var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var hasPlayableItem: Bool {
        currentItem != nil
    }

    var isPlaying: Bool {
        playbackState == .playing
    }

    var showsPauseControl: Bool {
        isPlaying
    }

    var isWaitingForPlayback: Bool {
        currentItem != nil
            && !hasExplicitPlaybackPause
            && !isAudioSessionInterrupted
            && (playbackState == .loading || playbackState == .waiting)
    }

    var hasPlaybackNetworkStartupDemand: Bool {
        playbackNetworkStartupToken != nil
    }

    var canGoPrevious: Bool {
        currentItem != nil
    }

    var canGoNext: Bool {
        queue?.canGoNext == true
            || queueExpansionHandler != nil
            || (queue?.repeatMode == .all && queue?.items.isEmpty == false)
    }

    var upcomingItems: [PlaybackItem] {
        queue?.upcomingItems ?? []
    }

    var playedQueueItems: [PlaybackItem] {
        queue?.playedItems ?? []
    }

    /// The transport history is the portion of the authoritative playback
    /// timeline before its current cursor.
    var historyItems: [PlaybackItem] {
        playedQueueItems
    }

    /// The destination requested by the latest queue transport command while
    /// the audible cursor remains unchanged. Surfaces use this to explain the
    /// otherwise invisible AVFoundation/network wait without presenting the
    /// candidate as Now Playing before it is ready.
    var preparingQueueItem: PlaybackItem? {
        guard
            let preparingQueueItemIdentity,
            preparingQueueItemIdentity != currentItem?.queueIdentity
        else {
            return nil
        }
        return queue?.items.first {
            $0.queueIdentity == preparingQueueItemIdentity
        }
    }

    var isPreparingQueueTransition: Bool {
        preparingQueueItem != nil
    }

    /// Cross-session discovery history for Home. This remains separate from
    /// transport history and never participates in Previous/Next navigation.
    var recentlyPlayedItems: [PlaybackItem] {
        let currentIdentity = currentItem?.queueIdentity
        let activeAccountScope = playbackAccount.map {
            "\($0.serverID)|\($0.userID)"
        }
        let compatibleItems = recentItems.filter {
            guard $0.queueIdentity != currentIdentity else { return false }
            guard $0.source == .jellyfin else { return true }
            return $0.accountScope == nil || $0.accountScope == activeAccountScope
        }
        // A pre-account-scope history entry and its migrated scoped entry can
        // refer to the same provider item. Prefer the newest compatible entry
        // so SwiftUI never receives duplicate row identities.
        var seenProviderItems = Set<String>()
        return Array(
            compatibleItems.filter {
                seenProviderItems.insert("\($0.source.rawValue)|\($0.id)").inserted
            }.reversed()
        )
    }

    var bufferedProgress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(bufferState.loadedThrough / duration, 0), 1)
    }

    var repeatMode: PlaybackRepeatMode {
        queue?.repeatMode ?? .off
    }

    func configureRequestResolver(
        _ resolver:
            @escaping @MainActor (PlaybackItem) async throws -> PlaybackRequest
    ) {
        requestResolver = resolver
    }

    func configureArtworkResolver(
        _ resolver:
            @escaping @MainActor (PlaybackItem) async
            -> ResolvedNowPlayingArtwork?
    ) {
        artworkResolver = resolver
        loadNowPlayingArtwork()
    }

    func play(
        _ request: PlaybackRequest,
        queueItems: [PlaybackItem] = [],
        context: PlaybackQueueContext = .single,
        account: PlaybackAccount? = nil,
        queueExpansion: (@MainActor () async -> [PlaybackItem])? = nil
    ) {
        guard
            !(request.item.source == .jellyfin
                && networkPolicy.isTerminalRemoteQuarantined)
        else {
            PlaybackDiagnosticJournal.shared.record(
                "playback-request phase=suppressed reason=terminal-quarantine"
            )
            return
        }
        cancelPendingPlaybackIntent()
        let replacedItemCount = queue?.items.count ?? 0
        let items = queueItems.isEmpty ? [request.item] : queueItems
        if let committedQueue = queue, playbackAccount == account {
            queue = committedQueue.replacingFuture(
                with: items,
                current: request.item,
                context: context
            )
        } else {
            queue = PlaybackQueue(
                items: items,
                currentItemID: request.item.id,
                context: context
            )
        }
        queueEditRevision += 1
        playbackAccount = account
        queueExpansionHandler = queueExpansion
        restoredElapsed = nil
        hasRetriedCurrentItem = false
        Self.logger.notice(
            "Queue commit kind=replace previous_items=\(replacedItemCount, privacy: .public) new_items=\(items.count, privacy: .public) revision=\(self.queueEditRevision, privacy: .public)"
        )
        playResolvedRequest(request, recordsQueueState: true)
    }

    /// Starts a fresh queue from an item whose provider request must still be
    /// resolved. Keeping this intent in the coordinator prevents a late
    /// history response from replacing a newer transport command.
    func play(_ item: PlaybackItem, account: PlaybackAccount? = nil) {
        guard requestResolver != nil else { return }

        guard
            !(item.source == .jellyfin
                && networkPolicy.isTerminalRemoteQuarantined)
        else {
            PlaybackDiagnosticJournal.shared.record(
                "playback-selection phase=suppressed reason=terminal-quarantine"
            )
            return
        }
        cancelPendingPlaybackIntent()
        Self.logger.notice(
            "Playback fallback kind=fresh-selection phase=resolve-required"
        )
        discardPreload()
        let preservesCommittedPlayback =
            currentItem != nil && engine.hasCurrentItem
        preparingQueueItemIdentity = item.queueIdentity
        if !preservesCommittedPlayback {
            playbackState = .loading
        }
        errorMessage = nil
        publishNowPlaying()

        let intentID = UUID()
        logIntentStarted(intentID, kind: "fresh-selection")
        playbackIntentID = intentID
        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                    playbackIntentID = nil
                    preparingQueueItemIdentity = nil
                }
            }
            do {
                let request = try await resolvePlaybackRequest(
                    for: item,
                    intentID: intentID,
                    coalescingRapidCommands: true
                )
                try Task.checkCancellation()
                guard playbackIntentID == intentID else { return }
                playbackIntentTask = nil
                playbackIntentID = nil
                preparingQueueItemIdentity = nil
                logIntentCommitted(intentID, kind: "fresh-selection")
                play(request, account: account)
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: "fresh-selection")
                return
            } catch {
                guard playbackIntentID == intentID else { return }
                presentIntentFailure(
                    error,
                    for: item,
                    preservingCommittedPlayback: preservesCommittedPlayback,
                    intentID: intentID,
                    kind: "fresh-selection"
                )
            }
        }
    }

    private func playResolvedRequest(
        _ request: PlaybackRequest,
        recordsQueueState: Bool,
        preservingRecoveryIntentGeneration: UUID? = nil
    ) {
        cancelPendingPlaybackActivation()
        hasExplicitPlaybackPause = false
        requiresRouteRecovery = false
        ensurePlaybackStartupSignpost()
        let playerItem = request.asset.makePlayerItem()

        reportPlaybackStopped()
        cancelPendingPlaybackIntent(
            preservingRecoveryIntentGeneration:
                preservingRecoveryIntentGeneration
        )
        preloadTask?.cancel()
        preloadTaskID = nil
        preloadedRequest = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        currentItem = request.item
        activeRequest = request
        transportKind = request.transportKind
        replaceLifecycleReporter(with: request.reporter)
        elapsed = 0
        duration = validatedDuration(request.item.duration)
        resetPlaybackStability()
        errorMessage = nil
        playbackState = .loading
        if request.recordsHistory {
            recordInHistory(request.item)
        }
        engine.load(playerItem, identity: request.item.queueIdentity)
        currentItemPlayerGeneration = engine.currentGeneration
        resourceLease = request.asset.resourceLease
        publishNowPlaying()
        loadNowPlayingArtwork()
        if recordsQueueState {
            saveNowPlayingState(force: true)
        }

        startPlaybackAfterAudioSessionActivation()
        scheduleItemRecoveryDeadline()
    }

    func togglePlayback() {
        guard currentItem != nil else { return }

        if isPlaying && !requiresRouteRecovery {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func seek(toProgress progress: Double) {
        guard progress.isFinite, duration.isFinite, duration > 0 else { return }

        let clampedProgress = min(max(progress, 0), 1)
        seek(toTime: duration * clampedProgress)
    }

    func seek(toTime time: TimeInterval) {
        guard engine.hasCurrentItem, time.isFinite else { return }

        let upperBound = duration.isFinite && duration > 0 ? duration : time
        let target = min(max(time, 0), upperBound)
        let generation = engine.currentGeneration
        let wasPlaying = playbackState == .playing
        invalidateForwardProgress(
            for: generation,
            preservingNativePlaying: wasPlaying
        )
        if wasPlaying {
            beginPlaybackStartupSignpost()
            playbackState = .waiting
            scheduleItemRecoveryDeadline()
        }
        seekRequestID = UUID()
        engine.seek(to: target)
        elapsed = target
        reportPlaybackProgress(isPaused: !isPlaying)
        publishNowPlaying()
    }

    func pausePlayback() {
        guard engine.hasCurrentItem else { return }
        cancelPendingPlaybackIntent()
        cancelItemRecoveryDeadline()
        hasExplicitPlaybackPause = true
        cancelPendingPlaybackActivation()
        if isAudioSessionInterrupted {
            wasPlayingBeforeInterruption = false
        }
        engine.pause()
        apply(.paused)
        saveNowPlayingState(force: true)
        reportPlaybackProgress(isPaused: true)
    }

    func resumePlayback() {
        resumePlayback(isExplicitUserGesture: true)
    }

    private func resumePlayback(isExplicitUserGesture: Bool) {
        guard currentItem != nil else { return }

        if currentItem?.source == .jellyfin,
            networkPolicy.isTerminalRemoteQuarantined
        {
            let trigger = isExplicitUserGesture ? "explicit" : "automatic"
            PlaybackDiagnosticJournal.shared.record(
                "playback-resume phase=suppressed reason=terminal-quarantine trigger=\(trigger)"
            )
            return
        }

        if currentItem?.source == .jellyfin,
            playbackState == .loading,
            playbackIntentTask != nil,
            !engine.hasCurrentItem
        {
            PlaybackDiagnosticJournal.shared.record(
                "playback-resume phase=coalesced reason=remote-resolve-active revision=\(queueEditRevision)"
            )
            return
        }

        // Play is idempotent while this exact restored or recovering item is
        // already resolving. Cancelling that work restarts the direct-file
        // path and can discard an in-flight PlaybackInfo fallback precisely
        // when the constrained route is beginning to recover.
        if let recovery = activePlaybackRecovery,
            recovery.kind == .currentItem,
            recovery.target == currentItem?.queueIdentity
        {
            PlaybackDiagnosticJournal.shared.record(
                "playback-resume phase=coalesced reason=current-recovery-active revision=\(queueEditRevision)"
            )
            return
        }
        cancelPendingPlaybackIntent()

        // An explicit Play is user intent. Some competing audio apps and route
        // changes never deliver their matching interruption-ended event, so do
        // not leave the app permanently blocked waiting for that notification.
        // Automatic resumption remains governed by `shouldResume` below.
        if isAudioSessionInterrupted {
            isAudioSessionInterrupted = false
            wasPlayingBeforeInterruption = false
        }

        // The single automatic retry may have happened while the server was
        // still unreachable. A later explicit Play is a new user-requested
        // recovery attempt, so negotiate a fresh stream instead of asking the
        // terminally failed AVPlayerItem to play again.
        if case .failed = playbackState,
            currentItem?.source == .jellyfin
        {
            resolveFailedJellyfinItemAndPlay()
            return
        }

        guard engine.hasCurrentItem else {
            hasExplicitPlaybackPause = false
            resolveRestoredItemAndPlay()
            return
        }

        let isRecoveringRoute = requiresRouteRecovery
        hasExplicitPlaybackPause = false

        // Reproduce the hardware Pause -> Play sequence that resets AVPlayer
        // after the old output route disappears without discarding its buffer.
        if isRecoveringRoute {
            engine.pause()
        }

        if playbackState == .ended || (duration > 0 && elapsed >= duration) {
            invalidateForwardProgress(for: engine.currentGeneration)
            beginPlaybackStartupSignpost()
            playbackState = .waiting
            engine.seek(to: 0)
            elapsed = 0
            didReportPlaybackStart = false
            didReportPlaybackStop = false
            lastProgressReportBucket = -1
        }

        errorMessage = nil
        if playbackState == .paused || isRecoveringRoute {
            beginPlaybackStartupSignpost()
            playbackState = .waiting
            publishNowPlaying()
        }
        startPlaybackAfterAudioSessionActivation()
        scheduleItemRecoveryDeadline()
    }

    func stop() {
        endPlaybackStartupSignpost()
        cancelPendingPlaybackActivation()
        cancelPendingPlaybackIntent()
        cancelItemRecoveryDeadline()
        preloadTask?.cancel()
        preloadTaskID = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        preloadedRequest = nil
        activeRequest = nil
        reportPlaybackStopped()
        engine.stop()
        resourceLease = nil
        currentItem = nil
        transportKind = nil
        elapsed = 0
        duration = 0
        bufferState = .empty
        playbackState = .idle
        errorMessage = nil
        queue = nil
        queueEditRevision += 1
        advancesAfterQueueExpansion = false
        queueExpansionAdvanceIsExplicit = false
        queueExpansionHandler = nil
        playbackAccount = nil
        restoredElapsed = nil
        wasPlayingBeforeInterruption = false
        isAudioSessionInterrupted = false
        hasExplicitPlaybackPause = false
        requiresRouteRecovery = false
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        lifecycleReporter = nil
        nowPlayingStateStore?.clearState()
        deactivateAudioSession()
    }

    private func handle(_ event: AudioPlayerEngineEvent) {
        switch event {
        case .timeChangedForGeneration(
            let newElapsed,
            let newDuration,
            let generation
        ):
            guard isAuthoritativeProgressGeneration(generation) else {
                PlaybackDiagnosticJournal.shared.record(
                    "playback-time phase=ignored reason=unowned-generation observed=\(generation)"
                )
                return
            }
            recordForwardProgress(
                elapsed: newElapsed,
                generation: generation
            )
            convergeLogicalPlaybackIfReady(generation: generation)
            if isCommittedTimeGeneration(generation) {
                applyPlayerTime(elapsed: newElapsed, duration: newDuration)
            }

        case .stateChanged(let state):
            handlePlayerState(
                state,
                generation: engine.currentGeneration
            )

        case .stateChangedForGeneration(let state, let generation):
            handlePlayerState(state, generation: generation)

        case .advancedToNextItem:
            if !bindAdvancedPreparedQueueSelectionHandoff() {
                commitPreloadedNextItem()
            }

        case .failedToAdvanceToNextItem(let failureKind):
            if let handoff = pendingQueueSelectionHandoff,
                handoff.expectedPlayerGeneration == nil,
                handoff.request?.item.queueIdentity
                    == preloadedRequest?.item.queueIdentity
            {
                pendingQueueSelectionHandoff = nil
                preparingQueueItemIdentity = nil
                rejectPreloadedNextItem(failureKind)
            } else if pendingQueueSelectionHandoff != nil {
                rejectPreparedQueueSelectionHandoff(failureKind)
            } else {
                rejectPreloadedNextItem(failureKind)
            }

        case .bufferStateChanged(let state):
            let generation = engine.currentGeneration
            guard isAuthoritativeBufferGeneration(generation) else {
                PlaybackDiagnosticJournal.shared.record(
                    "playback-buffer phase=ignored reason=unowned-generation observed=\(generation)"
                )
                return
            }
            bufferState = state
            bufferGeneration = generation
            if state.isEmpty {
                invalidateForwardProgress(for: generation)
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "Playback Stall"
                )
                if !hasExplicitPlaybackPause, !isAudioSessionInterrupted {
                    apply(.waiting, generation: generation)
                }
            }
            convergePlaybackStabilityIfReady()

        case .preparedNextItemStateChanged:
            // AVFoundation is the readiness authority. The resolved request is
            // retained only as metadata; Next consults this engine state before
            // choosing the staged path.
            break
        }
    }

    private func applyPlayerTime(
        elapsed newElapsed: TimeInterval,
        duration newDuration: TimeInterval
    ) {
        let previousDuration = duration
        if newElapsed.isFinite {
            elapsed = max(newElapsed, 0)
        }
        if newDuration.isFinite, newDuration > 0 {
            duration = newDuration
        }
        if duration != previousDuration {
            publishNowPlaying()
        }
        saveNowPlayingState(force: false)
        let reportBucket = Int(max(elapsed, 0) / 10)
        if reportBucket > lastProgressReportBucket {
            lastProgressReportBucket = reportBucket
            reportPlaybackProgress(isPaused: !isPlaying)
        }
    }

    /// An explicit prepared successor has crossed AVQueuePlayer's destructive
    /// native boundary, but it does not own the logical cursor yet. Bind the
    /// existing handoff to that exact generation and wait for its playing event.
    @discardableResult
    private func bindAdvancedPreparedQueueSelectionHandoff() -> Bool {
        guard let handoff = pendingQueueSelectionHandoff else { return false }
        guard
            handoff.intentID == playbackIntentID,
            handoff.expectedPlayerGeneration == nil,
            let request = handoff.request,
            request.item.queueIdentity == preparingQueueItemIdentity,
            request.item.queueIdentity == preloadedRequest?.item.queueIdentity
        else {
            PlaybackDiagnosticJournal.shared.record(
                "queue-selection phase=advanced-ignored reason=unowned-handoff generation=\(engine.currentGeneration)"
            )
            return true
        }
        reportPlaybackStopped()
        resetPlaybackStability()
        playbackState = .loading
        pendingQueueSelectionHandoff = PendingQueueSelectionHandoff(
            intentID: handoff.intentID,
            scope: handoff.scope,
            request: request,
            proposedQueue: handoff.proposedQueue,
            preservesPlayableCurrent: false,
            forcedPlaybackInfoFallbackAttempted:
                handoff.forcedPlaybackInfoFallbackAttempted,
            expectedPlayerGeneration: engine.currentGeneration
        )
        playbackIntentTask = nil
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(handoff.scope.rawValue) phase=advanced-bound generation=\(engine.currentGeneration) cursor-preserved=true"
        )
        publishNowPlaying()
        startPlaybackAfterAudioSessionActivation()
        scheduleItemRecoveryDeadline()
        return true
    }

    private func handlePlayerState(
        _ state: PlaybackState,
        generation: Int
    ) {
        guard generation == engine.currentGeneration else {
            PlaybackDiagnosticJournal.shared.record(
                "playback-state phase=ignored reason=stale-generation observed=\(generation) authoritative=\(engine.currentGeneration)"
            )
            return
        }
        guard isAuthoritativePlayerState(state, generation: generation) else {
            PlaybackDiagnosticJournal.shared.record(
                "playback-state phase=ignored reason=unowned-generation observed=\(generation)"
            )
            return
        }
        if let recovery = activePlaybackRecovery,
            recovery.kind == .preparedSuccessor,
            recovery.replacementPlayerGeneration == generation,
            recovery.target == preloadedRequest?.item.queueIdentity
        {
            if case .failed = state {
                let failureKind: AudioPlayerReplacementFailureKind =
                    engine.terminalFailureKind == .transportSecurity
                    ? .transportSecurity : .other
                if let preloadedRequest {
                    finalizeRejectedPreloadedNextItem(
                        preloadedRequest,
                        failureKind: failureKind
                    )
                }
                return
            }
        }
        if let handoff = pendingQueueSelectionHandoff,
            handoff.expectedPlayerGeneration == generation
        {
            if case .failed = state {
                let failureKind: AudioPlayerReplacementFailureKind =
                    engine.terminalFailureKind == .transportSecurity
                    ? .transportSecurity : .other
                finalizeRejectedQueueSelectionHandoff(
                    handoff,
                    failureKind: failureKind
                )
                return
            }
        }
        if state == .playing {
            let wasAlreadyNativePlaying = playingGeneration == generation
            playingGeneration = generation
            if !wasAlreadyNativePlaying {
                progressBaselineGeneration = nil
                progressBaselineElapsed = nil
            }
            convergeLogicalPlaybackIfReady(generation: generation)
            return
        }
        if state == .waiting {
            invalidateForwardProgress(for: generation)
        }
        apply(state, generation: generation)
    }

    private func isAuthoritativePlayerState(
        _ state: PlaybackState,
        generation: Int
    ) -> Bool {
        if let handoff = pendingQueueSelectionHandoff {
            return handoff.intentID == playbackIntentID
                && handoff.expectedPlayerGeneration == generation
                && handoff.proposedQueue.currentItem?.queueIdentity
                    == preparingQueueItemIdentity
        }
        if let recovery = activePlaybackRecovery,
            recovery.replacementPlayerGeneration == generation,
            isPlaybackRecoveryTargetAuthoritative(recovery)
        {
            return true
        }
        guard currentItemPlayerGeneration == generation else { return false }
        guard currentItem == nil else { return true }
        return state == .idle || state == .paused || state == .ended
    }

    private func isAuthoritativeBufferGeneration(_ generation: Int) -> Bool {
        if let handoff = pendingQueueSelectionHandoff {
            return handoff.intentID == playbackIntentID
                && handoff.expectedPlayerGeneration == generation
                && handoff.proposedQueue.currentItem?.queueIdentity
                    == preparingQueueItemIdentity
        }
        if let recovery = activePlaybackRecovery,
            recovery.replacementPlayerGeneration == generation,
            isPlaybackRecoveryTargetAuthoritative(recovery)
        {
            return true
        }
        return currentItem != nil && currentItemPlayerGeneration == generation
    }

    private func isAuthoritativeProgressGeneration(_ generation: Int) -> Bool {
        guard generation == engine.currentGeneration else { return false }
        if let handoff = pendingQueueSelectionHandoff {
            if handoff.expectedPlayerGeneration == generation {
                return handoff.intentID == playbackIntentID
                    && handoff.proposedQueue.currentItem?.queueIdentity
                        == preparingQueueItemIdentity
            }
            return handoff.expectedPlayerGeneration == nil
                && handoff.preservesPlayableCurrent
                && currentItem != nil
                && currentItemPlayerGeneration == generation
        }
        if let recovery = activePlaybackRecovery,
            recovery.replacementPlayerGeneration == generation,
            isPlaybackRecoveryTargetAuthoritative(recovery)
        {
            return true
        }
        return currentItem != nil && currentItemPlayerGeneration == generation
    }

    private func isCommittedTimeGeneration(_ generation: Int) -> Bool {
        currentItem != nil && currentItemPlayerGeneration == generation
    }

    private func recordInHistory(_ item: PlaybackItem) {
        recentItems.removeAll {
            guard $0.source == item.source, $0.id == item.id else {
                return false
            }
            return $0.accountScope == item.accountScope
                || ($0.accountScope == nil && item.accountScope != nil)
        }
        recentItems.insert(item, at: 0)
        recentItems = Self.normalizedHistory(recentItems)
        historyStore?.saveItems(recentItems)
    }

    private static func normalizedHistory(
        _ items: [PlaybackItem]
    ) -> [PlaybackItem] {
        var seen = Set<PlaybackItemQueueIdentity>()
        let uniqueItems = items.filter {
            seen.insert($0.queueIdentity).inserted
        }
        return Array(uniqueItems.prefix(maximumHistoryItemCount))
    }

    private func apply(
        _ observedState: PlaybackState,
        generation: Int? = nil
    ) {
        let incomingState = logicalState(
            for: observedState,
            generation: generation ?? engine.currentGeneration
        )
        let state: PlaybackState
        let isTransportSecurityFailure =
            engine.terminalFailureKind == .transportSecurity
        if incomingState == .paused,
            playbackActivationTask != nil,
            !hasExplicitPlaybackPause,
            !isAudioSessionInterrupted
        {
            state = .waiting
        } else if case .failed = incomingState, isTransportSecurityFailure {
            state = .failed(
                "The server's secure connection could not be verified. Reconnect the required VPN or private network, then try again."
            )
        } else if case .failed(let message) = incomingState {
            state = .failed(userSafeFailureMessage(message))
        } else {
            state = incomingState
        }

        if hasExplicitPlaybackPause || isAudioSessionInterrupted {
            switch state {
            case .waiting, .playing:
                return
            case .idle, .loading, .paused, .ended, .failed:
                break
            }
        }

        if case .failed = playbackState, errorMessage != nil {
            switch state {
            case .failed:
                break
            case .idle, .loading, .waiting, .playing, .paused, .ended:
                return
            }
        }

        if state == .playing {
            completePlaybackRecoveryIfAuthoritative(
                generation: generation ?? engine.currentGeneration
            )
        }

        guard state != playbackState else { return }

        let previousState = playbackState
        Self.logger.notice(
            "Playback state previous=\(self.diagnosticName(for: previousState), privacy: .public) current=\(self.diagnosticName(for: state), privacy: .public) revision=\(self.queueEditRevision, privacy: .public) upcoming=\(self.upcomingItems.count, privacy: .public) intent_active=\(self.playbackIntentTask != nil, privacy: .public) preload_ready=\(self.preloadedRequest != nil, privacy: .public)"
        )
        playbackState = state
        if state == .playing {
            requiresRouteRecovery = false
            cancelItemRecoveryDeadline()
        } else if state == .waiting,
            !hasExplicitPlaybackPause,
            !isAudioSessionInterrupted
        {
            if previousState == .playing {
                beginPlaybackStartupSignpost()
            }
            // Startup recovery is cancelled once audio begins. Re-arm it if an
            // already-playing stream later becomes stuck in AVPlayer waiting.
            scheduleItemRecoveryDeadline()
        }
        if case .failed(let message) = state {
            let failedGeneration = generation ?? engine.currentGeneration
            if activePlaybackRecovery?.replacementPlayerGeneration
                == failedGeneration
            {
                clearPlaybackRecovery()
            }
            errorMessage = message
            reportPlaybackStopped()
            let didStartRecovery =
                !isTransportSecurityFailure
                && renegotiateCurrentItemOnceIfPossible(
                    kind: "automatic-terminal-recovery"
                )
            if !didStartRecovery {
                if currentItem?.source == .jellyfin {
                    stopTerminalRemoteItem(generation: failedGeneration)
                }
                endPlaybackStartupSignpost()
            }
        }
        if state == .idle || state == .paused || state == .ended {
            endPlaybackStartupSignpost()
        }
        if state == .playing {
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Playback Audible"
            )
            convergePlaybackStabilityIfReady()
        }
        publishNowPlaying()
        switch state {
        case .paused, .ended, .failed:
            saveNowPlayingState(force: true)
        case .idle, .loading, .waiting, .playing:
            break
        }
        if state == .ended {
            reportPlaybackStopped()
            if repeatMode == .one {
                Self.logger.notice(
                    "Playback automatic-advance phase=repeat-current revision=\(self.queueEditRevision, privacy: .public)"
                )
                resumePlayback(isExplicitUserGesture: false)
            } else if canGoNext, playbackIntentTask == nil {
                // Remote speculation owns only the negotiated request. Natural
                // end deliberately enters the same direct-current,
                // playing-gated selection path as an explicit Next command.
                Self.logger.notice(
                    "Playback automatic-advance phase=request-next revision=\(self.queueEditRevision, privacy: .public) metadata_ready=\(self.preloadedRequest != nil, privacy: .public)"
                )
                nextTrack(cancellingPendingPlaybackRequest: false)
            } else if playbackIntentTask != nil {
                // End-of-item advancement is automatic intent. It must never
                // supersede a selection or transport command the user already
                // issued while its fresh PlaybackInfo request is in flight.
                Self.logger.notice(
                    "Playback automatic-advance phase=deferred active_user_intent=true"
                )
            } else {
                Self.logger.notice(
                    "Playback automatic-advance phase=no-successor revision=\(self.queueEditRevision, privacy: .public)"
                )
            }
        }
    }

    private func logicalState(
        for observedState: PlaybackState,
        generation: Int
    ) -> PlaybackState {
        guard observedState == .idle || observedState == .paused else {
            return observedState
        }
        if let handoff = pendingQueueSelectionHandoff,
            handoff.intentID == playbackIntentID,
            handoff.proposedQueue.currentItem?.queueIdentity
                == preparingQueueItemIdentity,
            handoff.expectedPlayerGeneration == generation
                || (handoff.expectedPlayerGeneration == nil
                    && !handoff.preservesPlayableCurrent
                    && generation == engine.currentGeneration)
        {
            PlaybackDiagnosticJournal.shared.record(
                "queue-selection scope=\(handoff.scope.rawValue) phase=preparing-state-preserved generation=\(generation)"
            )
            return .loading
        }
        guard let recovery = activePlaybackRecovery,
            isPlaybackRecoveryTargetAuthoritative(recovery)
        else {
            return observedState
        }
        if recovery.stoppedPlayerGeneration == generation,
            recovery.replacementPlayerGeneration == nil,
            !engine.hasCurrentItem
        {
            PlaybackDiagnosticJournal.shared.record(
                "playback-recovery phase=deferred-stopped-state-preserved generation=\(generation)"
            )
            return .loading
        }
        if recovery.replacementPlayerGeneration == generation,
            engine.hasCurrentItem
        {
            PlaybackDiagnosticJournal.shared.record(
                "playback-recovery phase=replacement-preparing-state-preserved generation=\(generation)"
            )
            return .loading
        }
        return observedState
    }

    private func isPlaybackRecoveryTargetAuthoritative(
        _ recovery: PlaybackRecoveryIdentity
    ) -> Bool {
        switch recovery.kind {
        case .currentItem:
            currentItem?.queueIdentity == recovery.target
        case .preparedSuccessor:
            pendingQueueSelectionHandoff?.request?.item.queueIdentity
                == recovery.target
                || preloadedRequest?.item.queueIdentity == recovery.target
        }
    }

    private func beginPlaybackRecovery(
        target: PlaybackItemQueueIdentity,
        intentGeneration: UUID,
        kind: PlaybackRecoveryKind
    ) {
        activePlaybackRecovery = PlaybackRecoveryIdentity(
            target: target,
            intentGeneration: intentGeneration,
            stoppedPlayerGeneration: engine.currentGeneration,
            kind: kind,
            replacementPlayerGeneration: nil
        )
    }

    private func bindPlaybackRecoveryToCurrentGeneration(
        intentGeneration: UUID
    ) {
        guard
            activePlaybackRecovery?.intentGeneration == intentGeneration
        else { return }
        activePlaybackRecovery?.replacementPlayerGeneration =
            engine.currentGeneration
    }

    private func bindPreparedRecoveryToCurrentGenerationIfNeeded() {
        guard
            let recovery = activePlaybackRecovery,
            recovery.kind == .preparedSuccessor,
            recovery.target == currentItem?.queueIdentity
        else { return }
        activePlaybackRecovery?.replacementPlayerGeneration =
            engine.currentGeneration
    }

    private func bindPreparedRecoveryReplacementToCurrentGeneration(
        target: PlaybackItemQueueIdentity
    ) {
        guard
            activePlaybackRecovery?.kind == .preparedSuccessor,
            activePlaybackRecovery?.target == target
        else { return }
        activePlaybackRecovery?.replacementPlayerGeneration =
            engine.currentGeneration
    }

    private func completePlaybackRecoveryIfAuthoritative(
        generation: Int
    ) {
        guard
            let recovery = activePlaybackRecovery,
            recovery.replacementPlayerGeneration == generation,
            recovery.target == currentItem?.queueIdentity
        else { return }
        activePlaybackRecovery = nil
    }

    private func clearPlaybackRecovery(intentGeneration: UUID? = nil) {
        guard let recovery = activePlaybackRecovery else { return }
        if let intentGeneration,
            recovery.intentGeneration != intentGeneration
        {
            return
        }
        if recovery.kind == .preparedSuccessor,
            recovery.replacementPlayerGeneration == engine.currentGeneration,
            recovery.target != currentItem?.queueIdentity
        {
            engine.stop()
            PlaybackDiagnosticJournal.shared.record(
                "playback-recovery phase=rejected-player-removed generation=\(engine.currentGeneration)"
            )
        }
        activePlaybackRecovery = nil
    }

    @discardableResult
    private func beginPlaybackStartupSignpost() -> UUID {
        endPlaybackStartupSignpost()
        let networkToken = UUID()
        playbackNetworkStartupToken = networkToken
        networkPolicy.beginPlaybackStartup(networkToken)
        PlaybackDiagnosticJournal.shared.record(
            "playback-admission phase=began"
        )
        let signpostID = OSSignpostID(log: Self.performanceLog)
        playbackStartupSignpostID = signpostID
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "Tap to Audio",
            signpostID: signpostID
        )
        return networkToken
    }

    private func ensurePlaybackStartupSignpost() {
        guard
            playbackStartupSignpostID == nil
                || playbackNetworkStartupToken == nil
        else { return }
        beginPlaybackStartupSignpost()
    }

    private func endPlaybackStartupSignpost() {
        let networkToken = playbackNetworkStartupToken
        playbackNetworkStartupToken = nil
        if let networkToken {
            networkPolicy.endPlaybackStartup(networkToken)
        }
        if networkToken != nil {
            PlaybackDiagnosticJournal.shared.record(
                "playback-admission phase=released"
            )
        }
        guard let signpostID = playbackStartupSignpostID else { return }
        os_signpost(
            .end,
            log: Self.performanceLog,
            name: "Tap to Audio",
            signpostID: signpostID
        )
        playbackStartupSignpostID = nil
    }

    private func waitForPlaybackNetworkQuiescence(
        token: UUID
    ) async throws {
        try await networkPolicy.waitUntilPlaybackStartupQuiescent(token)
        guard playbackNetworkStartupToken == token else {
            throw CancellationError()
        }
    }

    func setArtwork(
        _ image: PlatformImage?,
        identifier: String?,
        forItemID itemID: String?
    ) {
        guard currentItem?.id == itemID else { return }
        guard
            nowPlayingArtworkIdentifier != identifier
                || nowPlayingArtwork !== image
        else {
            return
        }
        nowPlayingArtworkIdentifier = identifier
        nowPlayingArtwork = image
        publishNowPlaying()
    }

    private func publishNowPlaying() {
        objectWillChange.send()
    }

    private func loadNowPlayingArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil

        guard let item = currentItem, let artworkResolver else { return }
        guard
            item.source != .jellyfin
                || !networkPolicy.isTerminalRemoteQuarantined
        else { return }

        let requestID = UUID()
        artworkRequestID = requestID
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let resolved = await artworkResolver(item)
            guard
                !Task.isCancelled,
                artworkRequestID == requestID,
                currentItem == item
            else {
                return
            }
            artworkTask = nil
            artworkRequestID = nil
            setArtwork(
                resolved?.image,
                identifier: resolved?.identifier,
                forItemID: item.id
            )
        }
    }

    func previousTrack() {
        let previousRetreatCount = pendingPreviousRetreatCount
        if elapsed > 3, previousRetreatCount == 0 {
            cancelPendingPlaybackIntent()
            seek(toTime: 0)
            return
        }

        let requestedRetreatCount = previousRetreatCount + 1
        let retreatCount: Int
        if repeatMode == .all {
            retreatCount = requestedRetreatCount
        } else {
            retreatCount = min(
                requestedRetreatCount,
                queue?.currentIndex ?? 0
            )
        }
        guard retreatCount > 0 else {
            cancelPendingPlaybackIntent()
            if elapsed > 0 {
                seek(toTime: 0)
            }
            return
        }
        guard
            let previousItem = queue?.item(
                retreatingBy: retreatCount,
                wrapping: repeatMode == .all
            )
        else { return }
        if retreatCount == previousRetreatCount,
            playbackIntentTask != nil || pendingQueueSelectionHandoff != nil
        {
            return
        }
        pendingPreviousRetreatCount = retreatCount
        prepareQueueSelection(
            previousItem,
            scope: .previous,
            preservingAccumulatedPrevious: true
        )
    }

    func nextTrack(cancellingPendingPlaybackRequest: Bool = true) {
        Self.logger.notice(
            "Playback skip phase=requested explicit=\(cancellingPendingPlaybackRequest, privacy: .public) revision=\(self.queueEditRevision, privacy: .public) upcoming=\(self.upcomingItems.count, privacy: .public) preload_ready=\(self.hasPreparedSuccessorReady, privacy: .public) intent_active=\(self.playbackIntentTask != nil, privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-next phase=requested revision=\(queueEditRevision) upcoming=\(upcomingItems.count) preload-ready=\(hasPreparedSuccessorReady) intent-active=\(playbackIntentTask != nil)"
        )
        if queue?.nextItem == nil, queueExpansionHandler != nil {
            pendingNextAdvanceCount = 0
            if cancellingPendingPlaybackRequest {
                cancelPendingPlaybackIntent()
            }
            advancesAfterQueueExpansion = true
            queueExpansionAdvanceIsExplicit =
                cancellingPendingPlaybackRequest
            expandQueueIfPossible()
            return
        }

        let previousAdvanceCount =
            cancellingPendingPlaybackRequest ? pendingNextAdvanceCount : 0
        let requestedAdvanceCount = previousAdvanceCount + 1
        let advanceCount: Int
        if repeatMode == .all {
            advanceCount = requestedAdvanceCount
        } else {
            advanceCount = min(
                requestedAdvanceCount,
                queue?.upcomingItems.count ?? 0
            )
        }
        guard advanceCount > 0 else {
            Self.logger.notice(
                "Playback skip phase=rejected reason=no-successor revision=\(self.queueEditRevision, privacy: .public)"
            )
            return
        }
        guard
            let nextItem = queue?.item(
                advancingBy: advanceCount,
                wrapping: repeatMode == .all
            )
        else {
            Self.logger.error(
                "Playback skip phase=rejected reason=queue-index revision=\(self.queueEditRevision, privacy: .public) distance=\(advanceCount, privacy: .public)"
            )
            return
        }
        // If repeated taps already target the final available queue item,
        // leave the in-flight negotiation alone instead of restarting it.
        if advanceCount == previousAdvanceCount,
            playbackIntentTask != nil
        {
            return
        }

        // A native-staged local successor remains the fastest single-skip
        // path. Remote metadata falls through to the direct-current path.
        // Multi-tap skips below still resolve only their final destination.
        if previousAdvanceCount == 0,
            advanceCount == 1,
            preloadedRequest?.item.queueIdentity == nextItem.queueIdentity,
            preparedSuccessorMatches(nextItem.queueIdentity)
        {
            // Queue ownership remains unchanged until AVFoundation proves the
            // candidate can become ready. A second Next command accumulates
            // from this pending distance and supersedes the candidate.
            pendingNextAdvanceCount = 1
            Self.logger.notice(
                "Playback skip phase=staged-handoff revision=\(self.queueEditRevision, privacy: .public)"
            )
            PlaybackDiagnosticJournal.shared.record(
                "queue-next phase=staged-handoff revision=\(queueEditRevision)"
            )
            advancePreparedSuccessor(
                target: nextItem.queueIdentity,
                scope: .next
            )
            return
        }
        pendingNextAdvanceCount = advanceCount
        Self.logger.notice(
            "Playback skip phase=coalesced distance=\(advanceCount, privacy: .public)"
        )
        prepareQueueSelection(
            nextItem,
            scope: .next,
            advancingBy: advanceCount,
            preservingAccumulatedNext: true
        )
    }

    func playQueueItem(_ item: PlaybackItem) {
        playQueueItem(item, requestedScope: nil)
    }

    func playHistoryItem(_ item: PlaybackItem) {
        guard
            queue?.playedItems.contains(where: {
                $0.queueIdentity == item.queueIdentity
            }) == true
        else { return }
        playQueueItem(item, requestedScope: .history)
    }

    private func playQueueItem(
        _ item: PlaybackItem,
        requestedScope: QueueSelectionScope?
    ) {
        cancelPendingPlaybackIntent()
        if currentItem?.source == item.source, currentItem?.id == item.id {
            Self.logger.notice("Queue selection scope=current action=resume")
            resumePlayback()
            return
        }

        let isInLiveQueue =
            queue?.items.contains {
                $0.queueIdentity == item.queueIdentity
            } == true
        guard isInLiveQueue else { return }
        let scope = requestedScope ?? .live
        Self.logger.notice(
            "Queue selection scope=\(scope.rawValue, privacy: .public) history_items=\(self.historyItems.count, privacy: .public) upcoming_items=\(self.upcomingItems.count, privacy: .public) revision=\(self.queueEditRevision, privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(scope.rawValue) phase=requested revision=\(queueEditRevision) upcoming=\(upcomingItems.count)"
        )
        // A local-file tap can use the item already inserted into AVQueuePlayer.
        // Remote metadata falls through to prepareQueueSelection, which reuses
        // its matching request without a second PlaybackInfo round-trip.
        if scope == .live,
            let request = preloadedRequest,
            request.item.queueIdentity == item.queueIdentity,
            queue?.nextItem?.queueIdentity == item.queueIdentity,
            preparedSuccessorMatches(item.queueIdentity)
        {
            pendingNextAdvanceCount = 1
            Self.logger.notice(
                "Queue selection scope=live phase=staged-next-commit"
            )
            advancePreparedSuccessor(
                target: item.queueIdentity,
                scope: .live
            )
            return
        }

        prepareQueueSelection(
            item,
            scope: scope
        )
    }

    private func advancePreparedSuccessor(
        target: PlaybackItemQueueIdentity,
        scope: QueueSelectionScope
    ) {
        guard
            let request = preloadedRequest,
            request.item.queueIdentity == target,
            preparedSuccessorMatches(target),
            var proposedQueue = queue,
            pendingQueueSelectionHandoff == nil
        else {
            return
        }
        switch scope {
        case .next:
            proposedQueue.moveNext(wrapping: repeatMode == .all)
        case .live:
            guard proposedQueue.select(request.item) else { return }
        case .history, .previous:
            return
        }
        guard proposedQueue.currentItem?.queueIdentity == target else {
            return
        }
        let expectedCurrentIdentity = currentItem?.queueIdentity
        let expectedQueueRevision = queueEditRevision
        let intentID = UUID()
        let intentKind = "prepared-successor"
        logIntentStarted(intentID, kind: intentKind)
        playbackIntentID = intentID
        preparingQueueItemIdentity = target
        pendingQueueSelectionHandoff = PendingQueueSelectionHandoff(
            intentID: intentID,
            scope: scope,
            request: request,
            proposedQueue: proposedQueue,
            preservesPlayableCurrent: true,
            forcedPlaybackInfoFallbackAttempted: false,
            expectedPlayerGeneration: nil
        )
        errorMessage = nil
        publishNowPlaying()
        let startupToken = beginPlaybackStartupSignpost()
        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                }
            }
            do {
                try await waitForPlaybackNetworkQuiescence(
                    token: startupToken
                )
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == expectedCurrentIdentity,
                    queueEditRevision == expectedQueueRevision,
                    pendingQueueSelectionHandoff?.intentID == intentID,
                    preloadedRequest?.item.queueIdentity == target,
                    preparedSuccessorMatches(target)
                else {
                    return
                }
                // Pause belongs to the outgoing item. Crossing the native
                // item-changing boundary makes this accepted selection a new
                // play intent; a later Pause can still cancel activation.
                hasExplicitPlaybackPause = false
                engine.advanceToNextItem()
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: intentKind)
                if playbackIntentID == intentID,
                    playbackNetworkStartupToken == startupToken
                {
                    endPlaybackStartupSignpost()
                }
            } catch {
                if playbackIntentID == intentID,
                    playbackNetworkStartupToken == startupToken
                {
                    endPlaybackStartupSignpost()
                }
            }
        }
    }

    private func prepareQueueSelection(
        _ item: PlaybackItem,
        scope: QueueSelectionScope,
        advancingBy advanceDistance: Int = 1,
        preservingAccumulatedNext: Bool = false,
        preservingAccumulatedPrevious: Bool = false
    ) {
        guard !networkPolicy.isTerminalRemoteQuarantined else {
            PlaybackDiagnosticJournal.shared.record(
                "queue-selection scope=\(scope.rawValue) phase=suppressed reason=terminal-quarantine"
            )
            return
        }
        cancelPendingPlaybackIntent(
            preservingAccumulatedNext: preservingAccumulatedNext,
            preservingAccumulatedPrevious: preservingAccumulatedPrevious
        )
        cancelItemRecoveryDeadline()
        guard
            requestResolver != nil,
            let committedQueue = queue,
            currentItem != nil
        else {
            play(item, account: playbackAccount)
            return
        }

        var proposedQueue = committedQueue
        switch scope {
        case .live:
            guard proposedQueue.select(item) else {
                Self.logger.error(
                    "Queue selection scope=live phase=rejected reason=queue-select revision=\(self.queueEditRevision, privacy: .public)"
                )
                return
            }
        case .history:
            guard proposedQueue.select(item) else {
                Self.logger.error(
                    "Queue selection scope=history phase=rejected reason=queue-select revision=\(self.queueEditRevision, privacy: .public)"
                )
                return
            }
        case .next:
            proposedQueue.moveNext(
                by: advanceDistance,
                wrapping: repeatMode == .all
            )
            guard proposedQueue.currentItem?.queueIdentity == item.queueIdentity
            else {
                Self.logger.error(
                    "Queue selection scope=next phase=rejected reason=queue-advance revision=\(self.queueEditRevision, privacy: .public) distance=\(advanceDistance, privacy: .public)"
                )
                return
            }
        case .previous:
            guard proposedQueue.select(item) else {
                Self.logger.error(
                    "Queue selection scope=previous phase=rejected reason=queue-select revision=\(self.queueEditRevision, privacy: .public)"
                )
                return
            }
        }

        let expectedCurrentIdentity = currentItem?.queueIdentity
        let expectedQueueRevision = queueEditRevision
        let preservesPlayableCurrent = engine.hasCurrentItem
        let reusablePreparedRequest =
            preloadedRequest?.item.queueIdentity == item.queueIdentity
            ? preloadedRequest : nil
        let hasNativeStagedPreload =
            preloadedRequest?.transportKind == .localFile
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskID = nil
        preloadedRequest = nil
        if hasNativeStagedPreload {
            engine.preload(nil, identity: nil)
        }
        let selectionStartupToken = beginPlaybackStartupSignpost()
        preparingQueueItemIdentity = item.queueIdentity
        if !preservesPlayableCurrent {
            playbackState = .loading
        }
        errorMessage = nil
        publishNowPlaying()

        let intentID = UUID()
        let intentKind = "\(scope.rawValue)-selection"
        logIntentStarted(intentID, kind: intentKind)
        playbackIntentID = intentID
        pendingQueueSelectionHandoff = PendingQueueSelectionHandoff(
            intentID: intentID,
            scope: scope,
            request: nil,
            proposedQueue: proposedQueue,
            preservesPlayableCurrent: preservesPlayableCurrent,
            forcedPlaybackInfoFallbackAttempted: false,
            expectedPlayerGeneration: nil
        )
        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                    if pendingQueueSelectionHandoff?.intentID != intentID {
                        playbackIntentID = nil
                        preparingQueueItemIdentity = nil
                    }
                }
            }
            do {
                let request: PlaybackRequest
                if let reusablePreparedRequest {
                    try await Task.sleep(
                        for: ResiliencePolicy.networkIntentCoalescingDelay
                    )
                    request = reusablePreparedRequest
                } else {
                    request = try await resolvePlaybackRequest(
                        for: item,
                        intentID: intentID,
                        coalescingRapidCommands: true
                    )
                }
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == expectedCurrentIdentity,
                    queueEditRevision == expectedQueueRevision,
                    pendingQueueSelectionHandoff?.intentID == intentID
                else {
                    return
                }
                pendingQueueSelectionHandoff = PendingQueueSelectionHandoff(
                    intentID: intentID,
                    scope: scope,
                    request: request,
                    proposedQueue: proposedQueue,
                    preservesPlayableCurrent: preservesPlayableCurrent,
                    forcedPlaybackInfoFallbackAttempted: false,
                    expectedPlayerGeneration: nil
                )
                PlaybackDiagnosticJournal.shared.record(
                    "queue-selection scope=\(scope.rawValue) phase=player-preparing revision=\(queueEditRevision) upcoming=\(upcomingItems.count)"
                )
                try await waitForPlaybackNetworkQuiescence(
                    token: selectionStartupToken
                )
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == expectedCurrentIdentity,
                    queueEditRevision == expectedQueueRevision,
                    pendingQueueSelectionHandoff?.intentID == intentID
                else {
                    return
                }
                // Preserve an intentional pause while resolution is still
                // reversible. Once the owned replacement is about to load,
                // the item-changing selection becomes the new play intent.
                hasExplicitPlaybackPause = false
                resetPlaybackStability()
                playbackState = .loading
                reportPlaybackStopped()
                engine.load(
                    request.asset.makePlayerItem(),
                    identity: request.item.queueIdentity
                )
                pendingQueueSelectionHandoff = PendingQueueSelectionHandoff(
                    intentID: intentID,
                    scope: scope,
                    request: request,
                    proposedQueue: proposedQueue,
                    preservesPlayableCurrent: false,
                    forcedPlaybackInfoFallbackAttempted: false,
                    expectedPlayerGeneration: engine.currentGeneration
                )
                playbackIntentTask = nil
                publishNowPlaying()
                startPlaybackAfterAudioSessionActivation()
                scheduleItemRecoveryDeadline()
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: intentKind)
            } catch {
                guard playbackIntentID == intentID else { return }
                cancelPendingQueueSelectionHandoff()
                pendingNextAdvanceCount = 0
                pendingPreviousRetreatCount = 0
                presentIntentFailure(
                    error,
                    for: item,
                    preservingCommittedPlayback: true,
                    intentID: intentID,
                    kind: intentKind
                )
            }
        }
    }

    func playNext(_ item: PlaybackItem) {
        editQueue(kind: "play-next") { $0.playNext(item) }
    }

    func playLast(_ item: PlaybackItem) {
        editQueue(kind: "play-last") { $0.playLast(item) }
    }

    func removeUpcomingItem(_ item: PlaybackItem) {
        editQueue(kind: "remove-upcoming") { $0.removeUpcomingItem(item) }
    }

    func moveUpcomingItem(from source: Int, to destination: Int) {
        editQueue(kind: "move-upcoming") {
            $0.moveUpcomingItem(from: source, to: destination)
        }
    }

    func reorderUpcomingItems(
        withIDs sourceIDs: [PlaybackItemQueueIdentity],
        before destinationID: PlaybackItemQueueIdentity?
    ) {
        editQueue(kind: "reorder-upcoming") {
            $0.reorderUpcomingItems(
                withIDs: sourceIDs,
                before: destinationID
            )
        }
    }

    func shuffleUpcoming() {
        editQueue(kind: "shuffle-upcoming") { $0.shuffleUpcoming() }
    }

    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        guard queue != nil, repeatMode != mode else { return }
        cancelPendingPlaybackIntent()
        queue?.setRepeatMode(mode)
        queueEditRevision += 1
        invalidatePreloadAndRefreshQueue()
    }

    private func editQueue(
        kind: String,
        _ mutation: (inout PlaybackQueue) -> Bool
    ) {
        cancelPendingPlaybackIntent()
        let previousNextIdentity = nextQueueItemForPreloading?.queueIdentity
        guard var editedQueue = queue else {
            Self.logger.error(
                "Queue edit kind=\(kind, privacy: .public) phase=rejected reason=no-live-queue"
            )
            PlaybackDiagnosticJournal.shared.record(
                "queue-edit kind=\(kind) phase=rejected reason=no-live-queue"
            )
            return
        }
        guard mutation(&editedQueue) else {
            Self.logger.notice(
                "Queue edit kind=\(kind, privacy: .public) phase=rejected reason=no-op revision=\(self.queueEditRevision, privacy: .public)"
            )
            PlaybackDiagnosticJournal.shared.record(
                "queue-edit kind=\(kind) phase=rejected reason=no-op revision=\(queueEditRevision)"
            )
            return
        }
        let previousUpcomingCount = queue?.upcomingItems.count ?? 0
        queue = editedQueue
        queueEditRevision += 1
        let nextItemChanged =
            previousNextIdentity != nextQueueItemForPreloading?.queueIdentity
        Self.logger.notice(
            "Queue edit kind=\(kind, privacy: .public) previous_upcoming=\(previousUpcomingCount, privacy: .public) new_upcoming=\(editedQueue.upcomingItems.count, privacy: .public) next_changed=\(nextItemChanged, privacy: .public) revision=\(self.queueEditRevision, privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-edit kind=\(kind) phase=committed previous-upcoming=\(previousUpcomingCount) new-upcoming=\(editedQueue.upcomingItems.count) next-changed=\(nextItemChanged) revision=\(queueEditRevision)"
        )
        if nextItemChanged {
            automaticallyRejectedPreloadIdentity = nil
            pendingNextAdvanceCount = 0
            discardPreload()
        }
        saveNowPlayingState(force: true)
        publishNowPlaying()
        if nextItemChanged {
            // The edit is already committed locally. Prepare only its immediate
            // successor through the shared bounded transport so an established
            // queue and an edited queue have the same deterministic handoff.
            Self.logger.notice(
                "Queue edit kind=\(kind, privacy: .public) preload=requested revision=\(self.queueEditRevision, privacy: .public)"
            )
            preloadNextItemIfPlaybackStable()
        }
    }

    private func invalidatePreloadAndRefreshQueue() {
        advancesAfterQueueExpansion = false
        queueExpansionAdvanceIsExplicit = false
        discardPreload()
        saveNowPlayingState(force: true)
        publishNowPlaying()
        preloadNextItemIfPlaybackStable()
    }

    private func discardPreload() {
        let hasNativeStagedPreload =
            preloadedRequest?.transportKind == .localFile
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskID = nil
        cancelForcedFallbackTask()
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        if hasNativeStagedPreload {
            engine.preload(nil, identity: nil)
        }
    }

    func restoreSavedState(serverID: String, userID: String) {
        guard currentItem == nil, let state = nowPlayingStateStore?.loadState()
        else {
            return
        }
        let account = PlaybackAccount(serverID: serverID, userID: userID)
        guard state.account == account, let item = state.queue.currentItem else {
            if state.account != account {
                nowPlayingStateStore?.clearState()
            }
            return
        }

        queue = state.queue
        queueEditRevision += 1
        currentItem = item
        playbackAccount = account
        elapsed = max(state.elapsed, 0)
        duration = max(state.duration ?? 0, 0)
        bufferState = .empty
        playbackState = .paused
        restoredElapsed = elapsed
        errorMessage = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        PlaybackDiagnosticJournal.shared.record(
            "queue-restore phase=committed items=\(state.queue.items.count) upcoming=\(state.queue.upcomingItems.count) revision=\(queueEditRevision)"
        )
        publishNowPlaying()
        loadNowPlayingArtwork()
    }

    func clearSavedState(serverID: String, userID: String) {
        let account = PlaybackAccount(serverID: serverID, userID: userID)
        if nowPlayingStateStore?.loadState()?.account == account {
            nowPlayingStateStore?.clearState()
        }
    }

    private func resolveRestoredItemAndPlay() {
        guard let item = currentItem else { return }
        guard
            item.source != .jellyfin
                || !networkPolicy.isTerminalRemoteQuarantined
        else { return }
        cancelPendingPlaybackIntent()

        // Local files can be recreated from their durable URL. Jellyfin stream
        // URLs are negotiated capabilities and may already be expired or tied
        // to a failed route, so never silently reload one after AVFoundation
        // has discarded it.
        if item.source != .jellyfin,
            reloadActiveRequest(kind: "missing-item-local-refresh")
        {
            return
        }
        guard requestResolver != nil else { return }
        ensurePlaybackStartupSignpost()
        playbackState = .loading
        errorMessage = nil
        publishNowPlaying()
        let seekTime = restoredElapsed ?? elapsed

        let intentID = UUID()
        logIntentStarted(intentID, kind: "restored-playback")
        playbackIntentID = intentID
        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                    playbackIntentID = nil
                }
            }
            do {
                let request = try await resolvePlaybackRequest(
                    for: item,
                    intentID: intentID
                )
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == item.queueIdentity
                else {
                    return
                }
                playbackIntentTask = nil
                playbackIntentID = nil
                logIntentCommitted(intentID, kind: "restored-playback")
                playResolvedRequest(request, recordsQueueState: false)
                if seekTime > 0 {
                    engine.seek(to: seekTime)
                    elapsed = seekTime
                }
                restoredElapsed = nil
                publishNowPlaying()
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: "restored-playback")
                return
            } catch {
                guard playbackIntentID == intentID else { return }
                logIntentFailed(intentID, kind: "restored-playback", error: error)
                failPlayback(error.localizedDescription)
            }
        }
    }

    private func resolveFailedJellyfinItemAndPlay() {
        guard let item = currentItem else { return }
        let forcedFallback = activeRequest?.forcedPlaybackInfoFallback
        cancelPendingPlaybackIntent()

        // A failed Jellyfin item always receives a new PlaybackInfo response,
        // stream URL, play-session identity, and lifecycle reporter.
        activeRequest = nil
        guard requestResolver != nil else { return }
        ensurePlaybackStartupSignpost()

        let seekTime = elapsed
        playbackState = .loading
        errorMessage = nil
        publishNowPlaying()

        let intentID = UUID()
        logIntentStarted(intentID, kind: "explicit-recovery")
        playbackIntentID = intentID
        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                    playbackIntentID = nil
                }
            }
            do {
                let request: PlaybackRequest
                if let forcedFallback {
                    request = try await forcedFallback()
                } else {
                    request = try await resolvePlaybackRequest(
                        for: item,
                        intentID: intentID
                    )
                }
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == item.queueIdentity
                else {
                    return
                }
                playbackIntentTask = nil
                playbackIntentID = nil
                logIntentCommitted(intentID, kind: "explicit-recovery")
                hasRetriedCurrentItem = false
                playResolvedRequest(request, recordsQueueState: false)
                if seekTime > 0 {
                    engine.seek(to: seekTime)
                    elapsed = seekTime
                }
                publishNowPlaying()
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: "explicit-recovery")
                return
            } catch {
                guard playbackIntentID == intentID else { return }
                logIntentFailed(intentID, kind: "explicit-recovery", error: error)
                failPlayback(error.localizedDescription)
            }
        }
    }

    private func saveNowPlayingState(force: Bool) {
        guard
            let nowPlayingStateStore,
            let queue,
            queue.currentItem != nil
        else {
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastStateSaveTime) >= 5 else {
            return
        }
        lastStateSaveTime = now
        nowPlayingStateStore.saveState(
            SavedNowPlayingState(
                queue: queue.persistenceWindow(),
                elapsed: elapsed,
                duration: duration.isFinite && duration > 0 ? duration : nil,
                account: playbackAccount,
                savedAt: now
            )
        )
    }

    private func validatedDuration(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }

    private func resetPlaybackStability() {
        playingGeneration = nil
        bufferGeneration = nil
        progressBaselineGeneration = nil
        progressBaselineElapsed = nil
        forwardProgressGeneration = nil
        stablePlaybackGeneration = nil
        bufferState = .empty
    }

    private func invalidateForwardProgress(
        for generation: Int,
        preservingNativePlaying: Bool = false
    ) {
        if progressBaselineGeneration == generation {
            progressBaselineGeneration = nil
            progressBaselineElapsed = nil
        }
        if forwardProgressGeneration == generation {
            forwardProgressGeneration = nil
        }
        if stablePlaybackGeneration == generation {
            stablePlaybackGeneration = nil
        }
        if !preservingNativePlaying, playingGeneration == generation {
            playingGeneration = nil
        }
    }

    private func recordForwardProgress(
        elapsed observedElapsed: TimeInterval,
        generation: Int
    ) {
        guard observedElapsed.isFinite, playingGeneration == generation else {
            return
        }
        guard forwardProgressGeneration != generation else { return }
        guard
            progressBaselineGeneration == generation,
            let baseline = progressBaselineElapsed
        else {
            progressBaselineGeneration = generation
            progressBaselineElapsed = observedElapsed
            PlaybackDiagnosticJournal.shared.record(
                "playback-progress phase=baseline generation=\(generation)"
            )
            return
        }
        if observedElapsed > baseline {
            forwardProgressGeneration = generation
            PlaybackDiagnosticJournal.shared.record(
                "playback-progress phase=proven generation=\(generation)"
            )
        } else if observedElapsed < baseline {
            progressBaselineElapsed = observedElapsed
        }
    }

    private func convergeLogicalPlaybackIfReady(generation: Int) {
        guard
            playingGeneration == generation,
            forwardProgressGeneration == generation
        else {
            return
        }
        if let recovery = activePlaybackRecovery,
            recovery.kind == .preparedSuccessor,
            recovery.replacementPlayerGeneration == generation,
            recovery.target == preloadedRequest?.item.queueIdentity
        {
            commitPreloadedNextItem(startingPlayback: false)
        }
        if let handoff = pendingQueueSelectionHandoff,
            handoff.expectedPlayerGeneration == generation
        {
            commitPreparedQueueSelectionHandoff(startingPlayback: false)
        }
        guard isCommittedTimeGeneration(generation) else { return }
        apply(.playing, generation: generation)
    }

    private func convergePlaybackStabilityIfReady() {
        let generation = engine.currentGeneration
        let wasAlreadyStable = stablePlaybackGeneration == generation
        guard
            playbackState == .playing,
            playingGeneration == generation,
            forwardProgressGeneration == generation,
            wasAlreadyStable
                || (bufferGeneration == generation
                    && bufferState.isLikelyToKeepUp)
        else {
            return
        }
        stablePlaybackGeneration = generation
        endPlaybackStartupSignpost()
        if !didReportPlaybackStart, let lifecycleReporter {
            didReportPlaybackStart = true
            enqueueLifecycleReport(
                .started(lifecycleReporter, elapsed)
            )
        }
        preloadNextItemIfPlaybackStable()
    }

    private func preloadNextItemIfPlaybackStable() {
        let nextIdentity = nextQueueItemForPreloading?.queueIdentity
        guard
            playbackState == .playing,
            bufferState.isLikelyToKeepUp,
            playingGeneration == engine.currentGeneration,
            bufferGeneration == engine.currentGeneration,
            stablePlaybackGeneration == engine.currentGeneration,
            playbackIntentTask == nil,
            preloadTask == nil,
            preloadedRequest == nil,
            nextIdentity == nil
                || automaticallyRejectedPreloadIdentity != nextIdentity
        else {
            return
        }
        preloadNextItem()
    }

    private func preloadNextItem() {
        guard !networkPolicy.isTerminalRemoteQuarantined else { return }
        var preparationItems = Array(
            (queue?.upcomingItems ?? []).prefix(
                ResiliencePolicy.queuePreparationWindowCount
            )
        )
        if preparationItems.isEmpty,
            let wrappedItem =
                queueExpansionHandler == nil && repeatMode == .all
                    && (queue?.items.count ?? 0) > 1
                ? queue?.items.first : nil
        {
            preparationItems = [wrappedItem]
        }
        guard !preparationItems.isEmpty else {
            expandQueueIfPossible()
            return
        }
        guard let requestResolver else {
            return
        }
        let currentItemID = currentItem?.id
        let expectedNextIdentity = preparationItems.first?.queueIdentity
        let taskID = UUID()
        preloadTaskID = taskID
        let expectedQueueRevision = queueEditRevision
        Self.logger.notice(
            "Playback preload id=\(taskID.uuidString, privacy: .public) phase=resolve-start revision=\(expectedQueueRevision, privacy: .public) candidates=\(preparationItems.count, privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-preload id=\(taskID.uuidString) phase=started revision=\(expectedQueueRevision) candidates=\(preparationItems.count)"
        )
        let startedAt = Date()
        preloadTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if preloadTaskID == taskID {
                    preloadTask = nil
                    preloadTaskID = nil
                }
            }
            var preparedCount = 0
            for (offset, item) in preparationItems.enumerated() {
                guard
                    currentItem?.id == currentItemID,
                    nextQueueItemForPreloading?.queueIdentity
                        == expectedNextIdentity,
                    preloadTaskID == taskID,
                    queueEditRevision == expectedQueueRevision
                else {
                    Self.logger.notice(
                        "Playback preload id=\(taskID.uuidString, privacy: .public) phase=superseded checkpoint=before-resolve revision_current=\(self.queueEditRevision, privacy: .public) revision_expected=\(expectedQueueRevision, privacy: .public)"
                    )
                    return
                }
                do {
                    let request =
                        try await VelacantoNetworkRequestContext
                        .$priorityOverride.withValue(
                            .playback
                        ) {
                            try await requestResolver(item)
                        }
                    try Task.checkCancellation()
                    guard
                        currentItem?.id == currentItemID,
                        nextQueueItemForPreloading?.queueIdentity
                            == expectedNextIdentity,
                        preloadTaskID == taskID,
                        queueEditRevision == expectedQueueRevision
                    else {
                        Self.logger.notice(
                            "Playback preload id=\(taskID.uuidString, privacy: .public) phase=superseded checkpoint=after-resolve revision_current=\(self.queueEditRevision, privacy: .public) revision_expected=\(expectedQueueRevision, privacy: .public)"
                        )
                        return
                    }
                    preparedCount += 1

                    // The immediate remote successor retains only reusable
                    // negotiation metadata. It must not create an AVPlayerItem
                    // or compete for media bytes before transition ownership.
                    // Local files retain their native staged handoff.
                    if offset == 0,
                        nextQueueItemForPreloading?.queueIdentity
                            == request.item.queueIdentity
                    {
                        preloadedRequest = request
                        preloadedFallbackAttempted = false
                        if request.transportKind == .localFile {
                            engine.preload(
                                request.asset.makePlayerItem(),
                                identity: request.item.queueIdentity
                            )
                            Self.logger.notice(
                                "Playback preload id=\(taskID.uuidString, privacy: .public) phase=staged revision=\(expectedQueueRevision, privacy: .public)"
                            )
                            PlaybackDiagnosticJournal.shared.record(
                                "playback-preload id=\(taskID.uuidString) phase=staged revision=\(expectedQueueRevision)"
                            )
                        } else {
                            Self.logger.notice(
                                "Playback preload id=\(taskID.uuidString, privacy: .public) phase=metadata-retained revision=\(expectedQueueRevision, privacy: .public)"
                            )
                            PlaybackDiagnosticJournal.shared.record(
                                "playback-preload id=\(taskID.uuidString) phase=metadata-retained revision=\(expectedQueueRevision)"
                            )
                        }
                    }
                } catch is CancellationError {
                    Self.logger.notice(
                        "Playback preload id=\(taskID.uuidString, privacy: .public) phase=cancelled revision=\(expectedQueueRevision, privacy: .public)"
                    )
                    PlaybackDiagnosticJournal.shared.record(
                        "playback-preload id=\(taskID.uuidString) phase=cancelled revision=\(expectedQueueRevision)"
                    )
                    return
                } catch {
                    if error as? JellyfinAPIError == .unsupportedMedia,
                        offset == 0
                    {
                        automaticallyRejectedPreloadIdentity =
                            item.queueIdentity
                    }
                    Self.logger.error(
                        "Playback preload phase=item-failed offset=\(offset, privacy: .public) category=\(self.failureCategory(for: error), privacy: .public)"
                    )
                    PlaybackDiagnosticJournal.shared.record(
                        "playback-preload id=\(taskID.uuidString) phase=failed offset=\(offset) category=\(failureCategory(for: error)) revision=\(expectedQueueRevision)"
                    )
                    if isPlaybackTransportWideFailure(error) {
                        return
                    }
                    continue
                }
            }
            Self.logger.debug(
                "Playback preload id=\(taskID.uuidString, privacy: .public) phase=window-prepared count=\(preparedCount, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000), privacy: .public)"
            )
        }
    }

    private func expandQueueIfPossible() {
        guard !networkPolicy.isTerminalRemoteQuarantined else { return }
        guard
            let expansionHandler = queueExpansionHandler,
            preloadTask == nil
        else {
            return
        }
        let currentItemID = currentItem?.id
        let expectedRevision = queueEditRevision
        let taskID = UUID()
        preloadTaskID = taskID
        preloadTask = Task { [weak self] in
            guard let self else { return }
            let expandedItems = await expansionHandler()
            guard
                currentItem?.id == currentItemID,
                queueEditRevision == expectedRevision,
                preloadTaskID == taskID
            else {
                return
            }
            preloadTask = nil
            preloadTaskID = nil
            let appendedItems = queue?.append(expandedItems) == true
            if !appendedItems {
                queueExpansionHandler = nil
            }
            let shouldAdvance = advancesAfterQueueExpansion
            let advanceIsExplicit = queueExpansionAdvanceIsExplicit
            advancesAfterQueueExpansion = false
            queueExpansionAdvanceIsExplicit = false
            if shouldAdvance {
                nextTrack(
                    cancellingPendingPlaybackRequest: advanceIsExplicit
                )
            } else if queue?.nextItem != nil || repeatMode == .all {
                preloadNextItemIfPlaybackStable()
            }
        }
    }

    private func commitPreloadedNextItem(
        startingPlayback: Bool = true
    ) {
        guard
            let request = preloadedRequest,
            nextQueueItemForPreloading?.queueIdentity == request.item.queueIdentity
        else {
            Self.logger.error(
                "Playback staged-handoff phase=rejected revision=\(self.queueEditRevision, privacy: .public) preload_ready=\(self.preloadedRequest != nil, privacy: .public)"
            )
            return
        }
        queue?.moveNext(wrapping: repeatMode == .all)
        queue?.replaceCurrentItem(with: request.item)
        playbackIntentTask = nil
        playbackIntentID = nil
        pendingNextAdvanceCount = 0
        pendingPreviousRetreatCount = 0
        automaticallyRejectedPreloadIdentity = nil
        reportPlaybackStopped()
        currentItem = request.item
        currentItemPlayerGeneration = engine.currentGeneration
        activeRequest = request
        transportKind = request.transportKind
        replaceLifecycleReporter(with: request.reporter)
        resourceLease = request.asset.resourceLease
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        hasExplicitPlaybackPause = false
        requiresRouteRecovery = false
        ensurePlaybackStartupSignpost()
        Self.logger.notice(
            "Playback staged-handoff phase=committed revision=\(self.queueEditRevision, privacy: .public) upcoming=\(self.upcomingItems.count, privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-next phase=committed revision=\(queueEditRevision) upcoming=\(upcomingItems.count)"
        )
        elapsed = 0
        duration = validatedDuration(request.item.duration)
        if startingPlayback {
            resetPlaybackStability()
        }
        errorMessage = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        hasRetriedCurrentItem = false
        if request.recordsHistory {
            recordInHistory(request.item)
        }
        saveNowPlayingState(force: true)
        publishNowPlaying()
        loadNowPlayingArtwork()
        if startingPlayback {
            startPlaybackAfterAudioSessionActivation()
            scheduleItemRecoveryDeadline()
            bindPreparedRecoveryToCurrentGenerationIfNeeded()
        }
    }

    private func commitPreparedQueueSelectionHandoff(
        startingPlayback: Bool = true
    ) {
        guard
            let handoff = pendingQueueSelectionHandoff,
            let request = handoff.request
        else {
            Self.logger.error(
                "Queue selection phase=rejected reason=no-pending-handoff"
            )
            return
        }
        pendingQueueSelectionHandoff = nil
        playbackIntentTask = nil
        playbackIntentID = nil
        preparingQueueItemIdentity = nil
        pendingNextAdvanceCount = 0
        pendingPreviousRetreatCount = 0
        automaticallyRejectedPreloadIdentity = nil
        queue = handoff.proposedQueue
        queue?.replaceCurrentItem(with: request.item)
        queueEditRevision += 1

        reportPlaybackStopped()
        currentItem = request.item
        currentItemPlayerGeneration = engine.currentGeneration
        activeRequest = request
        transportKind = request.transportKind
        replaceLifecycleReporter(with: request.reporter)
        resourceLease = request.asset.resourceLease
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        hasExplicitPlaybackPause = false
        requiresRouteRecovery = false
        hasRetriedCurrentItem = false
        elapsed = 0
        duration = validatedDuration(request.item.duration)
        if startingPlayback {
            resetPlaybackStability()
        }
        errorMessage = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        ensurePlaybackStartupSignpost()
        if request.recordsHistory {
            recordInHistory(request.item)
        }
        logIntentCommitted(
            handoff.intentID,
            kind: "\(handoff.scope.rawValue)-selection"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(handoff.scope.rawValue) phase=committed revision=\(queueEditRevision) upcoming=\(upcomingItems.count) speculation=quiesced"
        )
        saveNowPlayingState(force: true)
        publishNowPlaying()
        loadNowPlayingArtwork()
        if startingPlayback {
            startPlaybackAfterAudioSessionActivation()
            scheduleItemRecoveryDeadline()
            bindPreparedRecoveryToCurrentGenerationIfNeeded()
        }
    }

    private func rejectPreparedQueueSelectionHandoff(
        _ failureKind: AudioPlayerReplacementFailureKind
    ) {
        guard let handoff = pendingQueueSelectionHandoff else { return }
        finalizeRejectedQueueSelectionHandoff(
            handoff,
            failureKind: failureKind
        )
    }

    private func finalizeRejectedQueueSelectionHandoff(
        _ handoff: PendingQueueSelectionHandoff,
        failureKind: AudioPlayerReplacementFailureKind
    ) {
        guard pendingQueueSelectionHandoff?.intentID == handoff.intentID else {
            return
        }
        cancelPendingPlaybackActivation()
        cancelItemRecoveryDeadline()
        if let generation = handoff.expectedPlayerGeneration,
            handoff.request?.item.source == .jellyfin,
            generation == engine.currentGeneration
        {
            _ = enterTerminalRemoteContainment(
                generation: generation,
                item: handoff.request?.item
            )
        }
        terminateUncommittedPlayer(for: handoff)
        pendingQueueSelectionHandoff = nil
        playbackIntentTask = nil
        playbackIntentID = nil
        preparingQueueItemIdentity = nil
        pendingNextAdvanceCount = 0
        pendingPreviousRetreatCount = 0
        clearPlaybackRecovery()
        endPlaybackStartupSignpost()
        if handoff.expectedPlayerGeneration != nil {
            resetPlaybackStability()
        }
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        engine.preload(nil, identity: nil)
        let preservesAudiblePlayback =
            handoff.preservesPlayableCurrent && engine.hasCurrentItem
        let failureMessage =
            preservesAudiblePlayback
            ? replacementFailureMessage(failureKind)
            : "The selected track could not be loaded. Your queue was kept; try again or choose another track."
        errorMessage = failureMessage
        if !preservesAudiblePlayback {
            playbackState = .failed(failureMessage)
            saveNowPlayingState(force: true)
        }
        let category = replacementFailureCategory(failureKind)
        Self.logger.error(
            "Queue selection scope=\(handoff.scope.rawValue, privacy: .public) phase=failed category=\(category, privacy: .public) revision=\(self.queueEditRevision, privacy: .public) queue_preserved=true speculation_quiesced=true"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(handoff.scope.rawValue) phase=failed category=\(category) revision=\(queueEditRevision) queue-preserved=true audible-preserved=\(preservesAudiblePlayback) speculation-quiesced=true"
        )
        publishNowPlaying()
    }

    private func cancelPendingQueueSelectionHandoff() {
        guard let handoff = pendingQueueSelectionHandoff else { return }
        cancelForcedFallbackTask()
        cancelPendingPlaybackActivation()
        cancelItemRecoveryDeadline()
        terminateUncommittedPlayer(for: handoff)
        pendingQueueSelectionHandoff = nil
        endPlaybackStartupSignpost()
        if handoff.expectedPlayerGeneration != nil {
            resetPlaybackStability()
        }
        engine.preload(nil, identity: nil)
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(handoff.scope.rawValue) phase=cancelled revision=\(queueEditRevision) speculation-quiesced=true"
        )
    }

    private func terminateUncommittedPlayer(
        for handoff: PendingQueueSelectionHandoff
    ) {
        guard
            let expectedGeneration = handoff.expectedPlayerGeneration,
            expectedGeneration == engine.currentGeneration
        else {
            return
        }
        engine.stop()
        PlaybackDiagnosticJournal.shared.record(
            "queue-selection scope=\(handoff.scope.rawValue) phase=rejected-player-removed generation=\(expectedGeneration)"
        )
    }

    private func rejectPreloadedNextItem(
        _ failureKind: AudioPlayerReplacementFailureKind
    ) {
        guard let rejectedRequest = preloadedRequest else {
            Self.logger.notice(
                "Playback staged-handoff phase=ignored reason=superseded"
            )
            return
        }
        playbackIntentTask = nil
        playbackIntentID = nil
        if beginForcedFallbackForPreloadedNext(
            rejectedRequest,
            originalFailureKind: failureKind
        ) {
            return
        }
        finalizeRejectedPreloadedNextItem(
            rejectedRequest,
            failureKind: failureKind
        )
    }

    private func finalizeRejectedPreloadedNextItem(
        _ rejectedRequest: PlaybackRequest,
        failureKind: AudioPlayerReplacementFailureKind
    ) {
        guard
            preloadedRequest?.item.queueIdentity
                == rejectedRequest.item.queueIdentity
        else {
            return
        }
        let category = replacementFailureCategory(failureKind)
        let failedReplacementOwnsPlayer =
            activePlaybackRecovery?.kind == .preparedSuccessor
            && activePlaybackRecovery?.target
                == rejectedRequest.item.queueIdentity
            && activePlaybackRecovery?.replacementPlayerGeneration
                == engine.currentGeneration
        if failedReplacementOwnsPlayer,
            rejectedRequest.item.source == .jellyfin
        {
            _ = enterTerminalRemoteContainment(
                generation: engine.currentGeneration,
                item: rejectedRequest.item
            )
        }
        automaticallyRejectedPreloadIdentity =
            rejectedRequest.item.queueIdentity
        pendingNextAdvanceCount = 0
        clearPlaybackRecovery()
        endPlaybackStartupSignpost()
        preloadedRequest = nil
        preloadedFallbackAttempted = false
        engine.preload(nil, identity: nil)
        let failureMessage = replacementFailureMessage(failureKind)
        errorMessage = failureMessage
        let preservesAudiblePlayback =
            !failedReplacementOwnsPlayer && engine.hasCurrentItem
        if !preservesAudiblePlayback {
            playbackState = .failed(failureMessage)
            saveNowPlayingState(force: true)
        }
        Self.logger.error(
            "Playback staged-handoff phase=failed category=\(category, privacy: .public) revision=\(self.queueEditRevision, privacy: .public) queue_preserved=true"
        )
        PlaybackDiagnosticJournal.shared.record(
            "queue-next phase=failed category=\(category) revision=\(queueEditRevision) queue-preserved=true audible-preserved=\(preservesAudiblePlayback)"
        )
        publishNowPlaying()
    }

    private func beginForcedFallbackForPreloadedNext(
        _ request: PlaybackRequest,
        originalFailureKind: AudioPlayerReplacementFailureKind
    ) -> Bool {
        guard
            !preloadedFallbackAttempted,
            let fallback = request.forcedPlaybackInfoFallback
        else {
            return false
        }
        preloadedFallbackAttempted = true
        let expectedRevision = queueEditRevision
        startForcedFallbackTask(
            target: request.item.queueIdentity,
            journalContext: "queue-next",
            operation: fallback
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let fallbackRequest):
                guard
                    queueEditRevision == expectedRevision,
                    nextQueueItemForPreloading?.queueIdentity
                        == request.item.queueIdentity,
                    preloadedRequest?.item.queueIdentity
                        == request.item.queueIdentity
                else { return }
                preloadedRequest = fallbackRequest
                resetPlaybackStability()
                playbackState = .loading
                engine.load(
                    fallbackRequest.asset.makePlayerItem(),
                    identity: fallbackRequest.item.queueIdentity
                )
                bindPreparedRecoveryReplacementToCurrentGeneration(
                    target: fallbackRequest.item.queueIdentity
                )
                publishNowPlaying()
                startPlaybackAfterAudioSessionActivation()
                scheduleItemRecoveryDeadline()
            case .failure:
                finalizeRejectedPreloadedNextItem(
                    request,
                    failureKind: originalFailureKind
                )
            }
        }
        return true
    }

    private func releaseCurrentPlayerForReplacementFallback(
        journalContext: String
    ) {
        guard engine.hasCurrentItem else { return }
        let resumeTime = elapsed
        let resumeDuration = duration
        cancelPendingPlaybackActivation()
        cancelItemRecoveryDeadline()
        reportPlaybackStopped()
        engine.stop()
        resourceLease = nil
        elapsed = resumeTime
        duration = resumeDuration
        playbackState = .loading
        errorMessage = nil
        PlaybackDiagnosticJournal.shared.record(
            "\(journalContext) phase=player-released revision=\(queueEditRevision) cursor-preserved=true"
        )
        publishNowPlaying()
    }

    private func startForcedFallbackTask(
        target: PlaybackItemQueueIdentity,
        journalContext: String,
        operation: @escaping @Sendable () async throws -> PlaybackRequest,
        completion:
            @escaping @MainActor (Result<PlaybackRequest, Error>) -> Void
    ) {
        cancelForcedFallbackTask()
        let taskID = UUID()
        forcedFallbackTaskID = taskID
        beginPlaybackRecovery(
            target: target,
            intentGeneration: taskID,
            kind: .preparedSuccessor
        )
        ensurePlaybackStartupSignpost()
        let startupToken = playbackNetworkStartupToken
        releaseCurrentPlayerForReplacementFallback(
            journalContext: journalContext
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-fallback phase=playback-info-started"
        )
        forcedFallbackTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<PlaybackRequest, Error>
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            if case .success = result, let startupToken {
                do {
                    try await waitForPlaybackNetworkQuiescence(
                        token: startupToken
                    )
                } catch {
                    return
                }
            }
            guard
                forcedFallbackTaskID == taskID,
                !Task.isCancelled
            else { return }
            forcedFallbackTask = nil
            forcedFallbackTaskID = nil
            PlaybackDiagnosticJournal.shared.record(
                "playback-fallback phase=playback-info-completed"
            )
            if case .failure = result {
                clearPlaybackRecovery(intentGeneration: taskID)
            }
            completion(result)
        }
    }

    private func cancelForcedFallbackTask() {
        if activePlaybackRecovery?.kind == .preparedSuccessor {
            clearPlaybackRecovery()
        }
        guard forcedFallbackTask != nil || forcedFallbackTaskID != nil else {
            return
        }
        forcedFallbackTask?.cancel()
        forcedFallbackTask = nil
        forcedFallbackTaskID = nil
        PlaybackDiagnosticJournal.shared.record(
            "playback-fallback phase=cancelled"
        )
    }

    private func replacementFailureCategory(
        _ kind: AudioPlayerReplacementFailureKind
    ) -> String {
        switch kind {
        case .timeout: "timeout"
        case .offline: "offline"
        case .dns: "dns"
        case .transportSecurity: "tls"
        case .other: "player"
        }
    }

    private func replacementFailureMessage(
        _ kind: AudioPlayerReplacementFailureKind
    ) -> String {
        switch kind {
        case .timeout:
            "The next track did not become ready in time. The current queue position was kept."
        case .offline:
            "The next track could not open because the network is offline. The current queue position was kept."
        case .dns:
            "The music server could not be reached. The current queue position was kept."
        case .transportSecurity:
            "The next track's secure connection could not be verified. The current queue position was kept."
        case .other:
            "The next track could not become ready. The current queue position was kept."
        }
    }

    private var nextQueueItemForPreloading: PlaybackItem? {
        queue?.nextItem
            ?? (queueExpansionHandler == nil && repeatMode == .all
                && (queue?.items.count ?? 0) > 1
                ? queue?.items.first : nil)
    }

    private var hasPreparedSuccessorReady: Bool {
        guard case .ready = engine.preparedNextItemState.phase else {
            return false
        }
        return engine.preparedNextItemState.generation
            == engine.currentGeneration
    }

    private func preparedSuccessorMatches(
        _ identity: PlaybackItemQueueIdentity
    ) -> Bool {
        let state = engine.preparedNextItemState
        guard
            state.identity == identity,
            state.generation == engine.currentGeneration
        else {
            return false
        }
        guard case .ready = state.phase else { return false }
        return true
    }

    private func reportPlaybackProgress(isPaused: Bool) {
        guard
            let lifecycleReporter,
            didReportPlaybackStart,
            !didReportPlaybackStop
        else {
            return
        }
        enqueueLifecycleReport(
            .progress(lifecycleReporter, elapsed, isPaused: isPaused)
        )
    }

    private func reportPlaybackStopped() {
        guard
            let lifecycleReporter,
            didReportPlaybackStart,
            !didReportPlaybackStop
        else {
            return
        }
        didReportPlaybackStop = true
        enqueueLifecycleReport(
            .stopped(lifecycleReporter, elapsed)
        )
    }

    private func replaceLifecycleReporter(
        with reporter: (any PlaybackLifecycleReporting)?
    ) {
        lifecycleReporter = reporter
        didReportPlaybackStart = false
        didReportPlaybackStop = false
        lastProgressReportBucket = -1
    }

    private func enqueueLifecycleReport(
        _ report: PendingPlaybackLifecycleReport
    ) {
        guard
            currentItem?.source != .jellyfin
                || !networkPolicy.isTerminalRemoteQuarantined
        else { return }
        if report.isProgress, lifecycleReportTask != nil {
            // Keep only the newest periodic state while another report is in
            // flight. This bounds progress without dropping the final known
            // position before a stop.
            pendingProgressReport = report
            return
        }
        if !report.isProgress, let pendingProgressReport {
            self.pendingProgressReport = nil
            scheduleLifecycleReport(pendingProgressReport)
        }
        scheduleLifecycleReport(report)
    }

    private func scheduleLifecycleReport(
        _ report: PendingPlaybackLifecycleReport
    ) {
        let previousTask = lifecycleReportTask
        let taskID = UUID()
        lifecycleReportTaskID = taskID
        lifecycleReportTask = Task { [weak self] in
            await previousTask?.value
            do {
                try await report.send()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Playback lifecycle report failed")
            }
            guard let self, lifecycleReportTaskID == taskID else { return }
            lifecycleReportTask = nil
            lifecycleReportTaskID = nil
            if let pendingProgressReport {
                self.pendingProgressReport = nil
                enqueueLifecycleReport(pendingProgressReport)
            }
        }
    }

    @discardableResult
    private func renegotiateCurrentItemOnceIfPossible(kind: String) -> Bool {
        guard
            !hasRetriedCurrentItem,
            let item = currentItem,
            item.source == .jellyfin,
            let fallback = activeRequest?.forcedPlaybackInfoFallback
        else {
            return false
        }
        hasRetriedCurrentItem = true
        cancelItemRecoveryDeadline()
        cancelPendingPlaybackIntent()
        let expectedIdentity = item.queueIdentity
        let intentID = UUID()
        logIntentStarted(intentID, kind: kind)
        playbackIntentID = intentID
        beginPlaybackRecovery(
            target: expectedIdentity,
            intentGeneration: intentID,
            kind: .currentItem
        )
        let resumeTime = elapsed
        let resumeDuration = duration

        // A stalled AVPlayerItem can keep the constrained media route occupied
        // while its server-negotiated fallback is trying to establish a fresh
        // request. Release that exact player generation before resolving the
        // fallback, while the coordinator remains the sole owner of the queue
        // identity and persisted cursor.
        cancelPendingPlaybackActivation()
        ensurePlaybackStartupSignpost()
        engine.stop()
        resourceLease = nil
        elapsed = resumeTime
        duration = resumeDuration
        playbackState = .loading
        errorMessage = nil
        PlaybackDiagnosticJournal.shared.record(
            "playback-recovery phase=player-released revision=\(queueEditRevision) cursor-preserved=true"
        )
        publishNowPlaying()

        playbackIntentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackIntentID == intentID {
                    playbackIntentTask = nil
                    playbackIntentID = nil
                }
            }
            do {
                let request = try await fallback()
                try Task.checkCancellation()
                guard
                    playbackIntentID == intentID,
                    currentItem?.queueIdentity == expectedIdentity
                else {
                    return
                }
                playbackIntentTask = nil
                playbackIntentID = nil
                logIntentCommitted(intentID, kind: kind)
                playResolvedRequest(
                    request,
                    recordsQueueState: false,
                    preservingRecoveryIntentGeneration: intentID
                )
                bindPlaybackRecoveryToCurrentGeneration(
                    intentGeneration: intentID
                )
                if resumeTime > 0 {
                    engine.seek(to: resumeTime)
                    elapsed = resumeTime
                }
                publishNowPlaying()
            } catch is CancellationError {
                logIntentCancelled(intentID, kind: kind)
            } catch {
                guard playbackIntentID == intentID else { return }
                clearPlaybackRecovery(intentGeneration: intentID)
                logIntentFailed(intentID, kind: kind, error: error)
                activeRequest = nil
                abandonStalledCurrentItem()
            }
        }
        return true
    }

    @discardableResult
    private func reloadActiveRequest(kind: String) -> Bool {
        guard
            let item = currentItem,
            let request = activeRequest,
            request.item.queueIdentity == item.queueIdentity
        else {
            return false
        }

        let intentID = UUID()
        logIntentStarted(intentID, kind: kind)
        cancelPendingPlaybackActivation()
        cancelPendingPlaybackIntent()
        hasExplicitPlaybackPause = false
        let resumeTime = elapsed
        playbackState = .loading
        errorMessage = nil
        didReportPlaybackStart = false
        didReportPlaybackStop = false
        lastProgressReportBucket = -1
        transportKind = request.transportKind
        resourceLease = request.asset.resourceLease
        resetPlaybackStability()
        engine.load(
            request.asset.makePlayerItem(),
            identity: request.item.queueIdentity
        )
        currentItemPlayerGeneration = engine.currentGeneration
        if let preloadedRequest {
            engine.preload(
                preloadedRequest.asset.makePlayerItem(),
                identity: preloadedRequest.item.queueIdentity
            )
        }
        if resumeTime > 0 {
            engine.seek(to: resumeTime)
            elapsed = resumeTime
        }
        logIntentCommitted(intentID, kind: kind)
        publishNowPlaying()
        startPlaybackAfterAudioSessionActivation()
        scheduleItemRecoveryDeadline()
        return true
    }

    private func scheduleItemRecoveryDeadline() {
        cancelItemRecoveryDeadline()
        guard currentItem?.source == .jellyfin else { return }
        let expectedIdentity = currentItem?.queueIdentity
        let recoveryID = UUID()
        let deadline = itemRecoveryDeadline
        itemRecoveryID = recoveryID
        itemRecoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            guard let self else { return }
            guard
                itemRecoveryID == recoveryID,
                currentItem?.queueIdentity == expectedIdentity,
                !hasExplicitPlaybackPause
            else {
                return
            }
            switch playbackState {
            case .loading, .waiting:
                break
            case .idle, .playing, .paused, .ended, .failed:
                return
            }
            itemRecoveryTask = nil
            itemRecoveryID = nil
            if let recovery = activePlaybackRecovery,
                recovery.kind == .preparedSuccessor,
                recovery.replacementPlayerGeneration
                    == engine.currentGeneration,
                recovery.target == preloadedRequest?.item.queueIdentity,
                let preloadedRequest
            {
                finalizeRejectedPreloadedNextItem(
                    preloadedRequest,
                    failureKind: .timeout
                )
                return
            }
            if let handoff = pendingQueueSelectionHandoff,
                handoff.expectedPlayerGeneration == engine.currentGeneration
            {
                finalizeRejectedQueueSelectionHandoff(
                    handoff,
                    failureKind: .timeout
                )
                return
            }
            Self.logger.error(
                "Playback recovery phase=deadline retry_exhausted=\(self.hasRetriedCurrentItem, privacy: .public)"
            )
            if !hasRetriedCurrentItem {
                if renegotiateCurrentItemOnceIfPossible(
                    kind: "automatic-stall-recovery"
                ) {
                    return
                }
            }
            abandonStalledCurrentItem()
        }
    }

    private func cancelItemRecoveryDeadline() {
        itemRecoveryTask?.cancel()
        itemRecoveryTask = nil
        itemRecoveryID = nil
    }

    private func enterTerminalRemoteContainment(
        generation: Int,
        item: PlaybackItem? = nil
    ) -> Bool {
        guard
            (item ?? currentItem)?.source == .jellyfin,
            generation == engine.currentGeneration
        else { return false }

        networkPolicy.enterTerminalRemoteQuarantine()
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskID = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        lifecycleReportTask?.cancel()
        lifecycleReportTask = nil
        lifecycleReportTaskID = nil
        pendingProgressReport = nil
        PlaybackDiagnosticJournal.shared.record(
            "playback-containment phase=entered generation=\(generation)"
        )
        return true
    }

    @discardableResult
    private func stopTerminalRemoteItem(generation: Int) -> Bool {
        guard enterTerminalRemoteContainment(generation: generation) else {
            return false
        }
        cancelPendingPlaybackActivation()
        discardPreload()
        activeRequest = nil
        resourceLease = nil
        engine.stop()
        currentItemPlayerGeneration = nil
        resetPlaybackStability()
        return true
    }

    private func abandonStalledCurrentItem() {
        guard currentItem != nil else { return }
        guard stopTerminalRemoteItem(generation: engine.currentGeneration) else {
            return
        }
        failPlayback(
            "The current stream stopped responding. Choose another track or try this one again."
        )
    }

    private func userSafeFailureMessage(
        _ fallback: String,
        for item: PlaybackItem? = nil
    ) -> String {
        guard (item ?? currentItem)?.source == .jellyfin else { return fallback }
        return
            "The Jellyfin stream stopped unexpectedly. Try playing the track again."
    }

    private func cancelPendingPlaybackIntent(
        preservingAccumulatedNext: Bool = false,
        preservingAccumulatedPrevious: Bool = false,
        preservingRecoveryIntentGeneration: UUID? = nil
    ) {
        if activePlaybackRecovery?.intentGeneration
            != preservingRecoveryIntentGeneration
        {
            clearPlaybackRecovery()
        }
        if !preservingAccumulatedNext {
            pendingNextAdvanceCount = 0
        }
        if !preservingAccumulatedPrevious {
            pendingPreviousRetreatCount = 0
        }
        let hadForcedFallback =
            forcedFallbackTask != nil || forcedFallbackTaskID != nil
        cancelForcedFallbackTask()
        let hadPendingQueueSelectionHandoff =
            pendingQueueSelectionHandoff != nil
        if hadPendingQueueSelectionHandoff {
            cancelPendingQueueSelectionHandoff()
        }
        guard
            playbackIntentTask != nil || playbackIntentID != nil
                || hadPendingQueueSelectionHandoff || hadForcedFallback
        else {
            return
        }
        if let playbackIntentID {
            logIntentCancelled(playbackIntentID, kind: "superseded")
        }
        playbackIntentTask?.cancel()
        playbackIntentTask = nil
        playbackIntentID = nil
        preparingQueueItemIdentity = nil
        endPlaybackStartupSignpost()
    }

    private func startPlaybackAfterAudioSessionActivation() {
        guard let audioSessionController else {
            engine.play()
            return
        }

        let itemID = currentItem?.id
        cancelPendingPlaybackActivation()
        let activationID = UUID()
        playbackActivationID = activationID
        playbackActivationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if playbackActivationID == activationID {
                    playbackActivationTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                if let startupToken = playbackNetworkStartupToken {
                    try await waitForPlaybackNetworkQuiescence(
                        token: startupToken
                    )
                }
                try await audioSessionController.activate()
                try Task.checkCancellation()
                guard
                    currentItem?.id == itemID,
                    playbackActivationID == activationID,
                    !hasExplicitPlaybackPause,
                    !isAudioSessionInterrupted || requiresRouteRecovery
                else {
                    return
                }
                engine.play()
            } catch is CancellationError {
                return
            } catch {
                guard playbackActivationID == activationID else { return }
                apply(.failed(error.localizedDescription))
            }
        }
    }

    private func cancelPendingPlaybackActivation() {
        playbackActivationTask?.cancel()
        playbackActivationTask = nil
        playbackActivationID = nil
    }

    private func deactivateAudioSession() {
        guard let audioSessionController else { return }
        Task {
            await audioSessionController.deactivate(notifyingOthers: true)
        }
    }

    private func installPlatformEventObserver() {
        platformEventObserver?.start(
            interruption: { [weak self] event in
                self?.handleAudioSessionInterruption(event)
            },
            routeChange: { [weak self] event in
                self?.handleRouteChange(event)
            },
            didEnterBackground: { [weak self] in
                self?.saveNowPlayingState(force: true)
            }
        )
    }

    private func failPlayback(_ fallback: String) {
        endPlaybackStartupSignpost()
        let message = userSafeFailureMessage(fallback)
        playbackState = .failed(message)
        errorMessage = message
        saveNowPlayingState(force: true)
        publishNowPlaying()
    }

    private func resolvePlaybackRequest(
        for item: PlaybackItem,
        intentID: UUID,
        coalescingRapidCommands: Bool = false
    ) async throws -> PlaybackRequest {
        guard let requestResolver else { throw CancellationError() }
        guard !networkPolicy.isTerminalRemoteQuarantined else {
            throw CancellationError()
        }

        if coalescingRapidCommands {
            try await Task.sleep(
                for: ResiliencePolicy.networkIntentCoalescingDelay
            )
        }

        let networkDemandToken = UUID()
        networkPolicy.beginPlaybackStartup(networkDemandToken)
        defer {
            networkPolicy.endPlaybackStartup(networkDemandToken)
        }

        try Task.checkCancellation()
        let startedAt = Date()
        do {
            let request = try await requestResolver(item)
            Self.logger.debug(
                "Playback intent id=\(intentID.uuidString, privacy: .public) phase=resolved elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000), privacy: .public)"
            )
            return request
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error(
                "Playback intent id=\(intentID.uuidString, privacy: .public) phase=resolve-failed category=\(self.failureCategory(for: error), privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000), privacy: .public)"
            )
            throw error
        }
    }

    private func presentIntentFailure(
        _ error: Error,
        for item: PlaybackItem,
        preservingCommittedPlayback: Bool,
        intentID: UUID,
        kind: String
    ) {
        logIntentFailed(intentID, kind: kind, error: error)
        let canPreserveCurrentPlayback: Bool
        switch playbackState {
        case .failed, .ended, .idle:
            canPreserveCurrentPlayback = false
        case .loading, .waiting, .playing, .paused:
            canPreserveCurrentPlayback =
                preservingCommittedPlayback && engine.hasCurrentItem
        }

        if canPreserveCurrentPlayback {
            errorMessage =
                "The selected track could not be prepared. Current playback was preserved; try again."
            publishNowPlaying()
            return
        }

        let message = userSafeFailureMessage(
            error.localizedDescription,
            for: item
        )
        playbackState = .failed(message)
        errorMessage = message
        publishNowPlaying()
    }

    private func logIntentStarted(_ id: UUID, kind: String) {
        Self.logger.notice(
            "Playback intent id=\(id.uuidString, privacy: .public) kind=\(kind, privacy: .public) phase=started"
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-intent id=\(id.uuidString) kind=\(kind) phase=started revision=\(queueEditRevision)"
        )
    }

    private func logIntentCommitted(_ id: UUID, kind: String) {
        Self.logger.notice(
            "Playback intent id=\(id.uuidString, privacy: .public) kind=\(kind, privacy: .public) phase=committed"
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-intent id=\(id.uuidString) kind=\(kind) phase=committed revision=\(queueEditRevision)"
        )
    }

    private func logIntentCancelled(_ id: UUID, kind: String) {
        Self.logger.debug(
            "Playback intent id=\(id.uuidString, privacy: .public) kind=\(kind, privacy: .public) phase=cancelled"
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-intent id=\(id.uuidString) kind=\(kind) phase=cancelled revision=\(queueEditRevision)"
        )
    }

    private func logIntentFailed(_ id: UUID, kind: String, error: Error) {
        Self.logger.error(
            "Playback intent id=\(id.uuidString, privacy: .public) kind=\(kind, privacy: .public) phase=failed category=\(self.failureCategory(for: error), privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "playback-intent id=\(id.uuidString) kind=\(kind) phase=failed category=\(failureCategory(for: error)) revision=\(queueEditRevision)"
        )
    }

    private func failureCategory(for error: Error) -> String {
        guard let error = error as? JellyfinAPIError else {
            return String(describing: type(of: error))
        }
        switch error {
        case .offline: return "offline"
        case .unreachable: return "unreachable"
        case .timeout: return "timeout"
        case .dns: return "dns"
        case .unauthorized: return "unauthorized"
        case .transportSecurity: return "transport-security"
        case .unsupportedMedia: return "unsupported-media"
        case .invalidResponse: return "invalid-response"
        case .httpStatus(let code): return "http-\(code)"
        case .network: return "network"
        }
    }

    private func isPlaybackTransportWideFailure(_ error: Error) -> Bool {
        guard let error = error as? JellyfinAPIError else { return true }
        switch error {
        case .unsupportedMedia, .invalidResponse, .httpStatus:
            return false
        case .offline, .unreachable, .timeout, .dns, .unauthorized,
            .transportSecurity, .network:
            return true
        }
    }

    private func diagnosticName(for state: PlaybackState) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .waiting: "waiting"
        case .playing: "playing"
        case .paused: "paused"
        case .ended: "ended"
        case .failed: "failed"
        }
    }

    private func handleAudioSessionInterruption(
        _ interruption: PlaybackAudioInterruption
    ) {
        switch interruption {
        case .began:
            isAudioSessionInterrupted = true
            wasPlayingBeforeInterruption = isPlaying
            cancelPendingPlaybackActivation()
            if engine.hasCurrentItem {
                engine.pause()
            }
            apply(.paused)
            saveNowPlayingState(force: true)
        case .ended(let shouldResume):
            isAudioSessionInterrupted = false
            let shouldRestartPlayback =
                wasPlayingBeforeInterruption && shouldResume
            wasPlayingBeforeInterruption = false
            if shouldRestartPlayback {
                resumePlayback(isExplicitUserGesture: false)
            }
        }
    }

    private func handleRouteChange(_ routeChange: PlaybackAudioRouteChange) {
        if routeChange == .oldDeviceUnavailable {
            requiresRouteRecovery = true
            pausePlayback()
        }
    }
}
