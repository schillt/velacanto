import Combine
import SwiftUI

/// The account owns collection work, so its outcome remains visible above browsing.
private struct FoundationCollectionActionStatus: View {
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var compactPresentation = false

    var body: some View {
        if actions.isQueueLoading || actions.queueErrorMessage != nil || actions.queueNotice != nil
        {
            VStack(alignment: .leading, spacing: 8) {
                if actions.isQueueLoading {
                    if compactPresentation && !dynamicTypeSize.isAccessibilitySize {
                        HStack(spacing: 12) {
                            loadingStatus
                            Spacer(minLength: 0)
                            cancelButton
                        }
                    } else {
                        loadingStatus
                        cancelButton
                    }
                } else {
                    Text(actions.queueErrorMessage ?? actions.queueNotice ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if actions.canRetryQueueAddition {
                            Button("Retry") { actions.retryQueueAddition() }
                                .accessibilityLabel("Retry collection loading")
                                .frame(
                                    minWidth: compactPresentation ? 44 : nil,
                                    minHeight: compactPresentation ? 44 : nil)
                        }
                        Button("Dismiss") { actions.dismissQueueOutcome() }
                            .frame(
                                minWidth: compactPresentation ? 44 : nil,
                                minHeight: compactPresentation ? 44 : nil)
                    }
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, compactPresentation ? 4 : 16)
            .background {
                if !compactPresentation { Rectangle().fill(.regularMaterial) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var loadingStatus: some View {
        if let notice = actions.queueNotice {
            ProgressView(compactPresentation ? "Cancelling collection loading…" : notice)
        } else {
            ProgressView("Loading songs… \(actions.queueLoadedCount) loaded")
        }
    }

    @ViewBuilder private var cancelButton: some View {
        if actions.queueNotice == nil {
            Button("Cancel") { actions.cancelQueueAddition() }
                .accessibilityLabel("Cancel collection loading")
                .frame(
                    minWidth: compactPresentation ? 44 : nil,
                    minHeight: compactPresentation ? 44 : nil)
        }
    }
}

enum FoundationDestination: Int, CaseIterable {
    case home, new, library, search

    var title: String {
        switch self {
        case .home: "Home"
        case .new: "New"
        case .library: "Library"
        case .search: "Search"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .new: "square.grid.2x2"
        case .library: "music.pages"
        case .search: "magnifyingglass"
        }
    }
    var icon: Image {
        self == .home
            ? Image("HomeRounded").renderingMode(.template) : Image(systemName: symbol)
    }
}

struct FoundationLibraryView: View {
    let library: any FoundationLibrary
    let accountLibrary: any FoundationLibrary
    let librarySelection: FoundationMusicLibrarySelection?
    let player: FoundationPlayer
    let signOut: () -> Void
    @State private var displayedQueue: [FoundationQueueEntry] = []
    @State private var displayedEntryID: UUID?
    @State private var displayedState: FoundationPlayer.State = .idle
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var actions: FoundationLibraryActions
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var favorites = FoundationBrowseModel()
    @StateObject private var genres: FoundationBrowseModel
    @StateObject private var recentTracks: FoundationBrowseModel
    @StateObject private var recentAlbums: FoundationBrowseModel
    @StateObject private var mostPlayedAlbums = FoundationBrowseModel()
    @StateObject private var homeHistory: FoundationBrowseModel
    @StateObject private var homeFavorites: FoundationBrowseModel
    @StateObject private var homeGenres: FoundationBrowseModel
    @StateObject private var searchGenres: FoundationBrowseModel
    @State private var searchQuery = ""
    @State private var searchActivation = 0
    @State private var selectedTab = FoundationDestination.home
    @State private var displayedCatalogScope: String
    @State private var initialConnectionResolved = false
    @State private var selectedTabByUser = false
    #if os(iOS)
        @StateObject private var playerArtworkPresentation =
            FoundationPlayerArtworkPresentationModel()
        @AccessibilityFocusState private var miniPlayerFocused: Bool
    #endif
    @Namespace private var playerTransition
    @State private var showingPlayer = false
    #if os(macOS)
        @Environment(\.foundationReduceTransparency) private var macReduceTransparency
        @Environment(\.foundationReduceMotion) private var macReduceMotion
        @Environment(\.openSettings) private var openSettings
        @EnvironmentObject private var appModel: FoundationAppModel
        @State private var macPanel = FoundationMacPlaybackPanel.Mode.queue
        @State private var macLibraryRoute = FoundationMacLibraryRoute.overview
        @State private var macNavigationRevision = 0
        @State private var macInspectorWidth = CGFloat(340)
        @State private var macTransportInset = CGFloat(120)
        @State private var macLibraryExpanded = true
        @State private var macPlaylistsExpanded = true
    #endif
    @State private var showingSettings = false
    @State private var playlistSource: FoundationItem?
    @StateObject private var playlistChanges = FoundationPlaylistChanges()
    @State private var profileName = ""
    @State private var profileImage: Image?
    @State private var showingFavorites = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedItem: FoundationItem?
    @State private var offlineSurface: Color?

    init(
        library: any FoundationLibrary, accountLibrary: (any FoundationLibrary)? = nil,
        player: FoundationPlayer, signOut: @escaping () -> Void,
        librarySelection: FoundationMusicLibrarySelection? = nil
    ) {
        self.library = library
        self.accountLibrary = accountLibrary ?? library
        self.librarySelection = librarySelection
        _displayedCatalogScope = State(initialValue: library.catalogScopeID)
        self.player = player
        self.signOut = signOut
        _homeHistory = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("home-history")))
        _homeFavorites = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache,
                key: library.catalogCacheKey("home-favorites-collections-v1")))
        _homeGenres = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("home-genres")))
        _recentAlbums = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("recent-albums")))
        _recentTracks = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("recent-tracks")))
        _genres = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("library-genres")))
        _searchGenres = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("search-genres")))
    }

    private static func cachedModel(_ cache: FoundationCatalogPageCache?, key: String)
        -> FoundationBrowseModel
    {
        let model = FoundationBrowseModel()
        if let cache { model.configureCache(cache, key: key) }
        return model
    }

    var body: some View {
        VStack(spacing: 0) {
            if connectivity.localOnly { FoundationOfflineStatus(surfaceColor: offlineSurface) }
            if library.catalogScopeID.hasSuffix(".unavailable"), !connectivity.localOnly {
                Text(
                    "Music library unavailable. Choose a library in Settings or retry the connection."
                )
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            #if os(macOS)
                FoundationCollectionActionStatus()
            #endif
            shell
        }
        .onPreferenceChange(FoundationOfflineSurfacePreferenceKey.self) { offlineSurface = $0 }
        .onReceive(player.$queue.removeDuplicates()) { displayedQueue = $0 }
        .onReceive(player.$selectedEntryID.removeDuplicates()) { displayedEntryID = $0 }
        .onReceive(player.$state.removeDuplicates()) { displayedState = $0 }
        #if DEBUG
            .onChange(of: showingPlayer) { _, shown in
                FoundationTrace.event(
                    "surface origin=\(String(describing: selectedTab)) page=root playerSheet=\(shown ? 1 : 0)"
                )
            }
        #endif
        .onChange(of: selectedTab) { _, _ in actions.cancelQueueAddition() }
        .onChange(of: library.catalogScopeID) { _, _ in
            actions.cancelQueueAddition()
            resetCatalogScope()
        }
        .onChange(of: connectivity.localOnly) { _, localOnly in
            if localOnly {
                playlistSource = nil
                actions.cancelQueueAddition()
            }
        }
        .task { resolveInitialConnection() }
        .onChange(of: connectivity.status) { _, _ in resolveInitialConnection() }
        .onChange(of: playlistChanges.revisions) { _, _ in
            downloads.reconcilePlaylists()
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            favorites.request(.refresh)
            homeFavorites.request(.refresh)
        }
        .foundationPlayerCover(
            isPresented: $showingPlayer, player: player, sourceNamespace: playerTransition,
            onDismiss: playerDidDismiss
        ) {
            FoundationPlayerView(player: player, library: accountLibrary)
        }
        .foundationSettingsPresentation(isPresented: $showingSettings) {
            FoundationSettingsView(
                name: profileName, image: profileImage, signOut: signOut, library: accountLibrary,
                librarySelection: librarySelection)
        }
        .sheet(
            isPresented: Binding(
                get: { playlistSource != nil },
                set: { if !$0 { playlistSource = nil } })
        ) {
            if let source = playlistSource {
                FoundationPlaylistPicker(source: source, library: library)
            }
        }
        .foundationDownloadRemovalPresentation()
        .environmentObject(playlistChanges)
        .environment(\.foundationAddToPlaylist, playlistPresentation)
        #if os(iOS)
            .environment(\.foundationPlayerArtworkPresentation, playerArtworkPresentation)
            .onChange(of: playerArtworkPresentation.isPlayerPresented) { wasPresented, presented in
                if wasPresented, !presented { miniPlayerFocused = true }
            }
        #endif
        .environment(\.foundationOpenLibrary, libraryPresentation)
        #if os(macOS)
            .focusedSceneValue(\.foundationMacActions, macActions)
            .onChange(of: macLibraryRoute) { _, _ in actions.cancelQueueAddition() }
        #endif

    }

    private func playerDidDismiss() {
        #if os(iOS)
            miniPlayerFocused = true
        #endif
    }

    private func resetCatalogScope() {
        #if os(macOS)
            macLibraryRoute = .overview
        #endif
        openedItem = nil
        showingFavorites = false
        searchQuery = ""
        for model in [albums, artists, songs, playlists, favorites, mostPlayedAlbums] {
            model.clearRetainedData()
        }
        for (model, key) in [
            (homeHistory, "home-history"), (homeFavorites, "home-favorites-collections-v1"),
            (homeGenres, "home-genres"), (recentAlbums, "recent-albums"),
            (recentTracks, "recent-tracks"), (genres, "library-genres"),
            (searchGenres, "search-genres"),
        ] {
            model.clearRetainedData()
            model.configureCache(library.catalogPageCache, key: library.catalogCacheKey(key))
        }
        displayedCatalogScope = library.catalogScopeID
    }

    private func catalogIsActive(_ tab: FoundationDestination) -> Bool {
        selectedTab == tab && scenePhase == .active
    }

    private var libraryPresentation: (@MainActor @Sendable () -> Void)? {
        guard selectedTab != .library else { return nil }
        return { tabSelection.wrappedValue = .library }
    }

    private var playlistPresentation: (@MainActor @Sendable (FoundationItem) -> Void)? {
        guard !connectivity.localOnly, library.supportsPlaylistManagement else { return nil }
        return { playlistSource = $0 }
    }

    @ViewBuilder private var shell: some View {
        #if os(iOS)
            tabs.tabBarMinimizeBehavior(hasCollectionOutcome ? .never : .onScrollDown)
        #else
            FoundationMacLibraryShell(
                selection: tabSelection, searchQuery: $searchQuery,
                searchActivation: searchActivation,
                libraryNavigationID: macLibraryRoute.identity,
                navigationRevision: macNavigationRevision,
                playbackInset: $macTransportInset,
                showsMiniPlayer: true
            ) { destination in
                browsingContent(destination)
            } miniPlayer: {
                macTransport
            } librarySidebar: {
                macLibrarySidebar
            } profile: {
                profileButton(isActive: scenePhase == .active)
            }
            .inspector(isPresented: $showingPlayer) {
                FoundationMacPlaybackPanel(player: player, library: accountLibrary, mode: macPanel)
                    .environment(\.foundationMacTransportBottomInset, 0)
                    .environment(\.foundationMacUsesShellToolbar, false)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: { width in
                        if showingPlayer, width > 0 { macInspectorWidth = width }
                    }
            }
            .environment(
                \.foundationMacTransportBottomInset,
                macTransportInset
            )
            .environment(
                \.foundationMacToolbarTrailingReserve,
                showingPlayer ? macInspectorWidth : 0
            )
            .environment(\.foundationMacUsesShellToolbar, true)
            .animation(
                macReduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9),
                value: showingPlayer
            )
            .task(id: "\(library.catalogScopeID)-\(macPlaylistsExpanded)-\(connectivity.localOnly)")
            {
                guard macPlaylistsExpanded, !playlists.loaded else { return }
                await playlists.loadPending(
                    ifActive: macPlaylistsExpanded, allowsNetwork: !connectivity.localOnly
                ) { try await library.playlists(startIndex: $0) }
            }
            .id(library.catalogScopeID)
        #endif
    }

    private var tabSelection: Binding<FoundationDestination> {
        Binding(
            get: { selectedTab },
            set: { destination in
                selectedTabByUser = true
                #if os(macOS)
                    openedItem = nil
                    showingFavorites = false
                    macNavigationRevision += 1
                #endif
                selectedTab = destination
                if destination == .search { searchActivation += 1 }
            })
    }

    #if os(iOS)
        private var hasCollectionOutcome: Bool {
            actions.isQueueLoading || actions.queueErrorMessage != nil || actions.queueNotice != nil
        }

        private var tabs: some View {
            TabView(selection: tabSelection) {
                ForEach(FoundationDestination.allCases, id: \.self) { destination in
                    Tab(value: destination, role: destination == .search ? .search : nil) {
                        NavigationStack {
                            browsingContent(destination)
                        }
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            // Unlike TabView's fixed-height accessory, this inset sizes and
                            // hit-tests the complete status above the native playback controls.
                            FoundationCollectionActionStatus(compactPresentation: true)
                                .background(.regularMaterial)
                        }
                        .id(library.catalogScopeID + String(destination.rawValue))
                    } label: {
                        Label {
                            Text(destination.title)
                        } icon: {
                            destination.icon
                                .symbolVariant(selectedTab == destination ? .fill : .none)
                        }
                    }
                }
            }
            .tabViewBottomAccessory(isEnabled: !displayedQueue.isEmpty) {
                FoundationMiniPlayerPlacement { inline in
                    miniPlayer(showNext: !inline)
                }
            }
        }
    #endif

    @ViewBuilder private func browsingContent(_ tab: FoundationDestination) -> some View {
        if displayedCatalogScope != library.catalogScopeID {
            ProgressView("Opening music library…")
        } else {
            destinationContent(tab)
                .id(library.catalogScopeID)
                #if os(iOS)
                    .toolbar(.visible, for: .tabBar)
                #endif
        }
    }

    @ViewBuilder private func destinationContent(_ destination: FoundationDestination) -> some View
    {
        if destination == .library {
            libraryContent
                #if DEBUG
                    .environment(\.foundationTraceOrigin, .library)
                #endif
        } else if destination == .new {
            FoundationNewView(
                profile: profileButton(isActive: catalogIsActive(.new)), library: library,
                player: player, tracks: recentTracks, albums: recentAlbums,
                isActive: catalogIsActive(.new)
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .new)
            #endif
        } else if destination == .search {
            FoundationSearchView(
                profile: profileButton(isActive: catalogIsActive(.search)),
                library: library, player: player, genres: searchGenres, query: $searchQuery,
                isActive: catalogIsActive(.search), activation: searchActivation
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .search)
            #endif
        } else {
            FoundationHomeView(
                profile: profileButton(isActive: catalogIsActive(.home)), library: library,
                player: player, recentTracks: homeHistory,
                favorites: homeFavorites, recentAlbums: recentAlbums, genres: homeGenres,
                isActive: catalogIsActive(.home), hasQueue: !displayedQueue.isEmpty,
                accountLibrary: accountLibrary
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .home)
            #endif
        }
    }

    private func resolveInitialConnection() {
        guard !initialConnectionResolved else { return }
        switch connectivity.status {
        case .checking, .connecting: return
        case .available, .unavailable, .restricted:
            initialConnectionResolved = true
            if connectivity.localOnly, !selectedTabByUser { selectedTab = .library }
        }
    }

    @ViewBuilder private var libraryContent: some View {
        #if os(macOS)
            macLibraryContent
        #else
            libraryHome
        #endif
    }

    #if os(macOS)
        @ViewBuilder private var macLibraryContent: some View {
            switch macLibraryRoute {
            case .overview:
                libraryHome
            case .favorites:
                FoundationFavoritesView(
                    library: library, player: player, isActive: catalogIsActive(.library))
            case .albums:
                FoundationLibraryIndexView(
                    kind: .album, model: albums, library: library, player: player,
                    isActive: catalogIsActive(.library))
            case .artists:
                FoundationLibraryIndexView(
                    kind: .artist, model: artists, library: library, player: player,
                    isActive: catalogIsActive(.library))
            case .songs:
                FoundationLibraryIndexView(
                    kind: .track, model: songs, library: library, player: player,
                    isActive: catalogIsActive(.library))
            case .genres:
                macGenreIndex
            case .playlists:
                FoundationPlaylistIndex(
                    library: library, player: player, isActive: catalogIsActive(.library),
                    model: playlists, usesLibraryIndex: true)
            case .downloads:
                FoundationDownloadsView(
                    library: library, player: player, isActive: catalogIsActive(.library))
            case .playlist(let item), .item(let item):
                FoundationItemDestination(
                    item: item, library: library, player: player,
                    isActive: catalogIsActive(.library))
            }
        }

        private var macGenreIndex: some View {
            FoundationGenreIndex(
                genres: genres, library: library, player: player,
                isActive: catalogIsActive(.library), loader: library.genres
            )
            .foundationCatalogHeader("Genres")
        }

        private func openMacLibrary(_ route: FoundationMacLibraryRoute) {
            macLibraryRoute = route
            tabSelection.wrappedValue = .library
        }

        private func macLibraryButton(
            _ title: String, symbol: String, route: FoundationMacLibraryRoute
        ) -> some View {
            Button {
                openMacLibrary(route)
            } label: {
                Label(title, systemImage: symbol)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                selectedTab == .library && macLibraryRoute == route
                    ? Color.accentColor : Color.primary
            )
            .accessibilityValue(
                selectedTab == .library && macLibraryRoute == route ? "Selected" : "")
        }

        @ViewBuilder private var macLibrarySidebar: some View {
            Section(isExpanded: $macLibraryExpanded) {
                macLibraryButton("Favorites", symbol: "star", route: .favorites)
                macLibraryButton("Albums", symbol: "opticaldisc", route: .albums)
                macLibraryButton("Artists", symbol: "music.mic", route: .artists)
                macLibraryButton("Songs", symbol: "music.note", route: .songs)
                macLibraryButton("Genres", symbol: "guitars", route: .genres)
            } header: {
                Text("Library")
            }
            Section(isExpanded: $macPlaylistsExpanded) {
                macLibraryButton(
                    "All Playlists", symbol: "music.note.square.stack", route: .playlists)
                ForEach(
                    connectivity.localOnly ? downloads.downloadedPlaylists : playlists.items
                ) { item in
                    macLibraryButton(
                        item.title, symbol: "music.note.list", route: .playlist(item))
                }
                if playlists.isLoading { ProgressView().controlSize(.small) }
            } header: {
                Text("Playlists")
            }
            if !downloads.downloadedSongs.isEmpty {
                Section {
                    macLibraryButton("Downloads", symbol: "arrow.down.circle", route: .downloads)
                }
            }
        }
    #endif

    private var pinnedColumns: [GridItem] {
        #if os(macOS)
            [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]
        #else
            Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
        #endif
    }

    private var libraryHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pinned").font(.title2.bold())
                    LazyVGrid(columns: pinnedColumns, alignment: .leading, spacing: 12) {
                        Button {
                            showingFavorites = true
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "star.fill").font(.title2.weight(.semibold))
                                Spacer(minLength: 0)
                                Text("Favorites").font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                LinearGradient(
                                    colors: [.pink, .red], startPoint: .topLeading,
                                    endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                            .aspectRatio(1, contentMode: .fit)
                        }.buttonStyle(.plain).accessibilityHint("Open Favorites")
                        ForEach(Array(actions.pins.enumerated()), id: \.offset) { _, item in
                            if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty
                            {
                                pinnedTile(item)
                            }
                        }
                    }
                    if let error = actions.pinErrorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Music").font(.title2.bold()).padding(.bottom, 4)
                    if library.catalogScopeID != "all" {
                        Text(
                            connectivity.localOnly
                                ? "Offline downloads include all music libraries."
                                : (librarySelection?.selectedName ?? "Selected music library")
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        FoundationLibraryIndexView(
                            kind: .album, model: albums, library: library, player: player,
                            isActive: catalogIsActive(.library))
                    } label: {
                        categoryRow(
                            "Albums", subtitle: "Browse your collection by album",
                            symbol: "opticaldisc.fill")
                    }.accessibilityIdentifier("library-category-albums")
                    NavigationLink {
                        FoundationLibraryIndexView(
                            kind: .artist, model: artists, library: library, player: player,
                            isActive: catalogIsActive(.library))
                    } label: {
                        categoryRow(
                            "Artists", subtitle: "Find music by artist", symbol: "music.mic")
                    }.accessibilityIdentifier("library-category-artists")
                    NavigationLink {
                        FoundationLibraryIndexView(
                            kind: .track, model: songs, library: library, player: player,
                            isActive: catalogIsActive(.library))
                    } label: {
                        categoryRow(
                            "Songs", subtitle: "See every song in your library",
                            symbol: "music.note")
                    }.accessibilityIdentifier("library-category-songs")
                    NavigationLink {
                        FoundationPlaylistIndex(
                            library: library, player: player, isActive: catalogIsActive(.library),
                            model: playlists, usesLibraryIndex: true
                        )
                        #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                        #endif
                    } label: {
                        categoryRow(
                            "Playlists", subtitle: "Collections from all music libraries",
                            symbol: "music.note.list")
                    }.accessibilityIdentifier("library-category-playlists")
                    NavigationLink {
                        #if os(macOS)
                            macGenreIndex
                        #else
                            FoundationLibraryIndexView(
                                kind: .genre, model: genres, library: library, player: player,
                                isActive: catalogIsActive(.library))
                        #endif
                    } label: {
                        categoryRow(
                            "Genres", subtitle: "Browse albums by genre", symbol: "guitars")
                    }.accessibilityIdentifier("library-category-genres")
                    NavigationLink {
                        FoundationDownloadsView(
                            library: library, player: player, isActive: catalogIsActive(.library))
                    } label: {
                        categoryRow(
                            "Downloads", subtitle: "Saved music from all music libraries",
                            symbol: "arrow.down.circle")
                    }.accessibilityIdentifier("library-category-downloads")
                }
                FoundationLibraryMostPlayedAlbums(
                    model: mostPlayedAlbums, library: library, player: player,
                    isActive: catalogIsActive(.library))
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }
        .buttonStyle(.plain)
        .foundationHeader("Library", profile: profileButton(isActive: catalogIsActive(.library)))
        .navigationDestination(isPresented: $showingFavorites) {
            FoundationFavoritesView(
                library: library, player: player, isActive: catalogIsActive(.library)
            )
            .id(library.catalogScopeID)
            #if os(iOS)
                .toolbar(.visible, for: .navigationBar)
            #endif
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: catalogIsActive(.library)
        )
    }

    private func pinnedTile(_ item: FoundationItem) -> some View {
        FoundationCollectionSourceButton(item: item, action: { openedItem = item }) {
            VStack(alignment: .leading) {
                Spacer(minLength: 24)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .foregroundStyle(.white)
                    FoundationDownloadBadge(item: item).foregroundStyle(.white)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .background {
                GeometryReader { geometry in
                    FoundationCatalogArtwork(
                        item: item, library: library,
                        isActive: catalogIsActive(.library), size: geometry.size.width
                    )
                    .id(item.sharedArtworkIdentity)
                    .foundationCollectionArtworkSource(item: item)
                    .overlay {
                        LinearGradient(
                            colors: [.black.opacity(0.05), .black.opacity(0.8)],
                            startPoint: .top, endPoint: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityHint("Open pinned item")
        .contextMenu {
            FoundationItemMenu(
                item: item, actions: actions, initialFavorite: item.isFavorite,
                open: { openedItem = item }, library: library, player: player,
                navigate: { openedItem = $0 })
        }
    }

    private func profileButton(isActive: Bool) -> some View {
        Button {
            #if os(macOS)
                appModel.settingsShowsSignIn = appModel.requiresSignIn || profileName.isEmpty
                openSettings()
            #else
                showingSettings = true
            #endif
        } label: {
            #if os(macOS)
                HStack(spacing: 10) {
                    loadedProfileImage(isActive: isActive)
                        .padding(4)
                        .background {
                            if macReduceTransparency { Circle().fill(.background) }
                        }
                        .glassEffect(macReduceTransparency ? .identity : .regular, in: .circle)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profileName.isEmpty ? "Profile" : profileName)
                            .font(.body.weight(.medium)).lineLimit(1)
                        Text("Profile & Settings").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8).contentShape(Rectangle())
            #else
                loadedProfileImage(isActive: isActive)
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
        #if os(macOS)
            .help("Profile and settings (⌘,)")
        #endif
    }

    private func loadedProfileImage(isActive: Bool) -> some View {
        FoundationProfileImage(
            library: library, isActive: isActive && !connectivity.localOnly,
            onAuthenticationFailure: {
                #if os(macOS)
                    appModel.requireMacSignIn()
                #endif
            },
            onLoaded: { name, image in
                profileName = name
                profileImage = image
                #if os(macOS)
                    appModel.profileName = name
                    appModel.profileImage = image
                #endif
            })
    }

    private func categoryRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title + ", " + subtitle)
    }

    #if os(macOS)
        private var macTransport: some View {
            let item = displayedQueue.first { $0.id == displayedEntryID }?.item
            return FoundationMacTransport(
                player: player, item: item, state: displayedState,
                lyricsEnabled: item != nil && !connectivity.localOnly,
                lyricsSelected: showingPlayer && macPanel == .lyrics,
                queueSelected: showingPlayer && macPanel == .queue,
                toggleLyrics: { toggleMacPanel(.lyrics) },
                toggleQueue: { toggleMacPanel(.queue) },
                navigate: { openMacLibrary(.item($0)) },
                artwork: {
                    if let item {
                        FoundationCatalogArtwork(
                            source: .current(currentArtwork.result(for: item)),
                            item: item.catalogArtworkItem, library: library,
                            isActive: true, size: 40
                        ).id(item.sharedArtworkIdentity)
                    }
                }
            )
        }

        private func toggleMacPanel(_ mode: FoundationMacPlaybackPanel.Mode) {
            if showingPlayer && macPanel == mode {
                showingPlayer = false
            } else {
                macPanel = mode
                showingPlayer = true
            }
        }

        private var macActions: FoundationMacActions {
            FoundationMacActions(
                navigate: { tabSelection.wrappedValue = $0 },
                togglePlayback: { player.togglePlayback() },
                previous: { player.previous() }, next: { player.next() },
                queue: { toggleMacPanel(.queue) }, lyrics: { toggleMacPanel(.lyrics) },
                hasSelection: displayedEntryID != nil, canAdvance: player.canAdvance,
                canShowLyrics: displayedEntryID != nil && !connectivity.localOnly)
        }
    #endif

    private func miniPlayer(showNext: Bool = true) -> some View {
        let item = displayedQueue.first { $0.id == displayedEntryID }?.item
        return HStack(spacing: 10) {
            Button {
                showingPlayer = true
            } label: {
                HStack(spacing: 10) {
                    Group {
                        if let item {
                            let cover = item.catalogArtworkItem
                            FoundationCatalogArtwork(
                                source: .current(currentArtwork.result(for: item)),
                                item: cover, library: library, isActive: true, size: 34
                            ).id(cover.sharedArtworkIdentity)
                        } else {
                            Image(systemName: "music.note").frame(width: 34, height: 34)
                        }
                    }
                    #if os(iOS)
                        .foundationPlayerArtworkRegistration(
                            role: .compact, identity: item?.sharedArtworkIdentity,
                            cornerRadius: 6)
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item?.title ?? "Nothing Playing").font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(
                            displayedState == .playing
                                ? (item?.subtitle ?? "") : displayedState.label
                        )
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                {
                    #if os(macOS)
                        "Show playback sidebar"
                    #else
                        "Show Now Playing"
                    #endif
                }()
            )
            .accessibilityIdentifier(
                showNext ? "foundation-mini-player-normal" : "foundation-mini-player-minimized"
            )
            #if os(iOS)
                .accessibilityFocused($miniPlayerFocused)
            #endif
            .accessibilityValue(
                [item?.title, item?.subtitle, displayedState.label].compactMap { $0 }.filter {
                    !$0.isEmpty
                }.joined(separator: ", "))
            #if os(macOS)
                Button {
                    player.previous()
                } label: {
                    Image(systemName: "backward.fill").frame(width: 28, height: 32)
                }
                .buttonStyle(.plain).disabled(displayedEntryID == nil)
                .help("Previous track (⌘←)").accessibilityLabel("Previous")
            #endif
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).disabled(displayedEntryID == nil)
            .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
            .accessibilityIdentifier("foundation-mini-playback-toggle")
            if showNext {
                Button {
                    player.next()
                } label: {
                    Image(systemName: "forward.fill").frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(
                    displayedEntryID == nil || displayedEntryID == displayedQueue.last?.id
                )
                .accessibilityLabel("Next")
            }
            #if os(macOS)
                Divider().frame(height: 24)
                Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                Slider(
                    value: Binding(get: { player.playerVolume }, set: { player.playerVolume = $0 }),
                    in: 0...1
                )
                .frame(width: 90).accessibilityLabel("Player volume").help("Player volume")
                FoundationAirPlayPicker(player: player).frame(width: 30, height: 32)
                Button {
                    toggleMacPanel(.lyrics)
                } label: {
                    Image(systemName: "quote.bubble").frame(width: 28, height: 32)
                }
                .buttonStyle(.plain).disabled(displayedEntryID == nil || connectivity.localOnly)
                .foregroundStyle(
                    showingPlayer && macPanel == .lyrics ? Color.accentColor : Color.primary
                )
                .help("Lyrics (⇧⌘L)").accessibilityLabel("Show lyrics")
                .accessibilityAddTraits(showingPlayer && macPanel == .lyrics ? .isSelected : [])
                Button {
                    toggleMacPanel(.queue)
                } label: {
                    Image(systemName: "list.bullet").frame(width: 28, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    showingPlayer && macPanel == .queue ? Color.accentColor : Color.primary
                )
                .help("Queue (⇧⌘Q)").accessibilityLabel("Show queue")
                .accessibilityAddTraits(showingPlayer && macPanel == .queue ? .isSelected : [])
            #endif
        }.padding(.horizontal, showNext ? 10 : 6).padding(.vertical, showNext ? 6 : 0)
            #if os(iOS)
                .foundationPlayerSurfaceRegistration(identity: item?.sharedArtworkIdentity)
                .matchedTransitionSource(id: "now-playing", in: playerTransition) { source in
                    source.clipShape(.rect(cornerRadius: showNext ? 28 : 22))
                }
            #endif
    }
}

/// Each favorite type owns its cursor so a large album collection cannot hide favorite songs.
struct FoundationFavoritesView: View {
    @EnvironmentObject private var actions: FoundationLibraryActions
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach([FoundationItem.Kind.track, .album, .artist, .playlist], id: \.self) {
                    kind in
                    FoundationFavoriteShelf(
                        kind: kind, library: library, player: player, isActive: isActive)
                }
            }.padding(.vertical, 12)
        }
        .foundationCatalogHeader("Favorites")
        .accessibilityIdentifier("favorites-catalog")
        .onDisappear { actions.cancelQueueAddition() }
    }
}

private struct FoundationFavoriteShelf: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshOnActivation = true
    let kind: FoundationItem.Kind
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @StateObject private var model = FoundationBrowseModel()
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var songRowHeight = 76.0
    @State private var isVisible = false
    @State private var revision = 0
    @State private var needsRefresh = false
    @State private var openedItem: FoundationItem?
    private var displayedItems: [FoundationItem] { actions.favoriteItems(in: model.items) }
    private var title: String {
        switch kind {
        case .album: "Albums"
        case .artist: "Artists"
        case .playlist: "Playlists"
        default: "Songs"
        }
    }
    private var hasMore: Bool { model.nextStartIndex != nil || displayedItems.count > 6 }

    private var favoritesActivation: Bool {
        isActive && isVisible && scenePhase == .active && !connectivity.localOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink {
                FoundationCatalogView(
                    title: "Favorite " + title, model: model, library: library, player: player,
                    isActive: isActive, isFavorites: true, showsTrackArtwork: true
                ) { try await library.favorites(kind: kind, startIndex: $0) }
            } label: {
                HStack {
                    Text(title).font(.title2.bold())
                    if hasMore {
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                    }
                }.foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .disabled(!hasMore)
            .accessibilityIdentifier("favorites-see-all-" + kind.rawValue)
            .padding(.horizontal, 16)
            if !displayedItems.isEmpty {
                ScrollView(.horizontal) {
                    if kind == .track {
                        LazyHGrid(
                            rows: Array(repeating: GridItem(.fixed(songRowHeight)), count: 3),
                            spacing: 16
                        ) {
                            ForEach(
                                Array(model.items.enumerated()).filter {
                                    actions.favoriteState(
                                        for: $0.element, initial: $0.element.isFavorite) != false
                                }.prefix(6), id: \.offset
                            ) {
                                index, item in
                                FoundationLibraryItemRow(
                                    item: item, library: library, isActive: isActive && isVisible,
                                    open: { openedItem = item }, play: { play(index) },
                                    player: player,
                                    showsTrackArtwork: true, navigate: { openedItem = $0 }
                                )
                                .lineLimit(1).frame(
                                    width: dynamicTypeSize.isAccessibilitySize ? 360 : 300)
                            }
                        }.padding(.horizontal, 16)
                    } else {
                        LazyHStack(alignment: .top, spacing: 18) {
                            ForEach(displayedItems.prefix(6)) { item in
                                FoundationCollectionCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 }
                                )
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 160)
                            }
                        }.padding(.horizontal, 16)
                    }
                }.scrollIndicators(.hidden)
                    .foundationMacContainedShelf()
            } else if model.isLoading {
                FoundationLoadingPlaceholder(layout: kind == .track ? .rows : .albumGrid)
                    .padding(.horizontal, 16)
            } else if model.loaded {
                Text(
                    model.nextStartIndex == nil
                        ? "No favorite " + title.lowercased() + " yet."
                        : "No favorites in this page. Open the full list to load more."
                )
                .foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            if let error = model.errorMessage {
                VStack(alignment: .leading) {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") {
                        model.request(model.retryRequest)
                        revision += 1
                    }.disabled(connectivity.localOnly)
                }.padding(.horizontal, 16)
            }
        }
        .accessibilityIdentifier("favorites-section-" + kind.rawValue)
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .onAppear {
            isVisible = true
            model.configureCatalogPagination()
            if needsRefresh {
                needsRefresh = false
                model.request(.refresh)
                revision += 1
            }
        }
        .onDisappear {
            isVisible = false
            refreshOnActivation = true
        }
        .onChange(of: favoritesActivation) { _, active in
            if !active { refreshOnActivation = true }
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            // The full destination shares this model and owns its visible refresh.
            guard isVisible else {
                needsRefresh = true
                return
            }
            model.request(.refresh)
            revision += 1
        }
        .task(
            id:
                "\(isActive && isVisible && scenePhase == .active)-\(connectivity.localOnly)-\(revision)"
        ) {
            guard isActive, isVisible, scenePhase == .active, !connectivity.localOnly else {
                return
            }
            if favoritesActivation, refreshOnActivation {
                refreshOnActivation = false
                if model.loaded { model.request(.refresh) }
            }
            model.configureFavoriteObservations(actions, knownFavorites: true)
            await model.loadPending { try await library.favorites(kind: kind, startIndex: $0) }
        }
    }

    private func play(_ index: Int) {
        guard let selection = actions.favoriteTrackQueue(in: model.items, selecting: index) else {
            return
        }
        if connectivity.localOnly {
            guard downloads.isReady(selection.items[selection.index]) else { return }
            let ready = selection.items.filter { downloads.isReady($0) }
            let selected = selection.items.prefix(selection.index).filter { downloads.isReady($0) }
                .count
            player.setQueue(ready, selectedIndex: selected)
        } else {
            player.setQueue(selection.items, selectedIndex: selection.index)
        }
    }
}

