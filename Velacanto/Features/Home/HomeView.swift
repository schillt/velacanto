import SwiftUI

struct HomeView: View {
    enum Presentation: Equatable {
        case home
        case new

        var title: String {
            switch self {
            case .home: "Home"
            case .new: "New"
            }
        }
    }

    @EnvironmentObject private var favoriteActions: MusicItemActionStateOwner
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let playRecentItem: (PlaybackItem) -> Void
    let showProfile: () -> Void
    let showNowPlaying: () -> Void
    var presentation = Presentation.home

    @StateObject private var favorites = PagedMusicCatalogModel()
    @StateObject private var recentlyAdded = PagedMusicCatalogModel()
    @StateObject private var recentlyAddedTracks = PagedMusicCatalogModel()
    @State private var homeGenres: [MusicGenre] = []
    @State private var isLoadingHomeGenres = false
    @State private var preparingCatalogItemID: MusicCatalogItemID?
    @State private var catalogPlaybackError: String?
    @State private var selectedGenre: MusicGenre?
    @State private var isRootHeaderVisible = true
    @State private var genreShelfScrollAnchor: MusicCatalogItemID?
    @StateObject private var favoritesScrollPosition =
        CatalogScrollPositionState<MusicCatalogItemID>()
    @StateObject private var recentlyAddedScrollPosition =
        CatalogScrollPositionState<MusicCatalogItemID>()
    @Namespace private var albumTransitionNamespace

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if presentation == .home {
                    continueListening

                    if !playback.recentItems.isEmpty {
                        recentlyPlayed
                    }
                }

