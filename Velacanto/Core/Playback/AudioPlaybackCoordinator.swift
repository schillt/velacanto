import AVFoundation
import Combine

@MainActor
final class AudioPlaybackCoordinator: ObservableObject {
    @Published private(set) var currentItem: PlaybackItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var errorMessage: String?

    private let player = AVPlayer()
    private let systemMediaController: SystemMediaControlling
    private var timeObserver: Any?
    private var resourceAccess: SecurityScopedResourceAccess?

    init(
        systemMediaController: SystemMediaControlling = MediaPlayerSystemMediaController()
    ) {
        self.systemMediaController = systemMediaController
        installTimeObserver()
        registerSystemMediaCommands()
    }

    var progress: Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }

    var hasPlayableItem: Bool {
        currentItem != nil
    }

    func play(_ request: PlaybackRequest) {
        player.pause()

        resourceAccess = request.resourceAccess
        currentItem = request.item
        elapsed = 0
        duration = 0
        errorMessage = nil

        player.replaceCurrentItem(with: AVPlayerItem(url: request.mediaURL))

        do {
            try configureAudioSession()
            player.play()
            isPlaying = true
            publishNowPlaying()
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
            publishNowPlaying()
        }
    }

    func togglePlayback() {
        guard player.currentItem != nil else { return }

        if isPlaying {
            pausePlayback()
        } else {
            resumePlayback()
        }
    }

    func seek(toProgress progress: Double) {
        guard duration.isFinite, duration > 0 else { return }

        let clampedProgress = min(max(progress, 0), 1)
        seek(toTime: duration * clampedProgress)
    }

    func seek(toTime time: TimeInterval) {
        guard player.currentItem != nil else { return }

        let upperBound = duration.isFinite && duration > 0 ? duration : time
        let target = min(max(time, 0), upperBound)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        elapsed = target
        publishNowPlaying()
    }

    func pausePlayback() {
        guard player.currentItem != nil else { return }

        player.pause()
        isPlaying = false
        publishNowPlaying()
    }

    func resumePlayback() {
        guard player.currentItem != nil else { return }

        if duration > 0, elapsed >= duration {
            player.seek(to: .zero)
            elapsed = 0
        }

        do {
            try configureAudioSession()
            player.play()
            isPlaying = true
            errorMessage = nil
        } catch {
            isPlaying = false
            errorMessage = error.localizedDescription
        }
        publishNowPlaying()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        resourceAccess = nil
        currentItem = nil
        elapsed = 0
        duration = 0
        isPlaying = false
        errorMessage = nil
        systemMediaController.update(.empty)
        deactivateAudioSession()
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.updatePlaybackState(time: time)
            }
        }
    }

    private func updatePlaybackState(time: CMTime) {
        let currentSeconds = time.seconds
        if currentSeconds.isFinite {
            elapsed = max(currentSeconds, 0)
        }

        if let itemDuration = player.currentItem?.duration.seconds,
            itemDuration.isFinite,
            itemDuration > 0
        {
            duration = itemDuration
        }

        if let error = player.currentItem?.error ?? player.error {
            errorMessage = error.localizedDescription
            isPlaying = false
            publishNowPlaying()
            return
        }

        if duration > 0, elapsed >= duration - 0.05 {
            elapsed = duration
            isPlaying = false
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

    isolated deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}
