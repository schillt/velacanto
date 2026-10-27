import Combine
import SwiftUI

private struct FoundationCollectionOperationOwnerKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var foundationCollectionOperationOwner: UUID? {
        get { self[FoundationCollectionOperationOwnerKey.self] }
        set { self[FoundationCollectionOperationOwnerKey.self] = newValue }
    }
}

/// A collection outcome belongs to the visible surface that started its action.
private struct FoundationCollectionOutcomePresentation: ViewModifier {
    @EnvironmentObject private var actions: FoundationLibraryActions
    let owner: UUID?
    @State private var isVisible = false
    @State private var presentedOutcome: FoundationLibraryActions.CollectionOutcome?

    private var outcome: FoundationLibraryActions.CollectionOutcome? {
        isVisible ? actions.collectionOutcome(ownedBy: owner) : nil
    }

    func body(content: Content) -> some View {
        content
            .onAppear { isVisible = true }
            .onDisappear {
                isVisible = false
                presentedOutcome = nil
            }
            .onChange(of: outcome, initial: true) { _, next in presentedOutcome = next }
            .alert(
                presentedOutcome?.isError == true ? "Unable to Complete Action" : "Music",
                isPresented: Binding(
                    get: { presentedOutcome != nil },
                    set: { if !$0 { presentedOutcome = nil } }),
                presenting: presentedOutcome
            ) { presented in
                if presented.canRetry {
                    Button("Retry") {
                        guard outcome == presented else { return }
                        actions.retryQueueAddition(matching: presented)
                    }
                }
                Button("Dismiss", role: .cancel) {
                    guard outcome == presented else { return }
                    actions.dismissQueueOutcome(matching: presented)
                }
            } message: { presented in
                Text(presented.message)
            }
    }
}

extension View {
    func foundationCollectionOutcomePresentation(owner: UUID?) -> some View {
        modifier(FoundationCollectionOutcomePresentation(owner: owner))
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
    @Environment(\.foundationLocalLibrary) private var localLibrary
    @State private var showingLocalLibrary = false
    let library: any FoundationLibrary
    let accountLibrary: any FoundationLibrary
    let librarySelection: FoundationMusicLibrarySelection?
    let player: FoundationPlayer
    let signOut: () -> Void
    @State private var displayedQueue: [FoundationQueueEntry] = []
    #if os(iOS)
        @State private var bottomChromeGeometry = FoundationBottomChromeGeometry()
    #endif
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
    let primaryGenres: FoundationPrimaryGenresModel
    @StateObject private var recentTracks: FoundationBrowseModel
    @StateObject private var recentAlbums: FoundationBrowseModel
    @StateObject private var mostPlayedAlbums = FoundationBrowseModel()
    @StateObject private var homeHistory: FoundationBrowseModel
    @StateObject private var homeFavorites: FoundationBrowseModel
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
        @Environment(\.openSettings) private var openSettings
        @EnvironmentObject private var appModel: FoundationAppModel
        @State private var macPanel = FoundationMacPlaybackPanel.Mode.queue
        @State private var macQueuePresentation = 0
        @State private var macLibraryRoute = FoundationMacLibraryRoute.overview
        @State private var macNavigationRevision = 0
        @StateObject private var macNavigation = FoundationMacNavigation()
        @State private var macShellWidth = CGFloat.zero
        @State private var macTransportInset = CGFloat(120)
        @State private var macLibraryExpanded = true
        @State private var macPinsExpanded = true
        @State private var macPlaylistsExpanded = true
        @State private var macPlaylistSheet: MacPlaylistSheet?

        private enum MacPlaylistSheet: Identifiable {
            case create
            case addSongs(FoundationItem)
            case reorderSongs(FoundationItem)
            case manage(FoundationItem)
            case details(FoundationItem)

            var id: String {
                switch self {
                case .create: "create"
                case .addSongs(let item): "add-" + item.id
                case .reorderSongs(let item): "reorder-" + item.id
                case .manage(let item): "manage-" + item.id
                case .details(let item): "details-" + item.id
                }
            }
        }
    #endif
    @State private var showingSettings = false
    @State private var playlistSource: FoundationItem?
    @StateObject private var playlistChanges = FoundationPlaylistChanges()
    @State private var profileName = ""
    @State private var profileImage: Image?
    @State private var showingFavorites = false
    @State private var unavailableGenrePin = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.foundationHandoff) private var handoff
    @State private var openedItem: FoundationItem?
    @State private var offlineSurface: Color?

    init(
        library: any FoundationLibrary, accountLibrary: (any FoundationLibrary)? = nil,
        player: FoundationPlayer, primaryGenres: FoundationPrimaryGenresModel,
        signOut: @escaping () -> Void,
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
        _recentAlbums = StateObject(
            wrappedValue: Self.cachedModel(
                library.catalogPageCache, key: library.catalogCacheKey("recent-albums")))
        _recentTracks = StateObject(wrappedValue: Self.makeRecentTracksModel(library: library))
        self.primaryGenres = primaryGenres
    }

    private static func makeRecentTracksModel(library: any FoundationLibrary)
        -> FoundationBrowseModel
    {
        let model = FoundationBrowseModel()
        configureRecentTracksCache(model, library: library)
        return model
    }