struct FoundationCatalogView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshOnActivation = true
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var actions: FoundationLibraryActions
    let title: String
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var isFavorites = false
    var showsTrackArtwork = false
    var headerItem: FoundationItem?
    var localItems: (() -> [FoundationItem])? = nil
    @State private var detailTint = Color(white: 0.12)
    @State private var isVisible = false
    let loader: (Int) async throws -> FoundationPage
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    private var favoritesActivation: Bool {
        isActive && isVisible && scenePhase == .active && !connectivity.localOnly
    }

    var body: some View {
        Group {
            if showsCollectionGrid {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let headerItem {
                            identityHeader(headerItem)
                            #if os(iOS)
                                FoundationOverviewSection(
                                    item: headerItem, library: library,
                                    isActive: isActive && isVisible
                                ).id(headerItem.id)
                            #endif
                            FoundationArtistMostPlayed(
                                artist: headerItem, library: library, player: player,
                                isActive: isActive && isVisible, navigate: { openedItem = $0 }
                            ).id(headerItem.id + "-most-played")
                            Text("Albums").font(.title2.bold()).frame(
                                maxWidth: .infinity, alignment: .leading
                            ).padding()
                        }
                        if displayedItems.isEmpty, model.isLoading, !connectivity.localOnly {
                            FoundationLoadingPlaceholder(layout: .albumGrid).padding()
                        } else {
                            LazyVGrid(
                                columns: foundationCollectionColumns(for: dynamicTypeSize),
                                alignment: .leading, spacing: 22
                            ) {
                                ForEach(Array(displayedItems.enumerated()), id: \.offset) {
                                    _, item in
                                    collectionCard(item)
                                }
                            }.padding()
                        }
                        VStack(alignment: .leading, spacing: 12) { pageState }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        if let headerItem, headerItem.kind == .artist {
                            FoundationRelatedSection(
                                title: "Appears On", isActive: isActive && isVisible,
                                loader: {
                                    try await library.appearances(
                                        artistID: headerItem.id, startIndex: $0)
                                },
                                card: { collectionCard($0) }
                            ).id(headerItem.id + "-appearances")
                            FoundationRelatedSection(
                                title: "More Like This", isActive: isActive && isVisible,
                                loader: { _ in
                                    try await library.similarItems(for: headerItem)
                                },
                                card: { collectionCard($0) }
                            ).id(headerItem.id + "-similar")
                        }

                    }
                }
            } else {
                List {
                    if let headerItem { identityHeader(headerItem).listRowSeparator(.hidden) }
                    resultRows
                    pageState
                }
            }
        }
        #if DEBUG
            .onAppear {
                FoundationTrace.event(
                    "surface origin=\(traceOrigin.rawValue) page=catalog event=appeared")
            }
            .onDisappear {
                FoundationTrace.event(
                    "surface origin=\(traceOrigin.rawValue) page=catalog event=disappeared")
            }
        #endif
        .foundationDetailPresentation(title: title, immersive: headerItem != nil, tint: detailTint)
        .preference(
            key: FoundationOfflineSurfacePreferenceKey.self,
            value: isActive && isVisible && headerItem != nil ? detailTint : nil
        )
        .modifier(FoundationDetailTitle(item: headerItem))
        .toolbar {
            #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    if !relatedItemSheet { catalogActions }
                }
            #else
                if !relatedItemSheet { catalogActions }
            #endif
        }
        .overlay(alignment: .topTrailing) {
            if relatedItemSheet, headerItem != nil {
                FoundationImmersiveCollectionActions { catalogActions }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear {
            actions.cancelQueueAddition()
            isVisible = false
            refreshOnActivation = true
        }
        .onChange(of: favoritesActivation) { _, active in
            if !active { refreshOnActivation = true }
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            if isFavorites, isActive, isVisible {
                model.request(.refresh)
                revision += 1
            }
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .task(
            id:
                "favorite-\(library.catalogScopeID)-\(headerItem?.id ?? "")-\(isActive && isVisible && scenePhase == .active)-\(connectivity.localOnly)-\(revision)"
        ) {
            guard isActive, isVisible, scenePhase == .active, !connectivity.localOnly,
                let headerItem, headerItem.kind == .artist
            else { return }
            await actions.resolveFavorite(for: headerItem) { [library, headerItem] in
                try await library.itemDetails(for: headerItem)
            }
        }
        .onChange(of: connectivity.localOnly ? localItems?() : nil) { _, items in
            if let items { model.installSnapshot(items) }
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            model.request(.refresh)
            revision += 1
        }
        .task(
            id:
                "\(isActive && isVisible && scenePhase == .active)-\(connectivity.localOnly)-\(revision)"
        ) {
            guard isActive, isVisible, scenePhase == .active else { return }
            if isFavorites, favoritesActivation, refreshOnActivation {
                refreshOnActivation = false
                if model.loaded { model.request(.refresh) }
            }
            model.configureFavoriteObservations(actions, knownFavorites: isFavorites)
            if connectivity.localOnly, let localItems {
                model.installSnapshot(localItems())
                return
            }
            if !connectivity.localOnly, localItems != nil, model.isRetainedSnapshot {
                model.request(.refresh)
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .catalog) {
                    await model.refreshVisible(
                        allowsNetwork: !connectivity.localOnly, using: loader)
                }
            #else
                await model.refreshVisible(allowsNetwork: !connectivity.localOnly, using: loader)
            #endif
        }
    }

    @ViewBuilder private var catalogActions: some View {
        if let headerItem {
            if relatedItemSheet, headerItem.kind == .artist {
                Button {
                    actions.togglePin(headerItem)
                } label: {
                    Image(systemName: actions.isPinned(headerItem) ? "pin.fill" : "pin")
                }
                .accessibilityLabel(actions.isPinned(headerItem) ? "Unpin artist" : "Pin artist")
                .accessibilityIdentifier("related-artist-pin")
            } else {
                Menu {
                    FoundationItemMenu(
                        item: headerItem, actions: actions, initialFavorite: headerItem.isFavorite,
                        library: library, player: player)
                } label: {
                    Image(systemName: "ellipsis")
                }.foundationEllipsisMenuIndicator().accessibilityLabel("More actions")
            }
        }
    }

    private var displayedItems: [FoundationItem] {
        isFavorites ? actions.favoriteItems(in: model.items) : model.items
    }

    private var showsCollectionGrid: Bool {
        headerItem?.kind == .artist
            || (!displayedItems.isEmpty
                && displayedItems.allSatisfy { $0.kind == .album || $0.kind == .playlist })
    }

    private func identityHeader(_ item: FoundationItem) -> some View {
        FoundationDetailHero(
            item: item, library: library, isActive: isActive && isVisible, tint: $detailTint
        ) {
            FoundationDetailActions(item: item, library: library, player: player)
        }
    }

    private var hasVisibleItems: Bool {
        if !connectivity.localOnly { return !displayedItems.isEmpty }
        return displayedItems.contains {
            $0.kind == .track || !downloads.browseTracks(for: $0).isEmpty
        }
    }

    @ViewBuilder private var pageState: some View {
        if connectivity.hasConnectionIssue || model.hasConnectionIssue { FoundationOfflineNotice() }
        if let error = actions.pinErrorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if !connectivity.localOnly, model.loaded, displayedItems.isEmpty {
            Text(
                model.nextStartIndex == nil
                    ? "No items found." : "No matches in this page. Load more to continue.")
        }
        if let error = model.errorMessage, !model.hasConnectionIssue {
            Text(error).foregroundStyle(.red)
            Button("Retry") { reload(model.retryRequest) }.disabled(connectivity.localOnly)
        }
        if !connectivity.localOnly, model.isLoading,
            !showsCollectionGrid || !displayedItems.isEmpty
        {
            FoundationLoadingPlaceholder(layout: showsCollectionGrid ? .albumGrid : .rows)
        }
        if model.nextStartIndex != nil {
            Button("Load more") { reload(.more) }.disabled(
                model.isLoading || connectivity.localOnly)
        }
    }

    private func collectionCard(_ item: FoundationItem) -> some View {
        FoundationCollectionCard(
            item: item, library: library, player: player,
            isActive: isActive && isVisible, showsSubtitle: headerItem?.kind != .artist,
            open: { openedItem = item }, navigate: { openedItem = $0 })
    }

    private var resultRows: some View {
        ForEach(
            Array(model.items.enumerated()).filter {
                !isFavorites
                    || actions.favoriteState(for: $0.element, initial: $0.element.isFavorite)
                        != false
            }, id: \.offset
        ) { index, item in
            resultRow(item, at: index)
        }
    }

    private func resultRow(_ item: FoundationItem, at index: Int) -> some View {
        FoundationLibraryItemRow(
            item: item, library: library, isActive: isActive && isVisible,
            open: { openedItem = item },
            play: item.kind == .track
                ? {
                    if let selection = isFavorites
                        ? actions.favoriteTrackQueue(in: model.items, selecting: index)
                        : model.trackQueue(selecting: index)
                    {
                        if connectivity.localOnly {
                            guard downloads.isReady(item) else { return }
                            let ready = selection.items.filter { downloads.isReady($0) }
                            let selected = selection.items.prefix(selection.index).filter {
                                downloads.isReady($0)
                            }.count
                            player.setQueue(ready, selectedIndex: selected)
                        } else {
                            player.setQueue(selection.items, selectedIndex: selection.index)
                        }
                    }
                } : nil, player: player, showsTrackArtwork: showsTrackArtwork || isFavorites,
            navigate: { openedItem = $0 }, currentPageKind: headerItem?.kind)
    }

    private func reload(_ request: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        model.request(request)
        revision += 1
    }
}

/// Shared cover grids retain readable titles at accessibility text sizes.
func foundationCollectionColumns(for size: DynamicTypeSize) -> [GridItem] {
    [
        GridItem(
            .adaptive(
                minimum: size.isAccessibilitySize ? 240 : 140,
                maximum: size.isAccessibilitySize ? 320 : 240), spacing: 18)
    ]
}

struct FoundationCollectionCard: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var showsSubtitle = true
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)?
    @EnvironmentObject private var actions: FoundationLibraryActions

    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity

    var body: some View {
        if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty {
            VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 6) {
                FoundationCollectionSourceButton(item: item, action: open) {
                    if item.kind == .artist {
                        FoundationCatalogArtwork(
                            item: item, library: library, isActive: isActive, size: 150
                        ).id(item.sharedArtworkIdentity)
                            .foundationCollectionArtworkSource(item: item)
                    } else {
                        GeometryReader { geometry in
                            FoundationCatalogArtwork(
                                item: item, library: library, isActive: isActive,
                                size: geometry.size.width
                            ).id(item.sharedArtworkIdentity)
                                .foundationCollectionArtworkSource(item: item)
                        }.aspectRatio(1, contentMode: .fit)
                    }
                }.buttonStyle(.plain).accessibilityLabel("View " + item.title)
                Button {
                    open()
                } label: {
                    VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.title).font(.headline).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            FoundationDownloadBadge(item: item)
                        }
                        if showsSubtitle, !item.subtitle.isEmpty {
                            Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .frame(
                        maxWidth: .infinity, alignment: item.kind == .artist ? .center : .leading
                    )
                    .multilineTextAlignment(item.kind == .artist ? .center : .leading)
                }.buttonStyle(.plain)
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }.contextMenu {
                FoundationItemMenu(
                    item: item, actions: actions, initialFavorite: item.isFavorite,
                    open: open, library: library, player: player, navigate: navigate)
            }

        }
    }

}

