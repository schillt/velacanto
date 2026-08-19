import SwiftUI

struct MusicPlaylistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var scrollPosition = CatalogScrollPositionState<MusicCatalogItemID>()
    @State private var searchText = ""
    @Namespace private var playlistTransitionNamespace

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading playlists…")
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
                    "No Playlists",
                    systemImage: "music.note.list",
                    description: Text(
                        "Your Jellyfin playlists will appear here."
                    )
                )
            } else {
                ForEach(model.items) { playlist in
                    NavigationLink {
                        MusicPlaylistView(
                            playlist: playlist,
                            jellyfin: jellyfin,
                            playback: playback,
                            transitionNamespace: playlistTransitionNamespace
                        )
                    } label: {
                        HStack(spacing: 14) {
                            JellyfinArtworkView(
                                item: playlist,
                                jellyfin: jellyfin,
                                cornerRadius: 11,
                                maxWidth: 180
                            )
                            .frame(width: 58, height: 58)
                            .albumArtworkTransitionSource(
                                id: playlist.artworkTransitionID,
                                in: playlistTransitionNamespace
                            )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(playlist.name)
                                    .font(.body.weight(.medium))
                                if let childCount = playlist.childCount {
                                    Text(
                                        "\(childCount) \(childCount == 1 ? "song" : "songs")"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                } else {
                                    Text("Playlist")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .musicItemActions(for: playlist, jellyfin: jellyfin, playback: playback)
                    .id(playlist.id)
                    .onAppear {
                        loadMoreIfNeeded(playlist.id)
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
        .progressivePageHeader("Playlists")
        #if !os(macOS)
            .searchable(text: $searchText, prompt: "Playlists")
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
                    await jellyfin.cachedCatalogItems(kind: .playlists)
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
            try await jellyfin.musicPlaylistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .playlists)
        }
    }
}

struct MusicPlaylistView: View {
    let playlist: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    var transitionNamespace: Namespace.ID?

    @StateObject private var model = PagedMusicCatalogModel()
    @State private var preparingTrackID: MusicCatalogItemID?
    @State private var playbackErrorMessage: String?
    @State private var collectionPalette = MusicCollectionPalette.fallback

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                if !model.isInitialLoading {
                    MusicCollectionHero(
                        item: playlist,
                        jellyfin: jellyfin,
                        collectionLabel: "Playlist",
                        subtitle: "Playlist",
                        detail: model.items.isEmpty
                            ? nil
                            : "\(model.totalRecordCount) \(model.totalRecordCount == 1 ? "song" : "songs")",
                        palette: collectionPalette,
                        isPreparing: preparingTrackID != nil,
                        play: { playQueue(shuffled: false) },
                        shuffle: { playQueue(shuffled: true) }
                    )
                    .padding(.bottom, 22)
                }

                if model.isInitialLoading {
                    ProgressView("Loading playlist…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 88)
                } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                    VStack(spacing: 14) {
                        ErrorMessageView(message: errorMessage)
                        Button("Retry") {
                            Task {
                                await retry()
                            }
                        }
                    }
                    .padding(.vertical, 48)
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "Empty Playlist",
                        systemImage: "music.note.list",
                        description: Text("This playlist does not contain any songs.")
                    )
                    .padding(.vertical, 48)
                } else {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, song in
                        Button {
                            play(song)
                        } label: {
                            MusicSongRow(
                                song: song,
                                leadingNumber: index + 1,
                                jellyfin: jellyfin,
                                playback: playback,
                                isPreparing: preparingTrackID == song.id,
                                foreground: collectionPalette.foreground,
                                secondaryForeground: collectionPalette.secondaryForeground
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                        .padding(.vertical, 10)
                        .onAppear {
                            loadMoreIfNeeded(song.id)
                        }
                        if index < model.items.count - 1 {
                            Divider()
                        }
                    }

                    paginationFooter
                }

                if let playbackErrorMessage {
                    ErrorMessageView(message: playbackErrorMessage)
                        .padding(.top, 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 120)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .background {
            MusicCollectionArtworkBackdrop(
                item: playlist,
                jellyfin: jellyfin,
                palette: $collectionPalette
            )
        }
        .collectionDetailNavigationChrome()
        .albumArtworkZoomTransition(
            sourceID: playlist.artworkTransitionID,
            in: transitionNamespace
        )
        #if os(iOS)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(
                collectionPalette.usesLightForeground ? .dark : .light,
                for: .navigationBar
            )
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                #if os(macOS)
                    MusicFavoriteButton(item: playlist, presentation: .icon)
                #endif
                MusicLibraryPinMenu(item: playlist)
            }
        }
        .task(id: playlist.id) {
            await reset()
        }
    }

    private func reset() async {
        await model.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(
                    kind: .playlistTracks,
                    contextID: playlist.id
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

    @ViewBuilder
    private var paginationFooter: some View {
        if model.isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if let errorMessage = model.errorMessage {
            MusicPaginationErrorView(message: errorMessage) {
                Task {
                    await retry()
                }
            }
            .padding(.top, 12)
        }
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.tracksPage(
                inPlaylist: playlist,
                cursor: cursor
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .playlistTracks,
                contextID: playlist.id
            )
        }
    }

    private func play(_ song: MusicCatalogItem) {
        preparingTrackID = song.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                playback.play(
                    request,
                    queueItems: model.items.map(
                        JellyfinPlaybackAdapter.playbackItem(for:)
                    ),
                    context: .playlist(id: playlist.id.opaqueID),
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(
                            loader: pageLoader,
                            cacheWriter: cacheWriter
                        )
                        return model.items.map {
                            JellyfinPlaybackAdapter.playbackItem(for: $0)
                        }
                    }
                )
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }

    private func playQueue(shuffled: Bool) {
        guard !model.items.isEmpty else { return }
        let songs = shuffled ? model.items.shuffled() : model.items
        guard let song = songs.first else { return }

        preparingTrackID = song.id
        playbackErrorMessage = nil
        Task {
            do {
                let request = try await jellyfin.playbackRequest(for: song)
                if shuffled {
                    playback.play(
                        request,
                        queueItems: songs.map(JellyfinPlaybackAdapter.playbackItem(for:)),
                        context: .playlist(id: playlist.id.opaqueID),
                        account: jellyfin.playbackAccount
                    )
                } else {
                    playback.play(
                        request,
                        queueItems: songs.map(JellyfinPlaybackAdapter.playbackItem(for:)),
                        context: .playlist(id: playlist.id.opaqueID),
                        account: jellyfin.playbackAccount,
                        queueExpansion: {
                            await model.loadNextPage(
                                loader: pageLoader,
                                cacheWriter: cacheWriter
                            )
                            return model.items.map {
                                JellyfinPlaybackAdapter.playbackItem(for: $0)
                            }
                        }
                    )
                }
            } catch {
                playbackErrorMessage = error.localizedDescription
            }
            preparingTrackID = nil
        }
    }
}