    /// Initial construction and library changes must use the same grouped-music feed cache.
    static func configureRecentTracksCache(
        _ model: FoundationBrowseModel, library: any FoundationLibrary
    ) {
        model.clearRetainedData()
        model.configureCache(
            library.catalogPageCache, key: library.catalogCacheKey("date-added-ascending-v1"))
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
            shell
        }
        .sheet(isPresented: $showingLocalLibrary) {
            if let localLibrary { FoundationLocalLibraryView(model: localLibrary) }
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
        #if os(macOS)
            .onChange(of: showingPlayer && macPanel == .queue) { _, presented in
                if presented { macQueuePresentation += 1 }
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
                #if os(macOS)
                    macPlaylistSheet = nil
                #endif
                actions.cancelQueueAddition()
            }
        }
        .task { resolveInitialConnection() }
        .onChange(of: connectivity.status) { _, _ in resolveInitialConnection() }
        .onChange(of: playlistChanges.revisions) { _, _ in
            downloads.reconcilePlaylists()
        }
        .task(
            id:
                "playlist-catalog-\(playlistChanges.catalogRevision)-\(library.catalogScopeID)-\(connectivity.localOnly)"
        ) {
            guard playlistChanges.catalogRevision > 0, !connectivity.localOnly else { return }
            await playlists.load(.refresh, using: library.playlists)
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
                librarySelection: librarySelection, pinSync: actions.pinSync)
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
        .foundationCollectionOutcomePresentation(owner: nil)
        .foundationDownloadRemovalPresentation()
        .alert("Primary genre unavailable", isPresented: $unavailableGenrePin) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Build or refresh primary genres for this music library, then open the pin again. Your saved pin is retained."
            )
        }
        .environmentObject(primaryGenres)
        .environmentObject(playlistChanges)
        .onAppear {
            playlistChanges.configureTrackProjection(
                { items, albumID in actions.visibleTracks(items, albumID: albumID) },
                observe: { items, albumID in actions.observeTrackCopies(items, albumID: albumID) })
            for model in [
                albums, artists, songs, playlists, favorites, mostPlayedAlbums,
                homeHistory, homeFavorites, recentAlbums, recentTracks,
            ] {
                model.configureFavoriteObservations(actions)
            }
        }
        .environment(\.foundationAddToPlaylist, playlistPresentation)
        #if os(iOS)
            .environment(\.foundationPlayerArtworkPresentation, playerArtworkPresentation)
            .onChange(of: playerArtworkPresentation.isPlayerPresented) { wasPresented, presented in
                if wasPresented, !presented { miniPlayerFocused = true }
            }
        #endif
        .environment(\.foundationOpenLibrary, libraryPresentation)
        .background {
            if let handoff {
                FoundationHandoffRouteObserver(controller: handoff) { item in
                    selectedTab = .library
                    showingFavorites = false
                    #if os(macOS)
                        // The root collection binding may have no mounted observer
                        // on the current sidebar route. Route through the live stack.
                        openedItem = nil
                        actions.cancelQueueAddition()
                        macNavigation.continueBrowsing(item)
                    #else
                        openedItem = item
                    #endif
                }
            }
        }
        #if os(macOS)
            .environment(\.foundationMacNavigation, macNavigation)
            .focusedSceneValue(\.foundationMacActions, macActions)
            // A confirmed title update is metadata, not a new browsing destination.
            .onChange(of: macLibraryRoute.identity) { _, _ in actions.cancelQueueAddition() }
            .sheet(item: $macPlaylistSheet) { destination in
                switch destination {
                case .create:
                    FoundationPlaylistCreate(library: library)
                case .addSongs(let item):
                    FoundationPlaylistSongPicker(playlist: item, library: library)
                case .reorderSongs(let item):
                    FoundationPlaylistReorderSheet(playlist: item, library: library)
                case .manage(let item):
                    macPlaylistEditor(item, showsDetails: false)
                case .details(let item):
                    macPlaylistEditor(item, showsDetails: true)
                }
            }
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
            macPlaylistSheet = nil
            macNavigation.returnToRoot()
        #endif
        openedItem = nil
        showingFavorites = false
        searchQuery = ""
        for model in [albums, artists, songs, playlists, favorites, mostPlayedAlbums] {
            model.clearRetainedData()
        }
        for (model, key) in [
            (homeHistory, "home-history"), (homeFavorites, "home-favorites-collections-v1"),
            (recentAlbums, "recent-albums"),
        ] {
            model.clearRetainedData()
            model.configureCache(library.catalogPageCache, key: library.catalogCacheKey(key))
        }
        Self.configureRecentTracksCache(recentTracks, library: library)
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
            tabs.tabBarMinimizeBehavior(.onScrollDown)
        #else
            FoundationMacLibraryShell(
                selection: tabSelection, searchQuery: $searchQuery,
                searchActivation: searchActivation,
                libraryNavigationID: macLibraryRoute.identity,
                navigationRevision: macNavigationRevision,
                navigation: macNavigation,
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
            } destination: { item in
                FoundationItemDestination(
                    item: item, library: library, player: player,
                    isActive: scenePhase == .active
                )
                .environment(\.foundationRelatedItemSheet, false)
            } activateSearch: {
                handoff?.navigationChangedByUser()
                // Typing must not recreate the sidebar's native search field.
                macNavigation.returnToRoot()
                selectedTabByUser = true
                openedItem = nil
                showingFavorites = false
                selectedTab = .search
            }
            .inspector(isPresented: $showingPlayer) {
                FoundationMacPlaybackPanel(
                    player: player, library: accountLibrary, mode: macPanel,
                    queuePresentation: macQueuePresentation
                )
                .environment(\.foundationMacTransportBottomInset, 0)
                .environment(\.foundationMacUsesShellToolbar, false)
                // A meaningful, noninteractive title owns the inspector's native
                // toolbar section; Now Playing toggles still control presentation.
                .toolbar {
                    if showingPlayer {
                        ToolbarItem(placement: .principal) {
                            Text(macPanel.rawValue)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("mac-playback-inspector-title")
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
                .inspectorColumnWidth(
                    min: FoundationMacLayout.minimumInspectorWidth,
                    ideal: min(340, macMaximumInspectorWidth), max: macMaximumInspectorWidth)
            }
            .frame(
                minWidth: showingPlayer
                    ? FoundationMacLayout.minimumInspectingWindowWidth
                    : FoundationMacLayout.minimumWindowWidth,
                minHeight: 480
            )
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                macShellWidth = width
            }
            .environment(
                \.foundationMacTransportBottomInset,
                macTransportInset
            )
            .environment(\.foundationMacUsesShellToolbar, true)
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

    #if os(macOS)
        private var macMaximumInspectorWidth: CGFloat {
            guard macShellWidth > 0 else { return FoundationMacLayout.maximumInspectorWidth }
            return min(
                FoundationMacLayout.maximumInspectorWidth,
                max(
                    FoundationMacLayout.minimumInspectorWidth,
                    macShellWidth - FoundationMacLayout.minimumSplitWidth))
        }
    #endif

    private var tabSelection: Binding<FoundationDestination> {
        Binding(
            get: { selectedTab },
            set: { destination in
                handoff?.navigationChangedByUser()
                selectedTabByUser = true
                #if os(macOS)
                    macNavigation.returnToRoot()
                    openedItem = nil
                    showingFavorites = false
                    macNavigationRevision += 1
                #endif
                selectedTab = destination
                if destination == .search { searchActivation += 1 }
            })
    }

    #if os(iOS)
        private var tabs: some View {
            TabView(selection: tabSelection) {
                ForEach(FoundationDestination.allCases, id: \.self) { destination in
                    Tab(value: destination, role: destination == .search ? .search : nil) {
                        NavigationStack {
                            browsingContent(destination)
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
                FoundationMiniPlayerPlacement(geometry: bottomChromeGeometry) { inline in
                    miniPlayer(showNext: !inline)
                }
            }
            .modifier(
                FoundationBottomChromeHostProbe(
                    geometry: bottomChromeGeometry, hasAccessory: !displayedQueue.isEmpty))
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
                library: library, player: player, query: $searchQuery,
                isActive: catalogIsActive(.search), activation: searchActivation,
                openLocalLibrary: { showingLocalLibrary = true },
                isCurrentCatalog: { context in
                    composedCatalogIsCurrent(context) && catalogIsActive(.search)
                }
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .search)
            #endif
        } else {
            FoundationHomeView(
                profile: profileButton(isActive: catalogIsActive(.home)), library: library,
                player: player, recentTracks: homeHistory,
                favorites: homeFavorites, recentAlbums: recentAlbums,
                isActive: catalogIsActive(.home), hasQueue: !displayedQueue.isEmpty,
                accountLibrary: accountLibrary
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .home)
            #endif
        }
    }

    private var composedSongs: some View {
        FoundationComposedSongsView(
            query: .songs, library: library, player: player,
            isActive: catalogIsActive(.library), initialFilter: .jellyfin,
            openLocalLibrary: { showingLocalLibrary = true },
            isCurrent: { context in
                composedCatalogIsCurrent(context) && catalogIsActive(.library)
            },
            nativeIndex: { active, presented in
                FoundationLibraryIndexView(
                    kind: .track, model: songs, library: library, player: player, isActive: active,
                    showsContent: presented)
            })
    }

    private func composedCatalogIsCurrent(_ context: FoundationComposedCatalogModel.Context) -> Bool
    {
        guard context.catalogFilter == displayedCatalogScope else { return false }
        guard let jellyfin = library as? FoundationJellyfinLibrary else {
            return context.account == nil
        }
        guard context.account == jellyfin.catalogAccountIdentity,
            actions.acceptsCatalogAccount(jellyfin.catalogAccountIdentity)
        else { return false }
        if let librarySelection {
            return librarySelection.selectedID == jellyfin.musicLibraryID
                && librarySelection.unavailable == !jellyfin.catalogAvailable
        }
        return true
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
            case .pinned:
                macPinnedContent
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
                composedSongs
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
            FoundationPrimaryGenresView(
                library: library, player: player,
                isActive: catalogIsActive(.library), context: .cards
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
                Label {
                    Text(title).font(.system(size: 14)).lineLimit(1)
                } icon: {
                    Image(systemName: symbol).font(.system(size: 18))
                }
                .labelStyle(FoundationMacSidebarLabelStyle())
                .frame(
                    maxWidth: .infinity, minHeight: FoundationMacLayout.sidebarRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .foregroundStyle(
                selectedTab == .library && macLibraryRoute == route
                    ? Color.accentColor : Color.primary
            )
            .accessibilityValue(
                selectedTab == .library && macLibraryRoute == route ? "Selected" : "")
        }

        @ViewBuilder private var macLibrarySidebar: some View {
            Section(isExpanded: $macLibraryExpanded) {
                macPinnedSidebar
                macLibraryButton("Albums", symbol: "opticaldisc", route: .albums)
                macLibraryButton("Artists", symbol: "music.mic", route: .artists)
                macLibraryButton("Songs", symbol: "music.note", route: .songs)
                macLibraryButton("Genres", symbol: "guitars", route: .genres)
            } header: {
                HStack {
                    Text("Library")
                    Spacer()
                    localLibraryButton
                }
            }
            Section(isExpanded: $macPlaylistsExpanded) {
                macLibraryButton(
                    "All Playlists", symbol: "music.note.square.stack", route: .playlists)
                ForEach(
                    connectivity.localOnly ? downloads.downloadedPlaylists : playlists.items
                ) { item in
                    macLibraryButton(
                        item.title, symbol: "music.note.list", route: .playlist(item)
                    )
                    .contextMenu {
                        Button("Add Songs", systemImage: "plus") {
                            macPlaylistSheet = .addSongs(item)
                        }.disabled(connectivity.localOnly || !library.supportsPlaylistManagement)
                        Button("Reorder Songs", systemImage: "arrow.up.arrow.down") {
                            macPlaylistSheet = .reorderSongs(item)
                        }.disabled(connectivity.localOnly || !library.supportsPlaylistReordering)
                        Button("Manage Playlist", systemImage: "checklist") {
                            macPlaylistSheet = .manage(item)
                        }.disabled(connectivity.localOnly || !library.supportsPlaylistManagement)
                        Button("Playlist Details", systemImage: "pencil") {
                            macPlaylistSheet = .details(item)
                        }.disabled(connectivity.localOnly || !library.supportsPlaylistManagement)
                    }
                }
                if playlists.isLoading { ProgressView().controlSize(.small) }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Button("Create Playlist", systemImage: "plus") {
                        macPlaylistSheet = .create
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Create Playlist")
                    .disabled(connectivity.localOnly || !library.supportsPlaylistManagement)
                    .accessibilityIdentifier("mac-sidebar-create-playlist")
                }
            }
            if !downloads.downloadedSongs.isEmpty {
                Section {
                    macLibraryButton("Downloads", symbol: "arrow.down.circle", route: .downloads)
                }
            }
        }

        private func macPlaylistEditor(_ item: FoundationItem, showsDetails: Bool) -> some View {
            FoundationPlaylistEditor(
                playlist: item,
                onDeleted: {
                    switch macLibraryRoute {
                    case .playlist(let displayed), .item(let displayed):
                        if displayed.kind == .playlist && displayed.id == item.id {
                            openMacLibrary(.playlists)
                        }
                    default: break
                    }
                    if macNavigation.path.contains(where: {
                        $0.item.kind == .playlist && $0.item.id == item.id
                    }) {
                        macNavigation.returnToRoot()
                    }
                },
                onRenamed: { name in
                    switch macLibraryRoute {
                    case .playlist(let displayed) where displayed.id == item.id:
                        var renamed = displayed
                        renamed.title = name
                        macLibraryRoute = .playlist(renamed)
                    case .item(let displayed)
                    where displayed.kind == .playlist && displayed.id == item.id:
                        var renamed = displayed
                        renamed.title = name
                        macLibraryRoute = .item(renamed)
                    default: break
                    }
                    macNavigation.updatePlaylistTitle(id: item.id, name: name)
                },
                library: library, showsDetailsInitially: showsDetails)
        }

        private var macPinnedSidebar: some View {
            DisclosureGroup(isExpanded: $macPinsExpanded) {
                macLibraryButton("Favorites", symbol: "star", route: .favorites)
                ForEach(actions.pins) { item in
                    if item.kind == .genre || !connectivity.localOnly
                        || !downloads.browseTracks(for: item).isEmpty
                    {
                        macPinnedItemButton(item)
                    }
                }
            } label: {
                Label {
                    Text("Pinned").font(.system(size: 14)).lineLimit(1)
                } icon: {
                    Image(systemName: "pin").font(.system(size: 18))
                }
                .labelStyle(FoundationMacSidebarLabelStyle())
                .frame(
                    maxWidth: .infinity, minHeight: FoundationMacLayout.sidebarRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .accessibilityIdentifier("mac-sidebar-pinned-disclosure")
        }

        private func macPinnedItemButton(_ item: FoundationItem) -> some View {
            let selected: Bool
            if case .item(let current) = macLibraryRoute {
                selected =
                    selectedTab == .library && current.kind == item.kind && current.id == item.id
            } else {
                selected = false
            }
            return Button {
                guard let destination = pinnedDestination(item) else { return }
                openMacLibrary(.item(destination))
            } label: {
                HStack(spacing: 10) {
                    FoundationCatalogArtwork(
                        item: item.catalogArtworkItem, library: library,
                        isActive: scenePhase == .active, size: 24,
                        cornerRadius: item.kind == .artist ? 12 : 4
                    ).id(item.catalogArtworkItem.sharedArtworkIdentity)
                    Text(item.title).font(.system(size: 14)).lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity, minHeight: FoundationMacLayout.sidebarRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .accessibilityValue(selected ? "Selected" : "")
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

    #if os(macOS)
        private var macPinnedContent: some View {
            ScrollView {
                pinnedSection(showsTitle: false)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 20)
            }
            .foundationCatalogHeader("Pinned")
            .navigationDestination(isPresented: $showingFavorites) {
                FoundationFavoritesView(
                    library: library, player: player, isActive: catalogIsActive(.library))
            }
            .foundationCollectionDestination(
                item: $openedItem, library: library, player: player,
                isActive: catalogIsActive(.library))
        }
    #endif

    private func pinnedSection(showsTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle { Text("Pinned").font(.title2.bold()) }
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
                    if item.kind == .genre || !connectivity.localOnly
                        || !downloads.browseTracks(for: item).isEmpty
                    {
                        pinnedTile(item)
                    }
                }
            }
            if let error = actions.pinErrorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var localLibraryButton: some View {
        if localLibrary != nil {
            Button("Local Library", systemImage: "folder") { showingLocalLibrary = true }
                .labelStyle(.iconOnly)
                .help("Local Library")
                .accessibilityIdentifier("library-local-library")
        }
    }

    private var libraryHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pinnedSection()
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
                    categoryDivider
                    NavigationLink {
                        FoundationLibraryIndexView(
                            kind: .artist, model: artists, library: library, player: player,
                            isActive: catalogIsActive(.library))
                    } label: {
                        categoryRow(
                            "Artists", subtitle: "Find music by artist", symbol: "music.mic")
                    }.accessibilityIdentifier("library-category-artists")
                    categoryDivider
                    NavigationLink {
                        composedSongs
                    } label: {
                        categoryRow(
                            "Songs", subtitle: "See every song in your library",
                            symbol: "music.note")
                    }.accessibilityIdentifier("library-category-songs")
                    categoryDivider
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
                    categoryDivider
                    NavigationLink {
                        #if os(macOS)
                            macGenreIndex
                        #else
                            FoundationPrimaryGenresView(
                                library: library, player: player,
                                isActive: catalogIsActive(.library), context: .libraryRows
                            )
                            .foundationCatalogHeader("Genres")
                        #endif
                    } label: {
                        categoryRow(
                            "Genres", subtitle: "Browse albums by genre", symbol: "guitars")
                    }.accessibilityIdentifier("library-category-genres")
                    categoryDivider
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
                .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .buttonStyle(.plain)
        .foundationHeader("Library", profile: profileButton(isActive: catalogIsActive(.library)))
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { localLibraryButton }
            }
        #endif
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

    private func pinnedDestination(_ item: FoundationItem) -> FoundationItem? {
        guard item.kind == .genre else { return item }
        guard
            let current = primaryGenres.resolvePinnedGenre(
                item, libraryScope: library.primaryGenreIndexScope)
        else {
            unavailableGenrePin = true
            return nil
        }
        return current
    }

    private func pinnedTile(_ item: FoundationItem) -> some View {
        FoundationCollectionSourceButton(
            item: item, action: { openedItem = pinnedDestination(item) }
        ) {
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
                        isActive: catalogIsActive(.library), size: geometry.size.width,
                        cornerRadius: 0
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
                open: { openedItem = pinnedDestination(item) }, library: library, player: player,
                navigate: { openedItem = pinnedDestination($0) })
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

    private var categoryDivider: some View {
        Divider()
            .opacity(0.35)
            .padding(.leading, 50)
            .accessibilityHidden(true)
    }

    private func categoryRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2.weight(.medium))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 5)
            .contentShape(Rectangle())
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
                            isActive: true, size: FoundationMacLayout.transportContentHeight
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
                    FoundationMiniPlayerLabel(
                        title: item?.title ?? "Nothing Playing",
                        subtitle: displayedState == .playing
                            ? (item?.subtitle ?? "") : displayedState.label
                    ).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
    @State private var collectionOperationOwner = UUID()
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach([FoundationItem.Kind.playlist, .album, .track, .artist], id: \.self) {
                    kind in
                    FoundationFavoriteShelf(
                        kind: kind, library: library, player: player, isActive: isActive)
                }
            }.padding(.vertical, 12)
                .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .foundationCatalogHeader("Favorites")
        .accessibilityIdentifier("favorites-catalog")
        .environment(\.foundationCollectionOperationOwner, collectionOperationOwner)
        .foundationCollectionOutcomePresentation(owner: collectionOperationOwner)
        .onDisappear { actions.cancelQueueAdditionOwned(by: collectionOperationOwner) }
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
        guard
            let selection = actions.favoriteTrackQueue(
                in: model.items, selecting: index,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }
}

struct FoundationCatalogView: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
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
    var coverageMessage: String? = nil
    var localItems: (() -> [FoundationItem])? = nil
    @State private var detailTint = Color(white: 0.12)
    @State private var isVisible = false
    @State private var collectionOperationOwner = UUID()
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
                            // Realize the first song request with the hero, even on tall layouts.
                            VStack(spacing: 0) {
                                identityHeader(headerItem)
                                #if os(iOS)
                                    if headerItem.kind != .artist {
                                        FoundationOverviewSection(
                                            item: headerItem, library: library,
                                            isActive: isActive && isVisible
                                        ).id(headerItem.id)
                                    }
                                #endif
                                FoundationArtistSuggestedSongs(
                                    artist: headerItem, library: library, player: player,
                                    isActive: isActive && isVisible, navigate: { openedItem = $0 }
                                ).id(headerItem.id + "-suggested-songs")
                            }
                            Text("Albums").font(.title2.bold()).frame(
                                maxWidth: .infinity, alignment: .leading
                            ).padding()
                        }
                        Group {
                            if displayedItems.isEmpty, model.isLoading, !connectivity.localOnly {
                                FoundationLoadingPlaceholder(layout: .albumGrid).padding()
                                    .transition(.opacity)
                            } else {
                                LazyVGrid(
                                    columns: foundationCollectionColumns(for: dynamicTypeSize),
                                    alignment: .leading, spacing: 22
                                ) {
                                    ForEach(Array(displayedItems.enumerated()), id: \.offset) {
                                        _, item in
                                        collectionCard(item)
                                    }
                                }.padding().transition(.opacity)
                            }
                        }
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.22),
                            value: displayedItems.isEmpty)
                        VStack(alignment: .leading, spacing: 12) { pageState }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                        if !relatedItemSheet, let headerItem, headerItem.kind == .artist {
                            FoundationRelatedSection(
                                title: "Appears On", isActive: isActive && isVisible,
                                priority: .utility,
                                loader: {
                                    try await library.appearances(
                                        artistID: headerItem.id, startIndex: $0)
                                },
                                card: { collectionCard($0) }
                            ).id(headerItem.id + "-appearances")
                            FoundationRelatedSection(
                                title: "More Like This", isActive: isActive && isVisible,
                                priority: .utility,
                                loader: { _ in
                                    try await library.similarItems(for: headerItem)
                                },
                                card: { collectionCard($0) }
                            ).id(headerItem.id + "-similar")
                        }

                    }
                    .foundationBottomChromeEndPadding()
                }
                .foundationBottomChromeScrollClearance()
            } else {
                List {
                    if let headerItem { identityHeader(headerItem).listRowSeparator(.hidden) }
                    resultRows
                    pageState
                }
                .foundationBottomChromeListClearance()
                .listStyle(.plain)
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
        .foundationDetailPresentation(
            title: title, immersive: headerItem != nil, tint: detailTint,
            followsAppearance: headerItem?.kind == .artist
        )
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
        .environment(\.foundationCollectionOperationOwner, collectionOperationOwner)
        .foundationCollectionOutcomePresentation(owner: collectionOperationOwner)
        .onAppear { isVisible = true }
        .onDisappear {
            actions.cancelQueueAdditionOwned(by: collectionOperationOwner)
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
            if !connectivity.localOnly, localItems != nil, model.isRetainedSnapshot,
                !model.hasFreshCachedContent
            {
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
            if headerItem.kind == .artist {
                Button {
                    actions.togglePin(headerItem)
                } label: {
                    Image(systemName: actions.isPinned(headerItem) ? "pin.fill" : "pin")
                        .resizable().scaledToFit()
                        .frame(width: 16, height: 16)
                        .frame(width: 20, height: 20)
                }
                .accessibilityLabel(actions.isPinned(headerItem) ? "Unpin artist" : "Pin artist")
                .accessibilityIdentifier(relatedItemSheet ? "related-artist-pin" : "artist-pin")
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
        if let coverageMessage {
            Text(coverageMessage).font(.caption).foregroundStyle(.secondary)
        }
        if connectivity.hasConnectionIssue || model.hasConnectionIssue { FoundationOfflineNotice() }
        if let error = actions.pinErrorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if !connectivity.localOnly, model.loaded, displayedItems.isEmpty {
            Text(
                coverageMessage != nil
                    ? "No matches in the playlists checked."
                    : model.nextStartIndex == nil
                        ? "No items found." : "No matches in this page. Load more to continue.")
        }
        if let error = model.errorMessage, !model.hasConnectionIssue {
            Text(error).foregroundStyle(.red)
            Button("Retry") { reload(model.retryRequest) }.disabled(connectivity.localOnly)
        }
        if !connectivity.localOnly, model.isLoading,
            headerItem?.kind != .artist,
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
                ? { play(index) } : nil, player: player,
            showsTrackArtwork: showsTrackArtwork || isFavorites,
            navigate: { openedItem = $0 }, currentPageKind: headerItem?.kind
        )
        .foundationLibraryListRow()
    }

    private func play(_ index: Int) {
        let isAvailable: (FoundationItem) -> Bool = {
            !connectivity.localOnly || downloads.isReady($0)
        }
        guard
            let selection = isFavorites
                ? actions.favoriteTrackQueue(
                    in: model.items, selecting: index, isAvailable: isAvailable)
                : model.trackQueue(selecting: index, isAvailable: isAvailable)
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func reload(_ request: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        model.request(request)
        revision += 1
    }
}

/// Shared cover grids grow their columns at accessibility text sizes.
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
    var showsTrackArtwork = false
    var subtitleOverride: String? = nil
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)?
    @EnvironmentObject private var actions: FoundationLibraryActions

    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity

    private var artworkItem: FoundationItem { showsTrackArtwork ? item.catalogArtworkItem : item }
    private var subtitle: String { subtitleOverride ?? item.subtitle }

    var body: some View {
        if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty {
            VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 6) {
                FoundationCollectionSourceButton(item: item, action: open) {
                    if item.kind == .artist {
                        FoundationCatalogArtwork(
                            item: artworkItem, library: library, isActive: isActive, size: 150
                        ).id(artworkItem.sharedArtworkIdentity)
                            .foundationCollectionArtworkSource(item: item)
                    } else {
                        // The square owns its height; text never compresses the cover.
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay {
                                GeometryReader { geometry in
                                    FoundationCatalogArtwork(
                                        item: artworkItem, library: library, isActive: isActive,
                                        size: geometry.size.width
                                    ).id(artworkItem.sharedArtworkIdentity)
                                        .foundationCollectionArtworkSource(item: item)
                                }
                            }
                    }
                }.buttonStyle(.plain).accessibilityLabel("View " + item.title)
                Button {
                    open()
                } label: {
                    VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.title).font(.headline).lineLimit(1)
                                .truncationMode(.tail)
                            FoundationDownloadBadge(item: item)
                        }
                        if showsSubtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1, reservesSpace: true).truncationMode(.tail)
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
            }
            .fixedSize(horizontal: false, vertical: true)
            .contextMenu {
                FoundationItemMenu(
                    item: item, actions: actions, initialFavorite: item.isFavorite,
                    open: open, library: library, player: player, navigate: navigate)
            }

        }
    }

}

