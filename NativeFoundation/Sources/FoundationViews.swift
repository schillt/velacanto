import Combine
import SwiftUI

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
        case .new: "music.note.list"
        case .library: "rectangle.stack"
        case .search: "magnifyingglass"
        }
    }
}

struct FoundationLibraryView: View {
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let signOut: () -> Void
    @State private var displayedQueue: [FoundationQueueEntry] = []
    @State private var displayedEntryID: UUID?
    @State private var displayedState: FoundationPlayer.State = .idle
    @EnvironmentObject private var actions: FoundationLibraryActions
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var favorites = FoundationBrowseModel()
    @StateObject private var genres = FoundationBrowseModel()
    @StateObject private var recentTracks = FoundationBrowseModel()
    @StateObject private var recentAlbums = FoundationBrowseModel()
    @StateObject private var mostPlayedAlbums = FoundationBrowseModel()
    @StateObject private var homeHistory = FoundationBrowseModel()
    @StateObject private var homeFavorites = FoundationBrowseModel()
    @StateObject private var homeGenres = FoundationBrowseModel()
    @StateObject private var searchGenres = FoundationBrowseModel()
    @State private var searchQuery = ""
    @State private var searchActivation = 0
    @State private var selectedTab = FoundationDestination.home
    @State private var playerDestination: FoundationItem?
    @State private var playerDestinationTab: FoundationDestination?
    @Namespace private var playerTransition
    @State private var showingPlayer = false
    @State private var showingSettings = false
    @State private var profileName = ""
    @State private var profileImage: Image?
    @State private var showingFavorites = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var openedItem: FoundationItem?

    var body: some View {
        shell
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
            .onChange(of: actions.favoriteRevision) { _, _ in
                favorites.request(.refresh)
                homeFavorites.request(.refresh)
            }
            .foundationPlayerCover(isPresented: $showingPlayer) {
                FoundationPlayerView(player: player, library: library)
            }
            .sheet(isPresented: $showingSettings) {
                FoundationSettingsView(
                    name: profileName, image: profileImage, signOut: signOut)
            }
            .environment(\.foundationPlayerTransition, playerTransition)
            .environment(
                \.foundationOpenLibraryItem,
                { item in
                    showingSettings = false
                    playerDestinationTab = selectedTab
                    playerDestination = item
                })
    }

