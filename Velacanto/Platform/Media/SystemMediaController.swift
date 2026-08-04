import Foundation
import MediaPlayer

#if os(iOS)
    import UIKit
    typealias PlatformImage = UIImage
#elseif os(macOS)
    import AppKit
    typealias PlatformImage = NSImage
#endif

struct NowPlayingSnapshot: Equatable {
    let item: PlaybackItem?
    let elapsed: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    let artworkIdentifier: String?
    let artwork: PlatformImage?
    let canGoPrevious: Bool
    let canGoNext: Bool

    init(
        item: PlaybackItem?,
        elapsed: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool,
        artworkIdentifier: String? = nil,
        artwork: PlatformImage? = nil,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false
    ) {
        self.item = item
        self.elapsed = elapsed
        self.duration = duration
        self.isPlaying = isPlaying
        self.artworkIdentifier = artworkIdentifier
        self.artwork = artwork
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item
            && lhs.elapsed == rhs.elapsed
            && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying
            && lhs.artworkIdentifier == rhs.artworkIdentifier
            && lhs.canGoPrevious == rhs.canGoPrevious
            && lhs.canGoNext == rhs.canGoNext
    }

    static let empty = NowPlayingSnapshot(
        item: nil,
        elapsed: 0,
        duration: 0,
        isPlaying: false
    )
}

struct ResolvedNowPlayingArtwork {
    let identifier: String
    let image: PlatformImage
}

@MainActor
protocol SystemMediaControlling: AnyObject {
    func registerCommands(
        play: @escaping @MainActor () -> Void,
        pause: @escaping @MainActor () -> Void,
        previous: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
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
        previous: @escaping @MainActor () -> Void,
        next: @escaping @MainActor () -> Void,
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
        addTarget(to: commandCenter.previousTrackCommand) {
            Task { @MainActor in previous() }
        }
        addTarget(to: commandCenter.nextTrackCommand) {
            Task { @MainActor in next() }
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
        setCommandsEnabled(
            true,
            canGoPrevious: snapshot.canGoPrevious,
            canGoNext: snapshot.canGoNext
        )

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

        if let image = snapshot.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { @Sendable _ in
                image
            }
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

    private func setCommandsEnabled(
        _ isEnabled: Bool,
        canGoPrevious: Bool = false,
        canGoNext: Bool = false
    ) {
        guard
            commandsAreEnabled != isEnabled
                || commandCenter.previousTrackCommand.isEnabled != canGoPrevious
                || commandCenter.nextTrackCommand.isEnabled != canGoNext
        else {
            return
        }
        commandsAreEnabled = isEnabled

        commandCenter.playCommand.isEnabled = isEnabled
        commandCenter.pauseCommand.isEnabled = isEnabled
        commandCenter.stopCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = isEnabled
        commandCenter.changePlaybackPositionCommand.isEnabled = isEnabled

        commandCenter.nextTrackCommand.isEnabled = isEnabled && canGoNext
        commandCenter.previousTrackCommand.isEnabled = isEnabled && canGoPrevious
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
