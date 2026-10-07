import SwiftUI

/// Native search controls with the existing catalog owner, rows and destinations.
struct FoundationSearchView<Profile: View>: View {
    let profile: Profile
    @FocusState private var searchFocused: Bool
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
                .id(term)
            }
        }
        .foundationSearchHeader(profile: profile, search: searchField, keepsVisible: searchFocused)
        .onChange(of: activation, initial: true) { _, value in
            if isActive, value > 0 { searchFocused = true }
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
            TextField("Albums, artists, and songs", text: $query)
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
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 14).padding(.trailing, query.isEmpty ? 14 : 0)
        .frame(minHeight: 44)
    }

    private var searchField: some View {
        Group {
            if #available(iOS 26.0, macOS 26.0, *) {
                searchInput.glassEffect(.regular, in: Capsule())
            } else {
                searchInput.background(.regularMaterial, in: Capsule())
            }
        }.padding(.horizontal, 16).padding(.bottom, 8)
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12),
                    ], spacing: 12
                ) {
                    ForEach(Array(genres.items.enumerated()), id: \.offset) { _, genre in
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
                    Button("Load more") { reloadGenres(.more) }.disabled(genres.isLoading)
                }
                if genres.isLoading { FoundationLoadingPlaceholder(layout: .genreCards) }
                if genres.loaded, genres.items.isEmpty { Text("No genres found.") }
                if let error = genres.errorMessage {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") { reloadGenres(genres.retryRequest) }
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
        .task(id: isActive && isVisible ? genreRevision : nil) {
            #if DEBUG
                await FoundationTrace.withPage(origin: traceOrigin, page: .genreIndex) {
                    await genres.loadPending(ifActive: isActive && isVisible, using: loader)
                }
            #else
                await genres.loadPending(ifActive: isActive && isVisible, using: loader)
            #endif
        }
    }

    private func reloadGenres(_ request: FoundationBrowseModel.Request) {
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
                        .id(
                            (artworkItem ?? genre).id
                                + ((artworkItem ?? genre).primaryImageTag ?? "")
                        )
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

/// Three small, sequential, independently recoverable result sections.
private struct FoundationSearchOverview: View {
    let query: String
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @StateObject private var artists = FoundationBrowseModel()
    @StateObject private var albums = FoundationBrowseModel()
    @StateObject private var songs = FoundationBrowseModel()
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?

    private var sections: [(title: String, kind: FoundationItem.Kind, model: FoundationBrowseModel)]
    {
        [("Songs", .track, songs), ("Albums", .album, albums), ("Artists", .artist, artists)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
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
        .navigationDestination(
            isPresented: Binding(get: { openedItem != nil }, set: { if !$0 { openedItem = nil } })
        ) {
            if let item = openedItem {
                FoundationItemDestination(
                    item: item, library: library, player: player, isActive: isActive
                )
                #if os(iOS)
                    .toolbar(.visible, for: .navigationBar)
                #endif
            }
        }
        .task(id: isActive && isVisible ? revision : nil) {
            guard isActive, isVisible else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
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
            await section.model.loadPending {
                try await library.search(
                    query: query, kind: section.kind, startIndex: $0, limit: 5)
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
                            player.setQueue(selection.items, selectedIndex: selection.index)

                        } : nil, player: player, showsTrackArtwork: true,
                    navigate: { openedItem = $0 })
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    model.request(model.retryRequest)
                    revision += 1
                }
            }
        }
    }
}

private struct FoundationSearchCategory: View {
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
        ) {
            try await library.search(query: query, kind: kind, startIndex: $0, limit: 50)
        }
        #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
        #endif
    }
}