    @ViewBuilder private var shell: some View {
        #if os(iOS)
            if #available(iOS 26.1, *) {
                tabs
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory(isEnabled: !displayedQueue.isEmpty) {
                        FoundationNativeAccessory { miniPlayer(showNext: $0) }
                    }
            } else {
                tabs.safeAreaInset(edge: .bottom) {
                    if !displayedQueue.isEmpty { miniPlayer().background(.regularMaterial) }
                }
            }
        #else
            FoundationMacLibraryShell(
                selection: tabSelection, showsMiniPlayer: !displayedQueue.isEmpty
            ) { destination in
                browsingContent(destination)
            } miniPlayer: {
                miniPlayer()
            }
        #endif
    }

    private var tabSelection: Binding<FoundationDestination> {
        Binding(
            get: { selectedTab },
            set: { destination in
                selectedTab = destination
                if destination == .search { searchActivation += 1 }
            })
    }

    #if os(iOS)
        private var tabs: some View {
            TabView(selection: tabSelection) {
                ForEach(FoundationDestination.allCases, id: \.self) { destination in
                    Tab(
                        destination.title, systemImage: destination.symbol, value: destination,
                        role: destination == .search ? .search : nil
                    ) {
                        NavigationStack {
                            browsingContent(destination)
                        }
                    }
                }
            }
        }
    #endif

    private func browsingContent(_ tab: FoundationDestination) -> some View {
        destinationContent(tab)
            .navigationDestination(
                isPresented: Binding(
                    get: { playerDestinationTab == tab && playerDestination != nil },
                    set: { if !$0 && playerDestinationTab == tab { playerDestination = nil } })
            ) {
                if let item = playerDestination, playerDestinationTab == tab {
                    FoundationItemDestination(
                        item: item, library: library, player: player, isActive: selectedTab == tab)
                }
            }
            #if os(iOS)
                .toolbar(.visible, for: .tabBar)
            #endif
    }

    @ViewBuilder private func destinationContent(_ destination: FoundationDestination) -> some View
    {
        if destination == .library {
            libraryHome
                #if DEBUG
                    .environment(\.foundationTraceOrigin, .library)
                #endif
        } else if destination == .new {
            FoundationNewView(
                profile: profileButton(isActive: selectedTab == .new), library: library,
                player: player, tracks: recentTracks, albums: recentAlbums,
                isActive: selectedTab == .new
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .new)
            #endif
        } else if destination == .search {
            FoundationSearchView(
                profile: profileButton(isActive: selectedTab == .search),
                library: library, player: player, genres: searchGenres, query: $searchQuery,
                isActive: selectedTab == .search, activation: searchActivation
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .search)
            #endif
        } else {
            FoundationHomeView(
                profile: profileButton(isActive: selectedTab == .home), library: library,
                player: player, recentTracks: homeHistory,
                favorites: homeFavorites, recentAlbums: recentAlbums, genres: homeGenres,
                isActive: selectedTab == .home
            )
            #if DEBUG
                .environment(\.foundationTraceOrigin, .home)
            #endif
        }
    }

    private var libraryHome: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pinned").font(.title2.bold())
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 12),
                            count: dynamicTypeSize.isAccessibilitySize ? 2 : 3)
                    ) {
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
                            pinnedTile(item)
                        }
                    }
                    if let error = actions.pinErrorMessage {
                        Text(error).foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your Music").font(.title2.bold()).padding(.bottom, 4)
                    NavigationLink {
                        FoundationCatalogView(
                            title: "Albums", model: albums, library: library, player: player,
                            isActive: selectedTab == .library
                        ) { try await library.albums(startIndex: $0) }
                        #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                        #endif
                    } label: {
                        categoryRow(
                            "Albums", subtitle: "Browse your collection by album",
                            symbol: "opticaldisc.fill")
                    }
                    NavigationLink {
                        FoundationCatalogView(
                            title: "Artists", model: artists, library: library, player: player,
                            isActive: selectedTab == .library
                        ) { try await library.artists(startIndex: $0) }
                        #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                        #endif
                    } label: {
                        categoryRow(
                            "Artists", subtitle: "Find music by artist", symbol: "music.mic")
                    }
                    NavigationLink {
                        FoundationTrackList(
                            title: "Songs", tracks: songs, player: player, library: library,
                            isActive: selectedTab == .library
                        ) { try await library.songs(startIndex: $0) }
                        #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                        #endif
                    } label: {
                        categoryRow(
                            "Songs", subtitle: "See every song in your library",
                            symbol: "music.note")
                    }
                    NavigationLink {
                        FoundationCatalogView(
                            title: "Playlists", model: playlists, library: library, player: player,
                            isActive: selectedTab == .library
                        ) { try await library.playlists(startIndex: $0) }
                        #if os(iOS)
                            .toolbar(.visible, for: .navigationBar)
                        #endif
                    } label: {
                        categoryRow(
                            "Playlists", subtitle: "Collections you’ve created and saved",
                            symbol: "music.note.list")
                    }
                    NavigationLink {
                        FoundationGenreIndex(
                            genres: genres, library: library, player: player,
                            isActive: selectedTab == .library
                        ) {
                            try await library.genres(startIndex: $0)
                        }.foundationCatalogHeader("Genres")
                            #if os(iOS)
                                .toolbar(.visible, for: .navigationBar)
                            #endif
                    } label: {
                        categoryRow(
                            "Genres", subtitle: "Browse albums by genre", symbol: "guitars")
                    }
                }
                FoundationLibraryMostPlayedAlbums(
                    model: mostPlayedAlbums, library: library, player: player,
                    isActive: selectedTab == .library)
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }
        .buttonStyle(.plain)
        .foundationHeader("Library", profile: profileButton(isActive: selectedTab == .library))
        .navigationDestination(isPresented: $showingFavorites) {
            FoundationCatalogView(
                title: "Favorites", model: favorites, library: library, player: player,
                isActive: selectedTab == .library, isFavorites: true
            ) { try await library.favorites(startIndex: $0) }
            #if os(iOS)
                .toolbar(.visible, for: .navigationBar)
            #endif
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } }
            )
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player,
                    isActive: selectedTab == .library
                )
                #if os(iOS)
                    .toolbar(.visible, for: .navigationBar)
                #endif
            }
        }
    }

    private func pinnedTile(_ item: FoundationItem) -> some View {
        Button {
            openedItem = item
        } label: {
            VStack(alignment: .leading) {
                Spacer(minLength: 24)
                Text(item.title).font(.subheadline.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .foregroundStyle(.white)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)
            .background {
                GeometryReader { geometry in
                    FoundationCatalogArtwork(
                        item: item, library: library,
                        isActive: selectedTab == .library, size: geometry.size.width
                    )
                    .id(item.id + (item.primaryImageTag ?? ""))
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
            showingSettings = true
        } label: {
            FoundationProfileImage(library: library, isActive: isActive) { name, image in
                profileName = name
                profileImage = image
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Profile and settings")
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
    }

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
                                item: cover, library: library, isActive: true, size: 34
                            ).id(cover.id + (cover.primaryImageTag ?? ""))
                        } else {
                            Image(systemName: "music.note").frame(width: 34, height: 34)
                        }
                    }
                    .foundationPlayerArtworkSource(namespace: playerTransition)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item?.title ?? "Nothing Playing").font(.callout.weight(.medium))
                            .lineLimit(1)
                        Text(displayedState == .playing ? (item?.subtitle ?? "") : displayedState.label)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Show Now Playing")
            .accessibilityValue(
                [item?.title, item?.subtitle, displayedState.label].compactMap { $0 }.filter {
                    !$0.isEmpty
                }.joined(separator: ", "))
            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain).disabled(displayedEntryID == nil)
            .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
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
        }.padding(.horizontal, 10).padding(.vertical, 6)
    }
}