extension View {
    /// Match the native Library index rather than inheriting grouped-list row spacing.
    func foundationLibraryListRow() -> some View {
        self.padding(.vertical, 4)
            #if os(iOS)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            #endif
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
    var canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = { _ in true }
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
                        guard canPerform(play == nil ? .catalogPresence : .playback) else { return }
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
            navigate: navigate, currentPageKind: currentPageKind, canPerform: canPerform
        )
    }
}

struct FoundationItemDestination: View {
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    @Environment(\.foundationHandoff) private var handoff
    @State private var handoffOwner = UUID()
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
                if item.primaryGenreCensusID != nil {
                    FoundationPrimaryGenreDestination(
                        genre: item, library: library, player: player, isActive: isActive)
                } else if let current = primaryGenres.resolvePinnedGenre(
                    item, libraryScope: library.primaryGenreIndexScope)
                {
                    FoundationPrimaryGenreDestination(
                        genre: current, library: library, player: player, isActive: isActive)
                } else {
                    ContentUnavailableView(
                        "Primary genre index unavailable", systemImage: "music.note.list",
                        description: Text("Build or refresh primary genres for this music library.")
                    )
                }
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
            .onAppear { handoff?.beginBrowse(item, owner: handoffOwner) }
            .onDisappear { handoff?.endBrowse(owner: handoffOwner) }

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
    @StateObject private var albums: FoundationBrowseModel

