import SwiftUI

struct MusicAlbumsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedJellyfinItemsModel()
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            if model.isInitialLoading {
                ProgressView("Loading albums…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
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
                        "Jellyfin did not return any albums from your music libraries."
                    )
                )
                .padding(.top, 60)
            } else {
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
                            MusicAlbumCard(album: album, jellyfin: jellyfin)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            loadMoreIfNeeded(album.id)
                        }
                    }
                }
                .padding(20)

                if model.isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 24)
                } else if let errorMessage = model.errorMessage {
                    MusicPaginationErrorView(message: errorMessage) {
                        Task {
                            await retry()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("Albums")
        .searchable(text: $searchText, prompt: "Albums and artists")
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
                    await jellyfin.cachedCatalogItems(kind: .albums)
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
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedJellyfinItemsModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .albums)
        }
    }
}

struct MusicAlbumCard: View {
    let album: JellyfinItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtworkView(
                item: album,
                jellyfin: jellyfin,
                cornerRadius: 14,
                maxWidth: 480
            )
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}