struct FoundationLibraryItemRow: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    let open: () -> Void
    var play: (() -> Void)?
    var player: FoundationPlayer?
    var showsTrackArtwork = false
    var navigate: ((FoundationItem) -> Void)?
    var currentPageKind: FoundationItem.Kind?
    var subtitleOverride: String? = nil
    var isPlayable = true
    var availabilityMessage: String? = nil
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity

    private var artworkItem: FoundationItem { showsTrackArtwork ? item.catalogArtworkItem : item }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                FoundationCollectionSourceButton(
                    item: item,
                    action: {
                        if let play {
                            guard
                                !connectivity.localOnly || item.kind != .track
                                    || downloads.isReady(item)
                            else { return }
                            play()
                        } else {
                            open()
                        }
                    }
                ) {
                    HStack(spacing: 12) {
                        if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty {
                            FoundationCatalogArtwork(
                                item: artworkItem, library: library, isActive: isActive
                            )
                            .id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
                            .foundationCollectionArtworkSource(item: item)
                        }
                        VStack(alignment: .leading) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title)
                                if item.kind != .track { FoundationDownloadBadge(item: item) }
                            }
                            if let availabilityMessage {
                                Text(availabilityMessage).font(.caption).foregroundStyle(.secondary)
                            }
                            let subtitle = subtitleOverride ?? item.subtitle
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(
                        !isPlayable
                            || (connectivity.localOnly && item.kind == .track
                                && !downloads.isReady(item))
                    )
                if item.kind == .track { FoundationDownloadBadge(item: item) }
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .foundationEllipsisMenuIndicator()
                .accessibilityLabel("Actions for " + item.title)
            }
            if let error = actions.errorMessage(for: item) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .contextMenu { menu }
    }

    private var menu: some View {
        FoundationItemMenu(
            item: item, actions: actions, initialFavorite: item.isFavorite,
            open: item.kind == .track ? nil : open, play: play, library: library, player: player,
            navigate: navigate, currentPageKind: currentPageKind
        )
    }
}