    init(
        artist: FoundationItem, library: any FoundationLibrary, player: FoundationPlayer,
        isActive: Bool
    ) {
        self.artist = artist
        self.library = library
        self.player = player
        self.isActive = isActive
        _albums = StateObject(wrappedValue: Self.albumsModel(artist: artist, library: library))
    }

    private static func albumsModel(artist: FoundationItem, library: any FoundationLibrary)
        -> FoundationBrowseModel
    {
        let model = FoundationBrowseModel(usesCachedFreshness: true)
        model.configureCache(
            library.catalogPageCache, key: library.catalogCacheKey("artist-albums-" + artist.id))
        return model
    }

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
    @State private var playlistSheet: FoundationPlaylistSheet?
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
            managePlaylist: item.kind == .playlist ? { playlistSheet = .manage } : nil,
            addPlaylistSongs: item.kind == .playlist ? { playlistSheet = .addSongs } : nil,
            reorderPlaylistSongs: item.kind == .playlist ? { playlistSheet = .reorderSongs } : nil,
            loader: { offset in
                if item.kind == .playlist {
                    return try await library.playlistTracks(
                        playlistID: item.id, startIndex: offset)
                }
                return try await library.tracks(albumID: item.id, startIndex: offset)
            }
        )
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline { playlistSheet = nil }
        }
        .sheet(
            item: $playlistSheet,
            onDismiss: {
                guard !connectivity.localOnly else { return }
                refreshRevision += 1
            },
            content: { destination in
                switch destination {
                case .manage:
                    FoundationPlaylistEditor(
                        playlist: displayItem, onDeleted: { dismiss() },
                        onRenamed: { playlistName = $0 }, library: library)
                case .addSongs:
                    FoundationPlaylistSongPicker(playlist: displayItem, library: library)
                case .reorderSongs:
                    FoundationPlaylistReorderSheet(playlist: displayItem, library: library)
                }
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
    @EnvironmentObject private var playlistChanges: FoundationPlaylistChanges
    @StateObject private var playlistRemoval = FoundationPlaylistOperation()
    @EnvironmentObject private var preferences: FoundationPlaybackPreferences
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
    var addPlaylistSongs: (() -> Void)? = nil
    var reorderPlaylistSongs: (() -> Void)? = nil
    var localItems: (() -> [FoundationItem])? = nil
    @State private var loadedPlaylistRevision = 0
    @State private var loadedRefreshRevision = 0
    @State private var detailTint = Color(white: 0.12)
    let loader: (Int) async throws -> FoundationPage
    @State private var revision = 0
    @State private var isVisible = false
    @State private var collectionOperationOwner = UUID()
    @State private var openedCollection: FoundationItem?

    private var visibleTracks: [FoundationItem] {
        actions.visibleTracks(
            tracks.rawItems, albumID: collection?.kind == .album ? collection?.id : nil,
            isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
    }

    var body: some View {
        trackSurface
            .foundationDetailPresentation(
                title: title, immersive: collection != nil, tint: detailTint,
                scrollTitle: collection?.kind == .album
            )
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
            .environment(\.foundationCollectionOperationOwner, collectionOperationOwner)
            .foundationCollectionOutcomePresentation(owner: collectionOperationOwner)
            .onAppear {
                tracks.configureFavoriteObservations(actions)
                actions.observeTrackCopies(
                    tracks.rawItems, albumID: collection?.kind == .album ? collection?.id : nil)
                isVisible = true
            }
            .onDisappear {
                actions.cancelQueueAdditionOwned(by: collectionOperationOwner)
                if playlistRemoval.isPending { playlistRemoval.cancel() }
                isVisible = false
            }
            .onChange(of: tracks.rawItems) { _, items in
                actions.observeTrackCopies(
                    items, albumID: collection?.kind == .album ? collection?.id : nil)
            }
            .onChange(of: connectivity.localOnly) { _, offline in
                if offline, playlistRemoval.isPending { playlistRemoval.cancel() }
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
                if let addPlaylistSongs {
                    Button("Add Songs", systemImage: "plus", action: addPlaylistSongs)
                        .disabled(!library.supportsPlaylistManagement || connectivity.localOnly)
                }
                if let reorderPlaylistSongs {
                    Button(
                        "Reorder Songs", systemImage: "arrow.up.arrow.down",
                        action: reorderPlaylistSongs
                    )
                    .disabled(!library.supportsPlaylistReordering || connectivity.localOnly)
                    .accessibilityIdentifier("playlist-reorder-songs")
                }
                if let managePlaylist {
                    Button("Manage Playlist", systemImage: "pencil", action: managePlaylist)
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
                    showsFavoriteAction: collection.kind != .album,
                    library: library, player: player)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(
                        width: relatedItemSheet ? 48 : nil,
                        height: relatedItemSheet ? 48 : nil)
            }.foundationEllipsisMenuIndicator().accessibilityLabel("More actions")
        }
    }

    private func albumDiscHeading(_ heading: FoundationAlbumTrackPolicy.DiscHeading) -> some View {
        Group {
            switch heading {
            case .disc(let number): Text("Disc \(number)")
            case .unspecified: Text("Other Tracks")
            }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
        #if os(macOS)
            .padding(.horizontal, 16)
        #endif
    }

    @ViewBuilder private var trackSurface: some View {
        #if os(macOS)
            if collection?.kind == .album {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        trackContent
                    }.padding(.horizontal, 8)
                }.scrollClipDisabled()
            } else {
                List { trackContent }
                    .listStyle(.plain)
                    .contentMargins(collection == nil ? 8 : 0, for: .scrollContent)
            }
        #else
            List {
                trackContent
            }
            .listStyle(.plain)
            .foundationBottomChromeListClearance()
        #endif
    }

    @ViewBuilder private var trackContent: some View {
        if let collection {
            collectionHeader(collection)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        if collection?.kind == .playlist, library.supportsPlaylistManagement {
            HStack(spacing: 12) {
                if let addPlaylistSongs {
                    Button("Add Songs", systemImage: "plus", action: addPlaylistSongs)
                }
                if let managePlaylist {
                    Button("Manage Songs", systemImage: "checklist", action: managePlaylist)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered)
            .disabled(connectivity.localOnly)
            .padding(.vertical, 8)
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
        if collection?.kind == .playlist,
            playlistRemoval.message != nil || playlistRemoval.isPending
        {
            FoundationPlaylistStatus(operation: playlistRemoval)
        }
        if collection?.kind == .album {
            let albumDiscHeadings = FoundationAlbumTrackPolicy.discHeadings(for: visibleTracks)
            ForEach(Array(visibleTracks.enumerated()), id: \.offset) { index, item in
                // One list row per track, even when this track begins a new disc.
                VStack(alignment: .leading, spacing: 0) {
                    if let heading = albumDiscHeadings[index] {
                        albumDiscHeading(heading)
                    }
                    trackRow(item, index: index)
                    #if os(macOS)
                        Divider().overlay(.white.opacity(0.12)).padding(.horizontal, 16)
                    #endif
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(.white.opacity(0.12))
            }
        } else {
            ForEach(Array(visibleTracks.enumerated()), id: \.offset) { index, item in
                trackRow(item, index: index)
            }
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
        if !relatedItemSheet, let collection, collection.kind == .album {
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

    private func trackRow(_ item: FoundationItem, index: Int) -> some View {
        let artworkItem = item.catalogArtworkItem
        let albumTitle =
            item.album?.title ?? (collection?.kind == .album ? collection?.title : nil)
            ?? ""
        let subtitle = [item.subtitle, albumTitle]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading) {
            HStack {
                Button {
                    play(index, expected: item)
                } label: {
                    HStack {
                        if collection == nil {
                            FoundationCatalogArtwork(
                                item: artworkItem, library: library,
                                isActive: isActive && isVisible
                            )
                            .id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
                        } else {
                            Text(
                                "\(collection?.kind == .album ? (item.trackNumber ?? index + 1) : index + 1)"
                            ).font(.subheadline)
                                .accessibilityIdentifier("album-track-number-\(index)")
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
        #if os(macOS)
            .padding(.horizontal, collection?.kind == .album ? 16 : 0)
        #endif
        .contextMenu { trackMenu(item, index: index) }
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
            play: { play(index, expected: item) }, player: player,
            navigate: { openedCollection = $0 },
            currentPageKind: collection?.kind,
            removeFromPlaylist: collection?.kind == .playlist && library.supportsPlaylistManagement
                && item.playlistEntryID != nil ? { removePlaylistTrack(item) } : nil,
            removalPending: playlistRemoval.isPending
        )
    }

    private func removePlaylistTrack(_ track: FoundationItem) {
        guard isActive, isVisible, let collection, collection.kind == .playlist,
            !connectivity.localOnly
        else { return }
        playlistRemoval.run(
            successMessage: { "Removed from Playlist." },
            {
                try Task.checkCancellation()
                guard !connectivity.localOnly else { throw CancellationError() }
                try await playlistChanges.remove(
                    playlistID: collection.id, track: track, library: library)
                downloads.reconcilePlaylists()
            })
    }

    private func reload(_ next: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        tracks.request(next)
        revision += 1
    }
    private func play(_ requestedIndex: Int, expected: FoundationItem) {
        let items = visibleTracks
        let index: Int
        if items.indices.contains(requestedIndex),
            items[requestedIndex].id == expected.id,
            items[requestedIndex].playlistEntryID == expected.playlistEntryID
        {
            index = requestedIndex
        } else if collection?.kind == .album,
            let current = items.firstIndex(where: { $0.id == expected.id })
        {
            index = current
        } else {
            return
        }
        guard
            let selection = FoundationTrackQueueSelection(
                in: items, selecting: index,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
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
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
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
                        visibleHeader(headerContent.background { searchReadabilityBackground })
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

        @ViewBuilder private var searchReadabilityBackground: some View {
            // Search has a second header row. Keep its upper half legible before
            // feathering into the results, without changing other root headers.
            if searchHeight > 0 {
                GeometryReader { geometry in
                    let topInset = geometry.safeAreaInsets.top
                    let height = geometry.size.height + topInset
                    let midpoint = (topInset + 56 + searchHeight / 2) / max(1, height)
                    Rectangle()
                        .fill(
                            reduceTransparency
                                ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial)
                        )
                        .frame(height: height)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: midpoint),
                                    .init(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                        }
                        .offset(y: -topInset)
                }
                .opacity(isAtTop ? 0 : 1)
                .animation(.easeOut(duration: 0.18), value: isAtTop)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
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
    enum Layout { case rows, genreCards, albumShelf, albumGrid, overview }
    var layout: Layout = .rows
    var rowCount = 4
    var rowSpacing = 16.0
    var rowArtworkSize: CGFloat = 48
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
        case .overview:
            VStack(alignment: .leading, spacing: 8) {
                Text("Artist overview\nArtist overview\nArtist overview\nArtist overview")
                    .lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                Text("Read More").font(.subheadline.weight(.semibold))
            }.redacted(reason: .placeholder)
        case .rows:
            VStack(spacing: rowSpacing) {
                ForEach(0..<rowCount, id: \.self) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8)
                            .frame(width: rowArtworkSize, height: rowArtworkSize)
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
                        album.frame(width: 150).opacity(1 - Double(index) * 0.35)
                    }
                }.frame(width: geometry.size.width, alignment: .leading).clipped()
            }.frame(height: 188)
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

/// Native shelf geometry shared by Home and New; songs may supply their loaded album artwork.
struct FoundationAlbumShelfCard: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)?
    var artworkItem: FoundationItem? = nil
    @EnvironmentObject private var actions: FoundationLibraryActions

    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity

    var body: some View {
        if !connectivity.localOnly || !downloads.browseTracks(for: item).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                FoundationCollectionSourceButton(item: item, action: open) {
                    VStack(alignment: .leading, spacing: 8) {
                        FoundationCatalogArtwork(
                            item: artworkItem ?? item, library: library, isActive: isActive,
                            size: 144
                        )
                        .id((artworkItem ?? item).sharedArtworkIdentity)
                        .foundationCollectionArtworkSource(item: item)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(item.title).font(.headline).lineLimit(1)
                                    .truncationMode(.tail)
                                FoundationDownloadBadge(item: item)
                            }
                            Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1, reservesSpace: true).truncationMode(.tail)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(width: 144, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
            .glassEffect(reduceTransparency ? .identity : .regular, in: Capsule())
            .tint(.primary)
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

/// Allocate the proposed width without fixed child frames feeding back into split-view sizing.
private struct FoundationProportionalBrandingRow: Layout {
    private func widths(_ width: CGFloat) -> [CGFloat] {
        let available = max(0, width - 32)
        return [available * 0.4, available * 0.6]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let requested = proposal.width ?? 600
        let width = requested.isFinite ? max(0, requested) : 600
        let columns = widths(width)
        let height =
            subviews.prefix(2).enumerated().map { index, view in
                view.sizeThatFits(.init(width: columns[index], height: nil)).height
            }.max() ?? 0
        return CGSize(width: width, height: max(140, height))
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let columns = widths(bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.prefix(2).enumerated() {
            view.place(
                at: CGPoint(x: x + columns[index] / 2, y: bounds.midY), anchor: .center,
                proposal: .init(width: columns[index], height: nil))
            x += columns[index] + 32
        }
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
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationReduceMotion) private var heroReduceMotion
    @State private var artistMetadata: FoundationArtistBrandingMetadata?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var artistDisplayScale
    @State private var logoPresentation: FoundationArtistLogoContrast.Presentation = .original
    @State private var artistInputIdentity: String?
    @State private var artistLogo: FoundationCurrentArtwork.Result?
    @State private var artistBackdrop: FoundationCurrentArtwork.Result?
    @State private var artistBackdropLoading = false
    @State private var artistLogoFailed = false
    @State private var artistBackdropFailed = false
    @State private var artistMetadataRetry = 0
    @State private var artistHeroWidth: CGFloat = 0
    @State private var artistHeroSize: CGSize = .zero
    @State private var artistLogoFrame: CGRect = .zero
    @State private var artistOverviewFrame: CGRect = .zero
    @State private var overviewUsesLightText: Bool? = nil
    @State private var artistNameUsesLightText: Bool? = nil
    @State private var checkedLogoRevision: UUID?
    @State private var artistControlsBounds: [String: CGRect] = [:]
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var heroDynamicTypeSize

    private var brandedArtist: FoundationItem {
        artistMetadata?.resolved(for: item, scope: library.catalogScopeID) ?? item
    }

    private var displayedArtistBackdrop: FoundationCurrentArtwork.Result? {
        guard brandedArtist.artworkItem(for: .backdrop) != nil else { return nil }
        return artistBackdrop
    }

    private var brandingInputIdentity: String {
        "\(library.catalogScopeID)-\(item.artistBrandingRevision)"
    }

    private var logoContrastSurface: FoundationArtistLogoContrast.Surface? {
        guard artistHeroSize.height > 0, artistLogoFrame.width > 0, let artistLogo else {
            return nil
        }
        let scale = min(
            artistLogoFrame.width / CGFloat(artistLogo.image.width),
            min(76, artistLogoFrame.height) / CGFloat(artistLogo.image.height))
        let size = CGSize(
            width: CGFloat(artistLogo.image.width) * scale,
            height: CGFloat(artistLogo.image.height) * scale)
        let imageFrame = CGRect(
            x: artistLogoFrame.midX - size.width / 2,
            y: artistLogoFrame.midY - size.height / 2,
            width: size.width, height: size.height)
        return artistContrastSurface(frame: imageFrame)
    }

    private var overviewContrastSurface: FoundationArtistLogoContrast.Surface? {
        artistContrastSurface(frame: artistOverviewFrame)
    }

    private func artistContrastSurface(frame: CGRect) -> FoundationArtistLogoContrast.Surface? {
        guard artistHeroSize.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let profile = artistBackdropProfile
        return FoundationArtistLogoContrast.Surface(
            size: artistHeroSize, logoFrame: frame, frostStart: profile.start,
            frostEnd: profile.frostEnd, fadeStart: profile.fadeStart,
            frostOpacity: profile.frostOpacity, readingStart: profile.readingStart,
            readingEnd: profile.readingEnd, readingOpacity: profile.readingOpacity,
            smoothPageFade: profile.smoothPageFade)
    }

    private var artistBackdropProfile: FoundationArtistBackdropProfile {
        #if os(macOS)
            let midpoint = artistControlsBounds[item.id]?.midY
        #else
            let midpoint: CGFloat? = nil
        #endif
        return FoundationArtistBackdropProfile(
            height: artistHeroSize.height, controlsBottom: artistControlsBounds[item.id]?.maxY,
            increasedContrast: colorSchemeContrast == .increased,
            overviewTop: artistOverviewFrame.height > 0 ? artistOverviewFrame.minY : nil,
            controlsMidpoint: midpoint)
    }

    private var showsHeroBackdrop: Bool {
        #if os(iOS)
            true
        #else
            item.kind == .artist
        #endif
    }

    var body: some View {
        heroContent
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
                .overlay(alignment: .topLeading) {
                    if FoundationDownloadsTestHarness.enabled {
                        FoundationDetailUIContextEvidence(item: item)
                    }
                }
            #endif
            .background {
                if let logo = brandedArtist.artworkItem(for: .logo) {
                    FoundationArtistRoleArtwork(
                        item: logo, library: library, isActive: isActive,
                        image: $artistLogo, failed: $artistLogoFailed,
                        retryRevision: artistMetadataRetry,
                        requestedPixels: max(640, Int(artistLogoFrame.width * artistDisplayScale)))
                }
                if let backdrop = brandedArtist.artworkItem(for: .backdrop) {
                    FoundationArtistRoleArtwork(
                        item: backdrop, library: library, isActive: isActive,
                        image: $artistBackdrop, loading: $artistBackdropLoading,
                        failed: $artistBackdropFailed, retryRevision: artistMetadataRetry,
                        requestedPixels: Int(
                            max(1, max(artistHeroSize.width, artistHeroSize.height))
                                * artistDisplayScale))
                }
            }
            .task(
                id:
                    "\(brandingInputIdentity)-\(isActive)-\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)-\(artistMetadataRetry)"
            ) {
                guard !Task.isCancelled else { return }
                if artistInputIdentity != brandingInputIdentity {
                    artistMetadata = nil
                    // Each role loader owns its own image revision. Clearing siblings here
                    // would erase an unchanged image without restarting that role's task.
                    artistInputIdentity = brandingInputIdentity
                }
                guard item.kind == .artist, isActive
                else { return }
                if let cached = await library.cachedArtistDetails(for: item) {
                    guard !Task.isCancelled else { return }
                    artistMetadata = FoundationArtistBrandingMetadata(
                        scope: library.catalogScopeID,
                        inputRevision: item.artistBrandingRevision, detail: cached.item)
                }
                guard !connectivity.localOnly else { return }
                do {
                    let detail = try await library.itemDetails(for: item)
                    try Task.checkCancellation()
                    guard detail?.id == item.id, detail?.kind == .artist else { return }
                    if let detail {
                        artistMetadata = FoundationArtistBrandingMetadata(
                            scope: library.catalogScopeID,
                            inputRevision: item.artistBrandingRevision,
                            detail: detail)
                    }
                } catch {
                    // Artist branding is optional; the text title remains usable.
                }
            }
            .frame(maxWidth: .infinity).padding(.bottom, 24)
            .background {
                if showsHeroBackdrop {
                    if item.kind == .artist {
                        FoundationArtistBackdrop(
                            image: displayedArtistBackdrop?.image, tint: tint,
                            profile: artistBackdropProfile,
                            reduceTransparency: reduceTransparency)
                    } else {
                        GeometryReader { geometry in
                            ZStack(alignment: .top) {
                                tint
                                FoundationCatalogArtwork(
                                    item: item, library: library, isActive: isActive,
                                    size: geometry.size.width, sampledColor: $tint, isHero: true
                                ).id(item.sharedArtworkIdentity)
                                LinearGradient(
                                    stops: [
                                        .init(color: .black.opacity(0.1), location: 0),
                                        .init(color: tint.opacity(0.25), location: 0.3),
                                        .init(color: tint.opacity(0.95), location: 0.65),
                                        .init(color: tint, location: 0.9),
                                    ], startPoint: .top, endPoint: .bottom)
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.2),
                                        .init(color: .black.opacity(0.4), location: 0.55),
                                        .init(color: .black.opacity(0.2), location: 1),
                                    ], startPoint: .top, endPoint: .bottom)
                            }.clipped()
                        }
                    }
                }
            }
            .foregroundStyle(
                item.kind == .artist
                    ? (colorScheme == .dark ? Color.white : Color.black) : Color.white
            )
            .coordinateSpace(name: "artist-hero-\(item.id)")
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                artistHeroSize = $0
            }
            .onChange(of: colorScheme, initial: true) { _, scheme in
                if item.kind == .artist { tint = Color(white: scheme == .dark ? 0.12 : 0.96) }
            }
            .task(
                id:
                    "\(artistLogo?.revision.uuidString ?? "none")-\(displayedArtistBackdrop?.revision.uuidString ?? "none")-\(colorScheme)-\(reduceTransparency)-\(colorSchemeContrast)-\(String(describing: logoContrastSurface))"
            ) {
                guard let artistLogo else {
                    logoPresentation = .text
                    return
                }
                if checkedLogoRevision != artistLogo.revision {
                    logoPresentation = .original
                    checkedLogoRevision = artistLogo.revision
                }
                let dark = colorScheme == .dark
                let backdrop = displayedArtistBackdrop?.image
                let surface = logoContrastSurface
                let reduced = reduceTransparency
                let increased = colorSchemeContrast == .increased
                let decision = await Task.detached(priority: .utility) {
                    FoundationArtistLogoContrast.decision(
                        for: artistLogo.image, dark: dark, backdrop: backdrop,
                        surface: surface, reduceTransparency: reduced, increasedContrast: increased)
                }.value
                guard !Task.isCancelled else { return }
                logoPresentation = decision.presentation
            }
            .task(
                id:
                    "overview-\(displayedArtistBackdrop?.revision.uuidString ?? "none")-\(colorScheme)-\(reduceTransparency)-\(String(describing: overviewContrastSurface))-\(artistLogoFrame)"
            ) {
                guard item.kind == .artist else { return }
                let backdrop = displayedArtistBackdrop?.image
                let surface = overviewContrastSurface
                let nameSurface = artistContrastSurface(frame: artistLogoFrame)
                let dark = colorScheme == .dark
                let reduced = reduceTransparency
                let light = await Task.detached(priority: .utility) {
                    (
                        FoundationArtistLogoContrast.prefersLightText(
                            backdrop: backdrop, surface: surface, dark: dark,
                            reduceTransparency: reduced),
                        FoundationArtistLogoContrast.prefersLightText(
                            backdrop: backdrop, surface: nameSurface, dark: dark,
                            reduceTransparency: reduced)
                    )
                }.value
                guard !Task.isCancelled else { return }
                overviewUsesLightText = light.0
                artistNameUsesLightText = light.1
            }
    }

    @ViewBuilder private var heroContent: some View {
        if item.kind == .artist {
            artistHeroContent
        } else {
            #if os(macOS)
                if item.kind == .album {
                    VStack(spacing: 20) {
                        HStack(alignment: .top, spacing: 24) {
                            FoundationCatalogArtwork(
                                item: item, library: library, isActive: isActive,
                                size: imageSpace, sampledColor: $tint, isHero: true
                            )
                            .frame(width: imageSpace, height: imageSpace)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: item.kind == .artist ? imageSpace / 2 : 8)
                            )
                            .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    artistTitle
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
    }

    private var artistHeroSpacing: CGFloat {
        #if os(iOS)
            12
        #else
            20
        #endif
    }

    private var artistControlsDrop: CGFloat {
        #if os(iOS)
            brandedArtist.artworkItem(for: .logo) != nil ? 20 : 0
        #else
            0
        #endif
    }

    private var artistHeroContent: some View {
        VStack(spacing: artistHeroSpacing) {
            Color.clear.frame(height: imageSpace + artistControlsDrop)
            controls().frame(maxWidth: .infinity)
                .onGeometryChange(for: [String: CGRect].self) { [itemID = item.id] geometry in
                    [itemID: geometry.frame(in: .named("artist-hero-\(itemID)"))]
                } action: {
                    artistControlsBounds = $0
                }
            if artistHeroWidth >= 600, !heroDynamicTypeSize.isAccessibilitySize {
                FoundationProportionalBrandingRow {
                    positionedArtistTitle
                    artistOverview.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, -min(12, artistControlsDrop))
                #if os(macOS)
                    .padding(.top, 16)
                #endif
            } else {
                positionedArtistTitle.multilineTextAlignment(.center)
                    .padding(.top, -min(12, artistControlsDrop))
                    #if os(macOS)
                        .padding(.top, 16)
                    #endif
                artistOverview.frame(maxWidth: .infinity, alignment: .leading)
            }
            if artistLogoFailed || artistBackdropFailed, !connectivity.localOnly {
                Button("Retry Artist Artwork") { artistMetadataRetry += 1 }.font(.caption)
            }
        }
        .frame(maxWidth: 900)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            artistHeroWidth = $0
        }
        .padding(.horizontal, 24)
        .padding(.top, 64)
    }

    private var artistOverview: some View {
        FoundationOverviewSection(
            item: item, library: library, isActive: isActive,
            maximumLines: 4, horizontalInset: 0,
            retryMetadata: { artistMetadataRetry += 1 }, artistUsesLightText: overviewUsesLightText
        )
        .onGeometryChange(for: CGRect.self) { [itemID = item.id] geometry in
            geometry.frame(in: .named("artist-hero-\(itemID)"))
        } action: {
            artistOverviewFrame = $0
        }
        .id(item.id)
    }

    private var positionedArtistTitle: some View {
        artistTitle
            .onGeometryChange(for: CGRect.self) { [itemID = item.id] geometry in
                geometry.frame(in: .named("artist-hero-\(itemID)"))
            } action: {
                artistLogoFrame = $0
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: FoundationDetailTitlePosition.self,
                        value: [item.id: geometry.frame(in: .global).maxY])
                }
            }
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
                Color.clear.frame(height: imageSpace)
            #endif
            #if os(iOS)
                if item.kind == .album { controls().padding(.top, 8) }
            #endif
            VStack(spacing: 12) {
                artistTitle.multilineTextAlignment(.center)
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
            #if os(iOS)
                if item.kind != .album { controls().padding(.top, 8) }
            #else
                controls().padding(.top, 8)
            #endif
        }
    }

    private var artistTitle: some View {
        ZStack {
            if item.kind == .artist, brandedArtist.artworkItem(for: .logo) != nil,
                let artistLogo, logoPresentation != .text
            {
                contrastLogo(artistLogo.image)
                    .frame(maxWidth: 270, maxHeight: 76)
                    .id(artistLogo.revision)
                    .transition(.opacity)
                    // A stable branding slot keeps surrounding gaps independent of logo shape.
                    .frame(height: 88)
                    .accessibilityLabel(item.title)
                    .accessibilityAddTraits(.isHeader)
            } else {
                Text(item.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    .foregroundStyle(
                        item.kind == .artist
                            ? ((artistNameUsesLightText ?? (colorScheme == .dark))
                                ? Color.white : .black)
                            : .white)
            }
        }
        .frame(minHeight: item.kind == .artist ? 88 : nil)
        .animation(
            heroReduceMotion ? nil : .easeInOut(duration: 0.20),
            value: artistLogo?.revision)

    }

    private var logoSupportColor: Color {
        Color(
            white: FoundationArtistLogoContrast.supportTint(
                dark: logoPresentation == .originalOnDark))
    }

    @ViewBuilder private func contrastLogo(_ image: CGImage) -> some View {
        switch logoPresentation {
        case .originalOnLight, .originalOnDark:
            Image(decorative: image, scale: 1).renderingMode(.original).resizable().scaledToFit()
                // A soft halo follows the original ink; there is no enclosing surface.
                .shadow(color: logoSupportColor.opacity(0.55), radius: 5)
                .shadow(color: logoSupportColor.opacity(0.3), radius: 16)
        case .original, .text:
            Image(decorative: image, scale: 1).renderingMode(.original).resizable().scaledToFit()
        }
    }

}

struct FoundationDetailActions: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.foundationCollectionOperationOwner) private var collectionOperationOwner
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var connectivity: FoundationConnectivity
    private var localBrowsing: Bool { connectivity.localOnly }
    private var cannotPlay: Bool {
        localBrowsing ? downloads.browseTracks(for: item).isEmpty : actions.isQueueLoading
    }

    private var playIconColor: Color {
        if item.kind == .artist { return .primary }
        #if os(macOS)
            return .white
        #else
            if #available(iOS 26.0, *) { return .white } else { return .black }
        #endif
    }

    private func play(shuffled: Bool) {
        if localBrowsing {
            let tracks = actions.collectionTracks(downloads.browseTracks(for: item), for: item)
            guard !tracks.isEmpty else { return }
            player.setQueue(shuffled ? tracks.shuffled() : tracks, selectedIndex: 0)
        } else {
            actions.play(
                item, shuffled: shuffled, library: library, player: player,
                owner: collectionOperationOwner)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            playbackControls
            if let error = actions.errorMessage(for: item) {
                Text(error).font(.caption).foregroundStyle(
                    item.kind == .artist ? Color.primary : .white
                ).padding(.horizontal)
            }
        }
    }
    @ViewBuilder private var playbackControls: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 20) { controls }
        } else {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 20) {
            Button {
                play(shuffled: true)
            } label: {
                Image(systemName: "shuffle").frame(width: 44, height: 44)
            }.foundationDetailButton(adaptive: item.kind == .artist).disabled(cannotPlay)
                .accessibilityLabel(
                    "Shuffle")
            Button {
                play(shuffled: false)
            } label: {
                Image(systemName: "play.fill").font(.title).foregroundStyle(playIconColor)
                    .frame(width: 72, height: 72)
            }.foundationDetailButton(prominent: true, adaptive: item.kind == .artist).disabled(
                cannotPlay
            )
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
            }.foundationDetailButton(adaptive: item.kind == .artist)
                .disabled(localBrowsing || favorite == nil || actions.isPending(item))
                .accessibilityLabel(favorite == true ? "Unfavorite" : "Favorite")
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
    @ViewBuilder fileprivate func foundationDetailButton(
        prominent: Bool = false, adaptive: Bool = false
    ) -> some View {
        #if os(macOS)
            if adaptive {
                self.buttonStyle(.glass).buttonBorderShape(.circle).foregroundStyle(.primary)
            } else {
                self.modifier(FoundationMacDetailButton())
            }
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                if adaptive {
                    self.buttonStyle(.glass).buttonBorderShape(.circle).foregroundStyle(.primary)
                } else {
                    self.buttonStyle(.glass(.clear)).buttonBorderShape(.circle)
                }
            } else {
                self.buttonStyle(.plain)
                    .background(prominent ? Color.white : Color.white.opacity(0.16), in: Circle())
            }
        #endif
    }

    func foundationDetailPresentation(
        title: String, immersive: Bool, tint: Color, followsAppearance: Bool = false,
        scrollTitle: Bool = false
    ) -> some View {
        modifier(
            FoundationDetailPresentation(
                title: title, immersive: immersive, tint: tint,
                followsAppearance: followsAppearance,
                scrollTitle: scrollTitle
            ))
    }
}

/// Measure the actual hero text and native toolbar, independent of image or text height.
struct FoundationDetailTitlePosition: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { current, _ in current })
    }
}

