import SwiftUI

/// An explicit submit applies only to the current query and metadata/account scope.
struct FoundationSearchSubmission: Equatable {
    let query: String
    let metadataScope: String
    private let identity = UUID()

    init(query: String, metadataScope: String) {
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.metadataScope = metadataScope
    }

    func matches(query: String, metadataScope: String) -> Bool {
        self.query == query && self.metadataScope == metadataScope
    }
}

/// The view's existing query task owns the debounce; submitting cannot restart a live resolver.
struct FoundationSearchTypingState {
    private(set) var hasStarted = false
    private(set) var immediate = false
    private(set) var revision = 0

    mutating func submit(
        _ submission: FoundationSearchSubmission?, query: String, metadataScope: String
    ) {
        guard !hasStarted, !immediate,
            submission?.matches(query: query, metadataScope: metadataScope) == true
        else { return }
        immediate = true
        revision += 1
    }

    mutating func begin() { hasStarted = true }
}

/// Native search controls with the existing catalog owner, rows and destinations.
struct FoundationSearchView<Profile: View>: View {
    /// Replace from an already-resolved page, even when a retained partial query loaded before.
    /// This loader performs no provider reads and preserves old rows until replacement is ready.
    @MainActor
    static func replaceDirectSnapshot(
        _ direct: FoundationSearchResolver.DirectSection, in model: FoundationBrowseModel
    ) async throws {
        try Task.checkCancellation()
        model.request(.refresh)
        await model.loadPending { _ in
            if let error = direct.error { throw error }
            return direct.page
        }
        try Task.checkCancellation()
    }

