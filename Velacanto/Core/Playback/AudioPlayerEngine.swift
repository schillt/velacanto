import AVFoundation
import Foundation

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

enum AudioPlayerEngineEvent: Equatable, Sendable {
    case timeChanged(elapsed: TimeInterval, duration: TimeInterval)
    case stateChanged(PlaybackState)
    case advancedToNextItem
    case bufferStateChanged(PlaybackBufferState)
}

@MainActor
protocol AudioPlayerEngine: AnyObject {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)? { get set }
    var hasCurrentItem: Bool { get }

    func load(_ item: AVPlayerItem)
    func preload(_ item: AVPlayerItem?)
    func advanceToNextItem()
    func play()
    func pause()
    func seek(to time: TimeInterval)
    func stop()
}

@MainActor
final class AVFoundationAudioPlayerEngine: AudioPlayerEngine {
    var eventHandler: (@MainActor (AudioPlayerEngineEvent) -> Void)?

    var hasCurrentItem: Bool {
        player.currentItem != nil
    }

    private let player: AVQueuePlayer
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var bufferEmptyObservation: NSKeyValueObservation?
    private var bufferLikelyObservation: NSKeyValueObservation?
    private var loadedRangesObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var currentItemDidEnd = false
    private var terminalFailureMessage: String?

    init(player: AVQueuePlayer = AVQueuePlayer()) {
        self.player = player
        player.automaticallyWaitsToMinimizeStalling = true
        installTimeObserver()
        installTimeControlObservation()
    }

    func load(_ item: AVPlayerItem) {
        currentItemDidEnd = false
        terminalFailureMessage = nil
        removeCurrentItemObservers()
        player.pause()
        player.removeAllItems()
        player.insert(item, after: nil)
        eventHandler?(.timeChanged(elapsed: 0, duration: 0))
        eventHandler?(.stateChanged(.loading))
        observe(item)
    }

    func preload(_ item: AVPlayerItem?) {
        guard let currentItem = player.currentItem else { return }
        for queuedItem in player.items().dropFirst().reversed() {
            player.remove(queuedItem)
        }
        guard
            let item,
            player.canInsert(item, after: currentItem)
        else {
            return
        }
        player.insert(item, after: currentItem)
    }

    func advanceToNextItem() {
        guard player.items().count > 1 else { return }
        player.advanceToNextItem()
        beginObservingAdvancedItem()
    }

    func play() {
        guard player.currentItem != nil else { return }

        currentItemDidEnd = false
        terminalFailureMessage = nil
        player.play()
    }

    func pause() {
        guard player.currentItem != nil else { return }
        player.pause()
    }

    func seek(to time: TimeInterval) {
        guard player.currentItem != nil, time.isFinite else { return }

        if currentItemDidEnd {
            currentItemDidEnd = false
            eventHandler?(.stateChanged(.paused))
        }

        player.seek(
            to: CMTime(seconds: max(time, 0), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func stop() {
        currentItemDidEnd = false
        terminalFailureMessage = nil
        player.pause()
        removeCurrentItemObservers()
        player.removeAllItems()
        eventHandler?(.timeChanged(elapsed: 0, duration: 0))
        eventHandler?(.stateChanged(.idle))
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

    private func installTimeControlObservation() {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.publishState(for: player.timeControlStatus)
            }
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
                    self?.publishState(for: .waitingToPlayAtSpecifiedRate)
                }
            },
        ]
    }

    private func handleStatusChange(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }

        switch item.status {
        case .unknown:
            eventHandler?(.stateChanged(.loading))
        case .readyToPlay:
            publishTime(player.currentTime())
            publishState(for: player.timeControlStatus)
        case .failed:
            publishFailure(item.error ?? player.error)
        @unknown default:
            eventHandler?(.stateChanged(.loading))
        }
    }

    private func publishState(for status: AVPlayer.TimeControlStatus) {
        if let terminalFailureMessage {
            eventHandler?(.stateChanged(.failed(terminalFailureMessage)))
            return
        }

        if currentItemDidEnd {
            eventHandler?(.stateChanged(.ended))
            return
        }

        guard let item = player.currentItem else {
            eventHandler?(.stateChanged(.idle))
            return
        }

        if item.status == .failed {
            publishFailure(item.error ?? player.error)
            return
        }

        if item.status == .unknown {
            eventHandler?(.stateChanged(.loading))
            return
        }

        switch status {
        case .paused:
            eventHandler?(.stateChanged(.paused))
        case .waitingToPlayAtSpecifiedRate:
            eventHandler?(.stateChanged(.waiting))
        case .playing:
            eventHandler?(.stateChanged(.playing))
        @unknown default:
            eventHandler?(.stateChanged(.paused))
        }
    }

    private func publishTime(_ time: CMTime) {
        let currentSeconds = time.seconds
        let elapsed = currentSeconds.isFinite ? max(currentSeconds, 0) : 0

        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration =
            itemDuration.isFinite && itemDuration > 0
            ? itemDuration
            : 0

        eventHandler?(.timeChanged(elapsed: elapsed, duration: duration))
    }

    private func publishBufferState(for item: AVPlayerItem) {
        guard item === player.currentItem else { return }
        let loadedThrough =
            item.loadedTimeRanges
            .compactMap { $0.timeRangeValue.end.seconds }
            .filter(\.isFinite)
            .max() ?? 0
        eventHandler?(
            .bufferStateChanged(
                PlaybackBufferState(
                    loadedThrough: max(loadedThrough, 0),
                    isEmpty: item.isPlaybackBufferEmpty,
                    isLikelyToKeepUp: item.isPlaybackLikelyToKeepUp
                )
            )
        )
    }

    private func handlePlaybackEnded(_ endedItem: AVPlayerItem) {
        if player.currentItem !== endedItem {
            beginObservingAdvancedItem()
            return
        }
        currentItemDidEnd = true
        terminalFailureMessage = nil

        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            eventHandler?(.timeChanged(elapsed: duration, duration: duration))
        }
        eventHandler?(.stateChanged(.ended))
    }

    private func beginObservingAdvancedItem() {
        guard let currentItem = player.currentItem else {
            eventHandler?(.stateChanged(.ended))
            return
        }
        currentItemDidEnd = false
        terminalFailureMessage = nil
        removeCurrentItemObservers()
        observe(currentItem)
        eventHandler?(.timeChanged(elapsed: 0, duration: 0))
        eventHandler?(.advancedToNextItem)
        publishState(for: player.timeControlStatus)
    }

    private func publishFailure(_ error: Error?) {
        let message = error?.localizedDescription ?? "The audio could not be played."
        currentItemDidEnd = false
        terminalFailureMessage = message
        eventHandler?(.stateChanged(.failed(message)))
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
        timeControlObservation = nil
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