/// Albums and artists share one list, one page owner and explicit pagination.
struct FoundationCatalogView: View {
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    @EnvironmentObject private var actions: FoundationLibraryActions
    let title: String
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var isFavorites = false
    var showsTrackArtwork = false
    var headerItem: FoundationItem?
    @State private var detailTint = Color(white: 0.12)
    @State private var isVisible = false
    let loader: (Int) async throws -> FoundationPage
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    var body: some View {
        Group {
            if showsCollectionGrid {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let headerItem {
                            identityHeader(headerItem)
                            FoundationOverviewSection(
                                item: headerItem, library: library,
                                isActive: isActive && isVisible
                            ).id(headerItem.id)
                            FoundationArtistMostPlayed(
                                artist: headerItem, library: library, player: player,
                                isActive: isActive && isVisible, navigate: { openedItem = $0 }
                            ).id(headerItem.id + "-most-played")
                            Text("Albums").font(.title2.bold()).frame(
                                maxWidth: .infinity, alignment: .leading
                            ).padding()
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 18)],
                            alignment: .leading, spacing: 22
                        ) {
                            ForEach(Array(model.items.enumerated()), id: \.offset) { _, item in
                                collectionCard(item)
                            }
                        }.padding()
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
        .modifier(FoundationDetailTitle(item: headerItem))
        .toolbar {
            if let headerItem {
                Menu {
                    FoundationItemMenu(
                        item: headerItem, actions: actions, initialFavorite: headerItem.isFavorite,
                        library: library, player: player)
                } label: {
                    Image(systemName: "ellipsis")
                }.accessibilityLabel("More actions")
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: actions.favoriteRevision) { _, _ in
            // Root owns invalidation; this visible consumer only schedules the load.
            // Main-actor change callbacks finish before the asynchronous task begins.
            if isFavorites, isActive, isVisible { revision += 1 }
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openedItem != nil }, set: { if !$0 { openedItem = nil } }
            )
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive)
            }
        }
        .task(id: isActive ? revision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .catalog) {
                    await model.loadPending(ifActive: isActive, using: loader)
                }
            #else
                await model.loadPending(ifActive: isActive, using: loader)
            #endif
        }
    }

    private var showsCollectionGrid: Bool {
        !isFavorites
            && (headerItem?.kind == .artist
                || (!model.items.isEmpty
                    && model.items.allSatisfy { $0.kind == .album || $0.kind == .playlist }))
    }

    private func identityHeader(_ item: FoundationItem) -> some View {
        FoundationDetailHero(
            item: item, library: library, isActive: isActive && isVisible, tint: $detailTint
        ) {
            FoundationDetailActions(item: item, library: library, player: player)
        }
    }

    @ViewBuilder private var pageState: some View {
        if let error = actions.pinErrorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if model.loaded, model.items.isEmpty { Text("No items found.") }
        if let error = model.errorMessage {
            Text(error).foregroundStyle(.red)
            Button("Retry") { reload(model.retryRequest) }
        }
        if model.isLoading {
            FoundationLoadingPlaceholder(layout: showsCollectionGrid ? .albumGrid : .rows)
        }
        if model.nextStartIndex != nil {
            Button("Load more") { reload(.more) }.disabled(model.isLoading)
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
            Array(model.items.enumerated()),
            id: \.offset
        ) { index, item in
            FoundationLibraryItemRow(
                item: item, library: library, isActive: isActive,
                open: { openedItem = item },
                play: item.kind == .track
                    ? {
                        if let selection = model.trackQueue(selecting: index) {
                            player.setQueue(selection.items, selectedIndex: selection.index)
                        }
                    } : nil, player: player, showsTrackArtwork: showsTrackArtwork,
                navigate: { openedItem = $0 }, currentPageKind: headerItem?.kind)
        }
    }

    private func reload(_ request: FoundationBrowseModel.Request) {
        model.request(request)
        revision += 1
    }
}

