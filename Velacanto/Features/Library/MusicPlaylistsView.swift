import SwiftUI

struct MusicPlaylistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let showNowPlaying: () -> Void

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var searchText = ""

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
                            showNowPlaying: showNowPlaying
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
        .navigationTitle("Playlists")
        .searchable(text: $searchText, prompt: "Playlists")
        .task(id: taskID) {
            await reset()
        }
        .refreshable {
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

    private func loadMoreIfNeeded(_ itemID: String) {
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

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.musicPlaylistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .playlists)
        }
    }
}

struct MusicPlaylistView: View {
    let playlist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator
    let showNowPlaying: () -> Void

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var preparingTrackID: String?
    @State private var playbackErrorMessage: String?

    var body: some View {
        List {
            if !model.isInitialLoading {
                Section {
                    MusicDetailHeader(
                        item: playlist,
                        jellyfin: jellyfin,
                        subtitle: "Playlist",
                        detail: model.items.isEmpty
                            ? nil
                            : "\(model.totalRecordCount) \(model.totalRecordCount == 1 ? "song" : "songs")"
                    )
                }
            }

            if model.isInitialLoading {
                ProgressView("Loading playlist…")
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
                    "Empty Playlist",
                    systemImage: "music.note.list",
                    description: Text("This playlist does not contain any songs.")
                )
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
                            isPreparing: preparingTrackID == song.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(preparingTrackID != nil)
                    .onAppear {
                        loadMoreIfNeeded(song.id)
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

            if let playbackErrorMessage {
                ErrorMessageView(message: playbackErrorMessage)
            }
        }
        .navigationTitle(playlist.name)
        .task(id: playlist.id) {
            await reset()
        }
        .refreshable {
            await reset()
        }
        #if os(macOS)
            .macOSPlaybackAccessoryInset(
                playback: playback,
                jellyfin: jellyfin,
                isVisible: playback.hasPlayableItem,
                showNowPlaying: showNowPlaying
            )
            .preference(key: PlaybackAccessoryOwnerPreferenceKey.self, value: true)
        #endif
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

    private func loadMoreIfNeeded(_ itemID: String) {
        model.loadMoreIfNeeded(
            itemID: itemID,
            loader: pageLoader,
            cacheWriter: cacheWriter
        )
    }

    private func retry() async {
        await model.retry(loader: pageLoader, cacheWriter: cacheWriter)
    }

    private var pageLoader: PagedJellyfinItemsModel.Loader {
        { cursor in
            try await jellyfin.tracksPage(
                inPlaylist: playlist,
                cursor: cursor
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .playlistTracks,
                contextID: playlist.id
            )
        }
    }

    private func play(_ song: JellyfinItem) {
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
                    context: .playlist(id: playlist.id),
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
}
