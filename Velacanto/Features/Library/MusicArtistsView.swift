import SwiftUI

struct MusicArtistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var scrollPosition = CatalogScrollPositionState<MusicCatalogItemID>()
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading artists…")
                    .frame(maxWidth: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ErrorMessageView(message: errorMessage)
                Button("Retry") {
                    Task {
                        await retry()
                    }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No Artists",
                    systemImage: "music.mic",
                    description: Text(
                        "Jellyfin did not return any artists from your music libraries."
                    )
                )
            } else {
                ForEach(model.items) { artist in
                    NavigationLink {
                        MusicArtistView(
                            artist: artist,
                            jellyfin: jellyfin,
                            playback: playback
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: artist,
                                jellyfin: jellyfin,
                                cornerRadius: 28,
                                maxWidth: 180
                            )
                            .frame(width: 54, height: 54)
                            .clipShape(Circle())

                            Text(artist.name)
                                .font(.body.weight(.medium))
                        }
                    }
                    .musicItemActions(for: artist, jellyfin: jellyfin, playback: playback)
                    .id(artist.id)
                    .onAppear {
                        loadMoreIfNeeded(artist.id)
                    }
                }

                if model.isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                }
            }
        }
        .scrollPosition(id: scrollPosition.binding(identity: taskID))
        .progressivePageHeader("Artists")
        #if !os(macOS)
            .searchable(text: $searchText, prompt: "Artists")
        #endif
        .task(id: taskID) {
            guard scrollPosition.begin(identity: taskID) else { return }
            await reset()
        }
        .refreshable {
            _ = scrollPosition.begin(identity: taskID, forceReset: true)
            await reset()
        }
    }

    private var taskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    private func reset() async {
        await model.reset(
            debounce: query.isEmpty ? nil : .milliseconds(250),
            cachedItems: query.isEmpty
                ? {
                    await jellyfin.cachedCatalogItems(kind: .artists)
                }
                : nil,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private func retry() async {
        await model.retry(
            loader: pageLoader,
            cacheWriter: query.isEmpty ? cacheWriter : nil
        )
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.musicArtistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .artists)
        }
    }
}

struct MusicArtistView: View {
    private static let songShelfLimit = 24

    let artist: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var songsModel = PagedMusicCatalogModel()
    @State private var isPreparingQueue = false
    @State private var preparingSongID: MusicCatalogItemID?
    @State private var playbackErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(spacing: 14) {
                    JellyfinArtworkView(
                        item: artist,
                        jellyfin: jellyfin,
                        cornerRadius: 90,
                        maxWidth: 420
                    )
                    .frame(width: 172, height: 172)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

                    Text(artist.name)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                MusicQueuePlaybackControls(
                    capabilities: artist.capabilities,
                    isPreparing: isPreparingQueue,
                    play: { playQueue(shuffled: false) },
                    shuffle: { playQueue(shuffled: true) }
                )

                if let playbackErrorMessage {
                    ErrorMessageView(message: playbackErrorMessage)
                }

                songShelf

                if model.isInitialLoading {
                    ProgressView("Loading albums…")
                        .frame(maxWidth: .infinity)
                } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                    MusicCatalogErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "No Albums",
                        systemImage: "square.stack",
                        description: Text(
                            "No albums are currently associated with this artist."
                        )
                    )
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Albums")
                            .font(.title2.weight(.semibold))

                        LazyVGrid(
                            columns: MusicArtworkGridLayout.columns,
                            alignment: .leading,
                            spacing: MusicArtworkGridLayout.verticalSpacing
                        ) {
                            ForEach(model.items) { album in
                                NavigationLink {
                                    JellyfinTracksView(
                                        album: album,
                                        jellyfin: jellyfin,
                                        playback: playback
                                    )
                                } label: {
                                    MusicAlbumCard(
                                        album: album,
                                        jellyfin: jellyfin
                                    )
                                }
                                .buttonStyle(.plain)
                                .musicItemActions(
                                    for: album,
                                    jellyfin: jellyfin,
                                    playback: playback
                                )
                                .onAppear {
                                    loadMoreIfNeeded(album.id)
                                }
                            }
                        }

