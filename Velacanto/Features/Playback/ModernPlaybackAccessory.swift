import SwiftUI

#if os(iOS)
    @available(iOS 26.0, *)
    struct ModernPlaybackAccessory: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        @ObservedObject var playback: AudioPlaybackCoordinator
        @ObservedObject var jellyfin: JellyfinSessionController
        let showNowPlaying: () -> Void
        var nowPlayingTransitionNamespace: Namespace.ID?

        @ViewBuilder
        var body: some View {
            if let nowPlayingTransitionNamespace {
                accessoryContent.matchedTransitionSource(
                    id: "now-playing-surface",
                    in: nowPlayingTransitionNamespace
                )
            } else {
                accessoryContent
            }
        }

        @ViewBuilder
        private var accessoryContent: some View {
            if placement == .inline {
                inlineAccessory
            } else {
                expandedAccessory
            }
        }

        private var expandedAccessory: some View {
            HStack(spacing: 10) {
                nowPlayingArtwork(size: 34)
                trackMetadata
                playbackButton
                nextButton
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }

        private var inlineAccessory: some View {
            HStack(spacing: 8) {
                nowPlayingArtwork(size: 32)
                trackMetadata
                playbackButton
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }

        @ViewBuilder
        private func nowPlayingArtwork(size: CGFloat) -> some View {
            Button(action: showNowPlaying) {
                if let item = playback.currentItem {
                    PlaybackArtworkView(
                        item: item,
                        jellyfin: jellyfin,
                        cornerRadius: 6,
                        maxWidth: 128
                    )
                    .frame(width: size, height: size)
                }
            }
            .frame(width: 36, height: 36)
            .buttonStyle(.plain)
            .accessibilityLabel("Show Now Playing")
        }

        private var trackMetadata: some View {
            Button(action: showNowPlaying) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.currentItem?.title ?? "Nothing Playing")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(playback.currentItem?.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 6)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now Playing")
            .accessibilityValue(trackAccessibilityValue)
        }

        private var trackAccessibilityValue: String {
            let title = playback.currentItem?.title ?? "Nothing Playing"
            let artist = playback.currentItem?.artist ?? ""
            return artist.isEmpty ? title : "\(title), \(artist)"
        }

        private var playbackButton: some View {
            Button {
                playback.togglePlayback()
            } label: {
                if playback.isWaitingForPlayback {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 36, height: 36)
                } else {
                    Image(
                        systemName: playback.showsPauseControl
                            ? "pause.fill" : "play.fill"
                    )
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                playback.isWaitingForPlayback
                    ? "Loading playback"
                    : playback.showsPauseControl ? "Pause" : "Play"
            )
        }

        private var nextButton: some View {
            Button {
                playback.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!playback.canGoNext)
            .accessibilityLabel("Next")
        }
    }

#endif

#if os(iOS)
    struct NowPlayingTitleMarquee: View {
        let text: String
        let color: Color

        var body: some View {
            Text(text)
                .font(.title2.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(text)
        }
    }
#endif
