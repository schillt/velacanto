import SwiftUI

/// Recent content reuses the catalog page owners, destinations, menus and player.
struct FoundationNewView<Profile: View>: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var trackRowHeight: CGFloat = 72
    @ScaledMetric(relativeTo: .caption) private var albumTextHeight: CGFloat = 88
    let profile: Profile
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @ObservedObject var tracks: FoundationBrowseModel
    @ObservedObject var albums: FoundationBrowseModel
    let isActive: Bool
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var trackRevision = 0
    @State private var albumRevision = 0
    @State private var openedItem: FoundationItem?
    @StateObject private var allArtists = FoundationBrowseModel()
    @State private var hasWideViewport = false

    private var previewLimit: Int { hasWideViewport ? 24 : 12 }

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
                artistSection
                genreSection
                if let error = actions.pinErrorMessage, !connectivity.localOnly {
                    Text(error).foregroundStyle(.red)
                }
            }.padding()
                .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .onGeometryChange(for: Bool.self) { geometry in
            geometry.size.width >= 600
        } action: { wide in
            hasWideViewport = wide
        }
        .refreshable { requestRefresh() }
        .foundationLibraryRefresh(
            revision: actions.libraryRefreshRevision,
            active: isActive && isVisible && !connectivity.localOnly
        ) { requestRefresh() }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive else { return }
            requestRefresh()
        }
        .foundationHeader("New", profile: profile)
        .onAppear {
            tracks.configureCatalogPagination()
            albums.configureCatalogPagination()
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

    private var displayedArtists: [FoundationItem] {
        FoundationNewMusicProjection.artists(
            albums: displayedAlbums, tracks: displayedTracks,
            source: library.primaryGenreIndexScope?.source)
    }

    private var active: Bool { isActive && isVisible && scenePhase == .active }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connectivity.localOnly || !displayedTracks.isEmpty {
                sectionHeader("New Tracks", model: tracks) {
                    try await library.recentTracks(startIndex: $0)
                }
                trackGrid(trackRows)
                sectionState(tracks) {
                    tracks.request(tracks.retryRequest)
                    trackRevision += 1
                }
            }
        }
        .task(id: active ? trackRevision * 2 + (connectivity.localOnly ? 1 : 0) : nil) {
            guard active, !Task.isCancelled else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await tracks.refreshVisible(allowsNetwork: !connectivity.localOnly) {
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

    private func trackGrid(
        _ rows: [FoundationLibraryIndexSelection.PositionedItem],
        genreID: String? = nil
    ) -> some View {
        ScrollView(.horizontal) {
            LazyHGrid(
                rows: [GridItem(.fixed(trackRowHeight)), GridItem(.fixed(trackRowHeight))],
                alignment: .top, spacing: 12
            ) {
                ForEach(rows.prefix(previewLimit)) { row in
                    FoundationLibraryItemRow(
                        item: row.item, library: library, isActive: active,
                        open: {}, play: { playTrack(row.id, genreID: genreID) },
                        player: player, showsTrackArtwork: true,
                        canPerform: { _ in
                            FoundationLibraryIndexSelection.admits(
                                row.item, current: currentTrack(row.id)?.item)
                        }
                    )
                    .lineLimit(1)
                    .containerRelativeFrame(.horizontal) { width, _ in
                        min(320, max(44, width * 0.82))
                    }
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .foundationHorizontalScrollIndicators()
        .foundationMacShelfUnderlap()
        .accessibilityIdentifier(genreID.map { "new-genre-tracks-" + $0 } ?? "new-tracks-carousel")
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !connectivity.localOnly || !displayedAlbums.isEmpty {
                sectionHeader("New Albums", model: albums) {
                    try await library.recentAlbums(startIndex: $0)
                }
                if !albumRows.isEmpty {
                    ScrollView(.horizontal) {
                        LazyHGrid(
                            rows: [
                                GridItem(.fixed(144 + albumTextHeight), alignment: .top),
                                GridItem(.fixed(144 + albumTextHeight), alignment: .top),
                            ], alignment: .top, spacing: 20
                        ) {
                            ForEach(albumRows.prefix(previewLimit)) { row in
                                FoundationAlbumShelfCard(
                                    item: row.item, library: library, player: player,
                                    isActive: active, open: { openAlbum(row.id) },
                                    navigate: { navigateAlbum($0, from: row.id) },
                                    canPerform: { _ in
                                        FoundationLibraryIndexSelection.admits(
                                            row.item, current: currentAlbum(row.id)?.item)
                                    })
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .foundationHorizontalScrollIndicators()
                    .foundationMacShelfUnderlap()
                    .accessibilityIdentifier("new-albums-carousel")
                }
                sectionState(albums) {
                    albums.request(albums.retryRequest)
                    albumRevision += 1
                }
            }
        }
        .task(id: active ? albumRevision * 2 + (connectivity.localOnly ? 1 : 0) : nil) {
            guard active, !Task.isCancelled else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: .new, page: .shelf) {
                    await albums.refreshVisible(allowsNetwork: !connectivity.localOnly) {
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

    @ViewBuilder private var artistSection: some View {
        let rows = artistRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink {
                    FoundationLibraryIndexView(
                        kind: .artist, model: allArtists, library: library,
                        player: player, isActive: isActive
                    )
                    #if os(iOS)
                        .toolbar(.visible, for: .navigationBar)
                    #endif
                } label: {
                    HStack(spacing: 6) {
                        Text("Artists with New Music").font(.title2.bold())
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse all artists")
                Text("Browse all artists in your library.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(rows.prefix(previewLimit)) { row in
                            FoundationAlbumShelfCard(
                                item: row.item, library: library, player: player,
                                isActive: active, open: { openArtist(row.id) },
                                canPerform: { _ in
                                    FoundationLibraryIndexSelection.admits(
                                        row.item, current: currentArtist(row.id)?.item)
                                })
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .foundationHorizontalScrollIndicators()
                .foundationMacShelfUnderlap()
                .accessibilityIdentifier("new-artists-carousel")
            }
        }
    }

    private var genreSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("New Music by Genre").font(.title2.bold())
            if let record = primaryGenres.completedRecord(
                libraryScope: library.primaryGenreIndexScope)
            {
                let groups = FoundationNewMusicProjection.albumGenreGroups(
                    record: record, albums: displayedAlbums,
                    readySongIDs: connectivity.localOnly ? primaryGenres.readySongIDs : nil)
                if groups.isEmpty {
                    Text(
                        albums.isLoading && displayedAlbums.isEmpty
                            ? "Loading new music…"
                            : "No matching genres in this selection. Browse New Albums to explore more."
                    ).font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(groups, id: \.genre.genreIdentity) { group in
                                FoundationGenreCard(
                                    genre: group.genre, library: library, isActive: active,
                                    open: { openGenre(group.genre) },
                                    artworkItem: group.albums.first
                                )
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    min(280, max(44, width * 0.72))
                                }
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .foundationHorizontalScrollIndicators()
                    .foundationMacShelfUnderlap()
                    .accessibilityIdentifier("new-genres-carousel")
                }
            } else {
                Text(
                    primaryGenres.isBuilding
                        ? "Preparing genres…"
                        : connectivity.localOnly
                            ? "Connect to prepare genres for this library."
                            : "Genres are prepared automatically for your library."
                ).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("new-music-by-genre")
    }

    private func requestRefresh() {
        guard active, !connectivity.localOnly else { return }
        tracks.request(.refresh)
        albums.request(.refresh)
        trackRevision += 1
        albumRevision += 1
    }

    private func sectionHeader(
        _ title: String, model: FoundationBrowseModel,
        loader: @escaping (Int) async throws -> FoundationPage
    ) -> some View {
        HStack(spacing: 6) {
            if !connectivity.localOnly, !model.items.isEmpty {
                NavigationLink {
                    FoundationCatalogView(
                        title: title, model: model, library: library, player: player,
                        isActive: isActive, showsTrackArtwork: true, loader: loader
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
            Button("Retry") { retry() }
        } else if !connectivity.localOnly, !model.hasConnectionIssue, model.loaded,
            model.items.isEmpty
        {
            Text("No recently added items.").foregroundStyle(.secondary)
        }
    }

    private var trackRows: [FoundationLibraryIndexSelection.PositionedItem] {
        guard tracks.hasUniqueCatalogIdentity else { return [] }
        return FoundationLibraryIndexSelection.positionedItems(displayedTracks, actions: actions)
    }

    private var albumRows: [FoundationLibraryIndexSelection.PositionedItem] {
        guard albums.hasUniqueCatalogIdentity else { return [] }
        return FoundationLibraryIndexSelection.positionedItems(displayedAlbums, actions: actions)
    }

    private var artistRows: [FoundationLibraryIndexSelection.PositionedItem] {
        FoundationLibraryIndexSelection.positionedItems(displayedArtists, actions: actions)
    }

    private func currentTrack(_ id: FoundationLibraryIndexSelection.Identity)
        -> FoundationLibraryIndexSelection.Match?
    {
        guard active else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedTracks, actions: actions)
    }

    private func currentAlbum(_ id: FoundationLibraryIndexSelection.Identity)
        -> FoundationLibraryIndexSelection.Match?
    {
        guard active else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedAlbums, actions: actions)
    }

    private func currentArtist(_ id: FoundationLibraryIndexSelection.Identity)
        -> FoundationLibraryIndexSelection.Match?
    {
        guard active else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedArtists, actions: actions)
    }

    private func playTrack(_ id: FoundationLibraryIndexSelection.Identity, genreID: String? = nil) {
        var items = displayedTracks
        if let genreID {
            guard
                let record = primaryGenres.completedRecord(
                    libraryScope: library.primaryGenreIndexScope)
            else { return }
            items = FoundationNewMusicProjection.tracks(
                in: genreID, record: record, tracks: items,
                readySongIDs: connectivity.localOnly ? primaryGenres.readySongIDs : nil)
        }
        guard active,
            let match = FoundationLibraryIndexSelection.resolve(id, in: items, actions: actions),
            let selection = FoundationTrackQueueSelection(
                in: items, selecting: match.sourceIndex,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func openAlbum(_ id: FoundationLibraryIndexSelection.Identity) {
        guard let match = currentAlbum(id) else { return }
        openedItem = match.item
    }

    private func openGenre(_ genre: FoundationItem) {
        guard active,
            let record = primaryGenres.completedRecord(
                libraryScope: library.primaryGenreIndexScope),
            genre.primaryGenreCensusID == record.snapshot.censusID,
            let current = record.descriptors.first(where: { $0.id == genre.id })
        else { return }
        openedItem = current
    }

    private func openArtist(_ id: FoundationLibraryIndexSelection.Identity) {
        guard let match = currentArtist(id) else { return }
        openedItem = match.item
    }

    private func navigateAlbum(
        _ target: FoundationItem, from id: FoundationLibraryIndexSelection.Identity
    ) {
        guard active,
            let item = FoundationLibraryIndexSelection.relatedDestination(
                target, from: id, in: displayedAlbums, actions: actions)
        else { return }
        openedItem = item
    }
}

/// Project only already-loaded New metadata; no provider reads or independent genre classification.
enum FoundationNewMusicProjection {
    struct GenreGroup {
        let genre: FoundationItem
        let tracks: [FoundationItem]
    }

    struct AlbumGenreGroup {
        let genre: FoundationItem
        let albums: [FoundationItem]
    }

    /// Join only loaded album IDs to canonical song membership; album tags are never authority.
    static func albumGenreGroups(
        record: FoundationPrimaryGenreRecord, albums: [FoundationItem],
        readySongIDs: Set<String>? = nil
    ) -> [AlbumGenreGroup] {
        guard record.contentMetadataVersion == FoundationPrimaryGenreContentIndex.version,
            let content = record.contentIndex
        else { return [] }
        var seenAlbums = Set<String>()
        let loaded = albums.filter {
            $0.kind == .album
                && ($0.catalogSource == nil || $0.catalogSource == record.snapshot.scope.source)
                && seenAlbums.insert($0.id).inserted
        }
        let loadedIDs = Set(loaded.map(\.id))
        guard !loadedIDs.isEmpty else { return [] }
        var genresByAlbum: [String: [String]] = [:]
        // One bounded local traversal, independent of the number of genre shelves.
        for songID in record.snapshot.orderedSongIDs {
            guard readySongIDs?.contains(songID) ?? true,
                let albumID = content.tracks[songID]?.albumID, loadedIDs.contains(albumID)
            else { continue }
            for genreID in record.snapshot.primaryBySongID[songID] ?? []
            where record.snapshot.eligibleGenreIDs.contains(genreID) {
                if !(genresByAlbum[albumID]?.contains(genreID) ?? false) {
                    genresByAlbum[albumID, default: []].append(genreID)
                }
            }
        }
        let descriptors = Dictionary(uniqueKeysWithValues: record.descriptors.map { ($0.id, $0) })
        var genreOrder: [String] = []
        for album in loaded {
            for genreID in genresByAlbum[album.id] ?? []
            where !genreOrder.contains(genreID) && genreOrder.count < 6 {
                genreOrder.append(genreID)
            }
        }
        return genreOrder.compactMap { genreID in
            guard let genre = descriptors[genreID] else { return nil }
            return AlbumGenreGroup(
                genre: genre,
                albums: Array(
                    loaded.filter {
                        genresByAlbum[$0.id]?.contains(genreID) ?? false
                    }.prefix(12)))
        }
    }

    private struct ArtistKey: Hashable {
        let source: FoundationCatalogSource?
        let id: String
    }

    static func artists(
        albums: [FoundationItem], tracks: [FoundationItem], source: FoundationCatalogSource?
    ) -> [FoundationItem] {
        var seen = Set<ArtistKey>()
        return (albums.filter { $0.kind == .album } + tracks.filter { $0.kind == .track })
            .compactMap {
                item in
                guard source == nil || item.catalogSource == nil || item.catalogSource == source,
                    let artist = item.relatedArtist,
                    source == nil || artist.catalogSource == nil || artist.catalogSource == source,
                    seen.insert(.init(source: artist.catalogSource ?? source, id: artist.id))
                        .inserted
                else { return nil }
                return artist
            }
    }

    static func tracks(
        in genreID: String, record: FoundationPrimaryGenreRecord, tracks: [FoundationItem],
        readySongIDs: Set<String>? = nil
    ) -> [FoundationItem] {
        var seen = Set<String>()
        return tracks.filter { item in
            item.kind == .track
                && (item.catalogSource == nil || item.catalogSource == record.snapshot.scope.source)
                && (readySongIDs?.contains(item.id) ?? true)
                && (record.snapshot.primaryBySongID[item.id]?.contains(genreID) ?? false)
                && seen.insert(item.id).inserted
        }
    }

    static func genreGroups(
        record: FoundationPrimaryGenreRecord, tracks: [FoundationItem],
        readySongIDs: Set<String>? = nil
    ) -> [GenreGroup] {
        record.recentGenres(songs: tracks, readySongIDs: readySongIDs).map { entry in
            GenreGroup(
                genre: entry.genre,
                tracks: self.tracks(
                    in: entry.genre.id, record: record, tracks: tracks, readySongIDs: readySongIDs))
        }
    }
}

/// A retained, bounded album ranking independent of New and Home.
struct FoundationLibraryMostPlayedAlbums: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var actions: FoundationLibraryActions
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
                    ForEach(
                        FoundationLibraryIndexSelection.positionedItems(
                            displayedItems, actions: actions
                        )
                        .prefix(12)
                    ) { row in
                        let item = row.item
                        FoundationAlbumShelfCard(
                            item: item, library: library, player: player,
                            isActive: isActive && isVisible, open: { openAlbum(row.id) },
                            navigate: { navigateAlbum($0, from: row.id) },
                            canPerform: { _ in
                                FoundationLibraryIndexSelection.admits(
                                    row.item, current: currentAlbum(row.id)?.item)
                            })
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
    private func currentAlbum(_ id: FoundationLibraryIndexSelection.Identity)
        -> FoundationLibraryIndexSelection.Match?
    {
        guard isActive, isVisible else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedItems, actions: actions)
    }

    private func openAlbum(_ id: FoundationLibraryIndexSelection.Identity) {
        guard let match = currentAlbum(id) else { return }
        openedItem = match.item
    }

    private func navigateAlbum(
        _ target: FoundationItem, from id: FoundationLibraryIndexSelection.Identity
    ) {
        guard isActive, isVisible,
            let item = FoundationLibraryIndexSelection.relatedDestination(
                target, from: id, in: displayedItems, actions: actions)
        else { return }
        openedItem = item
    }

}
