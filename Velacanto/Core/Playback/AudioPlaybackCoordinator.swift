import AVFoundation
import Combine
import os

#if os(iOS)
    import UIKit
#endif

private enum AudioSessionError: LocalizedError {
    case activationFailed

    var errorDescription: String? {
        "The audio session could not be activated."
    }
}

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
    private var preloadedRequest: PlaybackRequest?
    private var artworkTask: Task<Void, Never>?
    private var artworkRequestID: UUID?
    private var nowPlayingArtworkIdentifier: String?
    private var nowPlayingArtwork: PlatformImage?
    private var wasPlayingBeforeInterruption = false
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var hasRetriedCurrentItem = false
    private var lifecycleReporter: (any PlaybackLifecycleReporting)?
    private var didReportPlaybackStart = false
    private var lastProgressReportBucket = -1
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
        nowPlayingStateStore: (any NowPlayingStateStoring)? = nil
    ) {
        self.engine = engine
        self.systemMediaController = systemMediaController
        self.historyStore = historyStore
        self.nowPlayingStateStore = nowPlayingStateStore
        recentItems = historyStore?.loadItems() ?? []
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        if systemMediaController != nil {
            registerSystemMediaCommands()
        }
        installAudioSessionObservers()
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
        switch playbackState {
        case .loading, .waiting, .playing:
            true
        case .idle, .paused, .ended, .failed:
            false
        }
    }

    var canGoPrevious: Bool {
        elapsed > 3 || queue?.canGoPrevious == true
    }

    var canGoNext: Bool {
        queue?.canGoNext == true
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
        beginPlaybackStartupSignpost()
        prepareSystemMediaController()
        let playerItem = request.asset.makePlayerItem()

        if currentItem?.id != request.item.id {
            reportPlaybackStopped()
        }
        queueTransitionTask?.cancel()
        preloadTask?.cancel()
        preloadedRequest = nil
        nowPlayingArtworkIdentifier = nil
        nowPlayingArtwork = nil
        currentItem = request.item
        lifecycleReporter = request.reporter
        didReportPlaybackStart = false
        lastProgressReportBucket = -1
        elapsed = 0
        duration = 0
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

        if showsPauseControl {
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
        engine.seek(to: target)
        elapsed = target
        reportPlaybackProgress(isPaused: !isPlaying)
        publishNowPlaying()
    }

    func pausePlayback() {
        guard engine.hasCurrentItem else { return }
        engine.pause()
        saveNowPlayingState(force: true)
        reportPlaybackProgress(isPaused: true)
    }

    func resumePlayback() {
        guard currentItem != nil else { return }

        guard engine.hasCurrentItem else {
            resolveRestoredItemAndPlay()
            return
        }

        if playbackState == .ended || (duration > 0 && elapsed >= duration) {
            engine.seek(to: 0)
            elapsed = 0
        }

        errorMessage = nil
        startPlaybackAfterAudioSessionActivation()
    }

    func stop() {
        queueTransitionTask?.cancel()
        preloadTask?.cancel()
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequestID = nil
        preloadedRequest = nil
        reportPlaybackStopped()
        engine.stop()
        resourceLease = nil
        currentItem = nil
        elapsed = 0
        duration = 0
        bufferState = .empty
        playbackState = .idle
        errorMessage = nil
        queue = nil
        queueExpansionHandler = nil
        playbackAccount = nil
        restoredElapsed = nil
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

    private func apply(_ state: PlaybackState) {
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
        if case .failed(let message) = state {
            errorMessage = message
            endPlaybackStartupSignpost()
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
                let elapsed = elapsed
                Task {
                    await lifecycleReporter.reportStarted(at: elapsed)
                }
            }
        }
        publishNowPlaying()
        switch state {
        case .paused, .ended, .failed:
            saveNowPlayingState(force: true)
        case .idle, .loading, .waiting, .playing:
            break
        }
        if state == .ended, canGoNext {
            nextTrack()
        } else if state == .ended {
            reportPlaybackStopped()
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
                canGoNext: canGoNext
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
        guard let previousItem = queue?.previousItem else {
            seek(toTime: 0)
            return
        }
        transition(to: previousItem, direction: .previous)
    }

    func nextTrack() {
        guard let nextItem = queue?.nextItem else { return }
        if preloadedRequest?.item.id == nextItem.id {
            engine.advanceToNextItem()
            return
        }
        transition(to: nextItem, direction: .next)
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
        duration = 0
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
                    queue?.movePrevious()
                case .next:
                    queue?.moveNext()
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
                account: playbackAccount,
                savedAt: now
            )
        )
    }

    private func preloadNextItem() {
        preloadTask?.cancel()
        preloadedRequest = nil
        engine.preload(nil)
        guard let nextItem = queue?.nextItem else {
            expandQueueIfPossible()
            return
        }
        guard let requestResolver else {
            return
        }
        let currentItemID = currentItem?.id
        preloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                preloadTask = nil
            }
            do {
                let request = try await requestResolver(nextItem)
                try Task.checkCancellation()
                guard
                    currentItem?.id == currentItemID,
                    queue?.nextItem?.id == request.item.id
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
            let queueExpansionHandler,
            preloadTask == nil
        else {
            return
        }
        let currentItemID = currentItem?.id
        preloadTask = Task { [weak self] in
            guard let self else { return }
            let expandedItems = await queueExpansionHandler()
            preloadTask = nil
            guard currentItem?.id == currentItemID else { return }
            queue?.append(expandedItems)
            if queue?.nextItem != nil {
                preloadNextItem()
            }
        }
    }

    private func commitPreloadedNextItem() {
        guard
            let request = preloadedRequest,
            queue?.nextItem?.id == request.item.id
        else {
            return
        }
        queue?.moveNext()
        reportPlaybackStopped()
        currentItem = request.item
        lifecycleReporter = request.reporter
        didReportPlaybackStart = false
        lastProgressReportBucket = -1
        resourceLease = request.asset.resourceLease
        preloadedRequest = nil
        elapsed = 0
        duration = 0
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

    private func reportPlaybackProgress(isPaused: Bool) {
        guard let lifecycleReporter else { return }
        let elapsed = elapsed
        Task {
            await lifecycleReporter.reportProgress(
                at: elapsed,
                isPaused: isPaused
            )
        }
    }

    private func reportPlaybackStopped() {
        guard let lifecycleReporter else { return }
        let elapsed = elapsed
        Task {
            await lifecycleReporter.reportStopped(at: elapsed)
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
                resourceLease = request.asset.resourceLease
                engine.load(request.asset.makePlayerItem())
                if resumeTime > 0 {
                    engine.seek(to: resumeTime)
                    elapsed = resumeTime
                }
                startPlaybackAfterAudioSessionActivation()
                preloadNextItem()
            } catch {
                errorMessage = error.localizedDescription
                publishNowPlaying()
            }
        }
    }

    private func prepareSystemMediaController() {
        guard systemMediaController == nil else { return }
        systemMediaController = MediaPlayerSystemMediaController()
        registerSystemMediaCommands()
    }

    private func startPlaybackAfterAudioSessionActivation() {
        #if os(iOS)
            let itemID = currentItem?.id
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await configureAudioSession()
                    guard currentItem?.id == itemID else { return }
                    engine.play()
                } catch {
                    apply(.failed(error.localizedDescription))
                }
            }
        #else
            engine.play()
        #endif
    }

    private func configureAudioSession() async throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            if #available(iOS 27.0, *) {
                guard try await session.activate(options: []) else {
                    throw AudioSessionError.activationFailed
                }
            } else {
                try session.setActive(true)
            }
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            if #available(iOS 27.0, *) {
                Task {
                    _ = try? await session.deactivate(
                        options: .notifyOthersOnDeactivation
                    )
                }
            } else {
                try? session.setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
        #endif
    }

    private func installAudioSessionObservers() {
        #if os(iOS)
            let center = NotificationCenter.default
            audioSessionObservers = [
                center.addObserver(
                    forName: AVAudioSession.interruptionNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let rawType =
                        notification.userInfo?[
                            AVAudioSessionInterruptionTypeKey
                        ] as? UInt
                    let rawOptions =
                        notification.userInfo?[
                            AVAudioSessionInterruptionOptionKey
                        ] as? UInt
                    MainActor.assumeIsolated {
                        self?.handleAudioSessionInterruption(
                            rawType: rawType,
                            rawOptions: rawOptions
                        )
                    }
                },
                center.addObserver(
                    forName: AVAudioSession.routeChangeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    let rawReason =
                        notification.userInfo?[
                            AVAudioSessionRouteChangeReasonKey
                        ] as? UInt
                    MainActor.assumeIsolated {
                        self?.handleRouteChange(rawReason: rawReason)
                    }
                },
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.saveNowPlayingState(force: true)
                    }
                },
            ]
        #endif
    }

    private func handleAudioSessionInterruption(
        rawType: UInt?,
        rawOptions: UInt?
    ) {
        #if os(iOS)
            guard
                let rawType,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else {
                return
            }

            switch type {
            case .began:
                wasPlayingBeforeInterruption = isPlaying
                if engine.hasCurrentItem {
                    engine.pause()
                }
                saveNowPlayingState(force: true)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions ?? 0
                )
                if wasPlayingBeforeInterruption,
                    options.contains(.shouldResume)
                {
                    resumePlayback()
                }
                wasPlayingBeforeInterruption = false
            @unknown default:
                break
            }
        #endif
    }

    private func handleRouteChange(rawReason: UInt?) {
        #if os(iOS)
            guard
                let rawReason,
                AVAudioSession.RouteChangeReason(rawValue: rawReason)
                    == .oldDeviceUnavailable
            else {
                return
            }
            pausePlayback()
        #endif
    }

    isolated deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
