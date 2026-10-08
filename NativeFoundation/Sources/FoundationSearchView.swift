import SwiftUI

/// Native search controls with the existing catalog owner, rows and destinations.
struct FoundationSearchView<Profile: View>: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let profile: Profile
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @Namespace private var searchGlass
    @FocusState private var searchFocused: Bool
    @State private var cancelledActivation: Int?
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    @ObservedObject var genres: FoundationBrowseModel
    @Binding var query: String
    let isActive: Bool
    let activation: Int

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            if term.isEmpty {
                genreGrid
            } else {
                FoundationSearchOverview(
                    query: term, library: library, player: player, isActive: isActive
                )
                .id(term + (connectivity.localOnly ? "-local" : "-online"))
            }
        }
        .foundationSearchHeader(profile: profile, search: searchField, keepsVisible: searchFocused)
        .onChange(of: activation, initial: true) { _, value in
            if isActive, value > 0, cancelledActivation != value { searchFocused = true }
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

    private func cancelSearchFocus() {
        cancelledActivation = activation
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
                if searchFocused {
                    dismissKeyboardButton
                        .glassEffectID("search-dismiss", in: searchGlass)
                        .glassEffectTransition(reduceMotion ? .identity : .matchedGeometry)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: searchFocused)
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
        FoundationGenreIndex(genres: genres, library: library, player: player, isActive: isActive) {
            _ in
            try await library.searchGenres()
        }
    }
}

/// Search and Library share card layout, ownership, pagination and local recovery.
struct FoundationGenreIndex: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @ObservedObject var genres: FoundationBrowseModel
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    let loader: (Int) async throws -> FoundationPage
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var genreRevision = 0
    @State private var openedGenre: FoundationItem?
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif

    private var visibleGenres: [FoundationItem] {
        connectivity.localOnly
            ? genres.items.filter { !downloads.browseTracks(for: $0).isEmpty } : genres.items
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if connectivity.hasConnectionIssue || genres.hasConnectionIssue {
                    FoundationOfflineNotice()
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                    ], spacing: 12
                ) {
                    ForEach(Array(visibleGenres.enumerated()), id: \.offset) { _, genre in
                        FoundationGenreCard(
                            genre: genre, library: library,
                            isActive: isActive && isVisible, open: { openedGenre = genre }
                        )
                        .contextMenu {
                            FoundationItemMenu(
                                item: genre, actions: actions, initialFavorite: nil,
                                open: { openedGenre = genre })
                        }
                    }
                }
                if genres.nextStartIndex != nil {
                    Button("Load more") { reloadGenres(.more) }.disabled(
                        genres.isLoading || connectivity.localOnly)
                }
                if genres.isLoading, !connectivity.localOnly {
                    FoundationLoadingPlaceholder(layout: .genreCards)
                }
                if genres.loaded, genres.items.isEmpty, !connectivity.hasConnectionIssue,
                    !genres.hasConnectionIssue
                {
                    Text("No genres found.")
                }
                if let error = genres.errorMessage, !genres.hasConnectionIssue,
                    !connectivity.localOnly
                {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { reloadGenres(genres.retryRequest) }.disabled(
                        connectivity.localOnly)
                }
                if let error = actions.pinErrorMessage { Text(error).foregroundStyle(.red) }
            }.padding(.horizontal).padding(.bottom)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .navigationDestination(
            isPresented: Binding(get: { openedGenre != nil }, set: { if !$0 { openedGenre = nil } })
        ) {
            if let genre = openedGenre {
                FoundationGenreView(
                    genre: genre, library: library, player: player, isActive: isActive
                )
                #if os(iOS)
                    .toolbar(.visible, for: .navigationBar)
                #endif
            }
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            genres.request(.refresh)
            genreRevision += 1
        }
        .task(id: "\(isActive && isVisible)-\(connectivity.localOnly)-\(genreRevision)") {
            guard isActive, isVisible else { return }
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .genreIndex) {
                    await genres.refreshVisible(
                        allowsNetwork: !connectivity.localOnly, using: loader)
                }
            #else
                await genres.refreshVisible(allowsNetwork: !connectivity.localOnly, using: loader)
            #endif
        }
    }

    private func reloadGenres(_ request: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        genres.request(request)
        genreRevision += 1
    }
}

