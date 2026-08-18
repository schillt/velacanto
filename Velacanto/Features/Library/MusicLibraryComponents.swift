import SwiftUI

enum MusicArtworkGridLayout {
    static let minimumWidth: CGFloat = 138
    static let maximumWidth: CGFloat = 210
    static let horizontalSpacing: CGFloat = 18
    static let verticalSpacing: CGFloat = 24

    static var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: minimumWidth, maximum: maximumWidth),
                spacing: horizontalSpacing,
                alignment: .top
            )
        ]
    }
}

enum MusicGenreCardLayout {
    static let carouselWidth: CGFloat = 172
    static let carouselHeight: CGFloat = 84
    static let collectionMinimumWidth: CGFloat = 126
    static let collectionMaximumWidth: CGFloat = 170
    static let spacing: CGFloat = 10
    static let cornerRadius: CGFloat = 14

    static var aspectRatio: CGFloat {
        carouselWidth / carouselHeight
    }
}

private struct DeviceEdgeCarouselModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, -20)
    }
}

extension View {
    /// Lets a carousel escape a main-content inset while its section header stays aligned.
    func carouselToDeviceEdges() -> some View {
        modifier(DeviceEdgeCarouselModifier())
    }
}

struct MusicGenreGrid: View {
    enum Presentation {
        case carousel
        case collection
    }

    @ObservedObject var jellyfin: JellyfinSessionController
    let selectGenre: (MusicGenre) -> Void
    var presentation = Presentation.collection
    var filterIDs: Set<String>?
    var filterNames: Set<String>?
    var limit: Int?