private struct FoundationCollectionCard: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var showsSubtitle = true
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)?
    @EnvironmentObject private var actions: FoundationLibraryActions

    var body: some View {
        VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 6) {
            Button {
                open()
            } label: {
                if item.kind == .artist {
                    FoundationCatalogArtwork(
                        item: item, library: library, isActive: isActive, size: 150
                    ).id(item.id + (item.primaryImageTag ?? ""))
                } else {
                    GeometryReader { geometry in
                        FoundationCatalogArtwork(
                            item: item, library: library, isActive: isActive,
                            size: geometry.size.width
                        ).id(item.id + (item.primaryImageTag ?? ""))
                    }.aspectRatio(1, contentMode: .fit)
                }
            }.buttonStyle(.plain).accessibilityLabel("View " + item.title)
            Button {
                open()
            } label: {
                VStack(alignment: item.kind == .artist ? .center : .leading, spacing: 3) {
                    Text(item.title).font(.headline).lineLimit(2)
                    if showsSubtitle, !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: item.kind == .artist ? .center : .leading)
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
    @EnvironmentObject private var actions: FoundationLibraryActions

    private var artworkItem: FoundationItem { showsTrackArtwork ? item.catalogArtworkItem : item }

    var body: some View {
        VStack(alignment: .leading) {
            HStack(spacing: 12) {
                Button {
                    if let play { play() } else { open() }
                } label: {
                    HStack(spacing: 12) {
                        FoundationCatalogArtwork(
                            item: artworkItem, library: library, isActive: isActive
                        )
                        .id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
                        VStack(alignment: .leading) {
                            Text(item.title)
                            let subtitle = subtitleOverride ?? item.subtitle
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu {
                    menu
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
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
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool

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
                EmptyView()
            }
        }.id(item.id)
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
    @StateObject private var albums = FoundationBrowseModel()

    var body: some View {
        FoundationCatalogView(
            title: artist.title, model: albums, library: library, player: player,
            isActive: isActive, headerItem: artist
        ) { try await library.albums(artistID: artist.id, startIndex: $0) }
    }
}

private struct FoundationCollectionView: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @StateObject private var tracks = FoundationBrowseModel()

    var body: some View {
        FoundationTrackList(
            title: item.title, tracks: tracks, player: player, library: library, isActive: isActive,
            collection: item
        ) {
            offset in
            if item.kind == .playlist {
                return try await library.playlistTracks(playlistID: item.id, startIndex: offset)
            }
            return try await library.tracks(albumID: item.id, startIndex: offset)
        }
    }
}

private struct FoundationTrackList: View {
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    @EnvironmentObject private var actions: FoundationLibraryActions
    let title: String
    @ObservedObject var tracks: FoundationBrowseModel
    let player: FoundationPlayer
    let library: any FoundationLibrary
    let isActive: Bool
    var collection: FoundationItem?
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
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Spacer(minLength: 8)
                        Menu {
                            trackMenu(item, index: index)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("Actions for " + item.title)
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
                if tracks.loaded, tracks.items.isEmpty { Text("No tracks found.") }
                if let error = tracks.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { reload(tracks.retryRequest) }
                }
                if tracks.isLoading { FoundationLoadingPlaceholder() }
                if tracks.nextStartIndex != nil {
                    Button("Load more tracks") { reload(.more) }.disabled(tracks.isLoading)
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
        .foundationDetailPresentation(title: title, immersive: collection != nil, tint: detailTint)
        .modifier(FoundationDetailTitle(item: collection))
        .toolbar {
            if let collection {
                Menu {
                    if collection.kind == .album, let artist = collection.artist {
                        Button("View Artist", systemImage: "music.mic") {
                            openedCollection = FoundationItem(
                                id: artist.id, title: artist.title, subtitle: "", kind: .artist,
                                duration: nil, primaryImageTag: artist.primaryImageTag)
                        }
                        Divider()
                    }
                    FoundationItemMenu(
                        item: collection, actions: actions, initialFavorite: collection.isFavorite,
                        library: library, player: player)
                } label: {
                    Image(systemName: "ellipsis")
                }.accessibilityLabel("More actions")
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isActive ? revision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .tracks) {
                    await tracks.loadPending(ifActive: isActive, using: loader)
                }
            #else
                await tracks.loadPending(ifActive: isActive, using: loader)
            #endif
        }
        .navigationDestination(
            isPresented: Binding(
                get: { openedCollection != nil }, set: { if !$0 { openedCollection = nil } })
        ) {
            if let item = openedCollection {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive)
            }
        }
    }

    private func collectionHeader(_ item: FoundationItem) -> some View {
        VStack(spacing: 0) {
            FoundationDetailHero(
                item: item, library: library, isActive: isActive && isVisible, tint: $detailTint
            ) {
                FoundationDetailActions(item: item, library: library, player: player)
            }
            if item.kind == .album {
                FoundationOverviewSection(
                    item: item, library: library, isActive: isActive && isVisible
                ).id(item.id)
            }
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
        tracks.request(next)
        revision += 1
    }
    private func play(_ index: Int) {
        player.setQueue(tracks.items, selectedIndex: index)
    }
}

#if os(iOS)
    @available(iOS 26.1, *)
    private struct FoundationNativeAccessory<Content: View>: View {
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement
        let content: (Bool) -> Content

        var body: some View { content(placement != .inline) }
    }
#endif

/// Optional account artwork belongs to the visible profile entry point only.
private struct FoundationProfileImage: View {
    let library: any FoundationLibrary
    let isActive: Bool
    let onLoaded: (String, Image?) -> Void
    @State private var image: Image?
    @State private var initial = ""
    @State private var completed = false
    @State private var isVisible = false

    var body: some View {
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
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isActive && isVisible) {
            guard isActive, isVisible, !completed, !Task.isCancelled else { return }
            do {
                let profile = try await library.profile()
                try Task.checkCancellation()
                initial = String(profile.name.prefix(1)).uppercased()
                #if os(iOS)
                    image = profile.image.flatMap { UIImage(data: $0) }.map { Image(uiImage: $0) }
                #else
                    image = profile.image.flatMap { NSImage(data: $0) }.map { Image(nsImage: $0) }
                #endif
                onLoaded(profile.name, image)
                completed = true
            } catch {
                if !Task.isCancelled { completed = true }
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
            content.navigationTitle(title).toolbar { profile }
                .safeAreaInset(edge: .top) { search.frame(height: searchHeight) }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var bright = false

    var body: some View {
        shapes
            .foregroundStyle(.quaternary)
            .opacity(reduceMotion || bright ? 1 : 0.55)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                value: bright
            )
            .onAppear { bright = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading")
            .allowsHitTesting(false)
    }

    @ViewBuilder private var shapes: some View {
        switch layout {
        case .rows:
            VStack(spacing: 16) {
                ForEach(0..<4) { index in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8).frame(width: 48, height: 48)
                        textLines
                        Spacer(minLength: 0)
                    }.opacity(1 - Double(index) * 0.23)
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
                columns: [GridItem(.adaptive(minimum: 140, maximum: 240), spacing: 18)],
                alignment: .leading, spacing: 22
            ) {
                ForEach(0..<4) { index in
                    album.opacity(1 - Double(index) * 0.23)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    FoundationCatalogArtwork(
                        item: item, library: library, isActive: isActive, size: 144
                    )
                    .id(item.id + (item.primaryImageTag ?? ""))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).lineLimit(
                            dynamicTypeSize.isAccessibilitySize ? nil : 2)
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

/// Native destination headers retain back navigation and collapse with scrolling.
extension View {
    func foundationCatalogHeader(_ title: String) -> some View {
        self.navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.large)
                .toolbar(.visible, for: .navigationBar)
            #endif
    }
}

/// One image-owned hero for album and artist destinations.
private struct FoundationDetailHero<Controls: View>: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    @Binding var tint: Color
    @ViewBuilder let controls: () -> Controls
    @ScaledMetric(relativeTo: .title) private var imageSpace = 210.0
    @ScaledMetric(relativeTo: .title) private var artistImageSpace = 280.0

    var body: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: item.kind == .artist ? artistImageSpace : imageSpace)
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
        .frame(maxWidth: .infinity).padding(.bottom, 24)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .top) {
                    tint
                    FoundationCatalogArtwork(
                        item: item, library: library, isActive: isActive,
                        size: geometry.size.width, sampledColor: $tint, isHero: true
                    )
                    .id(item.id + (item.primaryImageTag ?? ""))
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.1), location: 0),
                            .init(
                                color: tint.opacity(item.kind == .artist ? 0.12 : 0.25),
                                location: item.kind == .artist ? 0.4 : 0.3),
                            .init(color: tint.opacity(0.95), location: 0.65),
                            .init(color: tint, location: 0.9),
                        ], startPoint: .top, endPoint: .bottom)
                }.clipped()
            }
        }
        .foregroundStyle(.white)
    }
}