struct FoundationGenreCard: View {
    let genre: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    let open: () -> Void
    var artworkItem: FoundationItem? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tint = Color.indigo
    @State private var isVisible = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                if dynamicTypeSize.isAccessibilitySize {
                    Color.clear.frame(minHeight: 150)
                } else {
                    Color.clear.aspectRatio(1.6, contentMode: .fit)
                }
                Text(genre.title).font(.headline).foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).padding(12)
            }
            .background {
                GeometryReader { geometry in
                    ZStack {
                        FoundationCatalogArtwork(
                            item: artworkItem ?? genre, library: library,
                            isActive: isActive && isVisible, size: geometry.size.width,
                            sampledColor: $tint
                        )
                        .id((artworkItem ?? genre).sharedArtworkIdentity)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        LinearGradient(
                            stops: [
                                .init(color: tint.opacity(0.2), location: 0),
                                .init(color: tint.opacity(0.55), location: 0.55),
                                .init(color: tint.opacity(0.9), location: 0.85),
                                .init(color: tint, location: 1),
                            ], startPoint: .topTrailing, endPoint: .bottomLeading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(genre.title)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Small sequential result sections share local and remote catalog identities.
private struct FoundationSearchOverview: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let query: String
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @StateObject private var playlists = FoundationBrowseModel()
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    private var sections: [(title: String, kind: FoundationItem.Kind, model: FoundationBrowseModel)]
    {
        [("Songs", .track, songs), ("Albums", .album, albums), ("Artists", .artist, artists)]
            + (connectivity.localOnly ? [("Playlists", .playlist, playlists)] : [])
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
                ForEach(sections, id: \.title) { section in
                    if !section.model.items.isEmpty || section.model.errorMessage != nil {
                        resultSection(section.title, kind: section.kind, model: section.model)
                    }
                }
                if sections.contains(where: { $0.model.isLoading }) {
                    FoundationLoadingPlaceholder()
                }
                if sections.allSatisfy({ $0.model.loaded && $0.model.items.isEmpty }) {
                    Text("No results found.").foregroundStyle(.secondary)
                }
            }.padding(.horizontal).padding(.bottom)
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            for section in sections { section.model.request(.refresh) }
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

    private func loadSections() async {
        for section in sections {
            guard !Task.isCancelled else { return }
            if connectivity.localOnly { section.model.request(.refresh) }
            await section.model.loadPending { offset in
                if connectivity.localOnly {
                    return downloads.localSearch(
                        query: query, kind: section.kind, startIndex: offset, limit: 5)
                }
                return try await library.search(
                    query: query, kind: section.kind, startIndex: offset, limit: 5)
            }
        }
    }

    private func resultSection(
        _ title: String, kind: FoundationItem.Kind, model: FoundationBrowseModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.nextStartIndex != nil {
                NavigationLink {
                    FoundationSearchCategory(
                        title: title, query: query, kind: kind,
                        library: library, player: player, isActive: isActive)
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
            ForEach(Array(model.items.prefix(5).enumerated()), id: \.offset) { index, item in
                FoundationLibraryItemRow(
                    item: item, library: library, isActive: isActive && isVisible,
                    open: { openedItem = item },
                    play: item.kind == .track
                        ? {
                            guard let selection = model.trackQueue(selecting: index) else { return }
                            if connectivity.localOnly {
                                guard downloads.isReady(selection.items[selection.index]) else {
                                    return
                                }
                                let ready = selection.items.filter { downloads.isReady($0) }
                                let index = selection.items.prefix(selection.index).filter {
                                    downloads.isReady($0)
                                }.count
                                player.setQueue(ready, selectedIndex: index)
                            } else {
                                player.setQueue(selection.items, selectedIndex: selection.index)
                            }

                        } : nil, player: player, showsTrackArtwork: true,
                    navigate: { openedItem = $0 })
            }
            if let error = model.errorMessage, !model.hasConnectionIssue {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    guard !connectivity.localOnly else { return }
                    model.request(model.retryRequest)
                    revision += 1
                }.disabled(connectivity.localOnly)
            }
        }
    }
}

private struct FoundationSearchCategory: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    let query: String
    let kind: FoundationItem.Kind
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @StateObject private var results = FoundationBrowseModel()

    var body: some View {
        FoundationCatalogView(
            title: title, model: results, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true
        ) { offset in
            if connectivity.localOnly {
                return downloads.localSearch(
                    query: query, kind: kind, startIndex: offset, limit: 50)
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
        results.installSnapshot(downloads.localSearchItems(query: query, kind: kind))
    }
}
