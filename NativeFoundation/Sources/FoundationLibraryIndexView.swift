import SwiftUI

/// Library indexes share native rows; collection details keep their own canonical presentation.
struct FoundationLibraryIndexView: View {
    let kind: FoundationItem.Kind
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var refreshToken = 0
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @StateObject private var searchModel = FoundationBrowseModel()
    @State private var query = ""
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayed: FoundationBrowseModel { term.isEmpty ? model : searchModel }
    private var title: String {
        switch kind {
        case .album: "Albums"
        case .artist: "Artists"
        case .track: "Songs"
        case .playlist: "Playlists"
        case .genre: "Genres"
        }
    }

    private var localItems: [FoundationItem] {
        switch kind {
        case .album: return downloads.downloadedAlbums
        case .artist: return downloads.downloadedArtists
        case .track: return downloads.downloadedSongs
        case .playlist: return downloads.downloadedPlaylists
        case .genre:
            let references = (downloads.downloadedSongs + downloads.downloadedAlbums)
                .flatMap(\.genres)
            var seen: Set<String> = []
            return references.filter { seen.insert($0.id).inserted }.map {
                FoundationItem(
                    id: $0.id, title: $0.title, subtitle: "", kind: .genre, duration: nil)
            }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            indexList(placeholderRows: min(30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
        }
        .foundationCatalogHeader(title)
        #if os(iOS)
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search " + title.lowercased())
        #else
            .searchable(text: $query, prompt: "Search " + title.lowercased())
        #endif
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .onAppear {
            model.configureCatalogPagination()
            searchModel.configureCatalogPagination()
            isVisible = true
        }
        .onDisappear { isVisible = false }
        .onChange(of: query) { old, new in
            guard
                old.trimmingCharacters(in: .whitespacesAndNewlines)
                    != new.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            searchModel.clearRetainedData()
        }
        .onChange(of: refreshToken) { _, _ in
            model.request(.refresh)
            if !term.isEmpty { searchModel.request(.refresh) }
            revision += 1
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            displayed.request(.refresh)
            revision += 1
        }
        .onReceive(downloads.objectWillChange) {
            if connectivity.localOnly { revision += 1 }
        }
        .task(id: "\(isActive && isVisible)-\(connectivity.localOnly)-\(term)-\(revision)") {
            guard isActive, isVisible else { return }
            if connectivity.localOnly {
                let items =
                    term.isEmpty
                    ? localItems
                    : localItems.filter {
                        [$0.title, $0.subtitle, $0.album?.title ?? "", $0.artist?.title ?? ""]
                            .contains { $0.localizedStandardContains(term) }
                    }
                displayed.installSnapshot(items)
                return
            }
            if !term.isEmpty {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            if displayed.isRetainedSnapshot { displayed.request(.refresh) }
            await displayed.loadPending(using: loadPage)
        }
    }

    private func indexList(placeholderRows: Int) -> some View {
        List {
            if connectivity.hasConnectionIssue || displayed.hasConnectionIssue {
                FoundationOfflineNotice()
            }
            if displayed.items.isEmpty, !displayed.loaded, displayed.errorMessage == nil,
                !connectivity.localOnly
            {
                FoundationLoadingPlaceholder(rowCount: placeholderRows, rowSpacing: 24)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(Array(displayed.items.enumerated()), id: \.offset) { index, item in
                    FoundationLibraryItemRow(
                        item: item, library: library, isActive: isActive && isVisible,
                        open: { openedItem = item },
                        play: kind == .track ? { play(index) } : nil,
                        player: player, showsTrackArtwork: true,
                        navigate: { openedItem = $0 }
                    )
                    .padding(.vertical, 4)
                }
            }
            if displayed.loaded, displayed.items.isEmpty {
                Text(term.isEmpty ? "No \(title.lowercased()) found." : "No results found.")
                    .foregroundStyle(.secondary)
            }
            if let error = displayed.errorMessage, !displayed.hasConnectionIssue {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") {
                        displayed.request(displayed.retryRequest)
                        revision += 1
                    }.disabled(connectivity.localOnly)
                }
            }
            if displayed.nextStartIndex != nil, !connectivity.localOnly {
                Group {
                    if displayed.isLoading {
                        ProgressView("Loading more…")
                    } else {
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                    }
                }
                .listRowSeparator(.hidden)
                .task(
                    id:
                        "\(isActive && isVisible)-\(term)-\(displayed.nextStartIndex ?? -1)-\(revision)"
                ) {
                    await displayed.loadNextPage(
                        ifActive: isActive && isVisible,
                        allowsNetwork: !connectivity.localOnly, using: loadPage)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("library-index-\(kind)")
        .refreshable {
            guard isActive, isVisible, !connectivity.localOnly else { return }
            displayed.request(.refresh)
            revision += 1
        }
    }

    private func loadPage(_ offset: Int) async throws -> FoundationPage {
        if !term.isEmpty {
            return try await library.search(query: term, kind: kind, startIndex: offset, limit: 50)
        }
        switch kind {
        case .album: return try await library.albums(startIndex: offset)
        case .artist: return try await library.artists(startIndex: offset)
        case .track: return try await library.songs(startIndex: offset)
        case .playlist: return try await library.playlists(startIndex: offset)
        case .genre: return try await library.genres(startIndex: offset)
        }
    }

    private func play(_ index: Int) {
        guard let selection = displayed.trackQueue(selecting: index) else { return }
        if connectivity.localOnly {
            guard downloads.isReady(selection.items[selection.index]) else { return }
            let ready = selection.items.filter { downloads.isReady($0) }
            let selected = selection.items.prefix(selection.index).filter { downloads.isReady($0) }
                .count
            player.setQueue(ready, selectedIndex: selected)
        } else {
            player.setQueue(selection.items, selectedIndex: selection.index)
        }
    }
}
