import SwiftUI

/// Recent content reuses the catalog page owners, destinations, menus and player.
struct FoundationNewView<Profile: View>: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    let profile: Profile
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    @ObservedObject var tracks: FoundationBrowseModel
    @ObservedObject var albums: FoundationBrowseModel
    let isActive: Bool
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var trackRevision = 0
    @State private var albumRevision = 0
    @State private var openedItem: FoundationItem?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if connectivity.hasConnectionIssue || tracks.hasConnectionIssue
                    || albums.hasConnectionIssue
                {
                    FoundationOfflineNotice()
                }
                trackSection
                albumSection
                genreSection
                if let error = actions.pinErrorMessage, !connectivity.localOnly {
                    Text(error).foregroundStyle(.red)
                }
            }.padding()
                .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .refreshable {
            guard isActive, !connectivity.localOnly else { return }
            tracks.request(.refresh)
            albums.request(.refresh)
            trackRevision += 1
            albumRevision += 1
        }
        .foundationLibraryRefresh(
            revision: actions.libraryRefreshRevision,
            active: isActive && isVisible && !connectivity.localOnly
        ) {
            tracks.request(.refresh)
            albums.request(.refresh)
            trackRevision += 1
            albumRevision += 1
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive else { return }
            tracks.request(.refresh)
            albums.request(.refresh)
            trackRevision += 1
            albumRevision += 1
        }
        .foundationHeader("New", profile: profile)
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=new appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            #if DEBUG
                FoundationTrace.event("ui origin=new disappeared")
            #endif
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive)
    }

    private var displayedTracks: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: tracks.items) : tracks.items
    }

    private var displayedAlbums: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: albums.items) : albums.items
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connectivity.localOnly || !displayedTracks.isEmpty {
                sectionHeader("New Tracks", model: tracks) {
                    try await library.recentTracks(startIndex: $0)
                }
                ForEach(
                    Array(displayedTracks.prefix(6).enumerated()), id: \.offset
                ) { index, item in
                    FoundationLibraryItemRow(
                        item: item, library: library, isActive: isActive && isVisible,
                        open: {},
                        play: {
                            guard
                                let selection = FoundationTrackQueueSelection(
                                    in: displayedTracks, selecting: index,
                                    isAvailable: {
                                        !connectivity.localOnly || downloads.isReady($0)
                                    })
                            else { return }
                            player.setQueue(selection.items, selectedIndex: selection.index)
                        }, player: player, showsTrackArtwork: true)
                    if index < min(5, displayedTracks.count - 1) { Divider() }
                }
                sectionState(tracks) {
                    tracks.request(tracks.retryRequest)
                    trackRevision += 1
                }
            }
        }
        .task(
            id: isActive && isVisible ? trackRevision * 2 + (connectivity.localOnly ? 1 : 0) : nil
        ) {
            guard isActive, isVisible, !Task.isCancelled else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await tracks.refreshVisible(
                        allowsNetwork: !connectivity.localOnly
                    ) {
                        try await library.recentTracks(startIndex: $0)
                    }
                }
            #else
                await tracks.refreshVisible(allowsNetwork: !connectivity.localOnly) {
                    try await library.recentTracks(startIndex: $0)
                }
            #endif
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connectivity.localOnly || !displayedAlbums.isEmpty {
                sectionHeader("Recently Added", model: albums) {
                    try await library.recentAlbums(startIndex: $0)
                }
                if !displayedAlbums.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(Array(displayedAlbums.prefix(5).enumerated()), id: \.offset) {
                                _, item in
                                FoundationAlbumShelfCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 })
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .foundationMacShelfUnderlap()
                }
                sectionState(albums) {
                    albums.request(albums.retryRequest)
                    albumRevision += 1
                }
            }
        }
        .task(
            id: isActive && isVisible ? albumRevision * 2 + (connectivity.localOnly ? 1 : 0) : nil
        ) {
            guard isActive, isVisible, !Task.isCancelled else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await albums.refreshVisible(
                        allowsNetwork: !connectivity.localOnly
                    ) {
                        try await library.recentAlbums(startIndex: $0)
                    }
                }
            #else
                await albums.refreshVisible(allowsNetwork: !connectivity.localOnly) {
                    try await library.recentAlbums(startIndex: $0)
                }
            #endif
        }
    }

    private var recentGenres: [FoundationPrimaryGenreRecord.RecentGenre] {
        primaryGenres.completedRecord(libraryScope: library.primaryGenreIndexScope)?.recentGenres(
            songs: tracks.items,
            readySongIDs: connectivity.localOnly ? primaryGenres.readySongIDs : nil
        ) ?? []
    }

    @ViewBuilder private var genreSection: some View {
        let entries = recentGenres
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Genres with New Music").font(.title2.bold())
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 16) {
                        ForEach(entries, id: \.genre.genreIdentity) { entry in
                            FoundationGenreCard(
                                genre: entry.genre, library: library,
                                isActive: isActive && isVisible,
                                open: { openedItem = entry.genre }, artworkItem: entry.artwork
                            ).frame(width: 180)
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .foundationMacShelfUnderlap()
            }
        } else if !connectivity.localOnly,
            primaryGenres.completedRecord(libraryScope: library.primaryGenreIndexScope) == nil
        {
            Text(
                primaryGenres.isBuilding
                    ? "Preparing genres…" : "Genres are prepared automatically for your library."
            )
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(
        _ title: String, model: FoundationBrowseModel,
        loader: @escaping (Int) async throws -> FoundationPage
    ) -> some View {
        HStack(spacing: 6) {
            if !connectivity.localOnly,
                model.items.count > (model === tracks ? 6 : 5) || model.nextStartIndex != nil
            {
                NavigationLink {
                    FoundationCatalogView(
                        title: title, model: model, library: library, player: player,
                        isActive: isActive, showsTrackArtwork: true,
                        loader: loader
                    )
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #endif
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.title2.bold())
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityLabel("See all " + title.lowercased())
            } else {
                Text(title).font(.title2.bold()).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func sectionState(
        _ model: FoundationBrowseModel, retry: @escaping () -> Void
    ) -> some View {
        if model.isLoading, model.items.isEmpty, !connectivity.localOnly {
            FoundationLoadingPlaceholder(layout: model === albums ? .albumShelf : .rows)
        }
        if let error = model.errorMessage, !model.hasConnectionIssue, !connectivity.localOnly {
            Text(error).foregroundStyle(.red)
            Button("Retry") {
                guard !connectivity.localOnly else { return }
                retry()
            }.disabled(connectivity.localOnly)
        } else if !connectivity.localOnly, !model.hasConnectionIssue, model.loaded,
            model.items.isEmpty
        {
            Text("No recently added items.").foregroundStyle(.secondary)
        }
    }

}

/// A retained, bounded album ranking independent of New and Home.
struct FoundationLibraryMostPlayedAlbums: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    var refreshRevision = 0
    @State private var consumedRefreshRevision = 0
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    private var displayedItems: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: model.items) : model.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connectivity.localOnly || !displayedItems.isEmpty {
                Text("Most Played Albums").font(.title2.bold())
                Text("From your 100 most-played tracks").font(.subheadline).foregroundStyle(
                    .secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 144, maximum: 180), spacing: 16)],
                    alignment: .leading, spacing: 20
                ) {
                    ForEach(Array(displayedItems.prefix(12).enumerated()), id: \.offset) {
                        _, item in
                        FoundationAlbumShelfCard(
                            item: item, library: library, player: player,
                            isActive: isActive && isVisible, open: { openedItem = item },
                            navigate: { openedItem = $0 })
                    }
                }
                if connectivity.hasConnectionIssue || model.hasConnectionIssue {
                    FoundationOfflineNotice()
                }
                if model.isLoading, model.items.isEmpty, !connectivity.localOnly {
                    FoundationLoadingPlaceholder(layout: .albumGrid)
                }
                if let error = model.errorMessage, !model.hasConnectionIssue,
                    !connectivity.localOnly
                {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") {
                        guard !connectivity.localOnly else { return }
                        model.request(model.retryRequest)
                        revision += 1
                    }.disabled(connectivity.localOnly)
                } else if !connectivity.localOnly, !model.hasConnectionIssue, model.loaded,
                    model.items.isEmpty
                {
                    Text("No album listening history yet.").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            model.request(.refresh)
            revision += 1
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .task(
            id: isActive && isVisible && !connectivity.localOnly
                ? "\(revision)-\(refreshRevision)" : nil
        ) {
            guard isActive, isVisible, !Task.isCancelled else { return }
            if refreshRevision != consumedRefreshRevision {
                consumedRefreshRevision = refreshRevision
                model.request(.refresh)
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: .library, page: .shelf) {
                    await model.loadPending(
                        ifActive: isActive && isVisible && !connectivity.localOnly
                    ) { _ in
                        try await library.mostPlayedAlbums()
                    }
                }
            #else
                await model.loadPending(ifActive: isActive && isVisible && !connectivity.localOnly)
                { _ in
                    try await library.mostPlayedAlbums()
                }
            #endif
        }
    }
}
