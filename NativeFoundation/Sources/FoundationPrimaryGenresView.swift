import SwiftUI

/// Search and Library render one completed genre snapshot with context-specific native layout.
struct FoundationPrimaryGenresView: View {
    enum Context: Equatable { case cards, libraryRows }
    @EnvironmentObject private var genres: FoundationPrimaryGenresModel
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var actions: FoundationLibraryActions
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let context: Context
    var openItem: ((FoundationItem) -> Void)? = nil
    @State private var query: String
    @State private var visibleCount = 50
    @State private var openedGenre: FoundationItem?
    @State private var visible = false

    init(
        library: any FoundationLibrary, player: FoundationPlayer, isActive: Bool,
        context: Context, initialQuery: String = "", openItem: ((FoundationItem) -> Void)? = nil
    ) {
        self.library = library
        self.player = player
        self.isActive = isActive
        self.context = context
        self.openItem = openItem
        _query = State(initialValue: initialQuery)
    }

    private var items: [FoundationItem] {
        genres.items(query: query, localOnly: connectivity.localOnly)
    }
    private var columns: [GridItem] {
        #if os(macOS)
            [GridItem(.adaptive(minimum: 128, maximum: 168), spacing: 12)]
        #else
            [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        #endif
    }

    var body: some View {
        Group {
            if context == .libraryRows {
                List {
                    status
                    ForEach(Array(items.prefix(visibleCount)), id: \.genreIdentity) { item in
                        FoundationGenrePresentation(
                            genre: item, library: library, player: player,
                            isActive: isActive && visible, context: .libraryRow,
                            open: { open(item) }, navigate: { open($0) }
                        )
                        .foundationLibraryListRow()
                    }
                    more
                }
                .foundationBottomChromeListClearance()
                .listStyle(.plain)
                .accessibilityIdentifier("library-index-genre")
                #if os(iOS)
                    .searchable(
                        text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search genres")
                #endif
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        status
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Array(items.prefix(visibleCount)), id: \.genreIdentity) {
                                item in
                                FoundationGenrePresentation(
                                    genre: item, library: library, player: player,
                                    isActive: isActive && visible, context: .card,
                                    open: { open(item) }
                                )
                                .contextMenu {
                                    FoundationItemMenu(
                                        item: item, actions: actions, initialFavorite: nil,
                                        open: { open(item) })
                                }
                            }
                        }
                        more
                    }.padding(.horizontal).padding(.bottom)
                        .foundationBottomChromeEndPadding()
                }
                .foundationBottomChromeScrollClearance()
            }
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: query) { _, _ in visibleCount = 50 }
        .onChange(of: genres.publicationRevision) { _, _ in visibleCount = 50 }
        .foundationCollectionDestination(
            item: $openedGenre, library: library, player: player, isActive: isActive)
    }

    @ViewBuilder private var status: some View {
        if genres.isBuilding {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(
                    "Indexing song tags…", value: Double(genres.processedSongs),
                    total: Double(max(1, genres.totalSongs ?? 1)))
                Text("\(genres.processedSongs) songs read").font(.caption).foregroundStyle(
                    .secondary)
                Button("Cancel indexing") { genres.cancel() }
                    .accessibilityIdentifier("primary-genres-cancel")
            }
        } else if genres.isSupported {
            Button(genres.record == nil ? "Build primary genres" : "Refresh primary genres") {
                genres.start()
            }.disabled(connectivity.localOnly)
                .accessibilityIdentifier("primary-genres-build")
        }
        if let record = genres.record {
            Text(
                "Indexed \(record.snapshot.completedAt.formatted(date: .abbreviated, time: .shortened)). Refresh after changing song tags on your server."
            )
            .font(.caption).foregroundStyle(.secondary)
            if items.isEmpty { Text("No primary genres found.").foregroundStyle(.secondary) }
        } else {
            Text(
                connectivity.localOnly
                    ? "Connect and build primary genres to browse your downloaded songs by genre."
                    : "Build an index to choose up to two common tags for each song. Only song metadata is read."
            )
            .foregroundStyle(.secondary)
        }
        if let error = genres.errorMessage { Text(error).foregroundStyle(.red) }
        if connectivity.localOnly, let error = genres.offlineErrorMessage {
            Text(error).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var more: some View {
        if items.count > visibleCount { Button("Load more") { visibleCount += 50 } }
    }

    private func open(_ item: FoundationItem) {
        if let openItem { openItem(item) } else { openedGenre = item }
    }
}
