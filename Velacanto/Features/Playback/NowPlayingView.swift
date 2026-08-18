import SwiftUI

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
        @Environment(\.colorScheme) private var colorScheme
    #endif

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    @State private var isShowingQueue = false

    var body: some View {
        NavigationStack {
            nowPlayingContent
                .navigationTitle("Now Playing")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                #if os(iOS)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                dismiss()
                            }
                        }
                    }
                #endif
        }
    }

    @ViewBuilder
    private var nowPlayingContent: some View {
        #if os(iOS)
            GeometryReader { geometry in
                playerContent
                    .frame(
                        width: geometry.size.width,
                        height: geometry.size.height
                    )
                    .background {
                        Group {
                            if let item = playback.currentItem {
                                NowPlayingArtworkGradient(
                                    item: item,
                                    jellyfin: jellyfin,
                                    colorScheme: colorScheme
                                )
                            } else {
                                Color(uiColor: .systemBackground)
                            }
                        }
                        .ignoresSafeArea()
                    }
            }
        #else
            playerContent
        #endif
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            ScrollView {
                Group {
                    if let item = playback.currentItem {
                        #if os(iOS)
                            if geometry.size.width > geometry.size.height {
                                landscapePlayer(for: item, in: geometry.size)
                            } else {
                                portraitPlayer(for: item, in: geometry.size)
                            }
                        #else
                            macOSPlayer(for: item, in: geometry.size)
                        #endif
                    } else {
                        ContentUnavailableView(
                            "Nothing Playing",
                            systemImage: "music.note",
                            description: Text("Choose music from your library to begin.")
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(width: geometry.size.width)
                .frame(minHeight: geometry.size.height)
            }
        }
    }

    #if os(iOS)
        private func portraitPlayer(
            for item: PlaybackItem,
            in availableSize: CGSize
        ) -> some View {
            let width = min(520, max(0, availableSize.width - 48))
            return VStack(spacing: 18) {
                artwork(
                    for: item,
                    size: verticalArtworkSize(in: availableSize)
                )
                playbackDetails(for: item, width: width)
            }
            .frame(width: width)
        }

        private func landscapePlayer(
            for item: PlaybackItem,
            in availableSize: CGSize
        ) -> some View {
            let artworkSize = horizontalArtworkSize(in: availableSize)
            let detailsWidth = min(
                420,
                max(208, availableSize.width - artworkSize - 80)
            )
            return HStack(spacing: 32) {
                artwork(for: item, size: artworkSize)
                playbackDetails(for: item, width: detailsWidth)
            }
            .frame(maxWidth: 760)
        }
    #else
        private func macOSPlayer(
            for item: PlaybackItem,
            in availableSize: CGSize
        ) -> some View {
            let width = min(520, max(300, availableSize.width - 80))
            return VStack(spacing: 24) {
                artwork(
                    for: item,
                    size: verticalArtworkSize(in: availableSize)
                )
                playbackDetails(for: item, width: width)
            }
            .frame(width: width)
        }
    #endif

    private func artwork(for item: PlaybackItem, size: CGFloat) -> some View {
        NowPlayingArtwork(
            item: item,
            jellyfin: jellyfin
        )
        .aspectRatio(1, contentMode: .fill)
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.16), radius: 28, y: 14)
    }

    private func playbackDetails(
        for item: PlaybackItem,
        width: CGFloat
    ) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    if let favoriteItemID {
                        MusicFavoriteIDButton(itemID: favoriteItemID)
                            .buttonStyle(.borderless)
                            .frame(width: 44, height: 44)
                    }
                }
                Text(item.artist)
                    .foregroundStyle(.secondary)
                if let albumTitle = item.albumTitle {
                    Text(albumTitle)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                if let transportKind = playback.transportKind {
                    Text(transportKind.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            "Playback method: \(transportKind.displayName)"
                        )
                }
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
                .accessibilityLabel(playback.showsPauseControl ? "Pause" : "Play")

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

            HStack(spacing: 22) {
                Button {
                    playback.shuffleUpcoming()
                } label: {
                    Label("Shuffle Up Next", systemImage: "shuffle")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .disabled(playback.upcomingItems.count < 2)
                .accessibilityLabel("Shuffle Up Next")

                Button {
                    playback.cycleRepeatMode()
                } label: {
                    Label(
                        repeatAccessibilityLabel,
                        systemImage: playback.repeatMode == .one
                            ? "repeat.1" : "repeat"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(
                    playback.repeatMode == .off
                        ? Color.secondary : Color.cyan
                )
                .accessibilityLabel(repeatAccessibilityLabel)
            }

            #if os(iOS)
                SystemVolumeControl()
                    .frame(width: width, height: 34)
                    .accessibilityLabel("Volume")

                HStack {
                    PlaybackRoutePicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                    Spacer()
                    LyricsUnavailableControl()
                    Spacer()
                    Button {
                        isShowingQueue.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        isShowingQueue ? "Hide Up Next" : "Show Up Next"
                    )
                }
            #endif

            if shouldShowQueue, !playback.upcomingItems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Up Next")
                        .font(.headline)

                    ForEach(
                        Array(playback.upcomingItems.enumerated()),
                        id: \.element.id
                    ) { index, queuedItem in
                        UpNextRow(
                            item: queuedItem,
                            canMoveUp: index > 0,
                            canMoveDown: index < playback.upcomingItems.count - 1,
                            moveUp: {
                                playback.moveUpcomingItem(
                                    from: index,
                                    to: index - 1
                                )
                            },
                            moveDown: {
                                playback.moveUpcomingItem(
                                    from: index,
                                    to: index + 1
                                )
                            },
                            remove: {
                                playback.removeUpcomingItem(queuedItem)
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let errorMessage = playback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(width: width)
    }

    private var repeatAccessibilityLabel: String {
        switch playback.repeatMode {
        case .off: "Repeat Off"
        case .all: "Repeat All"
        case .one: "Repeat One"
        }
    }

    private var favoriteItemID: MusicCatalogItemID? {
        guard
            itemIsFromJellyfin,
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

    private var itemIsFromJellyfin: Bool {
        playback.currentItem?.source == .jellyfin
    }

    private var shouldShowQueue: Bool {
        #if os(iOS)
            isShowingQueue
        #else
            true
        #endif
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

#if os(iOS)
    private struct NowPlayingArtworkGradient: View {
        let item: PlaybackItem
        @ObservedObject var jellyfin: JellyfinSessionController
        let colorScheme: ColorScheme

        var body: some View {
            ZStack {
                Color(uiColor: .systemBackground)

                PlaybackArtworkView(
                    item: item,
                    jellyfin: jellyfin,
                    maxWidth: 1_024
                )
                .scaleEffect(1.5)
                .blur(radius: 72)
                .opacity(0.62)

                LinearGradient(
                    colors: [
                        Color(uiColor: .systemBackground).opacity(0.08),
                        colorScheme == .dark ? .black : .white,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .accessibilityHidden(true)
        }
    }
#endif