                if jellyfin.isSignedIn {
                    if presentation == .new {
                        recentlyAddedTracksShelf
                    }

                    if presentation == .home {
                        catalogShelf(
                            title: "Favorites",
                            model: favorites,
                            scrollPosition: favoritesScrollPosition,
                            identity: homeShelfIdentity("favorites"),
                            retry: loadFavorites
                        )
                    }

                    catalogShelf(
                        title: "Recently Added",
                        model: recentlyAdded,
                        scrollPosition: recentlyAddedScrollPosition,
                        identity: homeShelfIdentity("recently-added"),
                        retry: loadRecentlyAdded
                    )

                    if presentation == .home {
                        HomeGenreShelves(
                            genres: homeGenres,
                            isLoading: isLoadingHomeGenres,
                            playback: playback,
                            jellyfin: jellyfin,
                            selectGenre: { selectedGenre = $0 }
                        )
                    } else if !recentGenreIDs.isEmpty || !recentGenreNames.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Genres with Recently Added Music")
                                .font(.title2.weight(.semibold))
                            MusicGenreGrid(
                                jellyfin: jellyfin,
                                selectGenre: { selectedGenre = $0 },
                                presentation: .carousel,
                                filterIDs: recentGenreIDs,
                                filterNames: recentGenreNames
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .scrollTargetLayout()
        }
        .scrollPosition(id: $genreShelfScrollAnchor)
        .revealsRootHeader($isRootHeaderVisible)
        .progressiveNavigationChrome()
        .navigationTitle(presentation.title)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationDestination(item: $selectedGenre) { genre in
            MusicGenreCollectionView(
                genre: genre,
                playback: playback,
                jellyfin: jellyfin
            )
        }
        #if os(iOS)
            .toolbar {
                if isRootHeaderVisible {
                    // Occupy the native title position so the progressive
                    // header does not render beside the semantic title.
                    ToolbarItem(placement: .principal) {
                        Text(presentation.title)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: showProfile) {
                            AccountAvatar(jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Profile and settings")
                    }
                }
            }
        #endif
        .task(id: jellyfin.playbackAccount) {
            guard jellyfin.isSignedIn else {
                await clearProviderShelves()
                return
            }
            async let favoriteLoad: Void = loadFavorites()
            async let recentLoad: Void = loadRecentlyAdded()
            async let recentTracksLoad: Void = loadRecentlyAddedTracks()
            async let genreLoad: Void = loadHomeGenres()
            _ = await (favoriteLoad, recentLoad, recentTracksLoad, genreLoad)
        }
        .alert(
            "Couldn’t Play Music",
            isPresented: Binding(
                get: { catalogPlaybackError != nil },
                set: { if !$0 { catalogPlaybackError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                catalogPlaybackError = nil
            }
        } message: {
            Text(catalogPlaybackError ?? "An unknown playback error occurred.")
        }
    }

    @ViewBuilder
    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow("Continue Listening")

            if let item = playback.currentItem {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(item: item, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .frame(minWidth: 260, maxWidth: 600)

                        NowPlayingSummary(playback: playback, showsTransportButton: true)
                            .frame(minWidth: 230, idealWidth: 290)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        Button(action: showNowPlaying) {
                            HomePlaybackArtwork(item: item, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)

                        NowPlayingSummary(playback: playback, showsTransportButton: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 18) {
                        Image(systemName: "waveform")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(Color.velacantoAccent)
                            .frame(width: 58, height: 58)
                            .background(
                                Color.velacantoAccent.opacity(0.12),
                                in: .rect(cornerRadius: 16)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your music, ready when you are")
                                .font(.title3.weight(.semibold))
                            Text(emptyStateDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Open Audio File", systemImage: "folder") { openLocalFile() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Color.secondary.opacity(0.07), in: .rect(cornerRadius: 22))
            }
        }
    }

    private var recentlyPlayed: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played").font(.title2.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(playback.recentItems.prefix(8)) { item in
                        RecentItemCard(
                            item: item,
                            jellyfin: jellyfin,
                            canReplay: item.source == .jellyfin && jellyfin.isSignedIn,
                            action: { playRecentItem(item) }
                        )
                    }
                }
                .padding(.leading, 20)
            }
            .carouselToDeviceEdges()
        }
    }

    private var recentGenreIDs: Set<String> {
        Set(recentlyAdded.items.flatMap(\.genreIDs))
    }

    private var recentGenreNames: Set<String> {
        Set(recentlyAdded.items.flatMap(\.genres).map { $0.lowercased() })
    }

    @ViewBuilder
    private var recentlyAddedTracksShelf: some View {
        let tracks = Array(recentlyAddedTracks.items.prefix(24))

        if recentlyAddedTracks.isInitialLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Tracks").font(.title2.weight(.semibold))
                ProgressView("Loading new tracks…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        } else if !tracks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Tracks").font(.title2.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: [GridItem(.fixed(64)), GridItem(.fixed(64))],
                        spacing: 12
                    ) {
                        ForEach(tracks) { track in
                            recentlyAddedTrack(track, shelfTracks: tracks)
                        }
                    }
                    .padding(.leading, 20)
                }
                .frame(height: 140)
                .carouselToDeviceEdges()

                if let errorMessage = recentlyAddedTracks.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task { await loadRecentlyAddedTracks() }
                    }
                }
            }
        } else if let errorMessage = recentlyAddedTracks.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Tracks").font(.title2.weight(.semibold))
                MusicPaginationErrorView(message: errorMessage) {
                    Task { await loadRecentlyAddedTracks() }
                }
            }
        }
    }

    private func recentlyAddedTrack(
        _ track: MusicCatalogItem,
        shelfTracks: [MusicCatalogItem]
    ) -> some View {
        Button {
            play(track, shelfItems: shelfTracks)
        } label: {
            NewTrackGridCard(track: track, jellyfin: jellyfin)
        }
        .buttonStyle(.plain)
        .disabled(preparingCatalogItemID != nil)
        .accessibilityHint("Plays this song")
        .musicItemActions(for: track, jellyfin: jellyfin, playback: playback)
    }

    @ViewBuilder
    private func catalogShelf(
        title: String,
        model: PagedMusicCatalogModel,
        scrollPosition: CatalogScrollPositionState<MusicCatalogItemID>,
        identity: String,
        retry: @escaping @MainActor () async -> Void
    ) -> some View {
        let visibleItems =
            title == "Favorites"
            ? model.items.filter { favoriteActions.isFavorite($0) }
            : model.items
        let cappedItems =
            title == "Recently Added"
            ? Array(visibleItems.prefix(24))
            : visibleItems

        if model.isInitialLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                ProgressView("Loading \(title.lowercased())…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        } else if !cappedItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(cappedItems) { item in
                            catalogItem(item, shelfItems: cappedItems)
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, 20)
                }
                .scrollPosition(id: scrollPosition.binding(identity: identity), anchor: .leading)
                .carouselToDeviceEdges()

                if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task { await retry() }
                    }
                }
            }
        } else if let errorMessage = model.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                MusicPaginationErrorView(message: errorMessage) {
                    Task { await retry() }
                }
            }
        }
    }

    @ViewBuilder
    private func catalogItem(
        _ item: MusicCatalogItem,
        shelfItems: [MusicCatalogItem]
    ) -> some View {
        if item.kind == .song {
            Button {
                play(item, shelfItems: shelfItems)
            } label: {
                catalogCard(
                    item,
                    isPreparing: preparingCatalogItemID == item.id
                )
            }
            .buttonStyle(.plain)
            .disabled(preparingCatalogItemID != nil)
            .accessibilityHint("Plays this song")
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                catalogCard(item)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(item.name)")
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        }
    }

    @ViewBuilder
    private func catalogCard(
        _ item: MusicCatalogItem,
        isPreparing: Bool = false
    ) -> some View {
        if presentation == .new {
            MusicAlbumCard(
                album: item,
                jellyfin: jellyfin,
                transitionNamespace: item.kind == .album || item.kind == .playlist
                    ? albumTransitionNamespace
                    : nil
            )
            .frame(width: 154)
        } else {
            HomeCatalogCard(
                item: item,
                jellyfin: jellyfin,
                isPreparing: isPreparing,
                transitionNamespace: item.kind == .album || item.kind == .playlist
                    ? albumTransitionNamespace
                    : nil
            )
        }
    }

    @ViewBuilder
    private func destination(for item: MusicCatalogItem) -> some View {
        switch item.kind {
        case .album:
            JellyfinTracksView(
                album: item,
                jellyfin: jellyfin,
                playback: playback,
                transitionNamespace: albumTransitionNamespace
            )
        case .artist:
            MusicArtistView(
                artist: item,
                jellyfin: jellyfin,
                playback: playback
            )
        case .playlist:
            MusicPlaylistView(
                playlist: item,
                jellyfin: jellyfin,
                playback: playback,
                transitionNamespace: albumTransitionNamespace
            )
        case .song:
            EmptyView()
        }
    }

    private func loadFavorites() async {
        _ = favoritesScrollPosition.begin(
            identity: homeShelfIdentity("favorites"),
            forceReset: true
        )
        await favorites.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(kind: .favorites)
            },
            loader: { cursor in
                try await jellyfin.homeFavoritesPage(cursor: cursor)
            },
            cacheWriter: { items in
                await jellyfin.cacheCatalogItems(items, kind: .favorites)
            }
        )
    }

    private func loadRecentlyAdded() async {
        _ = recentlyAddedScrollPosition.begin(
            identity: homeShelfIdentity("recently-added"),
            forceReset: true
        )
        await recentlyAdded.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(kind: .recentlyAdded)
            },
            loader: { cursor in
                try await jellyfin.homeRecentlyAddedPage(cursor: cursor, limit: 24)
            },
            cacheWriter: { items in
                await jellyfin.cacheCatalogItems(items, kind: .recentlyAdded)
            }
        )
    }

    private func loadRecentlyAddedTracks() async {
        await recentlyAddedTracks.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(kind: .recentlyAddedTracks)
            },
            loader: { cursor in
                try await jellyfin.homeRecentlyAddedTracksPage(cursor: cursor, limit: 24)
            },
            cacheWriter: { items in
                await jellyfin.cacheCatalogItems(items, kind: .recentlyAddedTracks)
            }
        )
    }

    private func loadHomeGenres() async {
        let cachedAll = await jellyfin.cachedMusicGenres()
        if !cachedAll.isEmpty {
            homeGenres = rankedHomeGenres(cachedAll)
        }

        isLoadingHomeGenres = homeGenres.isEmpty
        let available = (try? await jellyfin.musicGenres(forceRefresh: true)) ?? cachedAll
        guard jellyfin.isSignedIn else {
            homeGenres = []
            isLoadingHomeGenres = false
            return
        }
        homeGenres = rankedHomeGenres(available)
        isLoadingHomeGenres = false
    }

    private func rankedHomeGenres(_ genres: [MusicGenre]) -> [MusicGenre] {
        Array(
            genres
                .sorted {
                    if $0.albumCount != $1.albumCount {
                        return $0.albumCount > $1.albumCount
                    }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .prefix(5)
        )
    }

    private func clearProviderShelves() async {
        let emptyLoader: PagedMusicCatalogModel.Loader = { _ in
            MusicCatalogPage(items: [], totalRecordCount: 0, cursor: nil)
        }
        await favorites.reset(loader: emptyLoader)
        await recentlyAdded.reset(loader: emptyLoader)
        await recentlyAddedTracks.reset(loader: emptyLoader)
        homeGenres = []
        isLoadingHomeGenres = false
    }

    private func homeShelfIdentity(_ shelf: String) -> String {
        "\(presentation.title)|\(jellyfin.playbackAccount?.serverID ?? "signed-out")|\(jellyfin.playbackAccount?.userID ?? "none")|\(shelf)"
    }

    private func play(
        _ song: MusicCatalogItem,
        shelfItems: [MusicCatalogItem]
    ) {
        guard song.capabilities.contains(.play) else { return }
        preparingCatalogItemID = song.id
        catalogPlaybackError = nil
        Task {
            defer { preparingCatalogItemID = nil }
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                let songs = shelfItems.filter { $0.kind == .song }
                playback.play(
                    request,
                    queueItems: songs.map(JellyfinPlaybackAdapter.playbackItem(for:)),
                    context: .single,
                    account: jellyfin.playbackAccount
                )
            } catch {
                catalogPlaybackError = error.localizedDescription
            }
        }
    }

    private var emptyStateDescription: String {
        jellyfin.isSignedIn
            ? "Choose music from your library or open a local audio file."
            : "Open a local audio file, or add a music server from your profile."
    }
}

