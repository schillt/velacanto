import Foundation
import MediaPlayer

struct NowPlayingSnapshot: Equatable {
    let item: PlaybackItem?
    let elapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool

    static let empty = NowPlayingSnapshot(
        item: nil,
        elapsed: 0,
        duration: 0,
        isPlaying: false
    )
}

@MainActor
protocol SystemMediaControlling: AnyObject {
    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (TimeInterval) -> Void
    )

    func update(_ snapshot: NowPlayingSnapshot)
}

@MainActor
final class MediaPlayerSystemMediaController: SystemMediaControlling {
    private let commandCenter: MPRemoteCommandCenter
    private let nowPlayingInfoCenter: MPNowPlayingInfoCenter
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var commandsAreEnabled: Bool?

    init(
        commandCenter: MPRemoteCommandCenter = .shared(),
        nowPlayingInfoCenter: MPNowPlayingInfoCenter = .default()
    ) {
        self.commandCenter = commandCenter
        self.nowPlayingInfoCenter = nowPlayingInfoCenter
        setCommandsEnabled(false)
    }

    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        stop: @escaping @MainActor () -> Void,
        togglePlayPause: @escaping @MainActor () -> Void,
        seek: @escaping @MainActor (TimeInterval) -> Void
    ) {
        removeCommandTargets()

        addTarget(to: commandCenter.playCommand) {
            Task { @MainActor in play() }
        }
        addTarget(to: commandCenter.pauseCommand) {
            Task { @MainActor in pause() }
        }
        addTarget(to: commandCenter.stopCommand) {
            Task { @MainActor in stop() }
        }
        addTarget(to: commandCenter.togglePlayPauseCommand) {
            Task { @MainActor in togglePlayPause() }
        }

        let positionCommand = commandCenter.changePlaybackPositionCommand
        let positionTarget = positionCommand.addTarget { event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            let position = positionEvent.positionTime
            Task { @MainActor in seek(position) }
            return .success
        }
        commandTargets.append((positionCommand, positionTarget))
    }

    func update(_ snapshot: NowPlayingSnapshot) {
        guard let item = snapshot.item else {
            nowPlayingInfoCenter.nowPlayingInfo = nil
            setCommandsEnabled(false)
            #if os(macOS)
                nowPlayingInfoCenter.playbackState = .stopped
            #endif
            return
        }

        nowPlayingInfoCenter.nowPlayingInfo = Self.makeNowPlayingInfo(
            snapshot: snapshot,
            item: item
        )
        setCommandsEnabled(true)

        #if os(macOS)
            nowPlayingInfoCenter.playbackState = snapshot.isPlaying ? .playing : .paused
        #endif
    }

    static func makeNowPlayingInfo(
        snapshot: NowPlayingSnapshot,
        item: PlaybackItem
    ) -> [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.artist,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(snapshot.elapsed, 0),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
        ]

        if snapshot.duration.isFinite, snapshot.duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = snapshot.duration
        }

        if let albumTitle = item.albumTitle, !albumTitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }

        return info
    }

    private func addTarget(
        to command: MPRemoteCommand,
        action: @escaping @Sendable () -> Void
    ) {
        let target = command.addTarget { _ in
            action()
            return .success
        }
        commandTargets.append((command, target))
    }

    private func setCommandsEnabled(_ isEnabled: Bool) {
        guard commandsAreEnabled != isEnabled else { return }
        commandsAreEnabled = isEnabled

        commandCenter.playCommand.isEnabled = isEnabled
        commandCenter.pauseCommand.isEnabled = isEnabled
        commandCenter.stopCommand.isEnabled = isEnabled
        commandCenter.togglePlayPauseCommand.isEnabled = isEnabled
        commandCenter.changePlaybackPositionCommand.isEnabled = isEnabled

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }

    private func removeCommandTargets() {
        for target in commandTargets {
            target.command.removeTarget(target.target)
        }
        commandTargets.removeAll()
    }

    isolated deinit {
        removeCommandTargets()
    }
}
