import SwiftUI

/// Native search controls with the existing catalog owner, rows and destinations.
struct FoundationSearchView<Profile: View>: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let profile: Profile
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @Namespace private var searchGlass
    @FocusState private var searchFocused: Bool
    @State private var searchExpanded = false
    @State private var cancelledActivation: Int?
    @State private var openedItem: FoundationItem?
    @State private var openedCategory: FoundationSearchCategorySelection?
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    @Binding var query: String
    let isActive: Bool
    let activation: Int
    let openLocalLibrary: () -> Void
    let isCurrentCatalog: @MainActor (FoundationComposedCatalogModel.Context) -> Bool

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if term.isEmpty {
                genreGrid
            } else {
                FoundationSearchOverview(
                    query: term, library: library, player: player, isActive: isActive,
                    openedItem: $openedItem, openCategory: { openedCategory = $0 }
                )
                .id(term + (connectivity.localOnly ? "-local" : "-online"))
            }
        }
        // The destination owner survives replacement of query-scoped result models.
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .navigationDestination(
            isPresented: Binding(
                get: { openedCategory != nil },
                set: { if !$0 { openedCategory = nil } })
        ) {
            if let category = openedCategory {
                if category.kind == .genre {
                    FoundationPrimaryGenresView(
                        library: library, player: player, isActive: isActive,
                        context: .libraryRows, initialQuery: term
                    )
                    .foundationCatalogHeader("Genres")
                } else if category.kind == .track {
                    FoundationComposedSongsView(
                        query: .search(text: term, kind: .track), library: library, player: player,
                        isActive: isActive, initialFilter: .all,
                        openLocalLibrary: openLocalLibrary,
                        isCurrent: { context in
                            context.query == .search(text: term, kind: .track)
                                && openedCategory?.kind == .track && isCurrentCatalog(context)
                        }
                    ) { active, presented in
                        FoundationSearchCategory(
                            title: category.title, query: term, kind: .track,
                            library: library, player: player, isActive: active,
                            initialPage: category.page, initialLocalOnly: category.localOnly,
                            showsContent: presented)
                    }
                } else {
                    FoundationSearchCategory(
                        title: category.title, query: term, kind: category.kind,
                        library: library, player: player, isActive: isActive,
                        initialPage: category.page, initialLocalOnly: category.localOnly,
                        musicContext: category.musicContext,
                        initialIncompleteCoverage: category.incompleteCoverage)
                }
            }
        }
        .onChange(of: query) { _, _ in
            openedItem = nil
            openedCategory = nil
        }
        #if os(macOS)
            .foundationHeader("Search", profile: profile)
        #else
            .foundationSearchHeader(
                profile: profile, search: searchField, keepsVisible: searchExpanded
            )
            .onChange(of: activation, initial: true) { _, value in
                if isActive, value > 0, cancelledActivation != value { beginSearchFocus() }
            }
        #endif
        .onChange(of: searchFocused) { _, focused in
            animateSearchExpansion(focused)
        }
        .onChange(of: isActive) { _, active in
            if !active { searchFocused = false }
        }
        #if os(iOS)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { searchFocused = false }
            }
            .scrollDismissesKeyboard(.immediately)
        #endif
    }

    private var searchInput: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                connectivity.localOnly
                    ? "Downloaded music and saved collections" : "Albums, artists, and songs",
                text: $query
            )
            .textFieldStyle(.plain)
            .focused($searchFocused)
            .autocorrectionDisabled()
            .submitLabel(.search)
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .simultaneousGesture(TapGesture().onEnded { beginSearchFocus() })
            .accessibilityLabel("Search music")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(
                    "Clear search")
            }
        }
        .padding(.leading, 14).padding(.trailing, query.isEmpty ? 14 : 0)
        .frame(minHeight: 44)
    }

    private func beginSearchFocus() {
        // Start splitting the glass on touch, before keyboard focus/layout completes.
        animateSearchExpansion(true)
        searchFocused = true
    }

    private func animateSearchExpansion(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
            searchExpanded = expanded
        }
    }

    private func cancelSearchFocus() {
        cancelledActivation = activation
        animateSearchExpansion(false)
        searchFocused = false
    }

    private var searchField: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                Group {
                    if reduceTransparency {
                        searchInput.background(.background, in: Capsule())
                    } else {
                        searchInput.glassEffect(.regular, in: Capsule())
                            .glassEffectID("search-input", in: searchGlass)
                    }
                }
                if searchExpanded {
                    dismissKeyboardButton
                        .glassEffectID("search-dismiss", in: searchGlass)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        .transition(.identity)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: searchExpanded)
        }
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var dismissKeyboardButton: some View {
        Button(action: cancelSearchFocus) {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            if reduceTransparency { Circle().fill(.background) }
        }
        .glassEffect(reduceTransparency ? .identity : .regular.interactive(), in: Circle())
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Dismiss search keyboard")
        .accessibilityIdentifier("search-dismiss-keyboard")
        .accessibilityHint("Keeps your search. Tap the search field to type again.")
    }

    private var genreGrid: some View {
        FoundationPrimaryGenresView(
            library: library, player: player, isActive: isActive, context: .cards,
            openItem: { openedItem = $0 })
    }
}