private struct HomeCatalogCard: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var isPreparing = false
    var transitionNamespace: Namespace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 14,
                maxWidth: 360
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(width: 142)
            .albumArtworkTransitionSource(
                id: item.artworkTransitionID,
                in: transitionNamespace
            )
            .overlay {
                if isPreparing {
                    ProgressView()
                        .padding(10)
                        .background(.regularMaterial, in: Circle())
                }
            }

            Text(item.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 142, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch item.kind {
        case .song, .album:
            item.displayArtist
        case .artist:
            "Artist"
        case .playlist:
            item.childCount.map { "\($0) \($0 == 1 ? "song" : "songs")" }
                ?? "Playlist"
        }
    }
}

struct SourceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.medium))
            .foregroundStyle(Color.velacantoAccent)
            .frame(width: 34, height: 34)
            .background(
                Color.velacantoAccent.opacity(0.10),
                in: .rect(cornerRadius: 10)
            )
    }
}

private struct SectionEyebrow: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(Color.velacantoAccent)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct HomeGenreShelves: View {
    let genres: [MusicGenre]
    let isLoading: Bool
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    let selectGenre: (MusicGenre) -> Void

    var body: some View {
        Group {
            if genres.isEmpty, isLoading {
                HomeGenreShelfPlaceholder()
            } else {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(genres) { genre in
                        HomeGenreAlbumShelf(
                            genre: genre,
                            playback: playback,
                            jellyfin: jellyfin,
                            showAll: { selectGenre(genre) }
                        )
                        .id(genre.id)
                    }
                }
            }
        }
    }
}

