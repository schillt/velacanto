import SwiftUI

private enum NowPlayingExploreDestination: Identifiable {
    case album(MusicCatalogItem)
    case artist(MusicCatalogItem)

    var id: String {
        switch self {
        case .album(let item): "album-\(item.id.opaqueID)"
        case .artist(let item): "artist-\(item.id.opaqueID)"
        }
    }
}

private struct UnavailableLyricsIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "quote.bubble")
            Rectangle()
                .frame(width: 25, height: 2)
                .rotationEffect(.degrees(-45))
        }
        .accessibilityHidden(true)
    }
}

struct NowPlayingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
        @Environment(\.colorScheme) private var colorScheme
    #endif

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    var dismissAction: (() -> Void)?
    @State private var isShowingQueue = false
    @State private var isShowingLyrics = false
    @State private var isLyricsForegroundVisible = false
    @State private var lyricsState = LyricsLoadState.loading
    @State private var scrubProgress: Double?
    @State private var isScrubbing = false
    @State private var sliderAccent = Color.velacantoAccent
    @State private var exploreDestination: NowPlayingExploreDestination?
    @State private var isQueueArtworkTransitionReady = false
    @State private var isQueueArtworkHandoffComplete = false
    @State private var queueTransitionGeneration = 0
    @State private var lyricsTransitionGeneration = 0

    var body: some View {
        #if os(iOS)
            nowPlayingContent
                .task(id: lyricsLoadIdentity) {
                    await loadLyrics()
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            guard
                                !isShowingQueue,
                                !isShowingLyrics,
                                value.translation.height > 120,
                                abs(value.translation.width) < value.translation.height
                            else {
                                return
                            }
                            closeNowPlaying()
                        }
                )
                .sheet(item: $exploreDestination) { destination in
                    NavigationStack {
                        switch destination {
                        case .album(let album):
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        case .artist(let artist):
                            MusicArtistView(
                                artist: artist,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        }
                    }
                }
        #elseif os(macOS)
            nowPlayingContent
                .task(id: lyricsLoadIdentity) {
                    await loadLyrics()
                }
                .overlay(alignment: .topLeading) {
                    Button(action: closeNowPlaying) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .padding(18)
                    .accessibilityLabel("Close Now Playing")
                }
        #endif
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
            .task(id: sliderAccentIdentity) {
                await updateSliderAccent()
            }
        #else
            playerContent
        #endif
    }

    private var playerContent: some View {
        GeometryReader { geometry in
            #if os(iOS)
                if let item = playback.currentItem,
                    geometry.size.width <= geometry.size.height
                {
                    mobilePortraitPlayerContent(for: item, in: geometry)
                } else {
                    scrollingPlayerContent(in: geometry)
                }
            #else
                scrollingPlayerContent(in: geometry)
            #endif
        }
    }

    #if os(iOS)
        private func mobilePortraitPlayerContent(
            for item: PlaybackItem,
            in geometry: GeometryProxy
        ) -> some View {
            let contentWidth = min(520, max(0, geometry.size.width - 48))
            let artworkSize = portraitArtworkSize(in: geometry.size)

            return VStack(spacing: 16) {
                GeometryReader { transitionSpace in
                    ZStack(alignment: .topLeading) {
                        if isShowingLyrics {
                            lyricsPresentation
                        } else if isShowingQueue {
                            ZStack(alignment: .topLeading) {
                                NowPlayingQueueContent(
                                    playback: playback,
                                    jellyfin: jellyfin,
                                    showsCurrentItemArtwork:
                                        isQueueArtworkHandoffComplete,
                                    onInitialPositioned: queueDidFinishInitialPositioning
                                )

                                if !isQueueArtworkTransitionReady {
                                    nowPlayingArtworkAndDetails(
                                        for: item,
                                        artworkSize: artworkSize,
                                        contentWidth: contentWidth
                                    )
                                }
                            }
                        } else {
                            nowPlayingArtworkAndDetails(
                                for: item,
                                artworkSize: artworkSize,
                                contentWidth: contentWidth
                            )
                        }

                        if !isShowingLyrics,
                            !isShowingQueue || !isQueueArtworkHandoffComplete
                        {
                            sharedQueueArtwork(
                                for: item,
                                sourceSize: artworkSize,
                                containerWidth: transitionSpace.size.width
                            )
                            .zIndex(4)
                        }
                    }
                    .frame(
                        width: transitionSpace.size.width,
                        height: transitionSpace.size.height,
                        alignment: .topLeading
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                playbackDetails(
                    for: item,
                    width: contentWidth,
                    showsTrackDetails: false
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .bottom
            )
            .animation(.smooth(duration: 0.38, extraBounce: 0), value: isShowingQueue)
        }
    #endif

    private func scrollingPlayerContent(in geometry: GeometryProxy) -> some View {
        ScrollView {
            Group {
                if let item = playback.currentItem {
                    #if os(iOS)
                        if geometry.size.width > geometry.size.height {
                            let artworkSize = landscapeArtworkSize(in: geometry.size)
                            HStack(spacing: 28) {
                                Group {
                                    if isShowingLyrics {
                                        lyricsPresentation
                                    } else {
                                        artwork(for: item, size: artworkSize)
                                    }
                                }
                                .frame(width: artworkSize, height: artworkSize)
                                playbackDetails(
                                    for: item,
                                    width: min(360, max(220, geometry.size.width * 0.44)),
                                    showsTrackDetails: !isShowingLyrics
                                )
                            }
                            .frame(maxWidth: 760)
                        } else {
                            let contentWidth = min(
                                520,
                                max(0, geometry.size.width - 48)
                            )
                            VStack(spacing: 24) {
                                artwork(
                                    for: item,
                                    size: portraitArtworkSize(in: geometry.size)
                                )
                                playbackDetails(for: item, width: contentWidth)
                            }
                            .frame(width: contentWidth)
                        }
                    #elseif os(macOS)
                        VStack(spacing: 28) {
                            let artworkSize = macOSArtworkSize(in: geometry.size)
                            Group {
                                if isShowingLyrics {
                                    lyricsPresentation
                                } else {
                                    artwork(for: item, size: artworkSize)
                                }
                            }
                            .frame(width: artworkSize, height: artworkSize)
                            playbackDetails(
                                for: item,
                                width: min(480, geometry.size.width - 80),
                                showsTrackDetails: !isShowingLyrics
                            )
                        }
                        .frame(maxWidth: 620)
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
            .frame(
                width: geometry.size.width,
                alignment: .top
            )
            .frame(minHeight: geometry.size.height, alignment: .top)
        }
    }

    @ViewBuilder
    private func artwork(
        for item: PlaybackItem,
        size: CGFloat
    ) -> some View {
        artworkContent(for: item, size: size)
    }

    #if os(iOS)
        private func sharedQueueArtwork(
            for item: PlaybackItem,
            sourceSize: CGFloat,
            containerWidth: CGFloat
        ) -> some View {
            let isAtQueueRow = isShowingQueue && isQueueArtworkTransitionReady
            let size = isAtQueueRow ? 46.0 : sourceSize
            let horizontalOffset =
                isAtQueueRow
                ? 20.0
                : max(0, (containerWidth - sourceSize) / 2)

            return PlaybackArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 0,
                maxWidth: 1_024
            )
            .frame(width: size, height: size)
            .clipShape(.rect(cornerRadius: isAtQueueRow ? 7 : 18))
            .shadow(
                color: .black.opacity(isAtQueueRow ? 0 : 0.16),
                radius: isAtQueueRow ? 0 : 28,
                y: isAtQueueRow ? 0 : 14
            )
            .offset(
                x: horizontalOffset,
                y: isAtQueueRow ? 4 : 0
            )
            .allowsHitTesting(false)
        }

        private func nowPlayingArtworkAndDetails(
            for item: PlaybackItem,
            artworkSize: CGFloat,
            contentWidth: CGFloat
        ) -> some View {
            VStack(spacing: 16) {
                Color.clear
                    .frame(width: artworkSize, height: artworkSize)
                    .accessibilityHidden(true)
                trackDetails(
                    for: item,
                    width: contentWidth
                )
            }
        }

        private func queueDidFinishInitialPositioning() {
            guard isShowingQueue, !isQueueArtworkTransitionReady else { return }
            let generation = queueTransitionGeneration
            withAnimation(.smooth(duration: 0.34, extraBounce: 0)) {
                isQueueArtworkTransitionReady = true
            }
            Task { @MainActor in
                await Task.yield()
                guard
                    generation == queueTransitionGeneration,
                    isShowingQueue,
                    isQueueArtworkTransitionReady
                else {
                    return
                }
                var handoff = Transaction()
                handoff.disablesAnimations = true
                withTransaction(handoff) {
                    isQueueArtworkHandoffComplete = true
                }
            }
        }

        private func toggleQueueVisibility() {
            if isShowingQueue {
                var handoff = Transaction()
                handoff.disablesAnimations = true
                withTransaction(handoff) {
                    queueTransitionGeneration += 1
                    isQueueArtworkHandoffComplete = false
                }
                Task { @MainActor in
                    await Task.yield()
                    withAnimation(.smooth(duration: 0.38, extraBounce: 0)) {
                        isQueueArtworkTransitionReady = false
                        isShowingQueue = false
                    }
                }
                return
            }

            var preparation = Transaction()
            preparation.disablesAnimations = true
            withTransaction(preparation) {
                queueTransitionGeneration += 1
                isShowingLyrics = false
                isLyricsForegroundVisible = false
                isQueueArtworkTransitionReady = false
                isQueueArtworkHandoffComplete = false
                isShowingQueue = true
            }
        }
    #endif

    private func artworkContent(for item: PlaybackItem, size: CGFloat) -> some View {
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
        width: CGFloat,
        showsTrackDetails: Bool = true
    ) -> some View {
        VStack(spacing: 18) {
            if showsTrackDetails {
                trackDetails(for: item, width: width)
            }

            VStack(spacing: 7) {
                BufferedPlaybackSlider(
                    value: Binding(
                        get: { scrubProgress ?? playback.progress },
                        set: { progress in
                            scrubProgress = progress
                            playback.seek(toProgress: progress)
                        }
                    ),
                    bufferedProgress: playback.bufferedProgress,
                    isEnabled: playback.duration > 0,
                    accent: sliderAccent,
                    onEditingChanged: updateScrubbing
                )
                .frame(maxWidth: .infinity)
                .onChange(of: playback.elapsed) { _, elapsed in
                    clearScrubProgressIfConfirmed(elapsed: elapsed)
                }
                .onChange(of: playback.seekRequestID) { _, _ in
                    if !isScrubbing {
                        scrubProgress = nil
                    }
                }

                HStack {
                    Text(PlaybackTimeFormatter.format(seconds: displayedElapsed))
                    Spacer()
                    Text(PlaybackTimeFormatter.format(seconds: playback.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(playbackSecondaryTextColor)
            }
            .frame(width: width)

            HStack(spacing: 30) {
                Button {
                    playback.previousTrack()
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(playbackPrimaryTextColor)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoPrevious)
                .accessibilityLabel("Previous")

                Button {
                    playback.togglePlayback()
                } label: {
                    if playback.isWaitingForPlayback {
                        ProgressView()
                            .controlSize(.large)
                            .frame(width: 64, height: 64)
                    } else {
                        Image(
                            systemName: playback.showsPauseControl
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.system(size: 42, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 64, height: 64)
                        .contentShape(Circle())
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    playback.isWaitingForPlayback
                        ? "Loading playback"
                        : playback.showsPauseControl ? "Pause" : "Play"
                )

                Button {
                    playback.nextTrack()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(playbackPrimaryTextColor)
                        .frame(width: 56, height: 56)
                        .contentShape(Circle())
                }
                .buttonStyle(.borderless)
                .disabled(!playback.canGoNext)
                .accessibilityLabel("Next")
            }

            #if os(iOS)
                SystemVolumeControl(accentColor: UIColor(sliderAccent))
                    .frame(width: width, height: 44)
                    .accessibilityLabel("Volume")

                HStack {
                    PlaybackRoutePicker()
                        .scaleEffect(1.12)
                        .frame(width: 48, height: 48)
                        .accessibilityLabel("AirPlay")
                    Spacer()
                    lyricsButton
                    Spacer()
                    Button {
                        toggleQueueVisibility()
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 48, height: 48)
                            .contentShape(Circle())
                            .background(
                                isShowingQueue ? playbackPrimaryTextColor.opacity(0.22) : .clear,
                                in: Circle()
                            )
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        isShowingQueue ? "Hide Queue" : "Show Queue"
                    )
                }
                .foregroundStyle(playbackPrimaryTextColor)
                .frame(width: width)
                .overlay(alignment: .bottom) {
                    if let transportKind = playback.transportKind {
                        Text(transportKind.displayName)
                            .font(.caption2)
                            .foregroundStyle(playbackTertiaryTextColor)
                            .frame(width: width, alignment: .center)
                            .offset(y: 22)
                            .allowsHitTesting(false)
                            .accessibilityLabel(
                                "Playback method: \(transportKind.displayName)"
                            )
                    }
                }
            #elseif os(macOS)
                HStack {
                    Spacer()
                    lyricsButton
                    Spacer()
                }
                .foregroundStyle(playbackPrimaryTextColor)
                .frame(width: width)
            #endif

            if let errorMessage = playback.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func trackDetails(
        for item: PlaybackItem,
        width: CGFloat
    ) -> some View {
        trackDetailsContent(for: item, width: width)
    }

    private func trackDetailsContent(
        for item: PlaybackItem,
        width: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                #if os(iOS)
                    NowPlayingTitleMarquee(
                        text: item.title,
                        color: playbackPrimaryTextColor
                    )
                    .frame(height: 31)
                #else
                    Text(item.title)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(playbackPrimaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                #endif
                Text(item.artist)
                    .foregroundStyle(playbackSecondaryTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let albumTitle = item.albumTitle {
                    Text(albumTitle)
                        .font(.callout)
                        .foregroundStyle(playbackTertiaryTextColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let favoriteItemID {
                if hasExploreOptions {
                    Menu {
                        if let albumExploreItem {
                            Button {
                                exploreDestination = .album(albumExploreItem)
                            } label: {
                                Label("View Album", systemImage: "square.stack")
                            }
                        }

                        if let artistExploreItem {
                            Button {
                                exploreDestination = .artist(artistExploreItem)
                            } label: {
                                Label("View Artist", systemImage: "music.mic")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("More playback options")
                }

                MusicFavoriteIDButton(
                    itemID: favoriteItemID,
                    fallback: playback.currentItem?.isFavorite ?? false
                )
                .buttonStyle(.borderless)
                .frame(width: 44, height: 44)
            }
        }
        .frame(width: width, alignment: .leading)
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

    @ViewBuilder
    private var lyricsButton: some View {
        switch lyricsState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(width: 48, height: 48)
                .accessibilityLabel("Loading lyrics")
        case .unavailable:
            UnavailableLyricsIcon()
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Lyrics unavailable")
        case .available:
            Button {
                toggleLyricsPresentation()
            } label: {
                Image(systemName: isShowingLyrics ? "quote.bubble.fill" : "quote.bubble")
                    .font(.system(size: 22, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isShowingLyrics)
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .background(
                        isShowingLyrics ? playbackPrimaryTextColor.opacity(0.22) : .clear,
                        in: Circle()
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isShowingLyrics ? "Hide Lyrics" : "Show Lyrics")
        case .failed:
            Button {
                presentLyrics()
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "quote.bubble")
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 10))
                }
                .font(.system(size: 22, weight: .medium))
                .frame(width: 48, height: 48)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Lyrics could not be loaded")
        }
    }

    private var lyricsPresentation: some View {
        LyricsPresentation(
            playback: playback,
            state: lyricsState,
            primaryColor: playbackPrimaryTextColor,
            secondaryColor: playbackSecondaryTextColor,
            isForegroundVisible: isLyricsForegroundVisible,
            retry: { Task { await loadLyrics() } }
        )
    }

    private var lyricsFailureContent: some View {
        ContentUnavailableView {
            Label("Lyrics Could Not Load", systemImage: "exclamationmark.bubble")
        } description: {
            Text("Check your connection and try again.")
        } actions: {
            Button("Try Again") {
                Task { await loadLyrics() }
            }
        }
        .foregroundStyle(playbackPrimaryTextColor)
    }

    private var lyricsLoadIdentity: String {
        guard let item = playback.currentItem else { return "no-track" }
        return "\(item.source.rawValue)|\(item.id)"
    }

    @MainActor
    private func loadLyrics() async {
        guard let item = playback.currentItem else {
            lyricsState = .unavailable
            dismissLyricsImmediately()
            return
        }

        lyricsState = .loading
        do {
            let lyrics = try await jellyfin.lyrics(for: item)
            guard lyricsLoadIdentity == "\(item.source.rawValue)|\(item.id)" else {
                return
            }
            if let lyrics {
                lyricsState = .available(lyrics)
            } else {
                lyricsState = .unavailable
                dismissLyricsImmediately()
            }
        } catch is CancellationError {
            return
        } catch {
            guard lyricsLoadIdentity == "\(item.source.rawValue)|\(item.id)" else {
                return
            }
            lyricsState = .failed
        }
    }

    private var hasExploreOptions: Bool {
        albumExploreItem != nil || artistExploreItem != nil
    }

    private var albumExploreItem: MusicCatalogItem? {
        guard let currentItem = playback.currentItem,
            let albumID = currentItem.albumID ?? albumContextID,
            let accountScope = playbackAccountScope
        else {
            return nil
        }
        return exploreItem(
            id: albumID,
            name: currentItem.albumTitle ?? "Album",
            kind: .album,
            artistName: currentItem.artist,
            accountScope: accountScope
        )
    }

    private var artistExploreItem: MusicCatalogItem? {
        guard let currentItem = playback.currentItem,
            let artistID = currentItem.artistID ?? artistContextID,
            let accountScope = playbackAccountScope
        else {
            return nil
        }
        return exploreItem(
            id: artistID,
            name: currentItem.artist,
            kind: .artist,
            artistName: currentItem.artist,
            accountScope: accountScope
        )
    }

    private var albumContextID: String? {
        guard let context = playback.queue?.context,
            case .album(let albumID) = context
        else {
            return nil
        }
        return albumID
    }

    private var artistContextID: String? {
        guard let context = playback.queue?.context,
            case .artist(let artistID) = context
        else {
            return nil
        }
        return artistID
    }

    private var playbackAccountScope: String? {
        guard
            playback.currentItem?.source == .jellyfin,
            let session = jellyfin.session
        else {
            return nil
        }
        return "\(session.serverID)|\(session.userID)"
    }

    private func exploreItem(
        id: String,
        name: String,
        kind: MusicCatalogItem.Kind,
        artistName: String,
        accountScope: String
    ) -> MusicCatalogItem {
        MusicCatalogItem(
            id: MusicCatalogItemID(
                source: .jellyfin,
                accountScope: accountScope,
                opaqueID: id
            ),
            name: name,
            kind: kind,
            sortName: nil,
            artists: kind == .album ? [artistName] : [],
            albumArtist: kind == .album ? artistName : nil,
            album: nil,
            trackNumber: nil,
            discNumber: nil,
            childCount: nil,
            duration: nil,
            artwork: nil,
            isFavorite: false,
            capabilities: [.navigate, .play, .shuffle, .favorite]
        )
    }

    private var displayedElapsed: TimeInterval {
        guard let scrubProgress else { return playback.elapsed }
        return playback.duration * scrubProgress
    }

    #if os(iOS)
        private var sliderAccentIdentity: String {
            guard let item = playback.currentItem else { return "no-artwork" }
            return [
                item.id,
                item.artworkItemID ?? "no-artwork",
                item.artworkTag ?? "no-tag",
            ].joined(separator: "|")
        }

        @MainActor
        private func updateSliderAccent() async {
            guard
                let item = playback.currentItem,
                item.source == .jellyfin,
                let artworkItemID = item.artworkItemID,
                let session = jellyfin.session
            else {
                sliderAccent = .velacantoAccent
                return
            }

            let key = ArtworkKey(
                serverID: session.serverID,
                userID: session.userID,
                itemID: artworkItemID,
                imageTag: item.artworkTag ?? "no-tag",
                sizeBucket: ArtworkKey.sizeBucket(for: 128)
            )
            let image = await ArtworkRepository.shared.image(for: key) {
                await jellyfin.artworkRequest(
                    itemID: artworkItemID,
                    imageTag: item.artworkTag,
                    maxWidth: key.sizeBucket
                )
            }
            guard let image, playback.currentItem?.id == item.id else {
                return
            }

            sliderAccent = Color(
                uiColor: ArtworkSliderAccent.color(
                    from: image,
                    colorScheme: colorScheme
                )
            )
        }
    #endif

    private func updateScrubbing(_ isScrubbing: Bool) {
        self.isScrubbing = isScrubbing
        if isScrubbing {
            scrubProgress = playback.progress
        }
    }

    private func clearScrubProgressIfConfirmed(elapsed: TimeInterval) {
        guard
            !isScrubbing,
            let scrubProgress,
            abs(elapsed - (playback.duration * scrubProgress)) <= 0.75
        else {
            return
        }
        self.scrubProgress = nil
    }

    private var itemIsFromJellyfin: Bool {
        playback.currentItem?.source == .jellyfin
    }

    private var playbackPrimaryTextColor: Color {
        #if os(iOS)
            colorScheme == .dark ? .white : .black
        #else
            .primary
        #endif
    }

    private var playbackSecondaryTextColor: Color {
        #if os(iOS)
            playbackPrimaryTextColor.opacity(0.72)
        #else
            .secondary
        #endif
    }

    private var playbackTertiaryTextColor: Color {
        #if os(iOS)
            playbackPrimaryTextColor.opacity(0.5)
        #else
            .secondary.opacity(0.7)
        #endif
    }

    private func portraitArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(
            360,
            max(
                160,
                min(availableSize.width - 48, availableSize.height * 0.38)
            )
        )
    }

    private func landscapeArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(280, max(150, min(availableSize.width * 0.38, availableSize.height - 40)))
    }

    private func macOSArtworkSize(in availableSize: CGSize) -> CGFloat {
        min(460, max(180, min(availableSize.width - 80, availableSize.height * 0.52)))
    }

    private func closeNowPlaying() {
        if let dismissAction {
            dismissAction()
        } else {
            dismiss()
        }
    }

    private func toggleLyricsPresentation() {
        isShowingQueue = false
        lyricsTransitionGeneration += 1
        let transitionGeneration = lyricsTransitionGeneration

        if isShowingLyrics {
            isLyricsForegroundVisible = false

            guard !reduceMotion else {
                isShowingLyrics = false
                return
            }

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard transitionGeneration == lyricsTransitionGeneration else { return }
                isShowingLyrics = false
            }
        } else {
            presentLyrics(transitionGeneration: transitionGeneration)
        }
    }

    private func presentLyrics(transitionGeneration: Int? = nil) {
        isShowingQueue = false
        isShowingLyrics = true

        guard !reduceMotion else {
            isLyricsForegroundVisible = true
            return
        }

        let transitionGeneration = transitionGeneration ?? lyricsTransitionGeneration
        Task { @MainActor in
            await Task.yield()
            guard transitionGeneration == lyricsTransitionGeneration else { return }
            isLyricsForegroundVisible = true
        }
    }

    private func dismissLyricsImmediately() {
        lyricsTransitionGeneration += 1
        isLyricsForegroundVisible = false
        isShowingLyrics = false
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
        .animation(.smooth(duration: 0.28, extraBounce: 0), value: artworkIdentity)
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
