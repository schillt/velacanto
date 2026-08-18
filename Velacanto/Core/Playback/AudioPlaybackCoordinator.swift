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

    private let engine: any AudioPlayerEngine
    private var systemMediaController: (any SystemMediaControlling)?
    private let historyStore: (any PlaybackHistoryStoring)?
    private let nowPlayingStateStore: (any NowPlayingStateStoring)?
    private var resourceLease: (any PlaybackResourceLease)?
    private var requestResolver: (@MainActor (PlaybackItem) async throws -> PlaybackRequest)?
    private var artworkResolver: (@MainActor (PlaybackItem) async -> ResolvedNowPlayingArtwork?)?
    private var queueExpansionHandler: (@MainActor () async -> [PlaybackItem])?
    private var playbackAccount: PlaybackAccount?
    private var restoredElapsed: TimeInterval?
    private var lastStateSaveTime = Date.distantPast
    private var queueTransitionTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var preloadTaskID: UUID?
    private var preloadedRequest: PlaybackRequest?
    private var queueEditRevision = 0
    private var advancesAfterQueueExpansion = false
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID: UUID?
    private var nowPlayingArtworkIdentifier: String?
    private var nowPlayingArtwork: PlatformImage?
    private var wasPlayingBeforeInterruption = false
    private var isAudioSessionInterrupted = false
    // Keep delayed AVPlayer state observations from undoing an intentional pause
    // while an output route or audio session is reconfiguring.
    private var hasExplicitPlaybackPause = false
    private var requiresRouteRecovery = false
    private var playbackActivationTask: Task<Void, Never>?
    private var playbackActivationID: UUID?
    private let audioSessionController: (any PlaybackAudioSessionControlling)?
    private let platformEventObserver: (any PlaybackPlatformEventObserving)?
    private var hasRetriedCurrentItem = false
    private var lifecycleReporter: (any PlaybackLifecycleReporting)?
    private var didReportPlaybackStart = false
    private var didReportPlaybackStop = false
    private var lastProgressReportBucket = -1
    private var lifecycleReportTask: Task<Void, Never>?
    private var playbackStartupSignpostID: OSSignpostID?

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
        systemMediaController: (any SystemMediaControlling)? = nil,
        historyStore: (any PlaybackHistoryStoring)? = nil,
        nowPlayingStateStore: (any NowPlayingStateStoring)? = nil,
        platformEventObserver: (any PlaybackPlatformEventObserving)? = nil,
        audioSessionController: (any PlaybackAudioSessionControlling)? = nil
    ) {
        self.engine = engine
        self.systemMediaController = systemMediaController
        self.historyStore = historyStore
        self.nowPlayingStateStore = nowPlayingStateStore
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
        recentItems = historyStore?.loadItems() ?? []
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        if systemMediaController != nil {
            registerSystemMediaCommands()
        }
        installPlatformEventObserver()
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

    var canGoPrevious: Bool {
        elapsed > 3 || queue?.canGoPrevious == true
            || (queue?.repeatMode == .all && queue?.items.isEmpty == false)
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
        let items = queueItems.isEmpty ? [request.item] : queueItems
        queue = PlaybackQueue(
            items: items,
            currentItemID: request.item.id,
            context: context
        )
        queueEditRevision += 1
        playbackAccount = account
        queueExpansionHandler = queueExpansion
        restoredElapsed = nil
        hasRetriedCurrentItem = false
        playResolvedRequest(request, recordsQueueState: true)
    }

    private func playResolvedRequest(
        _ request: PlaybackRequest,
        recordsQueueState: Bool
    ) {
        cancelPendingPlaybackActivation()
        hasExplicitPlaybackPause = false
        requiresRouteRecovery = false
        beginPlaybackStartupSignpost()
        prepareSystemMediaController()
        let playerItem = request.asset.makePlayerItem()

        reportPlaybackStopped()
        queueTransitionTask?.cancel()
        preloadTask?.cancel()
        preloadTaskID = nil
        preloadedRequest = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        currentItem = request.item
        transportKind = request.transportKind
        replaceLifecycleReporter(with: request.reporter)
        elapsed = 0
        duration = validatedDuration(request.item.duration)
        bufferState = .empty
        errorMessage = nil
        playbackState = .loading
        if request.recordsHistory {
            recordInHistory(request.item)
        }
        engine.load(playerItem)
        resourceLease = request.asset.resourceLease
        publishNowPlaying()
        loadNowPlayingArtwork()
        if recordsQueueState {
            saveNowPlayingState(force: true)
        }

        startPlaybackAfterAudioSessionActivation()
        preloadNextItem()
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
        seekRequestID = UUID()
        engine.seek(to: target)
        elapsed = target
        reportPlaybackProgress(isPaused: !isPlaying)
        publishNowPlaying()
    }

    func pausePlayback() {
        guard engine.hasCurrentItem else { return }
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
        guard currentItem != nil else { return }

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
            engine.seek(to: 0)
            elapsed = 0
            didReportPlaybackStart = false
            didReportPlaybackStop = false
            lastProgressReportBucket = -1
        }

        errorMessage = nil
        if playbackState == .paused || isRecoveringRoute {
            playbackState = .waiting
            publishNowPlaying()
        }
        startPlaybackAfterAudioSessionActivation()
    }

    func stop() {
        cancelPendingPlaybackActivation()
        queueTransitionTask?.cancel()
        preloadTask?.cancel()
        preloadTaskID = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        preloadedRequest = nil
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
        systemMediaController?.update(.empty)
        deactivateAudioSession()
    }

    private func handle(_ event: AudioPlayerEngineEvent) {
        switch event {
        case .timeChanged(let newElapsed, let newDuration):
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

        case .stateChanged(let state):
            apply(state)

        case .advancedToNextItem:
            commitPreloadedNextItem()

        case .bufferStateChanged(let state):
            bufferState = state
            if state.isEmpty {
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "Playback Stall"
                )
            }
        }
    }

    private func recordInHistory(_ item: PlaybackItem) {
        recentItems.removeAll { $0.id == item.id && $0.source == item.source }
        recentItems.insert(item, at: 0)
        recentItems = Array(recentItems.prefix(12))
        historyStore?.saveItems(recentItems)
    }

    private func apply(_ incomingState: PlaybackState) {
        let state: PlaybackState
        if case .failed(let message) = incomingState {
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

        guard state != playbackState else { return }

        playbackState = state
        if state == .playing {
            requiresRouteRecovery = false
        }
        if case .failed(let message) = state {
            errorMessage = message
            endPlaybackStartupSignpost()
            reportPlaybackStopped()
            retryCurrentItemOnceIfPossible()
        }
        if state == .playing, !didReportPlaybackStart {
            endPlaybackStartupSignpost()
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Playback Audible"
            )
            didReportPlaybackStart = true
            if let lifecycleReporter {
                enqueueLifecycleReport(
                    .started(lifecycleReporter, elapsed)
                )
            }
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
                resumePlayback()
            } else if canGoNext {
                nextTrack()
            }
        }
    }

    private func beginPlaybackStartupSignpost() {
        endPlaybackStartupSignpost()
        let signpostID = OSSignpostID(log: Self.performanceLog)
        playbackStartupSignpostID = signpostID
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "Tap to Audio",
            signpostID: signpostID
        )
    }

    private func endPlaybackStartupSignpost() {
        guard let signpostID = playbackStartupSignpostID else { return }
        os_signpost(
            .end,
            log: Self.performanceLog,
            name: "Tap to Audio",
            signpostID: signpostID
        )
        playbackStartupSignpostID = nil
    }

    private func registerSystemMediaCommands() {
        systemMediaController?.registerCommands(
            play: { [weak self] in
                self?.resumePlayback()
            },
            pause: { [weak self] in
                self?.pausePlayback()
            },
            previous: { [weak self] in
                self?.previousTrack()
            },
            next: { [weak self] in
                self?.nextTrack()
            },
            togglePlayPause: { [weak self] in
                self?.togglePlayback()
            },
            seek: { [weak self] time in
                self?.seek(toTime: time)
            },
            changeRepeatMode: { [weak self] mode in
                self?.setRepeatMode(mode)
            },
            shuffle: { [weak self] in
                self?.shuffleUpcoming()
            }
        )
    }

    private func publishNowPlaying() {
        systemMediaController?.update(
            NowPlayingSnapshot(
                item: currentItem,
                elapsed: elapsed,
                duration: duration,
                isPlaying: isPlaying,
                artworkIdentifier: nowPlayingArtworkIdentifier,
                artwork: nowPlayingArtwork,
                canGoPrevious: canGoPrevious,
                canGoNext: canGoNext,
                repeatMode: repeatMode
            )
        )
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

    private func loadNowPlayingArtwork() {
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil

        guard let item = currentItem, let artworkResolver else { return }

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
        if elapsed > 3 {
            seek(toTime: 0)
            return
        }
        let previousItem =
            queue?.previousItem
            ?? (repeatMode == .all ? queue?.items.last : nil)
        guard let previousItem else {
            seek(toTime: 0)
            return
        }
        transition(to: previousItem, direction: .previous)
    }

    func nextTrack() {
        if queue?.nextItem == nil, queueExpansionHandler != nil {
            advancesAfterQueueExpansion = true
            expandQueueIfPossible()
            return
        }
        let nextItem =
            queue?.nextItem
            ?? (repeatMode == .all ? queue?.items.first : nil)
        guard let nextItem else { return }
        if preloadedRequest?.item.id == nextItem.id {
            engine.advanceToNextItem()
            return
        }
        transition(to: nextItem, direction: .next)
    }

    func playQueueItem(_ item: PlaybackItem) {
        if currentItem?.source == item.source, currentItem?.id == item.id {
            resumePlayback()
            return
        }
        transition(to: item, direction: .selected)
    }

    func playNext(_ item: PlaybackItem) {
        editQueue { $0.playNext(item) }
    }

    func playLast(_ item: PlaybackItem) {
        editQueue { $0.playLast(item) }
    }

    func removeUpcomingItem(_ item: PlaybackItem) {
        editQueue { $0.removeUpcomingItem(item) }
    }

    func moveUpcomingItem(from source: Int, to destination: Int) {
        editQueue { $0.moveUpcomingItem(from: source, to: destination) }
    }

    func shuffleUpcoming() {
        editQueue { $0.shuffleUpcoming() }
    }

    func cycleRepeatMode() {
        setRepeatMode(repeatMode.next)
    }

    func setRepeatMode(_ mode: PlaybackRepeatMode) {
        guard queue != nil, repeatMode != mode else { return }
        queue?.setRepeatMode(mode)
        queueEditRevision += 1
        invalidatePreloadAndRefreshQueue()
    }

    private func editQueue(_ mutation: (inout PlaybackQueue) -> Bool) {
        guard var editedQueue = queue, mutation(&editedQueue) else { return }
        queue = editedQueue
        queueEditRevision += 1
        invalidatePreloadAndRefreshQueue()
    }

    private func invalidatePreloadAndRefreshQueue() {
        advancesAfterQueueExpansion = false
        preloadTask?.cancel()
        preloadTask = nil
        preloadTaskID = nil
        preloadedRequest = nil
        engine.preload(nil)
        saveNowPlayingState(force: true)
        publishNowPlaying()
        preloadNextItem()
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
        prepareSystemMediaController()
        publishNowPlaying()
        loadNowPlayingArtwork()
    }

    func clearSavedState(serverID: String, userID: String) {
        let account = PlaybackAccount(serverID: serverID, userID: userID)
        if nowPlayingStateStore?.loadState()?.account == account {
            nowPlayingStateStore?.clearState()
        }
    }

    private enum QueueDirection {
        case previous
        case next
        case selected
    }

    private func transition(
        to item: PlaybackItem,
        direction: QueueDirection
    ) {
        guard let requestResolver else { return }
        let expectedCurrentID = currentItem?.id
        queueTransitionTask?.cancel()
        playbackState = .loading
        errorMessage = nil
        publishNowPlaying()

        queueTransitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                queueTransitionTask = nil
            }
            do {
                let request = try await requestResolver(item)
                try Task.checkCancellation()
                guard currentItem?.id == expectedCurrentID else { return }
                switch direction {
                case .previous:
                    queue?.movePrevious(wrapping: repeatMode == .all)
                case .next:
                    queue?.moveNext(wrapping: repeatMode == .all)
                case .selected:
                    guard queue?.select(item) == true else { return }
                }
                hasRetriedCurrentItem = false
                Self.logger.debug("Queue transition")
                os_signpost(
                    .event,
                    log: Self.performanceLog,
                    name: "Queue Transition"
                )
                playResolvedRequest(request, recordsQueueState: true)
            } catch is CancellationError {
                return
            } catch {
                apply(.failed(error.localizedDescription))
            }
        }
    }

    private func resolveRestoredItemAndPlay() {
        guard
            let item = currentItem,
            let requestResolver,
            queueTransitionTask == nil
        else {
            return
        }
        playbackState = .loading
        errorMessage = nil
        publishNowPlaying()
        let seekTime = restoredElapsed ?? elapsed

        queueTransitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                queueTransitionTask = nil
            }
            do {
                let request = try await requestResolver(item)
                try Task.checkCancellation()
                guard currentItem?.id == item.id else { return }
                playResolvedRequest(request, recordsQueueState: false)
                if seekTime > 0 {
                    engine.seek(to: seekTime)
                    elapsed = seekTime
                }
                restoredElapsed = nil
                publishNowPlaying()
            } catch is CancellationError {
                return
            } catch {
                apply(.failed(error.localizedDescription))
            }
        }
    }

    private func resolveFailedJellyfinItemAndPlay() {
        guard
            let item = currentItem,
            let requestResolver,
            queueTransitionTask == nil
        else {
            return
        }

        let seekTime = elapsed
        playbackState = .loading
        errorMessage = nil
        publishNowPlaying()

        queueTransitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                queueTransitionTask = nil
            }
            do {
                let request = try await requestResolver(item)
                try Task.checkCancellation()
                guard currentItem?.id == item.id else { return }
                playResolvedRequest(request, recordsQueueState: false)
                if seekTime > 0 {
                    engine.seek(to: seekTime)
                    elapsed = seekTime
                }
                publishNowPlaying()
            } catch is CancellationError {
                return
            } catch {
                let message = userSafeFailureMessage(
                    error.localizedDescription
                )
                playbackState = .failed(message)
                errorMessage = message
                saveNowPlayingState(force: true)
                publishNowPlaying()
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

    private func preloadNextItem() {
        preloadTask?.cancel()
        preloadTaskID = nil
        preloadedRequest = nil
        engine.preload(nil)
        let nextItem =
            queue?.nextItem
            ?? (queueExpansionHandler == nil && repeatMode == .all
                && (queue?.items.count ?? 0) > 1
                ? queue?.items.first : nil)
        guard let nextItem else {
            expandQueueIfPossible()
            return
        }
        guard let requestResolver else {
            return
        }
        let currentItemID = currentItem?.id
        let expectedRevision = queueEditRevision
        let taskID = UUID()
        preloadTaskID = taskID
        preloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if preloadTaskID == taskID {
                    preloadTask = nil
                    preloadTaskID = nil
                }
            }
            do {
                let request = try await requestResolver(nextItem)
                try Task.checkCancellation()
                guard
                    currentItem?.id == currentItemID,
                    queueEditRevision == expectedRevision,
                    nextQueueItemForPreloading?.id == request.item.id
                else {
                    return
                }
                preloadedRequest = request
                engine.preload(request.asset.makePlayerItem())
            } catch {
                return
            }
        }
    }

    private func expandQueueIfPossible() {
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
            advancesAfterQueueExpansion = false
            if shouldAdvance {
                nextTrack()
            } else if queue?.nextItem != nil || repeatMode == .all {
                preloadNextItem()
            }
        }
    }

    private func commitPreloadedNextItem() {
        guard
            let request = preloadedRequest,
            nextQueueItemForPreloading?.id == request.item.id
        else {
            return
        }
        queue?.moveNext(wrapping: repeatMode == .all)
        reportPlaybackStopped()
        currentItem = request.item
        transportKind = request.transportKind
        replaceLifecycleReporter(with: request.reporter)
        resourceLease = request.asset.resourceLease
        preloadedRequest = nil
        elapsed = 0
        duration = validatedDuration(request.item.duration)
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
        preloadNextItem()
    }

    private var nextQueueItemForPreloading: PlaybackItem? {
        queue?.nextItem
            ?? (queueExpansionHandler == nil && repeatMode == .all
                && (queue?.items.count ?? 0) > 1
                ? queue?.items.first : nil)
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
        let previousTask = lifecycleReportTask
        lifecycleReportTask = Task {
            await previousTask?.value
            do {
                try await report.send()
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("Playback lifecycle report failed")
            }
        }
    }

    private func retryCurrentItemOnceIfPossible() {
        guard
            !hasRetriedCurrentItem,
            currentItem?.source == .jellyfin,
            let item = currentItem,
            let requestResolver
        else {
            return
        }
        hasRetriedCurrentItem = true
        hasExplicitPlaybackPause = false
        cancelPendingPlaybackActivation()
        let resumeTime = elapsed
        queueTransitionTask?.cancel()
        queueTransitionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                queueTransitionTask = nil
            }
            do {
                let request = try await requestResolver(item)
                try Task.checkCancellation()
                guard currentItem?.id == item.id else { return }
                playbackState = .loading
                errorMessage = nil
                replaceLifecycleReporter(with: request.reporter)
                transportKind = request.transportKind
                resourceLease = request.asset.resourceLease
                engine.load(request.asset.makePlayerItem())
                if resumeTime > 0 {
                    engine.seek(to: resumeTime)
                    elapsed = resumeTime
                }
                startPlaybackAfterAudioSessionActivation()
                preloadNextItem()
            } catch {
                let message = userSafeFailureMessage(
                    error.localizedDescription
                )
                playbackState = .failed(message)
                errorMessage = message
                saveNowPlayingState(force: true)
                publishNowPlaying()
            }
        }
    }

    private func userSafeFailureMessage(_ fallback: String) -> String {
        guard currentItem?.source == .jellyfin else { return fallback }
        return
            "The Jellyfin stream stopped unexpectedly. Try playing the track again."
    }

    private func prepareSystemMediaController() {
        guard systemMediaController == nil else { return }
        systemMediaController = MediaPlayerSystemMediaController()
        registerSystemMediaCommands()
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
                resumePlayback()
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