private struct FoundationDetailActions: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @EnvironmentObject private var actions: FoundationLibraryActions

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                Button {
                    actions.play(item, shuffled: true, library: library, player: player)
                } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }.foundationDetailButton().disabled(actions.isQueueLoading).accessibilityLabel(
                    "Shuffle")
                Button {
                    actions.play(item, shuffled: false, library: library, player: player)
                } label: {
                    Image(systemName: "play.fill").font(.title).foregroundStyle(.black)
                        .frame(width: 72, height: 72)
                }.foundationDetailButton(prominent: true).disabled(actions.isQueueLoading)
                    .accessibilityLabel("Play")
                let favorite = actions.favoriteState(for: item, initial: item.isFavorite)
                Button {
                    guard let favorite else { return }
                    Task { await actions.setFavorite(for: item, isFavorite: !favorite) }
                } label: {
                    Image(systemName: favorite == true ? "star.fill" : "star")
                        .frame(width: 44, height: 44)
                }.foundationDetailButton()
                    .disabled(favorite == nil || actions.isPending(item))
                    .accessibilityLabel(favorite == true ? "Unfavorite" : "Favorite")
            }
            if let error = actions.errorMessage(for: item) {
                Text(error).font(.caption).foregroundStyle(.white).padding(.horizontal)
            }
        }
    }
}