private struct HomeGenreAlbumShelf: View {
    let genre: MusicGenre
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    let showAll: () -> Void

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var scrollPosition = CatalogScrollPositionState<MusicCatalogItemID>()

    private var albums: [MusicCatalogItem] {
        Array(model.items.filter { $0.kind == .album }.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: showAll) {
                HStack(spacing: 7) {
                    Text(genre.name)
                        .font(.title2.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all \(genre.name) albums")

            if model.isInitialLoading {
                ProgressView("Loading \(genre.name.lowercased())…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 20)
            } else if !albums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink {
                                JellyfinTracksView(
                                    album: album,
                                    jellyfin: jellyfin,
                                    playback: playback
                                )
                            } label: {
                                MusicAlbumCard(album: album, jellyfin: jellyfin)
                                    .frame(width: 154)
                            }
                            .buttonStyle(.plain)
                            .musicItemActions(
                                for: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                            .id(album.id)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.leading, 20)
                }
                .scrollPosition(
                    id: scrollPosition.binding(identity: shelfIdentity),
                    anchor: .leading
                )
                .carouselToDeviceEdges()
            } else if let errorMessage = model.errorMessage {
                MusicPaginationErrorView(message: errorMessage) {
                    Task { await model.retry(loader: pageLoader) }
                }
            }
        }
        .task(id: genre.id) {
            _ = scrollPosition.begin(identity: shelfIdentity, forceReset: true)
            await model.reset(
                cachedItems: {
                    await jellyfin.cachedCatalogItems(kind: .genreItems, contextID: genre.id)
                },
                loader: pageLoader,
                cacheWriter: cacheWriter
            )
        }
    }

    private var shelfIdentity: String {
        "\(jellyfin.playbackAccount?.serverID ?? "signed-out")|\(jellyfin.playbackAccount?.userID ?? "none")|\(genre.id.opaqueID)"
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.genreItemsPage(in: genre, cursor: cursor, limit: 8)
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .genreItems, contextID: genre.id)
        }
    }
}

