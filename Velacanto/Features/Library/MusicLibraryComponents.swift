import SwiftUI

struct MusicQueuePlaybackControls: View {
    let isPreparing: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.bordered)
        }
        .disabled(isPreparing)
        .overlay {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct MusicSongRow: View {
    let song: JellyfinItem
    var leadingNumber: Int?
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let isPreparing: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let leadingNumber {
                Text(leadingNumber.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            } else {
                JellyfinArtworkView(
                    item: song,
                    jellyfin: jellyfin,
                    cornerRadius: 8,
                    maxWidth: 140
                )
                .frame(width: 46, height: 46)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(songSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else if playback.currentItem?.id == song.id {
                Image(
                    systemName: playback.showsPauseControl
                        ? "speaker.wave.2.fill"
                        : "pause.circle"
                )
                .foregroundStyle(.cyan)
            } else if let duration = song.duration {
                Text(PlaybackTimeFormatter.format(seconds: duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "play.circle")
                    .foregroundStyle(.cyan)
            }
        }
        .contentShape(Rectangle())
    }

    private var songSubtitle: String {
        if let album = song.album, !album.isEmpty {
            return "\(song.displayArtist) · \(album)"
        }
        return song.displayArtist
    }
}

struct MusicCatalogErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Music", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
}

struct MusicPaginationErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Retry", action: retry)
        }
        .padding(.vertical, 8)
    }
}