struct FoundationItemDestination: View {
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @EnvironmentObject private var connectivity: FoundationConnectivity

    var body: some View {
        Group {
            switch item.kind {
            case .artist:
                FoundationArtistView(
                    artist: item, library: library, player: player, isActive: isActive)
            case .genre:
                FoundationGenreView(
                    genre: item, library: library, player: player, isActive: isActive)
            case .album, .playlist:
                FoundationCollectionView(
                    item: item, library: library, player: player, isActive: isActive)
            case .track:
                FoundationTrackList(
                    title: item.title, tracks: downloads.collectionModel(for: item),
                    player: player, library: library, isActive: isActive
                ) { _ in .init(items: [item], nextStartIndex: nil) }
            }
        }.id(item.id)
            .onDisappear { actions.cancelQueueAddition() }
            #if DEBUG
                .onAppear {
                    FoundationTrace.event(
                        "destination origin=\(traceOrigin.rawValue) kind=\(String(describing: item.kind)) event=appeared"
                    )
                }
                .onDisappear {
                    FoundationTrace.event(
                        "destination origin=\(traceOrigin.rawValue) kind=\(String(describing: item.kind)) event=disappeared"
                    )
                }
            #endif
    }
}

private struct FoundationArtistView: View {
    let artist: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @EnvironmentObject private var downloads: FoundationDownloads
    @StateObject private var albums = FoundationBrowseModel()

