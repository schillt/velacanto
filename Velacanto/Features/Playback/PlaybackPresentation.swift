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

    var body: some View {
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(PlaybackAccessorySurface(appearance: appearance))
    }
}

#if os(macOS)
    enum PlaybackAccessoryOwnerPreferenceKey: PreferenceKey {
        static let defaultValue = false

        static func reduce(value: inout Bool, nextValue: () -> Bool) {
            value = value || nextValue()
        }
    }

    extension View {
        func macOSPlaybackAccessoryInset(
            playback: AudioPlaybackCoordinator,
            jellyfin: JellyfinSessionController,
            isVisible: Bool,
            showNowPlaying: @escaping () -> Void
        ) -> some View {
            safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    PlaybackAccessory(
                        playback: playback,
                        jellyfin: jellyfin,
                        appearance: .floating,
                        showNowPlaying: showNowPlaying
                    )
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }
#endif

private struct PlaybackAccessorySurface: ViewModifier {
    let appearance: PlaybackAccessoryAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .embedded:
            content
        case .floating:
            if #available(iOS 26.0, macOS 26.0, *) {
                content.glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 20)
                )
            } else {
                content
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(.separator.opacity(0.42), lineWidth: 0.5)
                    }
            }
        }
    }
}

#if os(iOS)
    @available(iOS 26.0, *)
    struct ModernPlaybackAccessory: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        @ObservedObject var playback: AudioPlaybackCoordinator
        @ObservedObject var jellyfin: JellyfinSessionController
        let showNowPlaying: () -> Void

        var body: some View {
            PlaybackAccessory(
                playback: playback,
                jellyfin: jellyfin,
                appearance: .embedded,
                showNowPlaying: showNowPlaying
            )
            .padding(.horizontal, placement == .inline ? 0 : 6)
        }
    }
#endif

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if let item = playback.currentItem {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 32) {
                                    artwork(
                                        for: item,
                                        size: horizontalArtworkSize(in: geometry.size)
                                    )

                                    playbackDetails(for: item)
                                        .frame(minWidth: 260, maxWidth: 420)
                                }
                                .frame(maxWidth: 760)

                                VStack(spacing: 24) {
                                    artwork(
                                        for: item,
                                        size: verticalArtworkSize(in: geometry.size)
                                    )

                                    playbackDetails(for: item)
                                        .frame(maxWidth: 520)
                                }
                            }
                        } else {
                            ContentUnavailableView(
                                "Nothing Playing",
                                systemImage: "music.note",
                                description: Text(
                                    "Choose music from your library to begin."
                                )
                            )
                        }
                    }
                    .padding(24)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: geometry.size.height
                    )
                }
            }
            .navigationTitle("Now Playing")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func artwork(for item: PlaybackItem, size: CGFloat) -> some View {
        NowPlayingArtwork(
            item: item,
            jellyfin: jellyfin
        )
        .aspectRatio(1, contentMode: .fill)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: 28, y: 14)
    }

    private func playbackDetails(for item: PlaybackItem) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 5) {
                Text(item.title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(item.artist)
                    .foregroundStyle(.secondary)
                if let albumTitle = item.albumTitle {
                    Text(albumTitle)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }

            if item.source == .jellyfin, let session = jellyfin.session {
                MusicFavoriteIDButton(
                    itemID: MusicCatalogItemID(
                        source: .jellyfin,
                        accountScope: "\(session.serverID)|\(session.userID)",
                        opaqueID: item.id
                    )
                )
                .buttonStyle(.bordered)
            }

            VStack(spacing: 7) {
                Slider(
                    value: Binding(
                        get: { playback.progress },
                        set: { playback.seek(toProgress: $0) }
                    ),
                    in: 0...1
                )
                .disabled(playback.duration <= 0)
                .accessibilityLabel("Playback position")

                HStack {
                    Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                    Spacer()
                    Text(PlaybackTimeFormatter.format(seconds: playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 38) {
                Button {
                    playback.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoPrevious)
                .accessibilityLabel("Previous")

                Button {
                    playback.togglePlayback()
                } label: {
                    Image(
                        systemName: playback.showsPauseControl
                            ? "pause.circle.fill"
                            : "play.circle.fill"
                    )
                    .font(.system(size: 64))
                    .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    playback.showsPauseControl ? "Pause" : "Play"
                )

                Button {
                    playback.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoNext)
                .accessibilityLabel("Next")
            }

            if let errorMessage = playback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func verticalArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(
            440,
            max(
                160,
                min(availableSize.width - 48, availableSize.height * 0.48)
            )
        )
    }

    private func horizontalArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(280, max(140, availableSize.height - 48))
    }
}

private struct NowPlayingArtwork: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        PlaybackArtworkView(
            item: item,
            jellyfin: jellyfin,
            maxWidth: 1_024
        )
        .id(artworkIdentity)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: artworkIdentity)
    }

    private var artworkIdentity: String {
        [
            item.id,
            item.artworkItemID ?? "no-artwork",
            item.artworkTag ?? "no-tag",
            "1024",
        ].joined(separator: "|")
    }
}
