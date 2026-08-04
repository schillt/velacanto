import SwiftUI

struct MusicArtistsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
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
        .navigationTitle("Artists")
        .searchable(text: $searchText, prompt: "Artists")
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
                    await jellyfin.cachedCatalogItems(kind: .artists)
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
            try await jellyfin.musicArtistsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .artists)
        }
    }
}

struct MusicArtistView: View {
    let artist: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()

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
                            columns: [
                                GridItem(
                                    .adaptive(minimum: 138, maximum: 210),
                                    spacing: 18,
                                    alignment: .top
                                )
                            ],
                            alignment: .leading,
                            spacing: 24
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
        .navigationTitle(artist.name)
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
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                artist: artist
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(
                items,
                kind: .albums,
                contextID: artist.id
            )
        }
    }
}