    var body: some View {
        FoundationCatalogView(
            title: artist.title, model: albums, library: library, player: player,
            isActive: isActive, headerItem: artist,
            localItems: { downloads.downloadedAlbums(artistID: artist.id) },
            loader: { try await library.albums(artistID: artist.id, startIndex: $0) }
        )
    }
}

private struct FoundationCollectionView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @State private var refreshRevision = 0
    @EnvironmentObject private var playlistChanges: FoundationPlaylistChanges
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @State private var managingPlaylist = false
    @State private var playlistName: String?
    @Environment(\.dismiss) private var dismiss

    private var tracks: FoundationBrowseModel { downloads.collectionModel(for: item) }

    private var displayItem: FoundationItem {
        var copy = item
        copy.title = playlistName ?? item.title
        return copy
    }

    var body: some View {
        FoundationTrackList(
            title: displayItem.title, tracks: tracks, player: player, library: library,
            isActive: isActive,
            collection: displayItem,
            playlistRevision: item.kind == .playlist
                ? playlistChanges.revision(for: item.id) : 0,
            refreshRevision: refreshRevision,
            managePlaylist: item.kind == .playlist ? { managingPlaylist = true } : nil,
            loader: { offset in
                if item.kind == .playlist {
                    return try await library.playlistTracks(
                        playlistID: item.id, startIndex: offset)
                }
                return try await library.tracks(albumID: item.id, startIndex: offset)
            }
        )
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline { managingPlaylist = false }
        }
        .sheet(
            isPresented: $managingPlaylist,
            onDismiss: {
                guard !connectivity.localOnly else { return }
                refreshRevision += 1
            },
            content: {
                FoundationPlaylistEditor(
                    playlist: displayItem, onDeleted: { dismiss() },
                    onRenamed: { playlistName = $0 }, library: library)
            })
    }
}

struct FoundationTrackList: View {
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var actions: FoundationLibraryActions
    let title: String
    @ObservedObject var tracks: FoundationBrowseModel
    let player: FoundationPlayer
    let library: any FoundationLibrary
    let isActive: Bool
    var collection: FoundationItem?
    var playlistRevision = 0
    var refreshRevision = 0
    var managePlaylist: (() -> Void)? = nil
    var localItems: (() -> [FoundationItem])? = nil
    @State private var loadedPlaylistRevision = 0
    @State private var loadedRefreshRevision = 0
    @State private var detailTint = Color(white: 0.12)
    let loader: (Int) async throws -> FoundationPage
    @State private var revision = 0
    @State private var isVisible = false
    @State private var openedCollection: FoundationItem?

