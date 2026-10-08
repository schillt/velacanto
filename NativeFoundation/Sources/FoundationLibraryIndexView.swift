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
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.foundationAddToPlaylist) private var addToPlaylist
    @Environment(\.foundationRequestDownloadRemoval) private var requestRemoval
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @Environment(\.foundationShowsDownloadBadges) private var showsBadges
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if DEBUG
        @Environment(\.foundationTraceOrigin) private var traceOrigin
    #endif
    @StateObject private var seekModel = FoundationBrowseModel()
    @State private var selectedLetter: String?
    @State private var usesNativeAlphabet = false
    @State private var capability: FoundationAlphabetCapability = .unavailable
    @StateObject private var searchModel = FoundationBrowseModel()
    @State private var query = ""
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayed: FoundationBrowseModel {
        !term.isEmpty ? searchModel : (selectedLetter == nil ? model : seekModel)
    }
    private var alphabetAvailable: Bool {
        term.isEmpty && (connectivity.localOnly || capability == .verified)
    }
    private var wantsNativeAlphabet: Bool {
        alphabetAvailable && (selectedLetter != nil || displayed.loaded || !displayed.items.isEmpty)
    }
    private var alphabetTitles: [String] {
        ["All"] + (connectivity.localOnly ? ["#"] : [])
            + (65...90).compactMap { UnicodeScalar($0).map { String($0) } }
    }
    private var windowDescription: String {
        guard let selectedLetter else { return "All" }
        return selectedLetter == "#" ? "Other downloaded names" : selectedLetter + " and following"
    }
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
            FoundationCollectionTransitionReader { transition in
                #if os(iOS)
                    if usesNativeAlphabet {
                        alphabetList(
                            transition: transition,
                            placeholderRows: min(
                                30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                    } else {
                        indexList(
                            placeholderRows: min(
                                30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                    }
                #else
                    indexList(
                        placeholderRows: min(
                            30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                #endif
            }
        }
        .foundationCatalogHeader(title)
        #if os(iOS)
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search " + title.lowercased())
        #else
            .searchable(text: $query, prompt: "Search " + title.lowercased())
            .toolbar {
                if alphabetAvailable, openedItem == nil {
                    ToolbarItem {
                        Menu("Jump to letter", systemImage: "textformat.abc") {
                            Picker(
                                "Jump to letter",
                                selection: Binding(
                                    get: { selectedLetter ?? "All" }, set: chooseLetter)
                            ) {
                                ForEach(alphabetTitles, id: \.self) { letter in
                                    Text(letter == "#" ? "Other downloaded names" : letter).tag(
                                        letter)
                                }
                            }
                        }
                        .accessibilityValue(windowDescription)
                        .accessibilityIdentifier("library-alphabet-jump-\(kind)")
                    }
                }
            }
        #endif
        .foundationCollectionDestination(
            item: $openedItem, library: library, player: player, isActive: isActive
        )
        .onAppear {
            model.configureCatalogPagination()
            searchModel.configureCatalogPagination()
            seekModel.configureCatalogPagination()
            isVisible = true
            if openedItem == nil { usesNativeAlphabet = wantsNativeAlphabet }
        }
        .onChange(of: wantsNativeAlphabet) { _, desired in
            // Keep the actual matched source hierarchy in place until navigation returns.
            guard openedItem == nil else { return }
            usesNativeAlphabet = desired
        }
        .onChange(of: openedItem) { _, item in
            if item == nil { usesNativeAlphabet = wantsNativeAlphabet }
        }
        .onDisappear { isVisible = false }
        .onChange(of: query) { old, new in
            guard
                old.trimmingCharacters(in: .whitespacesAndNewlines)
                    != new.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            searchModel.clearRetainedData()
            selectedLetter = nil
            seekModel.clearRetainedData()
        }
        .onChange(of: refreshToken) { _, _ in
            model.request(.refresh)
            if !term.isEmpty { searchModel.request(.refresh) }
            if selectedLetter != nil { seekModel.request(.refresh) }
            revision += 1
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            displayed.request(.refresh)
            revision += 1
        }
        .onChange(of: connectivity.localOnly) { old, offline in
            guard old, !offline else { return }
            restoreValidOnlineSelection()
        }
        .onReceive(downloads.objectWillChange) {
            if connectivity.localOnly { revision += 1 }
        }
        .onChange(of: library.catalogScopeID) { _, _ in
            selectedLetter = nil
            seekModel.clearRetainedData()
            searchModel.clearRetainedData()
            capability = .unavailable
            revision += 1
        }
        .task(
            id:
                "capability-\(isActive && isVisible)-\(connectivity.localOnly)-\(library.catalogScopeID)"
        ) {
            guard isActive, isVisible, !connectivity.localOnly else { return }
            let value = await library.alphabetCapability()
            guard !Task.isCancelled else { return }
            capability = value
        }
        .task(
            id:
                "\(isActive && isVisible)-\(connectivity.localOnly)-\(library.catalogScopeID)-\(term)-\(selectedLetter ?? "All")-\(revision)"
        ) {
            guard isActive, isVisible else { return }
            if connectivity.localOnly {
                let items =
                    term.isEmpty
                    ? localItems
                    : localItems.filter {
                        [$0.title, $0.subtitle, $0.album?.title ?? "", $0.artist?.title ?? ""]
                            .contains { $0.localizedStandardContains(term) }
                    }
                let sorted = items.sorted { offlineSortKey($0) < offlineSortKey($1) }
                let window =
                    selectedLetter.map { letter in
                        sorted.filter {
                            let key = offlineSortKey($0)
                            if letter == "#" { return !isASCIILetter(key.first) }
                            return key >= letter.lowercased()
                        }
                    } ?? items
                displayed.installSnapshot(window)
                return
            }
            if selectedLetter != nil,
                selectedLetter
                    != FoundationAlphabetSelectionPolicy.onlineSelection(
                        selectedLetter, capability: capability)
            {
                restoreValidOnlineSelection()
                return
            }
            if !term.isEmpty || selectedLetter != nil {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            if displayed.isRetainedSnapshot { displayed.request(.refresh) }
            await displayed.loadPending(using: loadPage)
        }
    }

    private func indexList(placeholderRows: Int) -> some View {
        List {
            if selectedLetter != nil, term.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(windowDescription)
                        Spacer()
                        Button("All") { chooseLetter("All") }
                            .accessibilityIdentifier("library-alphabet-all-\(kind)")
                    }
                    Text(
                        connectivity.localOnly
                            ? "Downloaded display names"
                            : "Server sort names; All restores browsing"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                .accessibilityIdentifier("library-alphabet-window-\(kind)")
            }
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
        if let selectedLetter {
            return try await library.alphabetPage(
                kind: kind, letter: selectedLetter, startIndex: offset)
        }
        switch kind {
        case .album: return try await library.albums(startIndex: offset)
        case .artist: return try await library.artists(startIndex: offset)
        case .track: return try await library.songs(startIndex: offset)
        case .playlist: return try await library.playlists(startIndex: offset)
        case .genre: return try await library.genres(startIndex: offset)
        }
    }

    private func offlineSortKey(_ item: FoundationItem) -> String {
        item.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private func isASCIILetter(_ character: Character?) -> Bool {
        guard let character, let scalar = character.unicodeScalars.first,
            character.unicodeScalars.count == 1
        else { return false }
        return (97...122).contains(scalar.value)
    }

    private func requestNextPage() {
        guard isActive, isVisible, !connectivity.localOnly, !displayed.isLoading,
            displayed.errorMessage == nil, displayed.nextStartIndex != nil
        else { return }
        // The existing keyed task owns execution, cancellation and publication.
        displayed.request(.more)
        revision += 1
    }

    private func restoreValidOnlineSelection() {
        let normalized = FoundationAlphabetSelectionPolicy.onlineSelection(
            selectedLetter, capability: capability)
        if selectedLetter != normalized { chooseLetter(normalized ?? "All") }
    }

    private func chooseLetter(_ letter: String) {
        let next: String? = letter == "All" ? nil : letter
        guard next != selectedLetter else { return }
        // Revoke old response ownership before the cancellable debounce.
        seekModel.clearRetainedData()
        selectedLetter = next
        revision += 1
    }

    #if os(iOS)
        private func alphabetList(
            transition: FoundationCollectionTransitionContext?, placeholderRows: Int
        ) -> some View {
            let window = selectedLetter ?? "All"
            let rows = displayed.items.enumerated().map { index, item in
                FoundationAlphabetRow(id: "\(kind):\(item.id):\(index)", item: item)
            }
            let sectionTitle =
                selectedLetter.map {
                    $0 == "#" ? "Other downloaded names" : $0 + " and following"
                } ?? title
            return VStack(spacing: 0) {
                Text(
                    connectivity.localOnly
                        ? "Downloaded display names" : "Server sort names; All restores browsing"
                )
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal).padding(.vertical, 4)
                if selectedLetter != nil {
                    Button("All") { chooseLetter("All") }
                        .accessibilityIdentifier("library-alphabet-all-\(kind)")
                }
                FoundationLibraryAlphabetIndex(
                    contextID: library.catalogScopeID + ":" + window,
                    sections: [
                        .init(
                            id: window, title: sectionTitle,
                            availability: displayed.isLoading && rows.isEmpty ? .loading : .loaded,
                            rows: rows)
                    ],
                    indexTitles: alphabetTitles,
                    allowsDemand: isActive && isVisible && !connectivity.localOnly
                        && !displayed.isLoading && displayed.errorMessage == nil,
                    isRefreshing: displayed.isLoading,
                    nextPageIdentity: displayed.nextStartIndex.map {
                        "\(window):\($0):\(revision)"
                    },
                    onChooseLetter: chooseLetter,
                    onDemandNextPage: requestNextPage,
                    onRefresh: {
                        guard isActive, isVisible, !connectivity.localOnly else { return }
                        displayed.request(.refresh)
                        revision += 1
                    }
                ) { entry in
                    FoundationLibraryItemRow(
                        item: entry.item, library: library, isActive: isActive && isVisible,
                        open: { openedItem = entry.item },
                        play: kind == .track
                            ? {
                                if let index = displayed.items.firstIndex(where: {
                                    $0.id == entry.item.id
                                }) {
                                    play(index)
                                }
                            } : nil,
                        player: player, showsTrackArtwork: true,
                        navigate: { openedItem = $0 }
                    )
                    .environmentObject(downloads)
                    .environmentObject(connectivity)
                    .environmentObject(actions)
                    .environment(\.foundationCollectionTransition, transition)
                    .environment(
                        \.foundationCollectionOccurrence,
                        library.catalogScopeID + ":" + window + ":" + entry.id
                    )
                    .environment(\.foundationAddToPlaylist, addToPlaylist)
                    .environment(\.foundationRequestDownloadRemoval, requestRemoval)
                    .environment(\.foundationShowsDownloadBadges, showsBadges)
                    .environment(\.foundationReduceMotion, reduceMotion)
                    .environment(\.foundationReduceTransparency, reduceTransparency)
                    .environment(\.colorScheme, colorScheme)
                    .environment(\.dynamicTypeSize, dynamicTypeSize)
                    #if DEBUG
                        .environment(\.foundationTraceOrigin, traceOrigin)
                    #endif
                }
                .overlay(alignment: .topLeading) {
                    if displayed.items.isEmpty, !displayed.loaded, displayed.errorMessage == nil,
                        !connectivity.localOnly
                    {
                        FoundationLoadingPlaceholder(rowCount: placeholderRows, rowSpacing: 24)
                            .padding(.horizontal, 16).padding(.trailing, 24)
                            .allowsHitTesting(false)
                    }
                }
                .accessibilityIdentifier("library-index-\(kind)")
                if connectivity.hasConnectionIssue || displayed.hasConnectionIssue {
                    FoundationOfflineNotice()
                }
                if displayed.loaded, displayed.items.isEmpty {
                    Text("No \(title.lowercased()) found in this window.").foregroundStyle(
                        .secondary)
                }
                if let error = displayed.errorMessage, !displayed.hasConnectionIssue {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") {
                        displayed.request(displayed.retryRequest)
                        revision += 1
                    }.disabled(connectivity.localOnly)
                }
            }
        }
    #endif

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
