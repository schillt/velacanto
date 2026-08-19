import SwiftUI

struct MusicSongsView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var scrollPosition = CatalogScrollPositionState<MusicCatalogItemID>()
    @State private var preparingTrackID: MusicCatalogItemID?
    @State private var playbackErrorMessage: String?
    @State private var searchText = ""

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if model.isInitialLoading {
                ProgressView("Loading songs…")
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
                    "No Songs",
                    systemImage: "music.note",
                    description: Text(
                        "Jellyfin did not return any songs from your music libraries."
                    )
                )
            } else {
                Section {
                    ForEach(model.items) { song in
                        Button {
                            play(song)
                        } label: {
                            MusicSongRow(
                                song: song,
                                jellyfin: jellyfin,
                                playback: playback,
                                isPreparing: preparingTrackID == song.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                        .id(song.id)
                        .onAppear {
                            loadMoreIfNeeded(song.id)
                        }
                    }
                } header: {
                    Text("\(model.totalRecordCount.formatted()) Songs")
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
        .scrollPosition(id: scrollPosition.binding(identity: taskID))
        .progressivePageHeader("Songs")
        #if !os(macOS)
            .searchable(text: $searchText, prompt: "Songs, artists, and albums")
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
                    await jellyfin.cachedCatalogItems(kind: .songs)
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
            try await jellyfin.musicSongsPage(
                cursor: cursor,
                searchTerm: query.isEmpty ? nil : query
            )
        }
    }

    private var cacheWriter: PagedMusicCatalogModel.CacheWriter {
        { items in
            await jellyfin.cacheCatalogItems(items, kind: .songs)
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
                    context: .songs,
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(
                            loader: pageLoader,
                            cacheWriter: query.isEmpty ? cacheWriter : nil
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