/// Small sequential result sections share local and remote catalog identities.
private struct FoundationSearchCategorySelection {
    let title: String
    let kind: FoundationItem.Kind
    let page: FoundationPage
    let localOnly: Bool
    var musicContext: FoundationMusicSearchContext? = nil
    var incompleteCoverage = false
}

private struct FoundationSearchOverview: View {
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let query: String
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var genreResults = FoundationBrowseModel()
    @State private var isVisible = false
    @State private var collectionOperationOwner = UUID()
    @State private var revision = 0
    @State private var rawDirect: [FoundationSearchResolver.DirectSection] = []
    @State private var rawRelated: [FoundationSearchResolver.RelatedSection] = []
    @State private var rawDiscovery: [FoundationItem] = []
    @State private var playlistContents: FoundationPlaylistContentPage?
    @State private var playlistMusicContext = FoundationMusicSearchContext()
    @State private var playlistContentError: FoundationLibraryError?
    @State private var isResolving = false
    @State private var resolutionID = UUID()
    @State private var resolvedRevision: Int?
    @State private var hasPartialFailure = false
    @Binding var openedItem: FoundationItem?
    let openCategory: (FoundationSearchCategorySelection) -> Void

    private var sections: [(title: String, kind: FoundationItem.Kind, model: FoundationBrowseModel)]
    {
        [
            ("Songs", .track, songs), ("Albums", .album, albums), ("Artists", .artist, artists),
            ("Playlists", .playlist, playlists), ("Genres", .genre, genreResults),
        ]
    }

    private var displaySections: [FoundationSearchResolver.DisplaySection] {
        FoundationSearchResolver.displaySections(
            direct: rawDirect.map { section in
                .init(
                    kind: section.kind,
                    page: .init(
                        items: projected(section.page.items),
                        nextStartIndex: section.page.nextStartIndex),
                    includesFuzzyMatches: section.includesFuzzyMatches, error: section.error)
            },
            related: rawRelated.map { section in
                .init(role: section.role, source: section.source, items: projected(section.items))
            }, query: query)
    }

    private var discovery: [FoundationItem] {
        let shown = Set(
            displaySections.flatMap { $0.items.prefix(5) }.map { $0.kind.rawValue + ":" + $0.id })
        return projected(rawDiscovery).filter { !shown.contains($0.kind.rawValue + ":" + $0.id) }
    }