    var body: some View {
        List {
            if let collection {
                collectionHeader(collection)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if connectivity.hasConnectionIssue || tracks.hasConnectionIssue {
                FoundationOfflineNotice().listRowBackground(Color.clear)
            }
            if connectivity.localOnly, let collection,
                !downloads.hasCompleteCollectionSnapshot(for: collection), !tracks.items.isEmpty
            {
                Text(
                    "Only previously known tracks are available. Connect to load the full collection."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(tracks.items.enumerated()), id: \.offset) { index, item in
                let artworkItem = item.catalogArtworkItem
                let albumTitle =
                    item.album?.title ?? (collection?.kind == .album ? collection?.title : nil)
                    ?? ""
                let subtitle = [item.subtitle, albumTitle]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
                VStack(alignment: .leading) {
                    HStack {
                        Button {
                            play(index)
                        } label: {
                            HStack {
                                if collection == nil {
                                    FoundationCatalogArtwork(
                                        item: artworkItem, library: library,
                                        isActive: isActive && isVisible
                                    )
                                    .id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
                                } else {
                                    Text("\(index + 1)").font(.subheadline)
                                        .foregroundStyle(.secondary).monospacedDigit()
                                        .frame(minWidth: 24, alignment: .leading)
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.body.weight(.medium))
                                        .lineLimit(2)
                                    if !subtitle.isEmpty {
                                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if connectivity.localOnly, !downloads.isReady(item) {
                                        Label("Not downloaded", systemImage: "icloud.slash")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(connectivity.localOnly && !downloads.isReady(item))
                            .opacity(connectivity.localOnly && !downloads.isReady(item) ? 0.5 : 1)
                            .accessibilityIdentifier("collection-track-\(index)")
                            .accessibilityLabel(item.title)
                            .accessibilityValue(
                                connectivity.localOnly && !downloads.isReady(item)
                                    ? "Not downloaded, unavailable offline" : "")
                        Spacer(minLength: 8)
                        FoundationDownloadBadge(item: item)
                            .accessibilityIdentifier("collection-track-download-\(index)")
                        Menu {
                            trackMenu(item, index: index)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .menuStyle(.borderlessButton)
                        .foundationEllipsisMenuIndicator()
                        .accessibilityLabel("Actions for " + item.title)
                        .accessibilityIdentifier("collection-track-actions-\(index)")
                    }
                    if let error = actions.errorMessage(for: item) {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(collection == nil ? nil : .white.opacity(0.12))
                .contextMenu { trackMenu(item, index: index) }
            }
            Group {
                if !connectivity.localOnly, tracks.loaded, tracks.items.isEmpty {
                    Text("No tracks found.")
                }
                if let error = tracks.errorMessage, !tracks.hasConnectionIssue {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { reload(tracks.retryRequest) }.disabled(connectivity.localOnly)
                }
                if !connectivity.localOnly, tracks.isLoading { FoundationLoadingPlaceholder() }
                if tracks.nextStartIndex != nil {
                    Button("Load more tracks") { reload(.more) }.disabled(
                        tracks.isLoading || connectivity.localOnly)
                }
            }
            .listRowBackground(Color.clear)
            if let collection, collection.kind == .album {
                FoundationRelatedSection(
                    title: "More Like This", isActive: isActive && isVisible, twoRows: true,
                    loader: { _ in try await library.similarItems(for: collection) },
                    card: { item in
                        FoundationCollectionCard(
                            item: item, library: library, player: player,
                            isActive: isActive && isVisible, open: { openedCollection = item },
                            navigate: { openedCollection = $0 })
                    }
                )
                .id(collection.id + "-similar")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        #if os(macOS)
            .contentMargins(collection == nil ? 8 : 0, for: .scrollContent)
        #endif
        .foundationDetailPresentation(title: title, immersive: collection != nil, tint: detailTint)
        .preference(
            key: FoundationOfflineSurfacePreferenceKey.self,
            value: isActive && isVisible && collection != nil ? detailTint : nil
        )
        .modifier(FoundationDetailTitle(item: collection))
        .accessibilityIdentifier(
            collection.map { "collection-detail-\($0.kind)-\($0.id)" } ?? "track-list"
        )
        .task(
            id:
                "favorite-\(library.catalogScopeID)-\(collection?.id ?? "")-\(isActive && isVisible)-\(connectivity.localOnly)-\(revision)"
        ) {
            guard isActive, isVisible, !connectivity.localOnly, let collection,
                collection.kind == .album
            else { return }
            await actions.resolveFavorite(for: collection) { [library, collection] in
                try await library.itemDetails(for: collection)
            }
        }
        .toolbar {
            #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    if !relatedItemSheet { collectionActions }
                }
            #else
                if !relatedItemSheet { collectionActions }
            #endif
        }
        .overlay(alignment: .topTrailing) {
            if relatedItemSheet, collection != nil {
                FoundationImmersiveCollectionActions { collectionActions }
            }
        }
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            actions.cancelQueueAddition()
            isVisible = false
        }
        .onChange(of: connectivity.localOnly ? localItems?() : nil) { _, items in
            if let items { tracks.installSnapshot(items) }
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            tracks.request(.refresh)
            revision += 1
        }
        // One appearance-owned task loads collection content on both platforms.
        // Do not wait for a separate onAppear state update or race a parent loader.
        .task(id: [
            isActive ? 1 : 0, connectivity.localOnly ? 1 : 0, revision,
            playlistRevision, refreshRevision,
        ]) {
            guard isActive, !Task.isCancelled else { return }
            if connectivity.localOnly {
                if let localItems { tracks.installSnapshot(localItems()) }
                return
            }
            if localItems != nil, tracks.isRetainedSnapshot { tracks.request(.refresh) }
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .tracks) {
                    await loadTracks()
                }
            #else
                await loadTracks()
            #endif
        }
        .foundationCollectionDestination(
            item: $openedCollection, library: library, player: player, isActive: isActive)
    }

    @ViewBuilder private var collectionActions: some View {
        if let collection {
            #if os(iOS)
                FoundationDownloadActionButton(
                    item: collection, iconFont: collectionActionFont)
            #endif
            Menu {
                if let managePlaylist {
                    Button("Edit Playlist", systemImage: "pencil", action: managePlaylist)
                        .disabled(!library.supportsPlaylistManagement || connectivity.localOnly)
                    Divider()
                }
                if collection.kind == .album {
                    FoundationRelatedDestinations(
                        item: collection, navigate: { openedCollection = $0 },
                        currentPageKind: .album)
                    Divider()
                }
                FoundationItemMenu(
                    item: collection, actions: actions, initialFavorite: collection.isFavorite,
                    library: library, player: player)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(
                        width: relatedItemSheet ? 48 : nil,
                        height: relatedItemSheet ? 48 : nil)
            }.foundationEllipsisMenuIndicator().accessibilityLabel("More actions")
        }
    }

    private var collectionActionFont: Font {
        #if os(macOS)
            .title3
        #else
            relatedItemSheet ? .title3 : .caption
        #endif
    }

    private func loadTracks() async {
        guard !connectivity.localOnly else { return }
        defer {
            if !Task.isCancelled, tracks.errorMessage == nil, !tracks.isLoading,
                let collection, !tracks.items.isEmpty || tracks.loaded
            {
                downloads.rememberCollection(
                    collection, tracks: tracks.items,
                    complete: tracks.loaded && tracks.nextStartIndex == nil)
            }
        }
        if (collection != nil && tracks.isRetainedSnapshot)
            || loadedPlaylistRevision != playlistRevision
            || loadedRefreshRevision != refreshRevision
        {
            await tracks.load(.refresh, using: loader)
            if !Task.isCancelled, tracks.errorMessage == nil {
                loadedPlaylistRevision = playlistRevision
                loadedRefreshRevision = refreshRevision
            }
        } else {
            await tracks.loadPending(
                ifActive: isActive, waitForInitialLoad: collection != nil, using: loader)
        }
    }

    private func collectionHeader(_ item: FoundationItem) -> some View {
        VStack(spacing: 0) {
            FoundationDetailHero(
                item: item, library: library, isActive: isActive && isVisible, tint: $detailTint
            ) {
                FoundationDetailActions(item: item, library: library, player: player)
            }
            #if os(iOS)
                if item.kind == .album {
                    FoundationOverviewSection(
                        item: item, library: library, isActive: isActive && isVisible
                    ).id(item.id)
                }
            #endif
        }
    }

    private func trackMenu(_ item: FoundationItem, index: Int) -> some View {
        FoundationItemMenu(
            item: item, actions: actions, initialFavorite: item.isFavorite,
            play: { play(index) }, player: player, navigate: { openedCollection = $0 },
            currentPageKind: collection?.kind
        )
    }

    private func reload(_ next: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        tracks.request(next)
        revision += 1
    }
    private func play(_ index: Int) {
        guard tracks.items.indices.contains(index) else { return }
        if connectivity.localOnly {
            guard downloads.isReady(tracks.items[index]) else { return }
            let ready = tracks.items.filter { downloads.isReady($0) }
            let selected = tracks.items.prefix(index).filter { downloads.isReady($0) }.count
            player.setQueue(ready, selectedIndex: selected)
        } else {
            player.setQueue(tracks.items, selectedIndex: index)
        }
    }
}

/// Optional account artwork belongs to the visible profile entry point only.
private struct FoundationProfileImage: View {
    let library: any FoundationLibrary
    let isActive: Bool
    var onAuthenticationFailure: () -> Void = {}
    let onLoaded: (String, Image?) -> Void
    @State private var image: Image?
    @State private var initial = ""
    @State private var completed = false
    @State private var isVisible = false

    var body: some View {
        Group {
            #if os(macOS)
                Group {
                    if let image {
                        image.resizable().scaledToFill()
                    } else if !initial.isEmpty {
                        Text(initial).font(.body.weight(.medium))
                    } else {
                        Image(systemName: "person.crop.circle").font(.title3)
                    }
                }
                .frame(width: 28, height: 28).clipShape(Circle())
            #else
                ZStack {
                    Circle().fill(.quaternary)
                    if let image {
                        image.resizable().scaledToFill()
                    } else if !initial.isEmpty {
                        Text(initial).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 32).clipShape(Circle())
                .overlay(Circle().strokeBorder(.background, lineWidth: 2))
                .frame(width: 44, height: 44)
            #endif
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isActive && isVisible) {
            guard isActive, isVisible, !completed, !Task.isCancelled else { return }
            do {
                let profile = try await library.profile()
                try Task.checkCancellation()
                initial = String(profile.name.prefix(1)).uppercased()
                let decoded = await Task.detached(priority: .utility) {
                    profile.image.flatMap {
                        FoundationCurrentArtwork.decode($0, maximumPixels: 160)
                    }
                }.value
                try Task.checkCancellation()
                image = decoded.map { Image(decorative: $0.image, scale: 1) }
                onLoaded(profile.name, image)
                completed = true
            } catch {
                if !Task.isCancelled {
                    completed = true
                    if FoundationLibraryError.category(error) == .authentication {
                        onAuthenticationFailure()
                    }
                }
            }
        }
    }
}

/// The same native scroll-driven header belongs to each root tab.
extension View {
    func foundationHeader<Profile: View>(_ title: String, profile: Profile) -> some View {
        modifier(
            FoundationScreenHeader(
                title: title, profile: profile, search: EmptyView(), searchHeight: 0))
    }

    func foundationSearchHeader<Profile: View, Search: View>(
        profile: Profile, search: Search, keepsVisible: Bool
    ) -> some View {
        modifier(
            FoundationScreenHeader(
                title: "Search", profile: profile, search: search,
                searchHeight: 60, keepsVisible: keepsVisible))
    }
}

private struct FoundationScreenHeader<Profile: View, Search: View>: ViewModifier {
    let title: String
    let profile: Profile
    let search: Search
    let searchHeight: CGFloat
    var keepsVisible = false
    @State private var headerVisible = true
    @State private var isAtTop = true
    @State private var legacyMaterialOpacity = 0.0
    @State private var isDraggingHeaderScroll = false

    private var showsHeader: Bool { headerVisible || keepsVisible }

    func body(content: Content) -> some View {
        #if os(iOS)
            headerLayout(content)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .onScrollPhaseChange { _, phase in
                    isDraggingHeaderScroll = phase == .interacting
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    let end = max(
                        0,
                        geometry.contentSize.height + geometry.contentInsets.top
                            + geometry.contentInsets.bottom - geometry.containerSize.height)
                    return min(end, max(0, geometry.contentOffset.y + geometry.contentInsets.top))
                } action: { previous, current in
                    isAtTop = current == 0
                    if #unavailable(iOS 26.0) {
                        legacyMaterialOpacity = min(1, current / 32)
                    }
                    if isAtTop {
                        headerVisible = true
                    } else if isDraggingHeaderScroll, current != previous {
                        headerVisible = current < previous
                    }
                }
        #else
            content.navigationTitle(title)
                .safeAreaInset(edge: .top) { search.frame(height: searchHeight) }
                .foundationMacTransportClearance()
        #endif
    }

    #if os(iOS)
        @ViewBuilder private func headerLayout(_ content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .safeAreaBar(edge: .top, spacing: 0) {
                        visibleHeader(headerContent)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .scrollEdgeEffectHidden(!showsHeader || isAtTop, for: .top)
            } else {
                content
                    .contentMargins(.top, 56 + searchHeight, for: .scrollContent)
                    .overlay(alignment: .top) {
                        visibleHeader(headerContent.background { legacyBackground })
                    }
            }
        }

        private var headerContent: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Spacer()
                    profile
                }.padding(.horizontal, 16).frame(height: 56)
                search.frame(height: searchHeight)
            }
        }

        private func visibleHeader<Header: View>(_ header: Header) -> some View {
            // Opacity preserves the bar's safe-area height during direction changes.
            header.opacity(showsHeader ? 1 : 0)
                .allowsHitTesting(showsHeader)
                .accessibilityHidden(!showsHeader)
                .animation(.easeOut(duration: 0.18), value: showsHeader)
        }

        private var legacyBackground: some View {
            GeometryReader { geometry in
                let topInset = geometry.safeAreaInsets.top
                Rectangle().fill(.regularMaterial)
                    .frame(height: geometry.size.height + topInset + 32)
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(
                                colors: [.black, .clear], startPoint: .top, endPoint: .bottom
                            ).frame(height: 32)
                        }
                    }
                    .offset(y: -topInset)
                    .opacity(legacyMaterialOpacity)
            }.allowsHitTesting(false)
        }
    #endif
}

/// Presentation-only skeletons share the content geometry and fade toward the end.
struct FoundationLoadingPlaceholder: View {
    enum Layout { case rows, genreCards, albumShelf, albumGrid }
    var layout: Layout = .rows
    var rowCount = 4
    var rowSpacing = 16.0
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        shapes
            .foregroundStyle(.quaternary)
            .transaction { $0.animation = nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .accessibilityIdentifier("loading-placeholder-\(layout)")
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .primary.opacity(0.16), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.55)
                        .phaseAnimator([false, true]) { content, bright in
                            content.offset(
                                x: bright ? geometry.size.width : -geometry.size.width * 0.55)
                        } animation: { bright in
                            bright ? .linear(duration: 1.4) : nil
                        }
                    }
                    .mask(shapes.transaction { $0.animation = nil })
                    .accessibilityHidden(true)
                }
            }
            .allowsHitTesting(false)
    }

    @ViewBuilder private var shapes: some View {
        switch layout {
        case .rows:
            VStack(spacing: rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8).frame(width: 48, height: 48)
                        textLines
                        Spacer(minLength: 0)
                    }.opacity(max(0.3, 1 - Double(index) / Double(max(1, rowCount)) * 0.7))
                }
            }
        case .genreCards:
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                ForEach(0..<6) { index in
                    RoundedRectangle(cornerRadius: 12)
                        .aspectRatio(1.6, contentMode: .fit)
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? 150 : nil)
                        .opacity(1 - Double(index / 2) * 0.35)
                }
            }
        case .albumShelf:
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<3) { index in
                        album.frame(width: 140).opacity(1 - Double(index) * 0.35)
                    }
                }.frame(width: geometry.size.width, alignment: .leading).clipped()
            }.frame(height: 180)
        case .albumGrid:
            LazyVGrid(
                columns: foundationCollectionColumns(for: dynamicTypeSize),
                alignment: .leading, spacing: 22
            ) {
                ForEach(0..<rowCount, id: \.self) { index in
                    album.opacity(
                        max(0.3, 1 - Double(index) / Double(max(1, rowCount)) * 0.7))
                }
            }
        }
    }

    private var album: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12).aspectRatio(1, contentMode: .fit)
            textLines
        }
    }

    private var textLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4).frame(maxWidth: 180).frame(height: 12)
            RoundedRectangle(cornerRadius: 4).frame(maxWidth: 120).frame(height: 10)
        }
    }
}

