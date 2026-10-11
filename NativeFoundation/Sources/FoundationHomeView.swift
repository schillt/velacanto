import SwiftUI

/// Home composes independently owned, visible catalog sections around the existing player.
struct FoundationHomeView<Profile: View>: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    let profile: Profile
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @ObservedObject var recentTracks: FoundationBrowseModel
    @ObservedObject var favorites: FoundationBrowseModel
    @ObservedObject var recentAlbums: FoundationBrowseModel
    @ObservedObject var genres: FoundationBrowseModel
    let isActive: Bool
    var hasQueue = false
    var accountLibrary: (any FoundationLibrary)? = nil
    @State private var isVisible = false
    @State private var genreRetryRevision = 0
    @State private var refreshRevision = 0
    @State private var showingPlayer = false
    @State private var openedItem: FoundationItem?
    @EnvironmentObject private var actions: FoundationLibraryActions

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if connectivity.hasConnectionIssue
                    || [recentTracks, favorites, recentAlbums, genres].contains(
                        where: \.hasConnectionIssue)
                {
                    FoundationOfflineNotice()
                }
                FoundationContinueListening(
                    player: player, library: library, isActive: isActive && isVisible,
                    showingPlayer: $showingPlayer)
                FoundationHomeShelf(
                    title: "Recently Played", model: recentTracks, library: library, player: player,
                    isActive: isActive, refreshRevision: refreshRevision, showsTracks: true,
                    openedItem: $openedItem
                ) { try await library.recentlyPlayed(startIndex: $0) }
                // A bounded mixed collection preview; the heading opens complete Favorites.
                FoundationHomeShelf(
                    title: "Favorites", model: favorites, library: library, player: player,
                    isActive: isActive, refreshRevision: refreshRevision, isFavorites: true,
                    openedItem: $openedItem
                ) { _ in try await library.favoriteCollectionsPreview() }
                FoundationHomeShelf(
                    title: "Recently Added", model: recentAlbums, library: library, player: player,
                    isActive: isActive, refreshRevision: refreshRevision,
                    openedItem: $openedItem
                ) { try await library.recentAlbums(startIndex: $0) }
                genreShelves
                if let error = actions.pinErrorMessage { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=home appeared")
            #endif
        }
        .onDisappear {
            actions.cancelQueueAddition()
            isVisible = false
            #if DEBUG
                FoundationTrace.event("ui origin=home disappeared")
            #endif
        }
        .refreshable {
            guard isActive, !connectivity.localOnly else { return }
            recentTracks.request(.refresh)
            favorites.request(.refresh)
            recentAlbums.request(.refresh)
            genres.request(.refresh)
            refreshRevision += 1
            genreRetryRevision += 1
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive else { return }
            recentTracks.request(.refresh)
            favorites.request(.refresh)
            recentAlbums.request(.refresh)
            genres.request(.refresh)
            refreshRevision += 1
            genreRetryRevision += 1
        }
        .foundationHeader("Home", profile: profile)
        #if DEBUG
            .onChange(of: showingPlayer) { _, presented in
                FoundationTrace.event(
                    presented
                        ? "ui origin=home player=presented" : "ui origin=home player=dismissed")
            }
        #endif
        .foundationPlayerCover(isPresented: $showingPlayer, player: player) {
            FoundationPlayerView(player: player, library: accountLibrary ?? library)
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive)
    }

    private var genreShelves: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            ForEach(Array(genres.items.prefix(5).enumerated()), id: \.element.id) { _, genre in
                FoundationHomeGenreShelf(
                    genre: genre, library: library, player: player,
                    isActive: isActive, refreshRevision: refreshRevision,
                    openedItem: $openedItem)
            }
            if genres.isLoading, genres.items.isEmpty, !connectivity.localOnly {
                FoundationLoadingPlaceholder(layout: .albumShelf)
            }
            if let error = genres.errorMessage, !genres.hasConnectionIssue {
                Text(error).foregroundStyle(.red)
                Button("Retry genres") {
                    guard !connectivity.localOnly else { return }
                    genres.request(genres.retryRequest)
                    genreRetryRevision += 1
                }.disabled(connectivity.localOnly)
            }
        }
        .task(
            id: isActive && isVisible
                ? genreRetryRevision * 2 + (connectivity.localOnly ? 1 : 0) : nil
        ) {
            guard isActive, isVisible, !Task.isCancelled else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .genreIndex) {
                    await genres.refreshVisible(
                        allowsNetwork: !connectivity.localOnly
                    ) { _ in
                        try await library.homeGenres()
                    }
                }
            #else
                await genres.refreshVisible(allowsNetwork: !connectivity.localOnly) { _ in
                    try await library.homeGenres()
                }
            #endif
        }
    }
}