    private func projected(_ items: [FoundationItem]) -> [FoundationItem] {
        actions.visibleTracks(
            items, isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
    }

    private func rawCategoryItems(_ kind: FoundationItem.Kind) -> [FoundationItem] {
        FoundationSearchResolver.displaySections(
            direct: rawDirect, related: rawRelated, query: query
        ).first { $0.kind == kind }?.items ?? []
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if connectivity.hasConnectionIssue
                    || sections.contains(where: { $0.model.hasConnectionIssue })
                {
                    FoundationOfflineNotice()
                }
                if connectivity.localOnly {
                    Text("Searching downloaded music and saved collections.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(displaySections, id: \.role) { section in
                    if let kind = section.kind,
                        let source = sections.first(where: { $0.kind == kind })
                    {
                        resultSection(
                            displayTitle(section.role), kind: kind,
                            model: source.model, items: section.items,
                            rawItems: rawCategoryItems(kind))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Top Results").font(.title2.bold()).frame(minHeight: 44)
                            resultRows(section.items, showsItemType: true)
                        }
                    }
                }
                if let playlistContents,
                    !playlistContents.items.isEmpty || playlistContents.hasIncompleteCoverage
                {
                    playlistContentSection(playlistContents)
                }
                if let error = playlistContentError {
                    Text(error.localizedDescription).foregroundStyle(.red)
                    Button("Retry playlist search", action: retrySearch)
                }
                ForEach(sections, id: \.title) { section in
                    if let error = section.model.errorMessage, !section.model.hasConnectionIssue {
                        Text(error).foregroundStyle(.red)
                        Button("Retry search", action: retrySearch)
                    }
                }
                if hasPartialFailure {
                    Text("Some related or close matches could not be loaded.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Retry search", action: retrySearch)
                }
                if isResolving || sections.contains(where: { $0.model.isLoading }) {
                    FoundationLoadingPlaceholder()
                }
                if !isResolving, displaySections.isEmpty,
                    sections.allSatisfy({
                        $0.model.loaded && $0.model.items.isEmpty && $0.model.errorMessage == nil
                    })
                {
                    Text("No results found.").foregroundStyle(.secondary)
                }
                if !discovery.isEmpty { discoveryCarousel }
            }.padding(.horizontal).padding(.bottom)
                .foundationBottomChromeEndPadding()
        }
        .foundationBottomChromeScrollClearance()
        .environment(\.foundationCollectionOperationOwner, collectionOperationOwner)
        .foundationCollectionOutcomePresentation(owner: collectionOperationOwner)
        .onAppear { isVisible = true }
        .onDisappear {
            isVisible = false
            actions.cancelQueueAdditionOwned(by: collectionOperationOwner)
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            for section in sections { section.model.request(.refresh) }
            resolvedRevision = nil
        }
        .onChange(of: primaryGenres.publicationRevision) { _, _ in
            for section in sections { section.model.clearRetainedData() }
            resolvedRevision = nil
            revision += 1
        }
        .onReceive(downloads.objectWillChange) {
            if connectivity.localOnly { revision += 1 }
        }
        .task(id: "\(isActive && isVisible)-\(revision)-\(connectivity.successfulRetryRevision)") {
            guard isActive, isVisible else { return }
            if !connectivity.localOnly {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: .search, page: .catalog) {
                    await loadSections()
                }
            #else
                await loadSections()
            #endif
        }
    }

    private func retrySearch() {
        for section in sections { section.model.request(.refresh) }
        revision += 1
    }

    private func loadSections() async {
        // A single query snapshot owns both direct and relationship results.
        guard resolvedRevision != revision else { return }
        let localOnly = connectivity.localOnly
        let identity = UUID()
        resolutionID = identity
        isResolving = true
        defer { if resolutionID == identity { isResolving = false } }
        let resolver: FoundationSearchResolver
        if localOnly {
            resolver = FoundationSearchResolver(localSearch: { query, kind, limit in
                if kind == .genre {
                    return await primaryGenres.page(query: query, limit: limit, localOnly: true)
                }
                return await downloads.localSearch(
                    query: query, kind: kind, startIndex: 0, limit: limit)
            })
        } else {
            let snapshot = primaryGenres.record
            resolver = FoundationSearchResolver(
                library: library,
                genreSearch: { query, _, limit in
                    snapshot?.page(query: query, limit: limit)
                        ?? .init(items: [], nextStartIndex: nil)
                })
        }
        do {
            let result = try await resolver.resolve(query: query)
            try Task.checkCancellation()
            guard connectivity.localOnly == localOnly, resolutionID == identity else { return }
            for section in sections {
                guard let direct = result.direct.first(where: { $0.kind == section.kind }) else {
                    continue
                }
                if localOnly {
                    section.model.request(.refresh)
                } else {
                    section.model.configureFavoriteObservations(actions)
                }
                await section.model.loadPending { _ in
                    if let error = direct.error { throw error }
                    return direct.page
                }
                try Task.checkCancellation()
            }
            actions.observeTrackCopies(
                result.direct.flatMap { $0.page.items } + result.related.flatMap(\.items)
                    + result.discovery)
            rawDirect = result.direct
            rawRelated = result.related
            rawDiscovery = result.discovery
            playlistContents = result.playlistContents
            playlistMusicContext = result.musicContext
            playlistContentError = result.playlistContentError
            hasPartialFailure = result.failures.contains {
                if case .direct = $0 { return false }
                return true
            }
            resolvedRevision = revision
        } catch {
            // Resolver cancellation never publishes an obsolete query snapshot.
            return
        }
    }

    private func displayTitle(_ role: FoundationSearchResolver.DisplaySection.Role) -> String {
        switch role {
        case .top: "Top Results"
        case .relatedSongs: "Related Songs"
        case .relatedArtists: "Related Artists"
        case .relatedAlbums: "Related Albums"
        case .relatedPlaylists: "Playlists"
        case .relatedGenres: "Genres"
        }
    }

    private var discoveryCarousel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("You May Also Like").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(Array(discovery.enumerated()), id: \.offset) { index, item in
                        FoundationCollectionCard(
                            item: item, library: library, player: player,
                            isActive: isActive && isVisible,
                            showsTrackArtwork: true, subtitleOverride: typedSubtitle(for: item),
                            open: {
                                if item.kind == .track {
                                    playResult(discovery, index: index)
                                } else {
                                    openedItem = item
                                }
                            }, navigate: { openedItem = $0 }
                        ).frame(width: 150)
                    }
                }.scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .foundationMacShelfUnderlap(horizontalInset: 0, contentInset: 0)
        }
    }

    private func playlistContentSection(_ page: FoundationPlaylistContentPage) -> some View {
        let title = "Playlists with “" + query + "”"
        return VStack(alignment: .leading, spacing: 12) {
            Button {
                openCategory(
                    .init(
                        title: title, kind: .playlist,
                        page: .init(items: page.items, nextStartIndex: page.nextStartIndex),
                        localOnly: false, musicContext: playlistMusicContext,
                        incompleteCoverage: page.hasIncompleteCoverage
                            || page.partialFailureCount > 0))
            } label: {
                HStack(spacing: 6) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }.buttonStyle(.plain).accessibilityLabel("See all " + title)
            resultRows(page.items)
            if page.hasIncompleteCoverage {
                Text("More playlists or tracks may contain matching music.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if page.partialFailureCount > 0 {
                Text("Some playlists could not be checked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func resultRows(_ items: [FoundationItem], showsItemType: Bool = false) -> some View {
        if !items.isEmpty, items.allSatisfy({ $0.kind == .genre }) {
            ForEach(Array(items.prefix(5)), id: \.genreIdentity) { item in
                FoundationGenrePresentation(
                    genre: item, library: library, player: player,
                    isActive: isActive && isVisible, context: .libraryRow,
                    open: { openedItem = item }, navigate: { openedItem = $0 })
            }
        } else {
            ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { index, item in
                FoundationLibraryItemRow(
                    item: item, library: library, isActive: isActive && isVisible,
                    open: { openedItem = item },
                    play: item.kind == .track ? { playResult(items, index: index) } : nil,
                    player: player, showsTrackArtwork: true, navigate: { openedItem = $0 },
                    subtitleOverride: showsItemType
                        ? typedSubtitle(for: item) : relatedSubtitle(for: item))
            }
        }
    }

    private func typedSubtitle(for item: FoundationItem) -> String {
        let type: String =
            switch item.kind {
            case .track: "Song"
            case .album: "Album"
            case .artist: "Artist"
            case .playlist: "Playlist"
            case .genre: "Genre"
            }
        return item.subtitle.isEmpty ? type : type + " · " + item.subtitle
    }

    private func relatedSubtitle(for item: FoundationItem) -> String? {
        guard item.kind == .track else { return nil }
        let artist = item.subtitle.isEmpty ? (item.artist?.title ?? "") : item.subtitle
        let parts = [item.album?.title ?? "", artist].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func playResult(_ items: [FoundationItem], index: Int) {
        guard
            let selection = FoundationTrackQueueSelection(
                in: items, selecting: index,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func resultSection(
        _ title: String, kind: FoundationItem.Kind, model: FoundationBrowseModel,
        items: [FoundationItem], rawItems: [FoundationItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.nextStartIndex != nil || items.count > 5 {
                Button {
                    openCategory(
                        .init(
                            title: title, kind: kind,
                            page: .init(items: rawItems, nextStartIndex: model.nextStartIndex),
                            localOnly: connectivity.localOnly))
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
            resultRows(items)
        }
    }
}

private struct FoundationSearchCategory: View {
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    let query: String
    let kind: FoundationItem.Kind
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    let initialPage: FoundationPage
    let initialLocalOnly: Bool
    var musicContext: FoundationMusicSearchContext? = nil
    var initialIncompleteCoverage = false
    var showsContent = true
    @State private var contentCoverage = false
    @StateObject private var results = FoundationBrowseModel()

    @ViewBuilder var body: some View {
        if showsContent { categoryBody }
    }

    private var categoryBody: some View {
        FoundationCatalogView(
            title: title, model: results, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true,
            coverageMessage: musicContext != nil && (contentCoverage || initialIncompleteCoverage)
                ? "More playlists or tracks may contain matching music." : nil
        ) { offset in
            if kind == .genre {
                return primaryGenres.page(
                    query: query, startIndex: offset, localOnly: connectivity.localOnly)
            }
            if offset == 0, connectivity.localOnly == initialLocalOnly { return initialPage }
            if connectivity.localOnly {
                if musicContext != nil { return .init(items: [], nextStartIndex: nil) }
                return downloads.localSearch(
                    query: query, kind: kind, startIndex: offset, limit: 50)
            }
            if let musicContext {
                let page = try await library.playlistsContainingMusic(
                    context: musicContext, startIndex: offset)
                try Task.checkCancellation()
                contentCoverage = page.hasIncompleteCoverage || page.partialFailureCount > 0
                return .init(items: page.items, nextStartIndex: page.nextStartIndex)
            }
            return try await library.search(query: query, kind: kind, startIndex: offset, limit: 50)
        }
        .onChange(of: connectivity.localOnly) { _, _ in results.clearRetainedData() }
        .task(id: connectivity.localOnly) {
            if connectivity.localOnly { installLocalResults() }
        }
        .onReceive(downloads.objectWillChange) {
            if connectivity.localOnly {
                Task { @MainActor in
                    guard connectivity.localOnly else { return }
                    installLocalResults()
                }
            }
        }
        #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }

    private func installLocalResults() {
        if kind == .genre {
            results.installSnapshot(primaryGenres.items(query: query, localOnly: true))
            return
        }
        guard musicContext == nil else {
            results.installSnapshot([])
            return
        }
        let current = downloads.localCatalogItems(kind: kind)
        let seedIdentities = Set(initialLocalOnly ? initialPage.items.map(\.id) : [])
        let matches =
            downloads.localSearchItems(query: query, kind: kind)
            + current.filter { seedIdentities.contains($0.id) }
        results.installSnapshot(FoundationSearchResolver.ranked(matches, query: query))
    }
}