private struct HomeGenreShelfPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Genres")
                .font(.title2.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(.quaternary)
                                .frame(width: 154, height: 154)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                                .frame(width: 112, height: 14)
                        }
                    }
                }
                .padding(.leading, 20)
            }
            .carouselToDeviceEdges()
        }
        .redacted(reason: .placeholder)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading genres")
    }
}

private struct NowPlayingSummary: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    let showsTransportButton: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(playback.currentItem?.title ?? "Nothing Playing").font(.title2.weight(.semibold))
                .lineLimit(2)
            Text(playback.currentItem?.artist ?? "").foregroundStyle(.secondary).lineLimit(1)
            if let albumTitle = playback.currentItem?.albumTitle {
                Text(albumTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView(value: playback.progress)
                .tint(.velacantoAccent)
                .padding(.top, 5)
            HStack {
                Text(PlaybackTimeFormatter.format(seconds: playback.elapsed))
                Spacer()
                Text(PlaybackTimeFormatter.format(seconds: playback.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if showsTransportButton {
                Button {
                    playback.togglePlayback()
                } label: {
                    Label(
                        playback.showsPauseControl ? "Pause" : "Play",
                        systemImage: playback.showsPauseControl ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
            }
        }
        .multilineTextAlignment(.leading)
    }
}

private struct NewTrackGridCard: View {
    let track: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        HStack(spacing: 10) {
            JellyfinArtworkView(
                item: track,
                jellyfin: jellyfin,
                cornerRadius: 10,
                maxWidth: 140
            )
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(trackSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(width: 250, height: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var trackSubtitle: String {
        guard let album = track.album, !album.isEmpty else {
            return track.displayArtist
        }
        return "\(track.displayArtist) · \(album)"
    }
}

private struct RecentItemCard: View {
    let item: PlaybackItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let canReplay: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                PlaybackArtworkView(item: item, jellyfin: jellyfin).frame(width: 142, height: 142)
                Text(item.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(
                    1)
                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 142, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canReplay)
        .opacity(canReplay || item.source == .localFiles ? 1 : 0.65)
        .accessibilityHint(
            canReplay ? "Plays this item again" : "Open this item again from its source to play it")
    }
}
