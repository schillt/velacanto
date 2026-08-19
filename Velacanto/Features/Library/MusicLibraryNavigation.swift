import SwiftUI

struct MusicLibraryView: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    let openLocalFile: () -> Void
    let showProfile: () -> Void

    var body: some View {
        Group {
            if jellyfin.isSignedIn {
                signedInLibrary
            } else {
                signedOutLibrary
            }
        }
        .progressiveSemanticNavigationTitle("Library")
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: showProfile) {
                        AccountAvatar(jellyfin: jellyfin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Profile and settings")
                }
            }
        #endif
    }

    private var signedInLibrary: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                PinnedLibraryGrid(
                    playback: playback,
                    jellyfin: jellyfin
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your Music").font(.title2.weight(.semibold))
                    ForEach(MusicLibraryCategory.allCases) { category in
                        NavigationLink {
                            destination(for: category)
                        } label: {
                            MusicLibraryNavigationRow(
                                title: category.title,
                                subtitle: category.subtitle,
                                symbolName: category.symbolName
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: openLocalFile) {
                        MusicLibraryNavigationRow(
                            title: "Open Audio File",
                            subtitle: "Play audio directly from this device",
                            symbolName: "folder"
                        )
                    }
                    .buttonStyle(.plain)

                    if let session = jellyfin.session {
                        Text(
                            "Music from every library available to \(session.username) is combined here."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }

                MostListenedLibraryGrid(playback: playback, jellyfin: jellyfin)
            }
            .frame(maxWidth: 1_050, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private var signedOutLibrary: some View {
        ScrollView {
            VStack(spacing: 24) {
                ContentUnavailableView {
                    Label(
                        "Connect Your Music Library",
                        systemImage: "music.note.house"
                    )
                } description: {
                    Text(
                        jellyfin.phase == .restoring
                            ? "Restoring your saved Jellyfin session…"
                            : "Add a Jellyfin server from your profile to browse albums, artists, songs, and playlists."
                    )
                } actions: {
                    Button("Open Profile", action: showProfile)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 48)

                Button(action: openLocalFile) {
                    Label("Open Audio File", systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary, in: .rect(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: 640)
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func destination(for category: MusicLibraryCategory) -> some View {
        MusicLibraryCategoryView(
            category: category,
            playback: playback,
            jellyfin: jellyfin
        )
    }
}

enum MusicLibraryCategory: String, CaseIterable, Identifiable {
    case albums
    case artists
    case songs
    case playlists
    case genres

    var id: Self { self }

    var title: String {
        switch self {
        case .albums:
            "Albums"
        case .artists:
            "Artists"
        case .songs:
            "Songs"
        case .playlists:
            "Playlists"
        case .genres:
            "Genres"
        }
    }

    var subtitle: String {
        switch self {
        case .albums:
            "Browse your collection by album"
        case .artists:
            "Find music by artist"
        case .songs:
            "See every song in your library"
        case .playlists:
            "Collections you’ve created and saved"
        case .genres:
            "Browse albums by genre"
        }
    }

    var symbolName: String {
        switch self {
        case .albums:
            "opticaldisc.fill"
        case .artists:
            "music.mic"
        case .songs:
            "music.note"
        case .playlists:
            "music.note.list"
        case .genres:
            "guitars"
        }
    }
}

struct MusicLibraryCategoryView: View {
    let category: MusicLibraryCategory
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @ViewBuilder
    var body: some View {
        switch category {
        case .albums:
            MusicAlbumsView(jellyfin: jellyfin, playback: playback)
        case .artists:
            MusicArtistsView(jellyfin: jellyfin, playback: playback)
        case .songs:
            MusicSongsView(jellyfin: jellyfin, playback: playback)
        case .playlists:
            MusicPlaylistsView(
                jellyfin: jellyfin,
                playback: playback
            )
        case .genres:
            MusicGenresBrowserView(
                jellyfin: jellyfin,
                playback: playback
            )
        }
    }
}

private struct MusicGenresBrowserView: View {
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @State private var selectedGenre: MusicGenre?
    @State private var returnAnchor: MusicCatalogItemID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                MusicGenreGrid(
                    jellyfin: jellyfin,
                    selectGenre: { genre in
                        returnAnchor = genre.id
                        selectedGenre = genre
                    }
                )
                .padding(20)
            }
            .onChange(of: selectedGenre) { previousGenre, currentGenre in
                guard previousGenre != nil, currentGenre == nil, let returnAnchor else {
                    return
                }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(returnAnchor, anchor: .center)
                }
            }
        }
        .progressivePageHeader("Genres")
        .navigationDestination(item: $selectedGenre) { genre in
            MusicGenreCollectionView(
                genre: genre,
                playback: playback,
                jellyfin: jellyfin
            )
        }
    }
}

private struct PinnedLibraryGrid: View {
    @EnvironmentObject private var actions: MusicItemActionStateOwner

    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pinned").font(.title2.weight(.semibold))

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 10),
                    count: 3
                ),
                spacing: 10
            ) {
                NavigationLink {
                    MusicLibraryCollectionView(
                        title: "Favorites",
                        playback: playback,
                        jellyfin: jellyfin
                    )
                } label: {
                    FavoritesPinnedTile()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open Favorites")

                ForEach(actions.pinnedItems) { item in
                    NavigationLink {
                        destination(for: item)
                    } label: {
                        PinnedCatalogItemTile(item: item, jellyfin: jellyfin)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open \(item.name)")
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for item: MusicCatalogItem) -> some View {
        switch item.kind {
        case .album:
            JellyfinTracksView(album: item, jellyfin: jellyfin, playback: playback)
        case .artist:
            MusicArtistView(artist: item, jellyfin: jellyfin, playback: playback)
        case .playlist:
            MusicPlaylistView(playlist: item, jellyfin: jellyfin, playback: playback)
        case .song:
            EmptyView()
        }
    }
}

private struct FavoritesPinnedTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "heart.fill")
                .font(.title2.weight(.semibold))
                .symbolRenderingMode(.hierarchical)

            Spacer(minLength: 0)

            Text("Favorites")
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(
                colors: [.pink, .red],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: .rect(cornerRadius: 16)
        )
        .aspectRatio(1, contentMode: .fit)
        .contentShape(.rect(cornerRadius: 16))
    }
}

private struct PinnedCatalogItemTile: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LinearGradient(
                    colors: [.indigo, .purple],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                JellyfinArtworkView(
                    item: item,
                    jellyfin: jellyfin,
                    cornerRadius: 16,
                    maxWidth: 360
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.78)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .overlay(alignment: .bottomLeading) {
                    Label(item.name, systemImage: item.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                        .padding(12)
                }
            }
            .clipShape(.rect(cornerRadius: 16))
            .contentShape(.rect(cornerRadius: 16))
    }
}

