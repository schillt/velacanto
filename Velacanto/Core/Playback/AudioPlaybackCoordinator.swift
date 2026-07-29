import AVFoundation
import Combine

@MainActor
final class AudioPlaybackCoordinator: ObservableObject {
    @Published private(set) var currentItem: PlaybackItem?
    @Published private(set) var playbackState = PlaybackState.idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var recentItems: [PlaybackItem]

    private let engine: any AudioPlayerEngine
    private let systemMediaController: SystemMediaControlling
    private let historyStore: (any PlaybackHistoryStoring)?
    private var resourceLease: (any PlaybackResourceLease)?

    init(
        engine: any AudioPlayerEngine = AVFoundationAudioPlayerEngine(),
        systemMediaController: SystemMediaControlling = MediaPlayerSystemMediaController(),
        historyStore: (any PlaybackHistoryStoring)? = nil
    ) {
        self.engine = engine
        self.systemMediaController = systemMediaController
        self.historyStore = historyStore
        recentItems = historyStore?.loadItems() ?? []
        engine.eventHandler = { [weak self] event in
            self?.handle(event)
        }
        registerSystemMediaCommands()
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

    func play(_ request: PlaybackRequest) {
        let playerItem = request.asset.makePlayerItem()

        currentItem = request.item
        elapsed = 0
        duration = 0
        errorMessage = nil
        playbackState = .loading
        recordInHistory(request.item)
        engine.load(playerItem)
        resourceLease = request.asset.resourceLease
        publishNowPlaying()

        do {
            try configureAudioSession()
            engine.play()
        } catch {
            apply(.failed(error.localizedDescription))
        }
    }

    func togglePlayback() {
        guard engine.hasCurrentItem else { return }

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
        publishNowPlaying()
    }

    func pausePlayback() {
        guard engine.hasCurrentItem else { return }
        engine.pause()
    }

    func resumePlayback() {
        guard engine.hasCurrentItem else { return }

        if playbackState == .ended || (duration > 0 && elapsed >= duration) {
            engine.seek(to: 0)
            elapsed = 0
        }

        do {
            try configureAudioSession()
            errorMessage = nil
            engine.play()
        } catch {
            apply(.failed(error.localizedDescription))
        }
    }

    func stop() {
        engine.stop()
        resourceLease = nil
        currentItem = nil
        elapsed = 0
        duration = 0
        playbackState = .idle
        errorMessage = nil
        systemMediaController.update(.empty)
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

        case .stateChanged(let state):
            apply(state)
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
        }
        publishNowPlaying()
    }

    private func registerSystemMediaCommands() {
        systemMediaController.registerCommands(
            play: { [weak self] in
                self?.resumePlayback()
            },
            pause: { [weak self] in
                self?.pausePlayback()
            },
            stop: { [weak self] in
                self?.stop()
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
        systemMediaController.update(
            NowPlayingSnapshot(
                item: currentItem,
                elapsed: elapsed,
                duration: duration,
                isPlaying: isPlaying
            )
        )
    }

    private func configureAudioSession() throws {
        #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        #endif
    }
}
