import AVKit
import SwiftUI

#if os(iOS)
    import MediaPlayer
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum PlaybackAccessoryAppearance {
    case embedded
    case floating
}

struct PlaybackAccessory: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    var appearance = PlaybackAccessoryAppearance.floating
    let showNowPlaying: () -> Void
    var dismiss: (() -> Void)?

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

                    Button(action: showNowPlaying) {
                        Image(systemName: "list.bullet")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Show Up Next")

                    PlaybackRoutePicker()
                        .frame(width: 28, height: 28)

                    if let dismiss {
                        Button(action: dismiss) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 28, height: 28)
                        .accessibilityLabel("Hide mini player")
                    }
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
            dismiss: @escaping () -> Void
        ) -> some View {
            safeAreaInset(edge: .bottom, spacing: 0) {
                if isVisible {
                    PlaybackAccessory(
                        playback: playback,
                        jellyfin: jellyfin,
                        appearance: .floating,
                        showNowPlaying: showNowPlaying,
                        dismiss: dismiss
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

struct PlaybackRoutePicker: View {
    var body: some View {
        #if os(iOS)
            IOSRoutePicker()
        #elseif os(macOS)
            MacOSRoutePicker()
        #endif
    }
}

#if os(iOS)
    private struct IOSRoutePicker: UIViewRepresentable {
        func makeUIView(context: Context) -> AVRoutePickerView {
            let picker = AVRoutePickerView()
            picker.activeTintColor = .systemPink
            picker.tintColor = .secondaryLabel
            return picker
        }

        func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
    }

    private struct SystemVolumeControl: UIViewRepresentable {
        func makeUIView(context: Context) -> MPVolumeView {
            let volumeView = MPVolumeView()
            volumeView.showsVolumeSlider = true
            return volumeView
        }

        func updateUIView(_ uiView: MPVolumeView, context: Context) {}
    }
#elseif os(macOS)
    private struct MacOSRoutePicker: NSViewRepresentable {
        func makeNSView(context: Context) -> AVRoutePickerView {
            AVRoutePickerView()
        }

        func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
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
            content.glassEffect(
                .regular.interactive(),
                in: .rect(cornerRadius: 20)
            )
        }
    }
}

#if os(iOS)
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
            ZStack {
                if let item = playback.currentItem {
                    NowPlayingArtworkGradient(
                        item: item,
                        jellyfin: jellyfin,
                        colorScheme: colorScheme
                    )
                } else {
                    Color(uiColor: .systemBackground)
                }
                playerContent
            }
            .ignoresSafeArea(edges: .bottom)
        #else
            playerContent
        #endif
    }

    private var playerContent: some View {
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
                            description: Text("Choose music from your library to begin.")
                        )
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
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
                    .frame(height: 34)
                    .accessibilityLabel("Volume")

                HStack {
                    PlaybackRoutePicker()
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("AirPlay")
                    Spacer()
                    Image(systemName: "quote.bubble")
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Lyrics unavailable")
                        .accessibilityAddTraits(.isStaticText)
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

private struct UpNextRow: View {
    let item: PlaybackItem
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                Text(item.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .accessibilityLabel("Move Earlier")
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            .accessibilityLabel("Move Later")
            Button(role: .destructive, action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove from Up Next")
        }
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
                        .clear,
                        colorScheme == .dark ? .black : .white,
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
        }
    }
#endif