extension MusicCatalogItem {
    fileprivate var symbolName: String {
        switch kind {
        case .album: "opticaldisc.fill"
        case .artist: "music.mic"
        case .playlist: "music.note.list"
        case .song: "music.note"
        }
    }
}

private struct MostListenedLibraryGrid: View {
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @StateObject private var model = PagedMusicCatalogModel()
    @State private var preparingItemID: MusicCatalogItemID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty {
                Text("Most Listened To").font(.title2.weight(.semibold))
                LazyVGrid(
                    columns: MusicArtworkGridLayout.columns,
                    alignment: .leading,
                    spacing: MusicArtworkGridLayout.verticalSpacing
                ) {
                    ForEach(Array(model.items.prefix(12))) { item in
                        itemView(item)
                    }
                }
            }
        }
        .task(id: jellyfin.playbackAccount) {
            await model.reset(loader: pageLoader)
        }
    }

    @ViewBuilder
    private func itemView(_ item: MusicCatalogItem) -> some View {
        if item.kind == .song {
            Button {
                play(item)
            } label: {
                MusicAlbumCard(album: item, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .disabled(preparingItemID != nil)
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                MusicAlbumCard(album: item, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        }
    }

    @ViewBuilder
    private func destination(for item: MusicCatalogItem) -> some View {
        switch item.kind {
        case .album:
            JellyfinTracksView(album: item, jellyfin: jellyfin, playback: playback)
        case .artist:
            MusicArtistView(artist: item, jellyfin: jellyfin, playback: playback)
        case .playlist:
            MusicPlaylistView(playlist: item, jellyfin: jellyfin, playback: playback)
        case .song:
            EmptyView()
        }
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.homeMostListenedPage(cursor: cursor, limit: 12)
        }
    }

    private func play(_ item: MusicCatalogItem) {
        preparingItemID = item.id
        Task {
            defer { preparingItemID = nil }
            guard let request = try? await jellyfin.playbackRequest(for: item) else { return }
            playback.play(request, context: .single, account: jellyfin.playbackAccount)
        }
    }
}

private struct MusicLibraryCollectionView: View {
    let title: String
    @ObservedObject var playback: AudioPlaybackCoordinator
    @ObservedObject var jellyfin: JellyfinSessionController

    @StateObject private var model = PagedMusicCatalogModel()
    @StateObject private var scrollPosition = CatalogScrollPositionState<MusicCatalogItemID>()
    @State private var preparingItemID: MusicCatalogItemID?

    var body: some View {
        ScrollView {
            if model.isInitialLoading {
                ProgressView("Loading \(title.lowercased())…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                MusicCatalogErrorView(message: errorMessage) {
                    Task { await retry() }
                }
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No \(title)",
                    systemImage: "heart",
                    description: Text("Music will appear here when it is available.")
                )
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: MusicArtworkGridLayout.columns,
                    alignment: .leading,
                    spacing: MusicArtworkGridLayout.verticalSpacing
                ) {
                    ForEach(model.items) { item in
                        itemView(item)
                            .id(item.id)
                            .onAppear { loadMoreIfNeeded(item.id) }
                    }
                }
                .padding(20)
                .scrollTargetLayout()
            }
        }
        .scrollPosition(id: scrollPosition.binding(identity: taskID))
        .progressivePageHeader(title)
        .task(id: taskID) {
            guard scrollPosition.begin(identity: taskID) else { return }
            await reset()
        }
        .refreshable {
            _ = scrollPosition.begin(identity: taskID, forceReset: true)
            await reset()
        }
    }

    @ViewBuilder
    private func itemView(_ item: MusicCatalogItem) -> some View {
        if item.kind == .song {
            Button {
                play(item)
            } label: {
                MusicAlbumCard(album: item, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .disabled(preparingItemID != nil)
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        } else {
            NavigationLink {
                destination(for: item)
            } label: {
                MusicAlbumCard(album: item, jellyfin: jellyfin)
            }
            .buttonStyle(.plain)
            .musicItemActions(for: item, jellyfin: jellyfin, playback: playback)
        }
    }

    @ViewBuilder
    private func destination(for item: MusicCatalogItem) -> some View {
        switch item.kind {
        case .album:
            JellyfinTracksView(album: item, jellyfin: jellyfin, playback: playback)
        case .artist:
            MusicArtistView(artist: item, jellyfin: jellyfin, playback: playback)
        case .playlist:
            MusicPlaylistView(playlist: item, jellyfin: jellyfin, playback: playback)
        case .song:
            EmptyView()
        }
    }

    private func reset() async {
        await model.reset(loader: pageLoader)
    }

    private func retry() async {
        await model.retry(loader: pageLoader)
    }

    private func loadMoreIfNeeded(_ itemID: MusicCatalogItemID) {
        model.loadMoreIfNeeded(itemID: itemID, loader: pageLoader)
    }

    private var taskID: String {
        "\(jellyfin.playbackAccount?.serverID ?? "signed-out")|\(jellyfin.playbackAccount?.userID ?? "none")|\(title)"
    }

    private var pageLoader: PagedMusicCatalogModel.Loader {
        { cursor in
            try await jellyfin.homeFavoritesPage(cursor: cursor)
        }
    }

    private func play(_ item: MusicCatalogItem) {
        preparingItemID = item.id
        Task {
            defer { preparingItemID = nil }
            guard let request = try? await jellyfin.playbackRequest(for: item) else {
                return
            }
            playback.play(request, context: .single, account: jellyfin.playbackAccount)
        }
    }
}

private struct MusicLibraryNavigationRow: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.velacantoAccent)
                .frame(width: 36, height: 36)
                .background(
                    Color.velacantoAccent.opacity(0.10),
                    in: .rect(cornerRadius: 10)
                )
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct MusicDetailHeader: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let subtitle: String
    let detail: String?
    var artworkSize: CGFloat?

    @ViewBuilder
    var body: some View {
        #if os(macOS)
            HStack(alignment: .bottom, spacing: 26) {
                artwork(size: 220, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
                metadata
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        #else
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(size: artworkSize ?? 116, cornerRadius: 14)
                    metadata
                }

                VStack(alignment: .leading, spacing: 12) {
                    artwork(size: artworkSize ?? 116, cornerRadius: 14)
                    metadata
                }
            }
            .padding(.vertical, 6)
        #endif
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        Color.clear
            .frame(width: size, height: size)
            .overlay {
                JellyfinArtworkView(
                    item: item,
                    jellyfin: jellyfin,
                    cornerRadius: cornerRadius,
                    maxWidth: 480
                )
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(titleFont)
            Text(subtitle)
                .font(subtitleFont)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleFont: Font {
        #if os(macOS)
            .largeTitle.weight(.bold)
        #else
            .title2.weight(.semibold)
        #endif
    }

    private var subtitleFont: Font {
        #if os(macOS)
            .title3
        #else
            .body
        #endif
    }
}

struct MusicCollectionHero: View {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    let collectionLabel: String?
    let subtitle: String
    let detail: String?
    var metadata: [String] = []
    let palette: MusicCollectionPalette
    let isPreparing: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            JellyfinArtworkView(
                item: item,
                jellyfin: jellyfin,
                cornerRadius: 22,
                maxWidth: 640
            )
            .frame(width: 208, height: 208)
            .shadow(color: .black.opacity(0.24), radius: 24, y: 12)
            .frame(maxWidth: .infinity, alignment: .center)

            VStack(spacing: 5) {
                if let collectionLabel {
                    Text(collectionLabel.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(palette.secondaryForeground)
                        .tracking(0.8)
                }
                Text(item.name)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.72)
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(palette.secondaryForeground)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(palette.secondaryForeground.opacity(0.82))
                }
                if !metadata.isEmpty {
                    Text(metadata.joined(separator: " · "))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondaryForeground)
                        .lineLimit(2)
                }
            }

            MusicCollectionActionBar(
                item: item,
                capabilities: item.capabilities,
                isPreparing: isPreparing,
                palette: palette,
                play: play,
                shuffle: shuffle
            )
        }
        .padding(.vertical, 12)
    }
}

extension MusicCatalogItem {
    var collectionMetadata: [String] {
        var metadata = Array(genres.prefix(2))
        if let releaseYear {
            metadata.append(String(releaseYear))
        }
        return metadata
    }
}

private struct MusicCollectionActionBar: View {
    let item: MusicCatalogItem
    let capabilities: MusicItemCapabilities
    let isPreparing: Bool
    let palette: MusicCollectionPalette
    let play: () -> Void
    let shuffle: () -> Void

    private let controlSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            if capabilities.contains(.shuffle) {
                Button(action: shuffle) {
                    Image(systemName: "shuffle")
                        .frame(width: controlSize, height: controlSize)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .tint(palette.secondaryForeground)
            } else {
                Color.clear.frame(width: controlSize, height: controlSize)
            }

            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .frame(height: controlSize)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(palette.foreground)
            .foregroundStyle(palette.primaryBackground)

            MusicFavoriteButton(
                item: item,
                presentation: .icon,
                iconSize: controlSize
            )
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .tint(palette.secondaryForeground)
        }
        .disabled(isPreparing)
        .overlay {
            if isPreparing {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: 320)
    }
}