/// One album shelf presentation shared by Home and New.
struct FoundationAlbumShelfCard: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)?
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity

    var body: some View {
        if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FoundationCollectionSourceButton(item: item, action: open) {
                    VStack(alignment: .leading, spacing: 8) {
                        FoundationCatalogArtwork(
                            item: item, library: library, isActive: isActive, size: 144
                        )
                        .id(item.sharedArtworkIdentity)
                        .foundationCollectionArtworkSource(item: item)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(
                                    dynamicTypeSize.isAccessibilitySize ? nil : 2)
                                FoundationDownloadBadge(item: item)
                            }
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(width: 144, alignment: .leading)
            .contextMenu {
                FoundationItemMenu(
                    item: item, actions: actions, initialFavorite: item.isFavorite,
                    open: open, library: library, player: player, navigate: navigate)
            }

        }
    }
}

/// The same canonical actions stay available without adding a sheet title bar.
private struct FoundationImmersiveCollectionActions<Controls: View>: View {
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        HStack(spacing: 4) { controls() }
            .font(.title3.weight(.semibold))
            .buttonStyle(FoundationImmersiveActionStyle())
            .padding(4)
            .background {
                if reduceTransparency { Capsule().fill(.background) }
            }
            .glassEffect(
                reduceTransparency ? .identity : .regular.tint(.black.opacity(0.22)), in: Capsule()
            )
            .environment(\.colorScheme, .dark)
            .tint(.white)
            .padding(.top, 24).padding(.trailing, 16)
    }
}

private struct FoundationImmersiveActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// Native destination headers retain back navigation and collapse with scrolling.
extension View {
    func foundationCatalogHeader(_ title: String) -> some View {
        self.navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                .toolbar(.visible, for: .navigationBar)
            #else
                .foundationMacTransportClearance()
            #endif
    }
}

/// One image-owned hero for album and artist destinations.
struct FoundationDetailHero<Controls: View>: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    @Binding var tint: Color
    @ViewBuilder let controls: () -> Controls
    @ScaledMetric(relativeTo: .title) private var imageSpace = 210.0
    @ScaledMetric(relativeTo: .title) private var artistImageSpace = 280.0

    var body: some View {
        heroContent
            .frame(maxWidth: .infinity).padding(.bottom, 24)
            .background {
                #if os(iOS)
                    GeometryReader { geometry in
                        ZStack(alignment: .top) {
                            tint
                            FoundationCatalogArtwork(
                                item: item, library: library, isActive: isActive,
                                size: geometry.size.width, sampledColor: $tint, isHero: true
                            )
                            .id(item.sharedArtworkIdentity)
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.1), location: 0),
                                    .init(
                                        color: tint.opacity(item.kind == .artist ? 0.12 : 0.25),
                                        location: item.kind == .artist ? 0.4 : 0.3),
                                    .init(color: tint.opacity(0.95), location: 0.65),
                                    .init(color: tint, location: 0.9),
                                ], startPoint: .top, endPoint: .bottom)
                            // Keep title and controls legible even over white album/artist artwork.
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.2),
                                    .init(color: .black.opacity(0.4), location: 0.55),
                                    .init(color: .black.opacity(0.2), location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                        }.clipped()
                    }
                #endif
            }
            .foregroundStyle(.white)
    }

    @ViewBuilder private var heroContent: some View {
        #if os(macOS)
            if item.kind == .album || item.kind == .artist {
                VStack(spacing: 20) {
                    HStack(alignment: .top, spacing: 24) {
                        FoundationCatalogArtwork(
                            item: item, library: library, isActive: isActive,
                            size: imageSpace, sampledColor: $tint, isHero: true
                        )
                        .frame(width: imageSpace, height: imageSpace)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title).font(.largeTitle.bold())
                                if !item.subtitle.isEmpty {
                                    Text(item.subtitle).font(.title3)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: FoundationDetailTitlePosition.self,
                                        value: [item.id: geometry.frame(in: .global).maxY])
                                }
                            }
                            FoundationOverviewSection(
                                item: item, library: library, isActive: isActive,
                                maximumLines: nil, horizontalInset: 0
                            )
                            .frame(maxHeight: .infinity, alignment: .top)
                            .id(item.id)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: imageSpace, alignment: .top)
                    }
                    controls().frame(maxWidth: .infinity)
                }
                .frame(maxWidth: 900).padding(.horizontal, 24).padding(.top, 24)
            } else {
                legacyHeroContent
            }
        #else
            legacyHeroContent
        #endif
    }

    private var legacyHeroContent: some View {
        VStack(spacing: 12) {
            #if os(macOS)
                FoundationCatalogArtwork(
                    item: item, library: library, isActive: isActive,
                    size: imageSpace, sampledColor: $tint, isHero: true
                )
                .frame(width: imageSpace, height: imageSpace)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            #else
                Color.clear.frame(height: item.kind == .artist ? artistImageSpace : imageSpace)
            #endif
            VStack(spacing: 12) {
                Text(item.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.subheadline).multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8)).padding(.horizontal, 20)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: FoundationDetailTitlePosition.self,
                        value: [item.id: geometry.frame(in: .global).maxY])
                }
            }
            controls().padding(.top, 8)
        }
    }

}

