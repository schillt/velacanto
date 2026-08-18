import SwiftUI

enum PlaybackAccessoryAppearance {
    case embedded
    case floating
}

struct PlaybackAccessory: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    var appearance = PlaybackAccessoryAppearance.floating
    let showNowPlaying: () -> Void
    var showQueue: (() -> Void)?

    var body: some View {
        #if os(macOS)
            macOSAccessory
        #else
            iOSAccessory
        #endif
    }

    #if os(iOS)
        private var iOSAccessory: some View {
            HStack(spacing: 10) {
                Button(action: showNowPlaying) {
                    HStack(spacing: 10) {
                        if let item = playback.currentItem {
                            PlaybackArtworkView(
                                item: item,
                                jellyfin: jellyfin,
                                cornerRadius: 7,
                                maxWidth: 180
                            )
                            .frame(width: 44, height: 44)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(playback.currentItem?.title ?? "Nothing Playing")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(playback.currentItem?.artist ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    playback.togglePlayback()
                } label: {
                    Image(
                        systemName: playback.showsPauseControl
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    playback.showsPauseControl ? "Pause" : "Play"
                )

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
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .modifier(PlaybackAccessorySurface(appearance: appearance))
        }
    #endif

    #if os(macOS)
        private var macOSAccessory: some View {
            VStack(spacing: 5) {
                HStack(spacing: 14) {
                    HStack(spacing: 4) {
                        transportButton("backward.fill", label: "Previous") {
                            playback.previousTrack()
                        }
                        .disabled(!playback.canGoPrevious)

                        transportButton(
                            playback.showsPauseControl ? "pause.fill" : "play.fill",
                            label: playback.showsPauseControl ? "Pause" : "Play"
                        ) {
                            playback.togglePlayback()
                        }

                        transportButton("forward.fill", label: "Next") {
                            playback.nextTrack()
                        }
                        .disabled(!playback.canGoNext)
                    }

                    Button(action: showNowPlaying) {
                        if let item = playback.currentItem {
                            PlaybackArtworkView(
                                item: item,
                                jellyfin: jellyfin,
                                cornerRadius: 6,
                                maxWidth: 128
                            )
                            .frame(width: 34, height: 34)
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: showNowPlaying) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(playback.currentItem?.title ?? "Nothing Playing")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Text(playback.currentItem?.artist ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(minWidth: 180, maxWidth: 360, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 12)

                    if let favoriteItemID {
                        MusicFavoriteIDButton(itemID: favoriteItemID)
                            .buttonStyle(.borderless)
                            .frame(width: 28, height: 28)
                    }

                    Button(action: showQueue ?? showNowPlaying) {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Show Up Next")

                    PlaybackRoutePicker()
                        .frame(width: 28, height: 28)

                }

                PlaybackProgressBar(playback: playback)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .modifier(PlaybackAccessorySurface(appearance: appearance))
        }

        private var favoriteItemID: MusicCatalogItemID? {
            guard
                playback.currentItem?.source == .jellyfin,
                let item = playback.currentItem,
                let session = jellyfin.session
            else {
                return nil
            }
            return MusicCatalogItemID(
                source: .jellyfin,
                accountScope: "\(session.serverID)|\(session.userID)",
                opaqueID: item.id
            )
        }

        private func transportButton(
            _ symbolName: String,
            label: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: symbolName)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    #endif
}

#if os(macOS)
    extension View {
        func macOSPlaybackAccessoryInset(
            playback: AudioPlaybackCoordinator,
            jellyfin: JellyfinSessionController,
            isVisible: Bool,
            showNowPlaying: @escaping () -> Void,
            showQueue: @escaping () -> Void
        ) -> some View {
            safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    PlaybackAccessory(
                        playback: playback,
                        jellyfin: jellyfin,
                        appearance: .floating,
                        showNowPlaying: showNowPlaying,
                        showQueue: showQueue
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
#endif

private struct PlaybackProgressBar: View {
    @ObservedObject var playback: AudioPlaybackCoordinator

    var body: some View {
        ProgressView(value: playback.progress)
            .progressViewStyle(.linear)
            .tint(.secondary.opacity(0.7))
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                PlaybackTimeFormatter.format(seconds: playback.elapsed)
            )
    }
}

private struct PlaybackAccessorySurface: ViewModifier {
    let appearance: PlaybackAccessoryAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .embedded:
            content
        case .floating:
            content.glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: 20)
            )
        }
    }
}