extension View {
    @ViewBuilder fileprivate func foundationDetailButton(prominent: Bool = false) -> some View {
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
    }

    @ViewBuilder fileprivate func foundationDetailPresentation(
        title: String, immersive: Bool, tint: Color
    ) -> some View {
        if immersive {
            self.navigationTitle("")
                .scrollContentBackground(.hidden)
                .background { tint.ignoresSafeArea() }
                .environment(\.colorScheme, .dark)
                #if os(iOS)
                    .ignoresSafeArea(.container, edges: .top)
                    .contentMargins(.top, 0, for: .scrollContent)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar(.visible, for: .navigationBar)
                #endif
        } else {
            self.foundationCatalogHeader(title)
        }
    }
}

/// Measure the actual hero text and native toolbar, independent of image or text height.
private struct FoundationDetailTitlePosition: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { current, _ in current })
    }
}

private struct FoundationDetailTitle: ViewModifier {
    let item: FoundationItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleBottom = CGFloat.greatestFiniteMagnitude
    @State private var toolbarBottom = CGFloat.zero

    private var collapsed: Bool { toolbarBottom > 0 && titleBottom <= toolbarBottom }

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(FoundationDetailTitlePosition.self) { positions in
                if let item, let bottom = positions[item.id] { titleBottom = bottom }
            }
            .toolbar {
                if let item, item.kind == .album || item.kind == .artist {
                    if #available(iOS 26.0, macOS 26.0, *) {
                        titleToolbar(item).sharedBackgroundVisibility(.hidden)
                    } else {
                        titleToolbar(item)
                    }
                }
            }
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
