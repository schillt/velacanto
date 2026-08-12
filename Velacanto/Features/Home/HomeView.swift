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
    let showLibrary: () -> Void
    let showSearch: (String) -> Void
    var presentation = Presentation.home

    @StateObject private var favorites = PagedMusicCatalogModel()
    @StateObject private var recentlyAdded = PagedMusicCatalogModel()
    @State private var preparingCatalogItemID: MusicCatalogItemID?
    @State private var catalogPlaybackError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if presentation == .home {
                    continueListening

                    if !playback.recentItems.isEmpty {
                        recentlyPlayed
                    }

                    if jellyfin.isSignedIn {
                        genres
                    }
                }

                if jellyfin.isSignedIn {
                    if presentation == .home {
                        catalogShelf(
                            title: "Favorites",
                            model: favorites,
                            retry: loadFavorites
                        )
                    }

                    catalogShelf(
                        title: "Recently Added",
                        model: recentlyAdded,
                        retry: loadRecentlyAdded
                    )
                }

                if presentation == .home {
                    librarySources
                }
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(presentation.title)
        .toolbar {
            #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button(action: showProfile) {
                        AccountAvatar(jellyfin: jellyfin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile and settings")
                }
            #endif
        }
        .task(id: jellyfin.playbackAccount) {
            guard jellyfin.isSignedIn else {
                await clearProviderShelves()
                return
            }
            async let favoriteLoad: Void = loadFavorites()
            async let recentLoad: Void = loadRecentlyAdded()
            _ = await (favoriteLoad, recentLoad)
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
                            .foregroundStyle(.cyan)
                            .frame(width: 58, height: 58)
                            .background(.cyan.opacity(0.12), in: .rect(cornerRadius: 16))

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
            }
        }
    }

    private var genres: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Genres").font(.title2.weight(.semibold))
            MusicGenreGrid { genre in
                showSearch(genre.rawValue)
            }
        }
    }

    @ViewBuilder
    private func catalogShelf(
        title: String,
        model: PagedMusicCatalogModel,
        retry: @escaping @MainActor () async -> Void
    ) -> some View {
        let visibleItems =
            title == "Favorites"
            ? model.items.filter { favoriteActions.isFavorite($0) }
            : model.items

        if model.isInitialLoading {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                ProgressView("Loading \(title.lowercased())…")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        } else if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title2.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(visibleItems) { item in
                            catalogItem(item, shelfItems: visibleItems)
                        }
                    }
                }

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
                HomeCatalogCard(
                    item: item,
                    jellyfin: jellyfin,
                    isPreparing: preparingCatalogItemID == item.id
                )
            }
            .buttonStyle(.plain)
            .disabled(preparingCatalogItemID != nil)
            .accessibilityHint("Plays this song")
            .musicFavoriteActions(for: item)
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                HomeCatalogCard(item: item, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(item.name)")
            .musicFavoriteActions(for: item)
        }
    }

    @ViewBuilder
    private func destination(for item: MusicCatalogItem) -> some View {
        switch item.kind {
        case .album:
            JellyfinTracksView(
                album: item,
                jellyfin: jellyfin,
                playback: playback
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
                playback: playback
            )
        case .song:
            EmptyView()
        }
    }

    private func loadFavorites() async {
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
        await recentlyAdded.reset(
            cachedItems: {
                await jellyfin.cachedCatalogItems(kind: .recentlyAdded)
            },
            loader: { cursor in
                try await jellyfin.homeRecentlyAddedPage(cursor: cursor)
            },
            cacheWriter: { items in
                await jellyfin.cacheCatalogItems(items, kind: .recentlyAdded)
            }
        )
    }

    private func clearProviderShelves() async {
        let emptyLoader: PagedMusicCatalogModel.Loader = { _ in
            MusicCatalogPage(items: [], totalRecordCount: 0, cursor: nil)
        }
        await favorites.reset(loader: emptyLoader)
        await recentlyAdded.reset(loader: emptyLoader)
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

    private var librarySources: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From Your Library").font(.title2.weight(.semibold))
            VStack(spacing: 0) {
                if let session = jellyfin.session {
                    Button(action: showLibrary) {
                        SourceRow(
                            title: "Jellyfin", subtitle: "Browse music on \(session.serverName)",
                            symbolName: "server.rack")
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                }
                Button(action: openLocalFile) {
                    SourceRow(
                        title: "Local Files", subtitle: "Play audio directly from this device",
                        symbolName: "folder")
                }
                .buttonStyle(.plain)
            }
            .background(Color.secondary.opacity(0.06), in: .rect(cornerRadius: 18))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 14,
                maxWidth: 360
            )
            .frame(width: 142, height: 142)
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

private struct SourceRow: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            SourceIcon(symbolName: symbolName)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
                .tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

struct SourceIcon: View {
    let symbolName: String

    var body: some View {
        Image(systemName: symbolName)
            .font(.body.weight(.medium))
            .foregroundStyle(.cyan)
            .frame(width: 34, height: 34)
            .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 10))
    }
}

private struct SectionEyebrow: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.1)
            .foregroundStyle(.cyan)
            .accessibilityAddTraits(.isHeader)
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
            ProgressView(value: playback.progress).tint(.cyan).padding(.top, 5)
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