    @State private var genres: [MusicGenre] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var carouselScrollAnchor: MusicCatalogItemID?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else if let errorMessage, genres.isEmpty {
                MusicCatalogErrorView(message: errorMessage) {
                    Task { await loadGenres() }
                }
            } else {
                grid
            }
        }
        .task(id: jellyfin.playbackAccount) {
            await loadGenres()
        }
    }

    @ViewBuilder
    private var grid: some View {
        if presentation == .carousel {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(displayedGenres) { genre in
                        Button {
                            selectGenre(genre)
                        } label: {
                            GenreTile(genre: genre, jellyfin: jellyfin)
                                .frame(
                                    width: MusicGenreCardLayout.carouselWidth,
                                    height: MusicGenreCardLayout.carouselHeight
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Browse \(genre.name)")
                        .id(genre.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.leading, 20)
            }
            .scrollPosition(id: $carouselScrollAnchor, anchor: .leading)
            .carouselToDeviceEdges()
        } else {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(
                            minimum: MusicGenreCardLayout.collectionMinimumWidth,
                            maximum: MusicGenreCardLayout.collectionMaximumWidth
                        ),
                        spacing: MusicGenreCardLayout.spacing
                    )
                ],
                alignment: .leading,
                spacing: MusicGenreCardLayout.spacing
            ) {
                genreTiles(displayedGenres)
            }
            .scrollTargetLayout()
        }
    }

    private var displayedGenres: [MusicGenre] {
        var result = genres.filter { genre in
            let idMatches = filterIDs?.contains(genre.id.opaqueID) ?? false
            let nameMatches = filterNames?.contains(genre.name.lowercased()) ?? false
            return filterIDs == nil && filterNames == nil || idMatches || nameMatches
        }
        if presentation == .carousel {
            result.sort {
                if $0.albumCount != $1.albumCount { return $0.albumCount > $1.albumCount }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        if let limit { result = Array(result.prefix(limit)) }
        return result
    }

    @ViewBuilder
    private func genreTiles(_ genres: [MusicGenre]) -> some View {
        ForEach(genres) { genre in
            Button {
                selectGenre(genre)
            } label: {
                GenreTile(genre: genre, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Browse \(genre.name) albums")
            .id(genre.id)
        }
    }

    private func loadGenres() async {
        guard jellyfin.isSignedIn else {
            genres = []
            errorMessage = nil
            isLoading = false
            return
        }
        isLoading = true
        let cached = await jellyfin.cachedMusicGenres()
        if !cached.isEmpty {
            genres = cached
            isLoading = false
            preloadLikelyGenreAlbums(from: genres)
        }
        do {
            genres = try await jellyfin.musicGenres(forceRefresh: true)
            errorMessage = nil
            preloadLikelyGenreAlbums(from: genres)
        } catch {
            genres = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func preloadLikelyGenreAlbums(from genres: [MusicGenre]) {
        let likelyDestinations = Array(
            genres.sorted {
                if $0.albumCount != $1.albumCount {
                    return $0.albumCount > $1.albumCount
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(6)
        )
        Task {
            await jellyfin.preloadGenreAlbums(for: likelyDestinations)
        }
    }
}

struct GenreTile: View {
    let genre: MusicGenre
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        // Establish the landscape card before laying artwork over it. Remote artwork
        // is naturally square, so letting it participate in the parent layout would
        // make collection tiles square as well.
        Color.clear
            .aspectRatio(MusicGenreCardLayout.aspectRatio, contentMode: .fit)
            .overlay { artworkBackground }
            .overlay { genreHueOverlay }
            .overlay(alignment: .bottomLeading) { titleOverlay }
            .clipShape(.rect(cornerRadius: MusicGenreCardLayout.cornerRadius))
            .contentShape(.rect(cornerRadius: MusicGenreCardLayout.cornerRadius))
    }

    @ViewBuilder
    private var artworkBackground: some View {
        if let artwork = genre.artwork {
            JellyfinArtworkView(
                item: MusicCatalogItem(
                    id: genre.id,
                    name: genre.name,
                    kind: .album,
                    sortName: nil,
                    artists: [],
                    albumArtist: nil,
                    album: nil,
                    trackNumber: nil,
                    discNumber: nil,
                    childCount: genre.albumCount,
                    duration: nil,
                    artwork: artwork,
                    isFavorite: false,
                    capabilities: [.navigate]
                ),
                jellyfin: jellyfin,
                cornerRadius: MusicGenreCardLayout.cornerRadius,
                maxWidth: 360
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LinearGradient(
                colors: [palette.0, palette.1],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var genreHueOverlay: LinearGradient {
        LinearGradient(
            colors: [
                palette.0.opacity(0.88),
                palette.1.opacity(0.76),
                .black.opacity(0.28),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var titleOverlay: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: symbolName)
                .font(.caption.weight(.bold))
            Text(genre.name)
                .font(.subheadline.weight(.bold))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
        .padding(10)
    }

    private var palette: (Color, Color) {
        let palette: [(Color, Color)] = [
            (.indigo, .purple),
            (.teal, .cyan),
            (.purple, .indigo),
            (.orange, .red),
            (.blue, .indigo),
            (.pink, .purple),
        ]
        let seed = genre.name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return palette[Int(seed.magnitude % UInt(palette.count))]
    }

    private var symbolName: String {
        let name = genre.name.lowercased()
        if name.contains("classical") { return "music.quarternote.3" }
        if name.contains("jazz") || name.contains("blues") { return "saxophone" }
        if name.contains("electronic") || name.contains("dance") { return "waveform" }
        if name.contains("rock") || name.contains("metal") { return "guitars" }
        if name.contains("country") || name.contains("folk") { return "guitars.fill" }
        return "music.note"
    }
}

struct MusicGenreCollectionView: View {
    let genre: MusicGenre
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @StateObject private var model = PagedMusicCatalogModel()

    private var albums: [MusicCatalogItem] {
        model.items.filter { $0.kind == .album }
    }

    var body: some View {
        ScrollView {
            if model.isInitialLoading {
                ProgressView("Loading \(genre.name)…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                MusicCatalogErrorView(message: errorMessage) {
                    Task { await retry() }
                }
            } else if albums.isEmpty {
                ContentUnavailableView(
                    "No \(genre.name) Music",
                    systemImage: "music.note",
                    description: Text("This genre has no available music in your Jellyfin library.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: MusicArtworkGridLayout.columns,
                    alignment: .leading,
                    spacing: MusicArtworkGridLayout.verticalSpacing
                ) {
                    ForEach(albums) { album in
                        NavigationLink {
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            MusicAlbumCard(album: album, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .musicItemActions(for: album, jellyfin: jellyfin, playback: playback)
                        .onAppear { loadMoreIfNeeded(album.id) }
                    }
                }
                .padding(20)

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task { await retry() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .progressivePageHeader(genre.name)
        .task(id: genre.id) {
            await model.reset(
                cachedItems: {
                    await jellyfin.cachedCatalogItems(kind: .genreItems, contextID: genre.id)
                },
                loader: pageLoader,
                cacheWriter: cacheWriter
            )
        }
        .refreshable {
            await model.reset(
                cachedItems: {
                    await jellyfin.cachedCatalogItems(kind: .genreItems, contextID: genre.id)
                },
                loader: pageLoader,
                cacheWriter: cacheWriter
            )
        }
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.genreItemsPage(in: genre, cursor: cursor)
        }
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .genreItems, contextID: genre.id)
        }
    }

}

struct MusicQueuePlaybackControls: View {
    let capabilities: MusicItemCapabilities
    let isPreparing: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
            }

            VStack(spacing: 10) {
                actionButtons
            }
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

    @ViewBuilder
    private var actionButtons: some View {
        if capabilities.contains(.play) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }

        if capabilities.contains(.shuffle) {
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct MusicSongRow: View {
    let song: MusicCatalogItem
    var leadingNumber: Int?
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let isPreparing: Bool
    var foreground: Color?
    var secondaryForeground: Color?

    var body: some View {
        HStack(spacing: 12) {
            if let leadingNumber {
                Text(leadingNumber.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryForeground ?? .secondary)
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
                    .foregroundStyle(foreground ?? .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(songSubtitle)
                    .font(.caption)
                    .foregroundStyle(secondaryForeground ?? .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            } else if playback.currentItem?.id == song.id.opaqueID {
                Image(
                    systemName: playback.showsPauseControl
                        ? "speaker.wave.2.fill"
                        : "pause.circle"
                )
                .foregroundStyle(Color.velacantoAccent)
            } else if let duration = song.duration {
                Text(PlaybackTimeFormatter.format(seconds: duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryForeground ?? .secondary)
            } else {
                Image(systemName: "play.circle")
                    .foregroundStyle(Color.velacantoAccent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            MusicFavoriteButton(item: song)

            Divider()

            if song.capabilities.contains(.playNext) {
                Button {
                    playback.playNext(
                        JellyfinPlaybackAdapter.playbackItem(for: song)
                    )
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }

            if song.capabilities.contains(.playLast) {
                Button {
                    playback.playLast(
                        JellyfinPlaybackAdapter.playbackItem(for: song)
                    )
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }

            Divider()

            NavigationLink {
                MusicSongDetailView(
                    song: song,
                    jellyfin: jellyfin,
                    playback: playback
                )
            } label: {
                Label("Go to Song", systemImage: "music.note")
            }

            if let album = song.albumNavigationItem {
                NavigationLink {
                    JellyfinTracksView(
                        album: album,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            if let artist = song.artistNavigationItem {
                NavigationLink {
                    MusicArtistView(
                        artist: artist,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                } label: {
                    Label("Go to Artist", systemImage: "music.mic")
                }
            }
        }
    }

    private var songSubtitle: String {
        if let album = song.album, !album.isEmpty {
            return "\(song.displayArtist) · \(album)"
        }
        return song.displayArtist
    }
}

private struct MusicSongDetailView: View {
    let song: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MusicDetailHeader(
                    item: song,
                    jellyfin: jellyfin,
                    subtitle: song.displayArtist,
                    detail: song.album
                )

                Button("Play", systemImage: "play.fill") {
                    play()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)

                if let errorMessage {
                    ErrorMessageView(message: errorMessage)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .progressivePageHeader(song.name)
    }

    private func play() {
        isPreparing = true
        errorMessage = nil
        Task {
            defer { isPreparing = false }
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    context: .single,
                    account: jellyfin.playbackAccount
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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

private struct MusicCatalogItemActionsModifier: ViewModifier {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .contextMenu { actionMenu }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if item.capabilities.contains(.favorite) {
                        MusicFavoriteButton(item: item, presentation: .icon)
                            .tint(.pink)
                    }
                }
        #else
            content.contextMenu { actionMenu }
        #endif
    }

    @ViewBuilder
    private var actionMenu: some View {
        if item.capabilities.contains(.favorite) {
            MusicFavoriteButton(item: item)
        }

        if item.capabilities.contains(.playNext) {
            Button {
                playback.playNext(JellyfinPlaybackAdapter.playbackItem(for: item))
            } label: {
                Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .disabled(playback.currentItem == nil)
        }

        if item.capabilities.contains(.playLast) {
            Button {
                playback.playLast(JellyfinPlaybackAdapter.playbackItem(for: item))
            } label: {
                Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
            }
            .disabled(playback.currentItem == nil)
        }

        switch item.kind {
        case .album:
            NavigationLink {
                JellyfinTracksView(album: item, jellyfin: jellyfin, playback: playback)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }
        case .artist:
            NavigationLink {
                MusicArtistView(artist: item, jellyfin: jellyfin, playback: playback)
            } label: {
                Label("View Artist", systemImage: "music.mic")
            }
        case .song:
            if let album = item.albumNavigationItem {
                NavigationLink {
                    JellyfinTracksView(album: album, jellyfin: jellyfin, playback: playback)
                } label: {
                    Label("View Album", systemImage: "square.stack")
                }
            }
            if let artist = item.artistNavigationItem {
                NavigationLink {
                    MusicArtistView(artist: artist, jellyfin: jellyfin, playback: playback)
                } label: {
                    Label("View Artist", systemImage: "music.mic")
                }
            }
        case .playlist:
            EmptyView()
        }
    }
}

extension View {
    func musicItemActions(
        for item: MusicCatalogItem,
        jellyfin: JellyfinSessionController,
        playback: AudioPlaybackCoordinator
    ) -> some View {
        modifier(
            MusicCatalogItemActionsModifier(
                item: item,
                jellyfin: jellyfin,
                playback: playback
            )
        )
    }

    @ViewBuilder
    func progressivePageHeader(_ title: String?) -> some View {
        #if os(iOS)
            navigationTitle(title ?? "")
                .navigationBarTitleDisplayMode(.large)
        #else
            navigationTitle(title ?? "")
        #endif
    }

    func collectionDetailNavigationChrome() -> some View {
        scrollContentBackground(.hidden)
    }

    func revealsRootHeader(_ isVisible: Binding<Bool>) -> some View {
        self
    }

    func progressiveNavigationChrome() -> some View {
        self
    }
}
