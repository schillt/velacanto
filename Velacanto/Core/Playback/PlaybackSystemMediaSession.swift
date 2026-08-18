import Combine
import CoreGraphics
import Foundation
import NowPlaying

#if os(iOS)
    import UIKit
    typealias PlatformImage = UIImage
#elseif os(macOS)
    import AppKit
    typealias PlatformImage = NSImage
#endif

struct ResolvedNowPlayingArtwork {
    let identifier: String
    let image: PlatformImage
}

/// The sole bridge from the app's playback coordinator to OS media surfaces.
///
/// `MediaSession` observes this model directly, so a state change replaces the
/// whole content value. That keeps a delayed artwork provider associated with
/// the track that created it instead of allowing it to mutate a newer track.
@MainActor
final class PlaybackSystemMediaSession: ObservableObject,
    MediaSessionRepresentable
{
    let id = "com.chameleonenterprise.velacanto.playback"

    @Published private(set) var content: (any MediaContentRepresentable)?
    @Published private(set) var playbackSnapshot: MediaPlaybackSnapshot?
    @Published private(set) var commands: [MediaCommand] = []

    private let playback: AudioPlaybackCoordinator
    private var observations: Set<AnyCancellable> = []

    lazy var mediaSession = MediaSession(self)

    init(playback: AudioPlaybackCoordinator) {
        self.playback = playback
        observePlayback()
        refresh()
    }

    func activate() {
        _ = mediaSession
        Task { [mediaSession] in
            #if os(iOS)
                try? await mediaSession.requestToBecomeSystemPrimary()
            #else
                try? await mediaSession.requestToBecomeApplicationPrimary()
            #endif
        }
    }

    private func observePlayback() {
        playback.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            .store(in: &observations)
    }

    private func refresh() {
        guard let item = playback.currentItem else {
            content = nil
            playbackSnapshot = nil
            commands = []
            return
        }

        content = MusicContent(
            id: item.id,
            songTitle: item.title,
            artistName: item.artist,
            albumName: item.albumTitle ?? "",
            type: .audio,
            duration: mediaDuration,
            artwork: systemArtwork
        )
        playbackSnapshot = MediaPlaybackSnapshot(
            state: systemPlaybackState,
            elapsedTime: max(playback.elapsed, 0),
            timestamp: .now
        )
        commands = supportedCommands
    }

    private var mediaDuration: MediaDuration? {
        guard playback.duration.isFinite, playback.duration > 0 else {
            return nil
        }
        return .finite(playback.duration)
    }

    private var systemArtwork: Artwork? {
        guard
            let artworkIdentifier = playback.nowPlayingArtworkIdentifier,
            let artwork = playback.nowPlayingArtwork.flatMap(Self.cgImage(from:))
        else {
            return nil
        }
        return Artwork(id: artworkIdentifier) { _ in
            try ArtworkRepresentation(cgImage: artwork)
        }
    }

    private var systemPlaybackState: MediaPlaybackSnapshot.PlaybackState {
        switch playback.playbackState {
        case .playing:
            .playing()
        case .paused, .ended:
            .paused
        case .loading, .waiting:
            .buffering
        case .idle, .failed:
            .stopped
        }
    }

    private var supportedCommands: [MediaCommand] {
        guard playback.hasPlayableItem else { return [] }

        var commands: [MediaCommand] = [
            .play { [weak playback] in
                await MainActor.run { playback?.resumePlayback() }
            },
            .pause { [weak playback] in
                await MainActor.run { playback?.pausePlayback() }
            },
            .togglePlayPause { [weak playback] in
                await MainActor.run { playback?.togglePlayback() }
            },
        ]

        if playback.canGoPrevious {
            commands.append(
                .previous { [weak playback] in
                    await MainActor.run { playback?.previousTrack() }
                })
        }
        if playback.canGoNext {
            commands.append(
                .next { [weak playback] in
                    await MainActor.run { playback?.nextTrack() }
                })
        }
        if playback.duration.isFinite, playback.duration > 0 {
            commands.append(
                .seekToPosition { [weak playback] position in
                    await MainActor.run { playback?.seek(toTime: position) }
                })
        }
        if playback.queue != nil {
            commands.append(
                .changeRepeatMode(
                    current: systemRepeatMode,
                    supported: [.off, .all, .one]
                ) { [weak playback] mode in
                    await MainActor.run {
                        playback?.setRepeatMode(PlaybackRepeatMode(mode))
                    }
                }
            )
            commands.append(
                .changeShuffleMode(current: .off, supported: [.items]) {
                    [weak playback] mode in
                    guard mode == .items else { return }
                    await MainActor.run { playback?.shuffleUpcoming() }
                }
            )
        }
        return commands
    }

    private var systemRepeatMode: MediaCommand.RepeatMode {
        switch playback.repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private static func cgImage(from image: PlatformImage) -> CGImage? {
        #if os(iOS)
            image.cgImage
        #elseif os(macOS)
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #endif
    }
}

extension PlaybackRepeatMode {
    fileprivate init(_ mode: MediaCommand.RepeatMode) {
        switch mode {
        case .off: self = .off
        case .all: self = .all
        case .one: self = .one
        @unknown default: self = .off
        }
    }
}