struct FoundationDetailTitle: ViewModifier {
    let item: FoundationItem?
    #if os(macOS)
        func body(content: Content) -> some View {
            content.modifier(FoundationMacDetailTitle(item: item))
        }
    #else
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @State private var titleBottom = CGFloat.greatestFiniteMagnitude
        @State private var toolbarBottom = CGFloat.zero
        @State private var headerScrolled = false

        private var revealProgress: CGFloat {
            guard headerScrolled, toolbarBottom > 0, titleBottom.isFinite else { return 0 }
            let progress = min(1, max(0, (toolbarBottom - titleBottom) / 48))
            return progress * progress * (3 - 2 * progress)
        }

        @ViewBuilder func body(content: Content) -> some View {
            let tracked = content.onPreferenceChange(FoundationDetailTitlePosition.self) {
                positions in
                if let item, let bottom = positions[item.id] { titleBottom = bottom }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, scrolled in
                headerScrolled = scrolled
            }
            .onChange(of: item?.id) { _, _ in
                titleBottom = .greatestFiniteMagnitude
                headerScrolled = false
            }
            if let item, item.kind == .album || item.kind == .artist {
                if #available(iOS 26.0, *) {
                    tracked
                        .scrollEdgeEffectStyle(.soft, for: .top)
                        .scrollEdgeEffectHidden(!headerScrolled, for: .top)
                        .toolbar { titleToolbar(item).sharedBackgroundVisibility(.hidden) }
                } else {
                    tracked.toolbar { titleToolbar(item) }
                }
            } else {
                tracked
            }
        }

        private func titleToolbar(_ item: FoundationItem) -> some ToolbarContent {
            ToolbarItem(placement: .principal) {
                ZStack {
                    // Keep the title position stable while the visible text transitions.
                    title(item).hidden().accessibilityHidden(true)
                    title(item)
                        .opacity(revealProgress)
                        .offset(y: reduceMotion ? 0 : 8 * (1 - revealProgress))
                        .scaleEffect(reduceMotion ? 1 : 0.97 + 0.03 * revealProgress)
                        .accessibilityHidden(revealProgress == 0)
                }
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.frame(in: .global).maxY
                } action: {
                    toolbarBottom = $0
                }
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
    #endif
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
    @Environment(\.foundationHandoff) private var handoff
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
            if item.kind != .track { handoff?.navigationChangedByUser() }
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
    @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet
    @Environment(\.foundationCollectionTransition) private var transition
    @Environment(\.foundationCollectionOccurrence) private var occurrence

    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
            if !relatedItemSheet, item.kind == .album || item.kind == .playlist,
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
    @Environment(\.foundationHandoff) private var handoff
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet
    @Binding var item: FoundationItem?
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @Namespace private var namespace
    @State private var sourceIdentity: String?
    @State private var sourceOccurrence: String?
    @Environment(\.foundationReduceMotion) private var reduceMotion
    #if os(macOS)
        @Environment(\.foundationMacNavigation) private var macNavigation
    #endif

    private var context: FoundationCollectionTransitionContext {
        .init(namespace: namespace) { selected, occurrence in
            sourceIdentity = selected.sharedArtworkIdentity
            sourceOccurrence = selected.primaryImageTag == nil ? nil : occurrence
        }
    }

    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
            if let macNavigation, !relatedItemSheet {
                content.environment(\.foundationCollectionTransition, context)
                    .onChange(of: item) { _, selected in
                        guard let selected else { return }
                        actions.cancelQueueAddition()
                        macNavigation.open(selected)
                        item = nil
                    }
            } else {
                localDestination(content)
            }
        #else
            localDestination(content)
        #endif
    }

    private func localDestination(_ content: Content) -> some View {
        content.environment(\.foundationCollectionTransition, context)
            .navigationDestination(
                isPresented: Binding(
                    get: { item != nil },
                    set: { presented in
                        if !presented, item != nil {
                            handoff?.navigationChangedByUser()
                            item = nil
                        }
                    })
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
        #if os(iOS)
            // A detented sheet retains its own navigation/context; it is not a root cover zoom.
            if !relatedItemSheet, !reduceMotion, sourceIdentity == item.sharedArtworkIdentity,
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
    let followsAppearance: Bool
    let scrollTitle: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet
    private var resolvedScheme: ColorScheme {
        followsAppearance || relatedItemSheet ? colorScheme : .dark
    }
    @ViewBuilder func body(content: Content) -> some View {
        if immersive {
            content
                #if os(macOS)
                    .navigationTitle(followsAppearance || scrollTitle ? "" : title)
                    .ignoresSafeArea(.container, edges: followsAppearance ? .top : [])
                    .contentMargins(.top, followsAppearance ? 0 : nil, for: .scrollContent)
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .scrollEdgeEffectHidden(true, for: .top)
                #else
                    .navigationTitle("")
                #endif
                .scrollContentBackground(.hidden)
                .foundationMacTransportClearance()
                .background {
                    if relatedItemSheet {
                        Rectangle().fill(.background).ignoresSafeArea()
                    } else {
                        tint.overlay(
                            .black.opacity(
                                followsAppearance ? 0 : (resolvedScheme == .dark ? 0.2 : 0))
                        )
                        .ignoresSafeArea()
                    }
                }
                .environment(\.colorScheme, resolvedScheme)
                #if os(iOS)
                    .tint(resolvedScheme == .dark ? .white : .black)
                    .ignoresSafeArea(.container, edges: .top)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbarColorScheme(resolvedScheme, for: .navigationBar)
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

private struct FoundationMiniPlayerLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String

    private var showsSubtitle: Bool {
        #if os(iOS)
            !dynamicTypeSize.isAccessibilitySize
        #else
            true
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            if showsSubtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

#if os(iOS)
    /// Let the system accessory own both normal and scroll-minimized placement.
    private struct FoundationMiniPlayerPlacement<Content: View>: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
        let geometry: FoundationBottomChromeGeometry
        @ViewBuilder let content: (Bool) -> Content

        var body: some View {
            content(placement == .inline)
                .modifier(
                    FoundationBottomChromeAccessoryProbe(
                        geometry: geometry, placement: placement)
                )
                #if DEBUG
                    .modifier(FoundationHomeReboundAccessoryProbe(placement: placement))
                #endif
        }
    }
#endif