    private struct OverviewIdentity: Hashable {
        let query: String
        let metadataScope: String
        let localOnly: Bool
    }
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
    var submission: FoundationSearchSubmission? = nil
    var submitSearch: () -> Void = {}
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
                    submission: submission, openedItem: $openedItem,
                    openCategory: { openedCategory = $0 }
                )
                .id(
                    OverviewIdentity(
                        query: term, metadataScope: library.metadataScopeID,
                        localOnly: connectivity.localOnly))
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
                        },
                        initialSearchSeed: category.searchSeed(for: term, library: library),
                        searchCoverageMessage: category.coverageMessage,
                        returnToSearch: { openedCategory = nil }
                    ) { active, presented in
                        FoundationSearchCategory(
                            title: category.title, query: term, kind: .track,
                            library: library, player: player, isActive: active,
                            initialPage: category.page, initialLocalOnly: category.localOnly,
                            initialFallbackCursor: category.fallbackCursor,
                            allowsInitialSeed: category.allowsSnapshot(for: term, library: library),
                            searchCoverageMessage: category.coverageMessage,
                            returnToSearch: { openedCategory = nil },
                            showsContent: presented)
                    }
                } else if let context = category.musicContext, let model = category.contentModel {
                    FoundationPlaylistLookupView(
                        title: category.title, context: context, model: model,
                        library: library, player: player, isActive: isActive
                    )
                    .id(category.title + library.metadataScopeID)
                } else {
                    FoundationSearchCategory(
                        title: category.title, query: term, kind: category.kind,
                        library: library, player: player, isActive: isActive,
                        initialPage: category.page, initialLocalOnly: category.localOnly,
                        initialFallbackCursor: category.fallbackCursor,
                        allowsInitialSeed: category.allowsSnapshot(for: term, library: library),
                        musicContext: category.musicContext,
                        initialIncompleteCoverage: category.incompleteCoverage,
                        searchCoverageMessage: category.coverageMessage,
                        returnToSearch: { openedCategory = nil })
                }
            }
        }
        .onChange(of: query) { _, _ in
            openedItem = nil
            openedCategory = nil
        }
        .onChange(of: library.metadataScopeID) { _, _ in
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
            .onSubmit(of: .search, submitSearch)
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
    var contentModel: FoundationPlaylistLookupModel? = nil
    var seedQuery: String? = nil
    var seedMetadataScope: String? = nil
    var supplementalIDs: Set<String> = []
    var fallbackCursor: FoundationSearchResolver.FallbackCursor? = nil
    var allowsSeed = true
    var coverageMessage: String? = nil

    func allowsSnapshot(for query: String, library: any FoundationLibrary) -> Bool {
        allowsSeed && seedQuery == query && seedMetadataScope == library.metadataScopeID
    }

    func searchSeed(for query: String, library: any FoundationLibrary)
        -> FoundationCatalogSearchSeed?
    {
        guard allowsSnapshot(for: query, library: library), kind == .track, !localOnly
        else { return nil }
        return .init(
            query: query, metadataScope: library.metadataScopeID, page: page,
            supplementalIDs: supplementalIDs, fallbackCursor: fallbackCursor)
    }
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
    let submission: FoundationSearchSubmission?
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var playlists = FoundationBrowseModel()
    @StateObject private var genreResults = FoundationBrowseModel()
    @State private var isVisible = false
    @State private var collectionOperationOwner = UUID()
    @State private var revision = 0
    @State private var typing = FoundationSearchTypingState()
    @State private var rawDirect: [FoundationSearchResolver.DirectSection] = []
    @State private var rawRelated: [FoundationSearchResolver.RelatedSection] = []
    @State private var rawDiscovery: [FoundationItem] = []
    @State private var playlistLookup: FoundationPlaylistLookupModel?
    @State private var playlistMusicContext = FoundationMusicSearchContext()
    @State private var playlistContentError: FoundationLibraryError?
    @State private var isResolving = false
    @State private var resolutionID = UUID()
    @State private var resolvedRevision: Int?
    @State private var resolvedMetadataScope: String?
    @State private var hasPartialFailure = false
    @State private var fallbackCoverage: FoundationSearchFallbackCoverage?
    @Binding var openedItem: FoundationItem?
    let openCategory: (FoundationSearchCategorySelection) -> Void

    private var hasUnwalkedFallback: Bool {
        fallbackCoverage?.hasUnwalkedPages(
            query: query, metadataScope: library.metadataScopeID,
            localOnly: connectivity.localOnly) == true
    }

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
                    includesFuzzyMatches: section.includesFuzzyMatches, error: section.error,
                    originalIDs: section.originalIDs)
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
        FoundationSearchResolver.categoryItems(
            direct: rawDirect, related: rawRelated, kind: kind, query: query)
    }

    var body: some View {
        ScrollView {
            // The bounded overview must instantiate the playlist lookup even when
            // earlier result sections place it below the initial viewport.
            VStack(alignment: .leading, spacing: 24) {
                if !typing.hasStarted || isResolving {
                    ProgressView("Searching…")
                        .accessibilityIdentifier("search-query-progress")
                }
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
                            displayTitle(section.role), kind: kind, role: section.role,
                            model: source.model, items: section.items,
                            rawItems: rawCategoryItems(kind))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Top Results").font(.title2.bold()).frame(minHeight: 44)
                            resultRows(section.items, role: section.role, showsItemType: true)
                        }
                    }
                }
                ForEach(
                    sections.filter { source in
                        FoundationSearchResolver.showsCategoryContinuationPlaceholder(
                            hasOriginalPage: source.model.nextStartIndex != nil,
                            hasFallbackPage: rawDirect.first(where: { $0.kind == source.kind })?
                                .fallbackCursor != nil,
                            hasVisibleSection: displaySections.contains(where: {
                                $0.kind == source.kind
                            }))
                    }, id: \.kind
                ) { source in
                    resultSection(
                        source.title, kind: source.kind, role: .relatedSongs,
                        model: source.model, items: [], rawItems: rawCategoryItems(source.kind))
                }
                if let playlistLookup {
                    FoundationPlaylistLookupView(
                        title: "Playlists with “" + query + "”", context: playlistMusicContext,
                        model: playlistLookup, library: library, player: player,
                        isActive: isActive && isVisible, inline: true,
                        openAll: { openPlaylistLookup(playlistLookup) }
                    )
                    .id(ObjectIdentifier(playlistLookup))
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
                if hasUnwalkedFallback {
                    Text("More close matches may exist. Narrow your search.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isResolving || sections.contains(where: { $0.model.isLoading }) {
                    FoundationLoadingPlaceholder()
                }
                if !isResolving, displaySections.isEmpty,
                    sections.allSatisfy({
                        $0.model.loaded && $0.model.items.isEmpty && $0.model.errorMessage == nil
                    })
                {
                    Text(
                        hasUnwalkedFallback
                            ? "No matches in the pages checked." : "No results found."
                    )
                    .foregroundStyle(.secondary)
                }
                if !discovery.isEmpty { discoveryCarousel }
            }.padding(.horizontal).padding(.bottom)
                .foundationBottomChromeEndPadding()
        }
        .accessibilityIdentifier("foundation-search-results-scroll")
        .foundationBottomChromeScrollClearance()
        #if os(iOS)
            .refreshable { requestVisibleRefresh() }
        #endif
        .foundationLibraryRefresh(
            revision: actions.libraryRefreshRevision,
            active: isActive && isVisible && !connectivity.localOnly
        ) { requestVisibleRefresh() }
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
        .onChange(of: submission, initial: true) { _, submission in
            guard isActive, isVisible else { return }
            typing.submit(submission, query: query, metadataScope: library.metadataScopeID)
        }
        .task(
            id:
                "\(query)-\(library.metadataScopeID)-\(connectivity.localOnly)-\(isActive && isVisible)-\(revision)-\(connectivity.successfulRetryRevision)-\(typing.revision)"
        ) {
            guard isActive, isVisible else { return }
            let submitted =
                submission?.matches(
                    query: query, metadataScope: library.metadataScopeID) == true
            if !connectivity.localOnly, !typing.hasStarted, !typing.immediate, !submitted {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled, isActive, isVisible else { return }
            typing.begin()
            #if DEBUG
                await FoundationTrace.withPage(origin: .search, page: .catalog) {
                    await loadSections()
                }
            #else
                await loadSections()
            #endif
        }
    }

    private func requestVisibleRefresh() {
        guard isActive, isVisible, !connectivity.localOnly else { return }
        resolvedRevision = nil
        retrySearch()
    }

    private func retrySearch() {
        for section in sections { section.model.request(.refresh) }
        revision += 1
    }

    private func loadSections() async {
        // A single query snapshot owns both direct and relationship results.
        guard resolvedRevision != revision else { return }
        let localOnly = connectivity.localOnly
        let metadataScope = library.metadataScopeID
        let requestedRevision = revision
        // Initial typed queries can show completed direct categories immediately.
        // Explicit same-query refresh keeps its accepted previous snapshot until replacement.
        let publishesDirectSections = rawDirect.isEmpty
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
            let result = try await resolver.resolve(
                query: query,
                onDirectSection: { resolved in
                    try Task.checkCancellation()
                    guard isActive, isVisible, connectivity.localOnly == localOnly,
                        library.metadataScopeID == metadataScope, revision == requestedRevision,
                        resolutionID == identity
                    else { throw CancellationError() }
                    guard publishesDirectSections,
                        let section = sections.first(where: { $0.kind == resolved.section.kind })
                    else { return }
                    let direct = resolved.section
                    if !localOnly { section.model.configureFavoriteObservations(actions) }
                    await section.model.loadPending { _ in
                        if let error = direct.error { throw error }
                        return direct.page
                    }
                    try Task.checkCancellation()
                    guard isActive, isVisible, connectivity.localOnly == localOnly,
                        library.metadataScopeID == metadataScope, revision == requestedRevision,
                        resolutionID == identity
                    else { throw CancellationError() }
                    actions.observeTrackCopies(direct.page.items)
                    rawDirect.append(direct)
                    fallbackCoverage = .init(
                        query: query, metadataScope: metadataScope, localOnly: localOnly,
                        kinds: Set(rawDirect.filter { $0.fallbackCursor != nil }.map(\.kind)))
                    resolvedMetadataScope = metadataScope
                })
            try Task.checkCancellation()
            guard isActive, isVisible, connectivity.localOnly == localOnly,
                library.metadataScopeID == metadataScope, revision == requestedRevision,
                resolutionID == identity
            else { return }
            for section in sections where !publishesDirectSections {
                guard let direct = result.direct.first(where: { $0.kind == section.kind }) else {
                    continue
                }
                if !localOnly { section.model.configureFavoriteObservations(actions) }
                try await FoundationSearchView<EmptyView>.replaceDirectSnapshot(
                    direct, in: section.model)
            }
            guard !Task.isCancelled, isActive, isVisible,
                connectivity.localOnly == localOnly, library.metadataScopeID == metadataScope,
                revision == requestedRevision, resolutionID == identity
            else { return }
            actions.observeTrackCopies(
                result.direct.flatMap { $0.page.items } + result.related.flatMap(\.items)
                    + result.discovery)
            rawDirect = result.direct
            rawRelated = result.related
            rawDiscovery = result.discovery
            playlistLookup?.cancel()
            playlistLookup = result.playlistContents.map {
                FoundationPlaylistLookupModel(scope: library.metadataScopeID, seed: $0)
            }
            playlistMusicContext = result.musicContext
            playlistContentError = result.playlistContentError
            hasPartialFailure = result.failures.contains {
                if case .direct = $0 { return false }
                return true
            }
            fallbackCoverage = .init(
                query: query, metadataScope: library.metadataScopeID, localOnly: localOnly,
                kinds: result.unwalkedFallbackKinds)
            resolvedMetadataScope = library.metadataScopeID
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
                    ForEach(
                        FoundationLibraryIndexSelection.positionedItems(discovery, actions: actions)
                    ) { row in
                        let item = row.item
                        FoundationCollectionCard(
                            item: item, library: library, player: player,
                            isActive: isActive && isVisible,
                            showsTrackArtwork: true,
                            subtitleOverride: explainedSubtitle(
                                typedSubtitle(for: item), item: item),
                            open: {
                                activateDiscovery(row.id)
                            }, navigate: { navigateResult($0, from: row.id, in: discovery) },
                            canPerform: { _ in
                                FoundationLibraryIndexSelection.admits(
                                    row.item, current: currentResult(row.id, in: discovery)?.item)
                            }
                        ).frame(width: 150)
                    }
                }.scrollTargetLayout()
            }
            .foundationHorizontalScrollIndicators()
            .scrollTargetBehavior(.viewAligned)
            .foundationMacShelfUnderlap(horizontalInset: 0, contentInset: 0)
        }
    }

    private func openPlaylistLookup(_ model: FoundationPlaylistLookupModel) {
        openCategory(
            .init(
                title: "Playlists with “" + query + "”", kind: .playlist,
                page: .init(items: [], nextStartIndex: nil), localOnly: false,
                musicContext: playlistMusicContext, contentModel: model))
    }

    @ViewBuilder
    private func resultRows(
        _ items: [FoundationItem], role: FoundationSearchResolver.DisplaySection.Role,
        showsItemType: Bool = false
    ) -> some View {
        if !items.isEmpty, items.allSatisfy({ $0.kind == .genre }) {
            ForEach(Array(items.prefix(5)), id: \.genreIdentity) { item in
                FoundationGenrePresentation(
                    genre: item, library: library, player: player,
                    isActive: isActive && isVisible, context: .libraryRow,
                    open: { openedItem = item }, navigate: { openedItem = $0 })
            }
        } else {
            ForEach(
                FoundationLibraryIndexSelection.positionedItems(
                    Array(items.prefix(5)), actions: actions)
            ) { row in
                let item = row.item
                FoundationLibraryItemRow(
                    item: item, library: library, isActive: isActive && isVisible,
                    open: { openResult(row.id, in: currentItems(for: role)) },
                    play: item.kind == .track
                        ? { playResult(row.id, in: currentItems(for: role)) } : nil,
                    player: player, showsTrackArtwork: true,
                    navigate: { navigateResult($0, from: row.id, in: currentItems(for: role)) },
                    subtitleOverride: explainedSubtitle(
                        showsItemType ? typedSubtitle(for: item) : relatedSubtitle(for: item),
                        item: item),
                    canPerform: { _ in
                        FoundationLibraryIndexSelection.admits(
                            row.item,
                            current: currentResult(row.id, in: currentItems(for: role))?.item)
                    })
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

    private func explainedSubtitle(_ subtitle: String?, item: FoundationItem) -> String? {
        FoundationSearchResolver.explainedSubtitle(subtitle, item: item, query: query)
    }

    private func relatedSubtitle(for item: FoundationItem) -> String? {
        guard item.kind == .track else { return nil }
        let artist = item.subtitle.isEmpty ? (item.artist?.title ?? "") : item.subtitle
        let parts = [item.album?.title ?? "", artist].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func currentItems(for role: FoundationSearchResolver.DisplaySection.Role)
        -> [FoundationItem]
    {
        displaySections.first(where: { $0.role == role })?.items ?? []
    }

    private func currentResult(
        _ id: FoundationLibraryIndexSelection.Identity, in items: [FoundationItem]
    ) -> FoundationLibraryIndexSelection.Match? {
        guard isActive, isVisible else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: items, actions: actions)
    }

    private func openResult(
        _ id: FoundationLibraryIndexSelection.Identity, in items: [FoundationItem]
    ) {
        guard let match = currentResult(id, in: items) else { return }
        openedItem = match.item
    }

    private func activateDiscovery(_ id: FoundationLibraryIndexSelection.Identity) {
        let items = discovery
        if id.kind == .track { playResult(id, in: items) } else { openResult(id, in: items) }
    }

    private func navigateResult(
        _ target: FoundationItem, from id: FoundationLibraryIndexSelection.Identity,
        in items: [FoundationItem]
    ) {
        guard isActive, isVisible,
            let item = FoundationLibraryIndexSelection.relatedDestination(
                target, from: id, in: items, actions: actions)
        else { return }
        openedItem = item
    }

    private func playResult(
        _ id: FoundationLibraryIndexSelection.Identity, in items: [FoundationItem]
    ) {
        guard isActive, isVisible,
            let match = FoundationLibraryIndexSelection.resolve(id, in: items, actions: actions),
            let selection = FoundationTrackQueueSelection(
                in: items, selecting: match.sourceIndex,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func resultSection(
        _ title: String, kind: FoundationItem.Kind,
        role: FoundationSearchResolver.DisplaySection.Role, model: FoundationBrowseModel,
        items: [FoundationItem], rawItems: [FoundationItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.nextStartIndex != nil
                || rawDirect.first(where: { $0.kind == kind })?.fallbackCursor != nil
                || items.count > 5
            {
                Button {
                    let direct = rawDirect.first { $0.kind == kind }
                    let partial = FoundationSearchResolver.categoryHasPartialFailure(
                        direct: rawDirect, kind: kind, hasOtherFailures: hasPartialFailure)
                    openCategory(
                        .init(
                            title: title, kind: kind,
                            page: .init(items: rawItems, nextStartIndex: model.nextStartIndex),
                            localOnly: connectivity.localOnly,
                            seedQuery: query, seedMetadataScope: resolvedMetadataScope,
                            supplementalIDs: Set(rawItems.map(\.id)).subtracting(
                                direct?.originalIDs ?? []),
                            fallbackCursor: direct?.fallbackCursor,
                            allowsSeed: FoundationSearchResolver.canSeedCategory(
                                directSucceeded: direct.map { $0.error == nil } ?? false,
                                itemCount: rawItems.count, hasNextPage: model.nextStartIndex != nil),
                            coverageMessage: FoundationSearchResolver.categoryCoverageMessage(
                                hasPartialFailure: partial, itemCount: rawItems.count,
                                hasUnwalkedFallback: direct?.fallbackCursor != nil)))
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
            resultRows(items, role: role)
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
    var allowsInitialSeed = true
    var musicContext: FoundationMusicSearchContext? = nil
    var initialIncompleteCoverage = false
    var searchCoverageMessage: String? = nil
    var returnToSearch: (() -> Void)? = nil
    var showsContent = true
    @State private var contentCoverage = false
    @State private var seedLease: FoundationSearchSeedLease
    @StateObject private var results: FoundationBrowseModel

    init(
        title: String, query: String, kind: FoundationItem.Kind, library: any FoundationLibrary,
        player: FoundationPlayer, isActive: Bool, initialPage: FoundationPage,
        initialLocalOnly: Bool,
        initialFallbackCursor: FoundationSearchResolver.FallbackCursor? = nil,
        allowsInitialSeed: Bool = true, musicContext: FoundationMusicSearchContext? = nil,
        initialIncompleteCoverage: Bool = false, searchCoverageMessage: String? = nil,
        returnToSearch: (() -> Void)? = nil, showsContent: Bool = true
    ) {
        // This scoped snapshot seeds the view-owned model once; source/query
        // replacement still retires the entire destination in its existing owner.
        let source = (library as? FoundationJellyfinLibrary).flatMap {
            try? FoundationCatalogSource.jellyfin(scope: $0.catalogAccountIdentity)
        }
        let categorySeed = FoundationSearchResolver.categorySeed(
            initialPage, kind: kind, source: source)
        let acceptsSeed = allowsInitialSeed && categorySeed != nil
        self.title = title
        self.query = query
        self.kind = kind
        self.library = library
        self.player = player
        self.isActive = isActive
        self.initialPage = initialPage
        self.initialLocalOnly = initialLocalOnly
        self.allowsInitialSeed = acceptsSeed
        self.musicContext = musicContext
        self.initialIncompleteCoverage = initialIncompleteCoverage
        self.searchCoverageMessage =
            searchCoverageMessage
            ?? (allowsInitialSeed && categorySeed == nil
                ? "Some close or related matches could not be loaded. Return to Search to retry."
                : nil)
        self.returnToSearch = returnToSearch
        self.showsContent = showsContent
        let lease = FoundationSearchSeedLease(
            page: categorySeed?.page ?? .init(items: [], nextStartIndex: nil))
        _seedLease = State(initialValue: lease)
        let model = FoundationBrowseModel(onLoadSettled: { lease.settle() })
        model.searchRefreshEnabled = !initialLocalOnly
        model.configureSearchContinuation(
            query: query, kind: kind, metadataScope: library.metadataScopeID,
            fallback: initialLocalOnly ? nil : initialFallbackCursor,
            seed: acceptsSeed && !initialLocalOnly ? categorySeed : nil, seedLease: lease,
            refresh: musicContext == nil
                ? {
                    let fresh = try await FoundationSearchResolver(library: library)
                        .resolveCategory(query: query, kind: kind)
                    try Task.checkCancellation()
                    guard
                        let seed = FoundationSearchResolver.categorySeed(
                            fresh.page, kind: kind, source: source)
                    else { throw FoundationLibraryError.invalidResponse }
                    return .init(
                        seed: seed, fallback: fresh.direct.fallbackCursor,
                        coverageMessage: fresh.incomplete
                            ? "Some close or related matches could not be loaded. Return to Search to retry or narrow your search."
                            : nil)
                } : nil,
            fetch: { term, kind, cursor in
                try await library.search(query: term, kind: kind, startIndex: cursor, limit: 50)
            })
        _results = StateObject(wrappedValue: model)
    }

    @ViewBuilder var body: some View {
        if showsContent { categoryBody }
    }

    private var categoryBody: some View {
        FoundationCatalogView(
            title: title, model: results, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true,
            subtitleForItem: {
                FoundationSearchResolver.explainedSubtitle(nil, item: $0, query: query)
            },
            coverageMessage: FoundationSearchResolver.continuationCoverageMessage(
                results.hasRefreshedSearchRelations
                    ? results.searchRefreshCoverageMessage : searchCoverageMessage,
                hasFallback: results.searchFallbackCursor != nil)
                ?? (musicContext != nil && (contentCoverage || initialIncompleteCoverage)
                    ? "More playlists or tracks may contain matching music." : nil),
            coverageAction: searchCoverageMessage != nil
                || results.searchRefreshCoverageMessage != nil ? returnToSearch : nil
        ) { offset in
            if kind == .genre {
                return primaryGenres.page(
                    query: query, startIndex: offset, localOnly: connectivity.localOnly)
            }
            if offset == 0,
                let seed = seedLease.offer(
                    eligible: allowsInitialSeed && connectivity.localOnly == initialLocalOnly)
            {
                return seed
            }
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
        .onChange(of: connectivity.localOnly) { _, _ in
            results.searchRefreshEnabled = !connectivity.localOnly
            seedLease.invalidate()
            results.clearRetainedData()
        }
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

private struct FoundationPlaylistLookupView: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    let title: String
    let context: FoundationMusicSearchContext
    @ObservedObject var model: FoundationPlaylistLookupModel
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    var inline = false
    var openAll: (() -> Void)? = nil
    @State private var visible = false
    @State private var visibilityOwner = UUID()
    @State private var openedItem: FoundationItem?

    private var displayedItems: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: model.items) : model.items
    }

    var body: some View {
        Group {
            if inline {
                contents
            } else {
                ScrollView { contents.padding().foundationBottomChromeEndPadding() }
                    .accessibilityIdentifier("foundation-playlist-lookup-scroll")
                    .foundationBottomChromeScrollClearance()
                    .foundationCatalogHeader(title)
            }
        }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .onAppear {
            visible = true
            registerVisibility()
        }
        .onDisappear {
            visible = false
            model.releaseVisible(visibilityOwner)
        }
        .onChange(of: connectivity.localOnly) { _, offline in
            if offline { model.cancel() } else { registerVisibility() }
        }
        .onChange(of: isActive) { _, active in
            if active { registerVisibility() } else { model.releaseVisible(visibilityOwner) }
        }
    }

    private func registerVisibility() {
        guard isActive, visible, !connectivity.localOnly else { return }
        model.registerVisible(visibilityOwner, context: context, library: library)
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !displayedItems.isEmpty {
                if inline, let openAll, displayedItems.count > 5 {
                    Button(action: openAll) {
                        HStack(spacing: 6) {
                            Text(title).font(.title2.bold())
                            Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        }.frame(minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel("See all " + title)
                } else if inline {
                    Text(title).font(.title2.bold()).frame(minHeight: 44)
                }
                ForEach(inline ? Array(displayedItems.prefix(5)) : displayedItems) { item in
                    FoundationLibraryItemRow(
                        item: item, library: library,
                        isActive: isActive && visible, open: { openedItem = item },
                        player: player, showsTrackArtwork: true, navigate: { openedItem = $0 })
                }
            }
            if !connectivity.localOnly {
                if model.showsSearchProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching playlists…").font(.caption).foregroundStyle(.secondary)
                    }.accessibilityIdentifier("search-playlists-progress")
                }
                if model.error != nil {
                    Text("Playlist search could not finish. Results found so far are shown.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.canRetryContinuation {
                        Button("Retry playlist search") {
                            guard isActive, visible, !connectivity.localOnly else { return }
                            model.retryVisible(
                                visibilityOwner, context: context, library: library)
                        }
                        .accessibilityIdentifier("search-playlists-retry")
                        .disabled(!isActive || !visible)
                    }
                } else if !model.searching, model.incomplete, model.cursor == nil {
                    Text("Some music relationships could not be checked in this library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !inline, displayedItems.isEmpty {
                Text("No downloaded music in these playlists.").foregroundStyle(.secondary)
            }
        }
    }

}
