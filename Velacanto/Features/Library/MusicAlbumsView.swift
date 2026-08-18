import SwiftUI

struct MusicAlbumsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedMusicCatalogModel()
    @State private var searchText = ""
    @StateObject private var gridPosition = AlbumGridPositionState()
    @Namespace private var albumTransitionNamespace

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
                                jellyfin: jellyfin,
                                transitionNamespace: albumTransitionNamespace
                            )
                        }
                        .buttonStyle(.plain)
                        .musicItemActions(for: album, jellyfin: jellyfin, playback: playback)
                        .id(album.id)
                        .onAppear {
                            loadMoreIfNeeded(album.id)
                        }
                    }
                }
                .scrollTargetLayout()
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
        .scrollPosition(id: scrollPositionBinding)
        .progressivePageHeader("Albums")
        #if !os(macOS)
            .searchable(text: $searchText, prompt: "Albums and artists")
        #endif
        .task(id: taskID) {
            guard gridPosition.begin(identity: taskID) else { return }
            await reset()
        }
        .refreshable {
            _ = gridPosition.begin(identity: taskID, forceReset: true)
            await reset()
        }
    }

    private var taskID: String {
        let account = jellyfin.playbackAccount
        return "\(account?.serverID ?? "signed-out")|\(account?.userID ?? "none")|\(query)"
    }

    private var scrollPositionBinding: Binding<MusicCatalogItemID?> {
        Binding(
            get: { gridPosition.anchor },
            set: { gridPosition.record($0, identity: taskID) }
        )
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
            try await jellyfin.musicAlbumsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .albums)
        }
    }
}

struct MusicAlbumCard: View {
    let album: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var transitionNamespace: Namespace.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    JellyfinArtworkView(
                        item: album,
                        jellyfin: jellyfin,
                        cornerRadius: 14,
                        maxWidth: 480
                    )
                    .albumArtworkTransitionSource(
                        id: album.artworkTransitionID,
                        in: transitionNamespace
                    )
                }
                .clipShape(.rect(cornerRadius: 14))

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

extension MusicCatalogItem {
    var artworkTransitionID: String {
        "album-artwork-\(id.opaqueID)"
    }
}

extension View {
    @ViewBuilder
    func albumArtworkTransitionSource(
        id: String,
        in namespace: Namespace.ID?
    ) -> some View {
        #if os(iOS)
            if #available(iOS 18.0, *), let namespace {
                matchedTransitionSource(id: id, in: namespace)
            } else {
                self
            }
        #else
            self
        #endif
    }

    @ViewBuilder
    func albumArtworkZoomTransition(
        sourceID: String,
        in namespace: Namespace.ID?
    ) -> some View {
        #if os(iOS)
            if #available(iOS 18.0, *), let namespace {
                navigationTransition(.zoom(sourceID: sourceID, in: namespace))
            } else {
                self
            }
        #else
            self
        #endif
    }
}