struct FoundationDetailActions: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    private var localBrowsing: Bool { connectivity.localOnly }
    private var cannotPlay: Bool {
        localBrowsing ? downloads.browseTracks(for: item).isEmpty : actions.isQueueLoading
    }

    private var playIconColor: Color {
        #if os(macOS)
            .white
        #else
            .black
        #endif
    }

    private func play(shuffled: Bool) {
        if localBrowsing {
            let tracks = downloads.browseTracks(for: item)
            guard !tracks.isEmpty else { return }
            player.setQueue(shuffled ? tracks.shuffled() : tracks, selectedIndex: 0)
        } else {
            actions.play(item, shuffled: shuffled, library: library, player: player)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                Button {
                    play(shuffled: true)
                } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }.foundationDetailButton().disabled(cannotPlay).accessibilityLabel(
                    "Shuffle")
                Button {
                    play(shuffled: false)
                } label: {
                    Image(systemName: "play.fill").font(.title).foregroundStyle(playIconColor)
                        .frame(width: 72, height: 72)
                }.foundationDetailButton(prominent: true).disabled(cannotPlay)
                    .accessibilityLabel("Play")
                let favorite = actions.favoriteState(for: item, initial: item.isFavorite)
                Button {
                    guard !localBrowsing, let favorite else { return }
                    Task {
                        guard !localBrowsing else { return }
                        await actions.setFavorite(for: item, isFavorite: !favorite)
                    }
                } label: {
                    Image(systemName: favorite == true ? "star.fill" : "star")
                        .frame(width: 44, height: 44)
                }.foundationDetailButton()
                    .disabled(localBrowsing || favorite == nil || actions.isPending(item))
                    .accessibilityLabel(favorite == true ? "Unfavorite" : "Favorite")
            }
            if let error = actions.errorMessage(for: item) {
                Text(error).font(.caption).foregroundStyle(.white).padding(.horizontal)
            }
        }
    }
}

#if os(macOS)
    private struct FoundationMacDetailButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.contentShape(Circle())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }

    private struct FoundationMacDetailButton: ViewModifier {
        @Environment(\.foundationReduceTransparency) private var reduceTransparency

        func body(content: Content) -> some View {
            content.buttonStyle(FoundationMacDetailButtonStyle())
                .background {
                    if reduceTransparency { Circle().fill(.background) }
                }
                .glassEffect(reduceTransparency ? .identity : .clear.interactive(), in: .circle)
        }
    }
#endif

extension View {
    @ViewBuilder fileprivate func foundationDetailButton(prominent: Bool = false) -> some View {
        #if os(macOS)
            self.modifier(FoundationMacDetailButton())
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                if prominent {
                    self.buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(.white)
                } else {
                    self.buttonStyle(.glass).buttonBorderShape(.circle)
                }
            } else {
                self.buttonStyle(.plain)
                    .background(prominent ? Color.white : Color.white.opacity(0.16), in: Circle())
            }
        #endif
    }

    func foundationDetailPresentation(title: String, immersive: Bool, tint: Color) -> some View {
        modifier(FoundationDetailPresentation(title: title, immersive: immersive, tint: tint))
    }
}

/// Measure the actual hero text and native toolbar, independent of image or text height.
private struct FoundationDetailTitlePosition: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { current, _ in current })
    }
}

struct FoundationDetailTitle: ViewModifier {
    let item: FoundationItem?
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @State private var titleBottom = CGFloat.greatestFiniteMagnitude
    @State private var toolbarBottom = CGFloat.zero

    private var collapsed: Bool { toolbarBottom > 0 && titleBottom <= toolbarBottom }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(FoundationDetailTitlePosition.self) { positions in
                if let item, let bottom = positions[item.id] { titleBottom = bottom }
            }
            #if os(iOS)
                .toolbar {
                    if let item, item.kind == .album || item.kind == .artist {
                        if #available(iOS 26.0, *) {
                            titleToolbar(item).sharedBackgroundVisibility(.hidden)
                        } else {
                            titleToolbar(item)
                        }
                    }
                }
            #endif
    }

    private func titleToolbar(_ item: FoundationItem) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ZStack {
                // Keep the title position stable while the visible text transitions.
                title(item).hidden().accessibilityHidden(true)
                if collapsed {
                    title(item)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity
                                    .combined(with: .scale(scale: 0.92, anchor: .bottom))
                                    .combined(with: .offset(y: 10)))
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.frame(in: .global).maxY
            } action: {
                toolbarBottom = $0
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.9), value: collapsed
            )
            .allowsHitTesting(false)
        }
    }

    private func title(_ item: FoundationItem) -> some View {
        VStack(spacing: 1) {
            Text(item.title).font(.headline).lineLimit(1)
            if item.kind == .album, !item.subtitle.isEmpty {
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

/// Transition state belongs to the page that owns its existing destination binding.
struct FoundationCollectionTransitionContext: Sendable {
    let namespace: Namespace.ID
    let select: @MainActor @Sendable (FoundationItem, String) -> Void
}

private struct FoundationCollectionTransitionKey: EnvironmentKey {
    static let defaultValue: FoundationCollectionTransitionContext? = nil
}

private struct FoundationCollectionOccurrenceKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var foundationCollectionTransition: FoundationCollectionTransitionContext? {
        get { self[FoundationCollectionTransitionKey.self] }
        set { self[FoundationCollectionTransitionKey.self] = newValue }
    }
    var foundationCollectionOccurrence: String? {
        get { self[FoundationCollectionOccurrenceKey.self] }
        set { self[FoundationCollectionOccurrenceKey.self] = newValue }
    }
}

private struct FoundationCollectionSourceButton<Label: View>: View {
    let item: FoundationItem
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var occurrence = UUID().uuidString
    @Environment(\.foundationCollectionTransition) private var transition

    @Environment(\.foundationCollectionOccurrence) private var hostedOccurrence
    private var sourceID: String {
        item.sharedArtworkIdentity + "-" + (hostedOccurrence ?? occurrence)
    }

    var body: some View {
        Button {
            if item.kind == .album || item.kind == .playlist {
                transition?.select(item, sourceID)
            }
            action()
        } label: {
            label().environment(\.foundationCollectionOccurrence, sourceID)
        }
    }
}

private struct FoundationCollectionArtworkSource: ViewModifier {
    let item: FoundationItem
    @Environment(\.foundationCollectionTransition) private var transition
    @Environment(\.foundationCollectionOccurrence) private var occurrence

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
            if item.kind == .album || item.kind == .playlist,
                item.primaryImageTag != nil, let transition, let occurrence
            {
                content.matchedTransitionSource(id: occurrence, in: transition.namespace)
            } else {
                content
            }
        #else
            content
        #endif
    }
}

private struct FoundationCollectionDestination: ViewModifier {
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Binding var item: FoundationItem?
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @Namespace private var namespace
    @State private var sourceIdentity: String?
    @State private var sourceOccurrence: String?
    @Environment(\.foundationReduceMotion) private var reduceMotion

    private var context: FoundationCollectionTransitionContext {
        .init(namespace: namespace) { selected, occurrence in
            sourceIdentity = selected.sharedArtworkIdentity
            sourceOccurrence = selected.primaryImageTag == nil ? nil : occurrence
        }
    }

    func body(content: Content) -> some View {
        content.environment(\.foundationCollectionTransition, context)
            .navigationDestination(
                isPresented: Binding(
                    get: { item != nil }, set: { if !$0 { item = nil } })
            ) {
                if let item {
                    destination(item)
                }
            }
            .onChange(of: item?.sharedArtworkIdentity) { _, identity in
                actions.cancelQueueAddition()
                if identity == nil {
                    sourceIdentity = nil
                    sourceOccurrence = nil
                }
            }
    }

    @ViewBuilder private func destination(_ item: FoundationItem) -> some View {
        let page = FoundationItemDestination(
            item: item, library: library, player: player, isActive: isActive
        )
        .environment(\.foundationRelatedItemSheet, false)
        #if os(iOS)
            if !reduceMotion, sourceIdentity == item.sharedArtworkIdentity,
                let sourceOccurrence, item.kind == .album || item.kind == .playlist
            {
                page.navigationTransition(.zoom(sourceID: sourceOccurrence, in: namespace))
            } else {
                page
            }
        #else
            page
        #endif
    }
}

extension View {
    fileprivate func foundationCollectionArtworkSource(item: FoundationItem) -> some View {
        modifier(FoundationCollectionArtworkSource(item: item))
    }

    func foundationCollectionDestination(
        item: Binding<FoundationItem?>, library: any FoundationLibrary,
        player: FoundationPlayer, isActive: Bool
    ) -> some View {
        modifier(
            FoundationCollectionDestination(
                item: item, library: library, player: player, isActive: isActive))
    }
}

private struct FoundationDetailPresentation: ViewModifier {
    let title: String
    let immersive: Bool
    let tint: Color
    @ViewBuilder func body(content: Content) -> some View {
        if immersive {
            content
                #if os(macOS)
                    .navigationTitle(title)
                #else
                    .navigationTitle("")
                #endif
                .scrollContentBackground(.hidden)
                .foundationMacTransportClearance()
                .background { tint.overlay(.black.opacity(0.2)).ignoresSafeArea() }
                .environment(\.colorScheme, .dark)
                #if os(iOS)
                    .tint(.white)
                    .ignoresSafeArea(.container, edges: .top)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar(.visible, for: .navigationBar)
                #endif
        } else {
            content.foundationCatalogHeader(title)
        }
    }
}

extension View {
    @ViewBuilder fileprivate func foundationSettingsPresentation<Settings: View>(
        isPresented: Binding<Bool>, @ViewBuilder settings: @escaping () -> Settings
    ) -> some View {
        #if os(iOS)
            self.fullScreenCover(isPresented: isPresented, content: settings)
        #else
            self  // macOS uses the app-owned Settings scene.
        #endif
    }
}

/// Reads the destination modifier's existing namespace inside its content hierarchy.
struct FoundationCollectionTransitionReader<Content: View>: View {
    @Environment(\.foundationCollectionTransition) private var transition
    @ViewBuilder let content: (FoundationCollectionTransitionContext?) -> Content
    var body: some View { content(transition) }
}

#if os(iOS)
    /// Let the system accessory own both normal and scroll-minimized placement.
    private struct FoundationMiniPlayerPlacement<Content: View>: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
        @ViewBuilder let content: (Bool) -> Content

        var body: some View { content(placement == .inline) }
    }
#endif
