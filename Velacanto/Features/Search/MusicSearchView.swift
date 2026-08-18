import SwiftUI

#if os(iOS)
    import UIKit
#endif

struct MusicSearchView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController
    @Binding var searchText: String

    let showProfile: () -> Void
    var focusRequest = 0

    @StateObject private var model = PagedMusicCatalogModel()
    @State private var preparingTrackID: MusicCatalogItemID?
    @State private var playbackErrorMessage: String?
    @State private var selectedGenre: MusicGenre?
    @State private var isSearchPresented = false
    @State private var isRootHeaderVisible = true
    @State private var genreGridScrollAnchor: MusicCatalogItemID?

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var albums: [MusicCatalogItem] {
        model.items.filter { $0.kind == .album }
    }

    private var artists: [MusicCatalogItem] {
        model.items.filter { $0.kind == .artist }
    }

    private var songs: [MusicCatalogItem] {
        model.items.filter { $0.kind == .song }
    }

    private var playlists: [MusicCatalogItem] {
        model.items.filter { $0.kind == .playlist }
    }

    var body: some View {
        Group {
            if !jellyfin.isSignedIn {
                ContentUnavailableView {
                    Label("Search Needs a Music Server", systemImage: "magnifyingglass")
                } description: {
                    Text("Add a Jellyfin server from your profile to search your library.")
                } actions: {
                    Button("Open Profile", action: showProfile)
                        .buttonStyle(.borderedProminent)
                }
            } else if query.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Browse Genres")
                            .font(.title2.weight(.semibold))
                        MusicGenreGrid(
                            jellyfin: jellyfin,
                            selectGenre: { genre in
                                selectedGenre = genre
                            },
                            presentation: .collection
                        )
                    }
                    .padding(20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isSearchPresented = false
                    }
                }
                .revealsRootHeader($isRootHeaderVisible)
                .scrollPosition(id: $genreGridScrollAnchor)
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 4).onChanged { _ in
                        isSearchPresented = false
                    }
                )
            } else if query.count < 2 {
                ContentUnavailableView(
                    "Search Your Library",
                    systemImage: "magnifyingglass",
                    description: Text("Enter at least two characters to find music.")
                )
            } else if model.isInitialLoading {
                ProgressView("Searching…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ContentUnavailableView {
                    Label("Search Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await retry()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if model.items.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsList
            }
        }
        .progressiveNavigationChrome()
        .navigationDestination(item: $selectedGenre) { genre in
            MusicGenreCollectionView(
                genre: genre,
                playback: playback,
                jellyfin: jellyfin
            )
        }
        #if os(iOS)
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: "Albums, artists, songs, and playlists"
            )
            .toolbar {
                if isRootHeaderVisible {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarLeading) {
                            Text("Search")
                            .font(.title2.weight(.bold))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarLeading) {
                            Text("Search")
                            .font(.title2.weight(.bold))
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
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
        #if os(iOS)
            .background(SearchFieldFocusBridge(focusRequest: focusRequest))
        #endif
        .task(id: searchTaskID) {
            await search()
        }
        .task(id: focusRequest) {
            #if os(iOS)
                guard focusRequest > 0 else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                isSearchPresented = true
            #endif
        }
    }

    private var resultsList: some View {
        List {
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        NavigationLink {
                            JellyfinTracksView(
                                album: album,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: album, jellyfin: jellyfin)
                        }
                        .musicItemActions(for: album, jellyfin: jellyfin, playback: playback)
                        .onAppear {
                            loadMoreIfNeeded(album.id)
                        }
                    }
                }
            }

            if !artists.isEmpty {
                Section("Artists") {
                    ForEach(artists) { artist in
                        NavigationLink {
                            MusicArtistView(
                                artist: artist,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: artist, jellyfin: jellyfin)
                        }
                        .musicItemActions(for: artist, jellyfin: jellyfin, playback: playback)
                        .onAppear {
                            loadMoreIfNeeded(artist.id)
                        }
                    }
                }
            }

            if !songs.isEmpty {
                Section("Songs") {
                    ForEach(songs) { song in
                        Button {
                            play(song)
                        } label: {
                            SearchResultRow(
                                item: song,
                                jellyfin: jellyfin,
                                isPreparing: preparingTrackID == song.id
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(preparingTrackID != nil)
                        .musicItemActions(for: song, jellyfin: jellyfin, playback: playback)
                        .onAppear {
                            loadMoreIfNeeded(song.id)
                        }
                    }
                }
            }

            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            MusicPlaylistView(
                                playlist: playlist,
                                jellyfin: jellyfin,
                                playback: playback
                            )
                        } label: {
                            SearchResultRow(item: playlist, jellyfin: jellyfin)
                        }
                        .musicItemActions(for: playlist, jellyfin: jellyfin, playback: playback)
                        .onAppear {
                            loadMoreIfNeeded(playlist.id)
                        }
                    }
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

            if let playbackErrorMessage {
                ErrorMessageView(message: playbackErrorMessage)
            }
        }
        .revealsRootHeader($isRootHeaderVisible)
    }

    private var searchTaskID: String {
        "\(jellyfin.session?.serverID ?? "signed-out")|\(query)"
    }

    @MainActor
    private func search() async {
        guard jellyfin.isSignedIn, query.count >= 2 else {
            await model.reset(
                loader: { _ in
                    MusicCatalogPage(
                        items: [],
                        totalRecordCount: 0,
                        cursor: nil
                    )
                }
            )
            return
        }

        await model.reset(
            debounce: .milliseconds(250),
            loader: pageLoader
        )
    }

    private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
        model.loadMoreIfNeeded(itemID: itemID, loader: pageLoader)
    }

    private func retry() async {
        await model.retry(loader: pageLoader)
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.searchMusicPage(
                query: query,
                cursor: cursor
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
                    queueItems: model.items.compactMap {
                        guard $0.kind == .song else { return nil }
                        return JellyfinPlaybackAdapter.playbackItem(for: $0)
                    },
                    context: .search,
                    account: jellyfin.playbackAccount,
                    queueExpansion: {
                        await model.loadNextPage(loader: pageLoader)
                        return model.items.compactMap {
                            guard $0.kind == .song else { return nil }
                            return JellyfinPlaybackAdapter.playbackItem(for: $0)
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

#if os(iOS)
    private struct SearchFieldFocusBridge: UIViewRepresentable {
        let focusRequest: Int

        func makeUIView(context: Context) -> UIView {
            UIView()
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            guard focusRequest > 0, context.coordinator.lastRequest != focusRequest else {
                return
            }
            context.coordinator.lastRequest = focusRequest

            Task { @MainActor [weak uiView] in
                guard let uiView else { return }
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(80))
                    guard !Task.isCancelled else { return }
                    if let searchField = findSearchField(in: uiView.window ?? uiView) {
                        searchField.becomeFirstResponder()
                        return
                    }
                }
            }
        }

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        final class Coordinator {
            var lastRequest = 0
        }

        private func findSearchField(in view: UIView) -> UISearchTextField? {
            if let searchField = view as? UISearchTextField {
                return searchField
            }
            for subview in view.subviews {
                if let searchField = findSearchField(in: subview) {
                    return searchField
                }
            }
            return nil
        }
    }
#endif

private struct SearchResultRow: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    var isPreparing = false

    var body: some View {
        HStack(spacing: 12) {
            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 9,
                maxWidth: 180
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch item.kind {
        case .song:
            if let album = item.album, !album.isEmpty {
                return "\(item.displayArtist) · \(album)"
            }
            return item.displayArtist
        case .album:
            return item.displayArtist
        case .artist:
            return "Artist"
        case .playlist:
            if let childCount = item.childCount {
                return "\(childCount) \(childCount == 1 ? "song" : "songs")"
            }
            return "Playlist"
        }
    }
}