                        if model.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else if let errorMessage = model.errorMessage {
                            MusicPaginationErrorView(message: errorMessage) {
                                Task {
                                    await retry()
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .progressivePageHeader(artist.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                MusicFavoriteButton(item: artist, presentation: .icon)
                MusicLibraryPinMenu(item: artist)
            }
        }
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.id) {
            await reset()
        }
        .refreshable {
            await reset()
        }
    }

    private func reset() async {
        await songsModel.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .artistTracks,
                    contextID: artist.id
                )
            },
            loader: songShelfPageLoader,
            cacheWriter: songShelfCacheWriter
        )
        await model.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .albums,
                    contextID: artist.id
                )
            },
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                artist: artist
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .albums,
                contextID: artist.id
            )
        }
    }

    @ViewBuilder
    private var songShelf: some View {
        let songs = Array(songsModel.items.prefix(Self.songShelfLimit))
        let rows = Array(
            repeating: GridItem(.fixed(64)),
            count: min(songs.count, 2)
        )

        if songsModel.isInitialLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text("Songs")
                    .font(.title2.weight(.semibold))
                ProgressView("Loading songs…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        } else if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Songs")
                    .font(.title2.weight(.semibold))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(
                        rows: rows,
                        spacing: 12
                    ) {
                        ForEach(songs) { song in
                            Button {
                                play(song, shelfSongs: songs)
                            } label: {
                                MusicSongRow(
                                    song: song,
                                    jellyfin: jellyfin,
                                    playback: playback,
                                    isPreparing: preparingSongID == song.id
                                )
                                .frame(width: 270, height: 64)
                            }
                            .buttonStyle(.plain)
                            .disabled(preparingSongID != nil)
                            .accessibilityHint("Plays this song")
                        }
                    }
                    .padding(.leading, 20)
                }
                .frame(height: songs.count == 1 ? 64 : 140)
                .carouselToDeviceEdges()

                if let errorMessage = songsModel.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retrySongs()
                        }
                    }
                }
            }
        } else if let errorMessage = songsModel.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text("Songs")
                    .font(.title2.weight(.semibold))
                MusicCatalogErrorView(message: errorMessage) {
                    Task {
                        await retrySongs()
                    }
                }
            }
        }
    }

    private var songShelfPageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.musicSongsPage(
                cursor: cursor,
                limit: Self.songShelfLimit,
                artist: artist
            )
        }
    }

    private var songShelfCacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                Array(items.prefix(Self.songShelfLimit)),
                kind: .artistTracks,
                contextID: artist.id
            )
        }
    }

    private func retrySongs() async {
        await songsModel.retry(
            loader: songShelfPageLoader,
            cacheWriter: songShelfCacheWriter
        )
    }

    private func play(
        _ song: MusicCatalogItem,
        shelfSongs: [MusicCatalogItem]
    ) {
        guard song.capabilities.contains(.play) else { return }
        preparingSongID = song.id
        playbackErrorMessage = nil
        Task {
            defer { preparingSongID = nil }
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    queueItems: shelfSongs.map(JellyfinPlaybackAdapter.playbackItem(for:)),
                    context: .artist(id: artist.id.opaqueID),
                    account: jellyfin.playbackAccount
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
        }
    }

    private func playQueue(shuffled: Bool) {
        isPreparingQueue = true
        playbackErrorMessage = nil
        Task {
            do {
                let tracks = try await artistTracks()
                let queue = shuffled ? tracks.shuffled() : tracks
                guard let track = queue.first else {
                    playbackErrorMessage = "This artist does not have any playable tracks."
                    isPreparingQueue = false
                    return
                }
                let request = try await jellyfin.playbackRequest(for: track)
                playback.play(
                    request,
                    queueItems: queue.map(JellyfinPlaybackAdapter.playbackItem(for:)),
                    context: .artist(id: artist.id.opaqueID),
                    account: jellyfin.playbackAccount
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            isPreparingQueue = false
        }
    }

    private func artistTracks() async throws -> [MusicCatalogItem] {
        var tracks: [MusicCatalogItem] = []
        var cursor: MusicCatalogCursor?

        repeat {
            let page = try await jellyfin.musicSongsPage(
                cursor: cursor,
                limit: 100,
                artist: artist
            )
            tracks += page.items
            cursor = page.cursor
        } while cursor != nil

        var seen = Set<MusicCatalogItemID>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
}