private struct FoundationContinueListening: View {
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @ObservedObject var player: FoundationPlayer
    let library: any FoundationLibrary
    let isActive: Bool
    @Binding var showingPlayer: Bool

    var body: some View {
        if let item = player.queue.first(where: { $0.id == player.selectedEntryID })?.item,
            !connectivity.localOnly || downloads.isReady(item)
        {
            continueListening(item)
        }
    }

    private var playbackProgress: Double {
        guard player.duration.isFinite, player.duration > 0, player.elapsed.isFinite else {
            return 0
        }
        return min(1, max(0, player.elapsed / player.duration))
    }

    private func continueListening(_ item: FoundationItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Listening")
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase).tracking(1)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Button {
                    showingPlayer = true
                } label: {
                    HStack(spacing: 12) {
                        FoundationCatalogArtwork(
                            source: .current(currentArtwork.result(for: item)),
                            item: item.catalogArtworkItem, library: library,
                            isActive: isActive, size: 64
                        ).id(
                            item.catalogArtworkItem.id
                                + (item.catalogArtworkItem.primaryImageTag ?? ""))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.headline).lineLimit(2)
                            Text(
                                player.state == .playing || player.state == .paused
                                    ? item.subtitle : player.state.label
                            )
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Now Playing")
                .accessibilityValue(item.title + ", " + item.subtitle + ", " + player.state.label)
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(.quaternary, in: Circle())
                        .overlay {
                            Circle()
                                .trim(from: 0, to: playbackProgress)
                                .stroke(
                                    .primary.opacity(0.75),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                                .padding(2)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
    }

}

private struct FoundationHomeGenreShelf: View {
    let genre: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let refreshRevision: Int
    @Binding var openedItem: FoundationItem?
    @StateObject private var albums: FoundationBrowseModel

    init(
        genre: FoundationItem, library: any FoundationLibrary, player: FoundationPlayer,
        isActive: Bool, refreshRevision: Int, openedItem: Binding<FoundationItem?>
    ) {
        self.genre = genre
        self.library = library
        self.player = player
        self.isActive = isActive
        self.refreshRevision = refreshRevision
        _openedItem = openedItem
        let model = FoundationBrowseModel()
        model.configureCache(
            library.catalogPageCache, key: library.catalogCacheKey("home.genre." + genre.id))
        _albums = StateObject(wrappedValue: model)
    }

    var body: some View {
        FoundationHomeShelf(
            title: genre.title, model: albums, library: library, player: player,
            isActive: isActive, refreshRevision: refreshRevision,
            openedItem: $openedItem
        ) { try await library.albums(genreID: genre.id, startIndex: $0) }
    }
}

private struct FoundationHomeShelf: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshOnActivation = true
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var refreshRevision = 0
    var showsTracks = false
    var isFavorites = false
    @Binding var openedItem: FoundationItem?
    let loader: (Int) async throws -> FoundationPage
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var retryRevision = 0
    @State private var consumedRefreshRevision = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var displayedItems: [FoundationItem] {
        isFavorites ? actions.favoriteItems(in: model.items) : model.items
    }

    private var favoritesActivation: Bool {
        isActive && isVisible && scenePhase == .active && !connectivity.localOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if isFavorites || !displayedItems.isEmpty || model.nextStartIndex != nil {
                    NavigationLink {
                        if isFavorites {
                            FoundationFavoritesView(
                                library: library, player: player, isActive: isActive)
                        } else {
                            FoundationCatalogView(
                                title: title, model: model, library: library, player: player,
                                isActive: isActive, loader: loader)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(title).font(.title2.bold())
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all " + title.lowercased())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(isFavorites ? "home-favorites" : "home-shelf-" + title)
                } else {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
            }
            if showsTracks {
                if usesVerticalRecentRows {
                    VStack(spacing: 12) {
                        recentRows
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: [GridItem(.fixed(64)), GridItem(.fixed(64))], spacing: 16) {
                            recentRows
                        }
                        .frame(height: 136)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .foundationMacShelfUnderlap()
                    .accessibilityLabel("Recently Played carousel")
                }
            } else if !displayedItems.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(displayedItems.prefix(5).enumerated()), id: \.offset) {
                            _, item in
                            if isFavorites {
                                FoundationCollectionCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 }
                                )
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 160)
                            } else {
                                FoundationAlbumShelfCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 })
                            }
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .modifier(FoundationHomeShelfBoundary(contained: isFavorites))
            }
            if model.hasConnectionIssue, !connectivity.hasConnectionIssue {
                FoundationOfflineNotice()
            }
            if model.isLoading, displayedItems.isEmpty, !connectivity.localOnly {
                FoundationLoadingPlaceholder(layout: showsTracks ? .rows : .albumShelf)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    guard !connectivity.localOnly else { return }
                    model.request(model.retryRequest)
                    retryRevision += 1
                }.disabled(connectivity.localOnly)
            } else if !connectivity.localOnly, !model.hasConnectionIssue, model.loaded,
                displayedItems.isEmpty
            {
                Text(
                    model.nextStartIndex == nil
                        ? "No items yet."
                        : "No matches in this page. Open the full list to load more."
                ).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=home appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            refreshOnActivation = true
            #if DEBUG
                FoundationTrace.event("ui origin=home disappeared")
            #endif
        }
        .onChange(of: favoritesActivation) { _, active in
            if !active { refreshOnActivation = true }
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            if isFavorites, isActive, isVisible, !connectivity.localOnly {
                model.request(.refresh)
                retryRevision += 1
            }
        }
        .task(
            id: isActive && isVisible && scenePhase == .active
                ? "\(refreshRevision):\(retryRevision):\(connectivity.localOnly)" : nil
        ) {
            guard isActive, isVisible, scenePhase == .active, !Task.isCancelled else { return }
            if isFavorites, favoritesActivation, refreshOnActivation {
                refreshOnActivation = false
                if model.loaded { model.request(.refresh) }
            }
            // This capped preview cannot establish nonmembership from absent rows.
            model.configureFavoriteObservations(actions)
            if refreshRevision != consumedRefreshRevision {
                model.request(.refresh)
                consumedRefreshRevision = refreshRevision
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .shelf) {
                    guard isActive, isVisible, !Task.isCancelled else {
                        return
                    }
                    await model.refreshVisible(
                        allowsNetwork: !connectivity.localOnly, using: loader)
                }
            #else
                guard isActive, isVisible, !Task.isCancelled else {
                    return
                }
                await model.refreshVisible(allowsNetwork: !connectivity.localOnly, using: loader)
            #endif
        }
    }

    private var usesVerticalRecentRows: Bool {
        dynamicTypeSize.isAccessibilitySize
            || displayedItems.prefix(6).contains { actions.errorMessage(for: $0) != nil }
    }

    private var recentRows: some View {
        ForEach(
            Array(displayedItems.prefix(6).enumerated()).filter {
                !connectivity.localOnly || downloads.isReady($0.element)
            }, id: \.offset
        ) { index, item in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        playRecent(index)
                    } label: {
                        HStack(spacing: 10) {
                            homeArtwork(
                                item, library: library, isActive: isActive && isVisible, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.body.weight(.medium))
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    FoundationDownloadBadge(item: item)
                    Menu {
                        recentMenu(item, index: index)
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .foundationEllipsisMenuIndicator()
                    .accessibilityLabel("Actions for " + item.title)
                }
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(width: usesVerticalRecentRows ? nil : 276)
            .contextMenu { recentMenu(item, index: index) }
        }
    }

    private func playRecent(_ index: Int) {
        guard let selection = model.trackQueue(selecting: index) else { return }
        if connectivity.localOnly {
            guard downloads.isReady(selection.items[selection.index]) else { return }
            let ready = selection.items.filter { downloads.isReady($0) }
            let index = selection.items.prefix(selection.index).filter { downloads.isReady($0) }
                .count
            player.setQueue(ready, selectedIndex: index)
        } else {
            player.setQueue(selection.items, selectedIndex: selection.index)
        }
    }

    private func recentMenu(_ item: FoundationItem, index: Int) -> some View {
        FoundationItemMenu(
            item: item, actions: actions, initialFavorite: item.isFavorite,
            play: { playRecent(index) }, player: player, navigate: { openedItem = $0 })
    }

}

/// Display supplied album artwork without resolving metadata or changing the source item.
@MainActor private func homeArtwork(
    _ item: FoundationItem, library: any FoundationLibrary, isActive: Bool, size: CGFloat
) -> some View {
    let artworkItem = item.catalogArtworkItem
    return FoundationCatalogArtwork(
        item: artworkItem, library: library, isActive: isActive, size: size
    ).id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
}

private struct FoundationHomeShelfBoundary: ViewModifier {
    let contained: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if contained {
            content.foundationMacContainedShelf()
        } else {
            content.foundationMacShelfUnderlap()
        }
    }
}
