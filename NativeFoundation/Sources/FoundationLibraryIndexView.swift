import Combine
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
    @State private var capabilityResolved = false
    @State private var capabilityRefreshRevision = 0
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
    // An unsupported server can still index complete known membership without issuing seeks.
    private var usesLoadedAlphabet: Bool {
        !connectivity.localOnly && capabilityResolved && capability == .unavailable
            && model.loaded && model.nextStartIndex == nil && model.errorMessage == nil
    }
    private var indexesDisplayNames: Bool { connectivity.localOnly || usesLoadedAlphabet }
    private var alphabetDescription: String {
        connectivity.localOnly
            ? "Downloaded display names"
            : (usesLoadedAlphabet
                ? "Loaded display names; All restores browsing"
                : "Server sort names; All restores browsing")
    }
    private var alphabetAvailable: Bool {
        kind == .track && term.isEmpty
            && (connectivity.localOnly || capability == .verified || usesLoadedAlphabet)
    }
    private var wantsNativeAlphabet: Bool {
        alphabetAvailable && (selectedLetter != nil || displayed.loaded || !displayed.items.isEmpty)
    }
    private var alphabetTitles: [String] {
        ["All"] + (indexesDisplayNames ? ["#"] : [])
            + (65...90).compactMap { UnicodeScalar($0).map { String($0) } }
    }
    private var windowDescription: String {
        guard let selectedLetter else { return "All" }
        return selectedLetter == "#"
            ? (connectivity.localOnly ? "Other downloaded names" : "Other display names")
            : selectedLetter + " and following"
    }
    private var isCoverGrid: Bool { kind == .album || kind == .playlist }

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
        // The task key and its closure must describe the same rendered activation.
        // Reading live @State after onAppear could start work under a superseded key.
        let active = isActive && isVisible
        let allowsNetwork = !connectivity.localOnly
        return GeometryReader { geometry in
            FoundationCollectionTransitionReader { transition in
                #if os(iOS)
                    if usesNativeAlphabet {
                        alphabetList(
                            transition: transition, viewport: geometry.size,
                            placeholderRows: min(
                                30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                    } else if isCoverGrid {
                        collectionGrid(viewport: geometry.size)
                    } else {
                        indexList(
                            placeholderRows: min(
                                30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                    }
                #else
                    if isCoverGrid {
                        collectionGrid(viewport: geometry.size)
                    } else {
                        indexList(
                            placeholderRows: min(
                                30, max(1, Int(ceil(geometry.size.height / rowHeight)))))
                    }
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
            if usesLoadedAlphabet, selectedLetter != nil { chooseLetter("All") }
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
            capabilityResolved = false
            revision += 1
        }
        .task(
            id:
                "capability-\(active)-\(!allowsNetwork)-\(library.catalogScopeID)-\(connectivity.successfulRetryRevision)-\(capabilityRefreshRevision)"
        ) {
            guard kind == .track, active, allowsNetwork, !Task.isCancelled else { return }
            let value = await library.alphabetCapability()
            guard !Task.isCancelled else { return }
            capability = value
            capabilityResolved = true
        }
        .task(
            id:
                "\(active)-\(!allowsNetwork)-\(library.catalogScopeID)-\(term)-\(selectedLetter ?? "All")-\(usesLoadedAlphabet)-\(revision)"
        ) {
            guard active, !Task.isCancelled else { return }
            if !allowsNetwork || (usesLoadedAlphabet && selectedLetter != nil) {
                let source = allowsNetwork ? model.items : localItems
                let items =
                    term.isEmpty
                    ? source
                    : source.filter {
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
            if selectedLetter != nil, !usesLoadedAlphabet,
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
            await displayed.loadPending(
                ifActive: active, allowsNetwork: allowsNetwork, using: loadPage)
        }
    }

    private func indexList(placeholderRows: Int) -> some View {
        let active = isActive && isVisible
        let allowsNetwork = !connectivity.localOnly
        let pageModel = displayed
        return List {
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
                VStack(spacing: 0) {
                    if displayed.isLoading {
                        ProgressView("Loading more…")
                    } else {
                        Color.clear.frame(height: 1).accessibilityHidden(true)
                    }
                }
                .listRowSeparator(.hidden)
                .task(
                    id:
                        "\(active)-\(allowsNetwork)-\(term)-\(displayed.nextStartIndex ?? -1)-\(revision)"
                ) {
                    await loadDemandedPage(
                        pageModel, active: active, allowsNetwork: allowsNetwork)
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("library-index-\(kind)")
        .refreshable {
            guard isActive, isVisible, !connectivity.localOnly else { return }
            retryAlphabetCapabilityIfNeeded()
            displayed.request(.refresh)
            revision += 1
        }
    }

    private func gridColumnCount(width: CGFloat, nativeIndex: Bool = false) -> Int {
        FoundationLibraryGridLayout.columnCount(
            width: width, accessibility: dynamicTypeSize.isAccessibilitySize,
            nativeIndex: nativeIndex)
    }

    private func gridPlaceholderCount(viewport: CGSize, nativeIndex: Bool = false) -> Int {
        FoundationLibraryGridLayout.placeholderCount(
            width: viewport.width, height: viewport.height,
            accessibility: dynamicTypeSize.isAccessibilitySize,
            textHeight: rowHeight, nativeIndex: nativeIndex)
    }

    private func collectionTile(_ item: FoundationItem) -> some View {
        FoundationCollectionCard(
            item: item, library: library, player: player,
            isActive: isActive && isVisible, open: { openedItem = item },
            navigate: { openedItem = $0 }
        )
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 240, alignment: .topLeading)
        .environment(
            \.foundationCollectionOccurrence,
            library.catalogScopeID + ":" + (selectedLetter ?? "All") + ":" + term + ":"
                + kind.rawValue + ":" + item.id)
    }

    private func collectionGrid(viewport: CGSize) -> some View {
        let active = isActive && isVisible
        let allowsNetwork = !connectivity.localOnly
        let pageModel = displayed
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if selectedLetter != nil {
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
                if connectivity.hasConnectionIssue || displayed.hasConnectionIssue {
                    FoundationOfflineNotice()
                }
                if displayed.items.isEmpty, !displayed.loaded, displayed.errorMessage == nil,
                    !connectivity.localOnly
                {
                    FoundationLoadingPlaceholder(
                        layout: .albumGrid,
                        rowCount: gridPlaceholderCount(viewport: viewport))
                } else {
                    LazyVGrid(
                        columns: foundationCollectionColumns(for: dynamicTypeSize),
                        alignment: .leading, spacing: 22
                    ) {
                        ForEach(displayed.items) { item in collectionTile(item) }
                    }
                    .accessibilityIdentifier("library-cover-grid-\(kind)")
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
                    VStack(spacing: 0) {
                        if displayed.isLoading {
                            ProgressView("Loading more…")
                        } else {
                            Color.clear.frame(height: 1).accessibilityHidden(true)
                        }
                    }
                    .task(
                        id:
                            "\(active)-\(allowsNetwork)-\(term)-\(selectedLetter ?? "All")-\(displayed.nextStartIndex ?? -1)-\(revision)"
                    ) {
                        await loadDemandedPage(
                            pageModel, active: active, allowsNetwork: allowsNetwork)
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
        }
        .accessibilityIdentifier("library-index-\(kind)")
        .refreshable {
            guard isActive, isVisible, !connectivity.localOnly else { return }
            retryAlphabetCapabilityIfNeeded()
            displayed.request(.refresh)
            revision += 1
        }
    }

    /// A visible footer retains one demand through initial publication/cache completion.
    /// The stable task host owns the subscription and cancels it when the footer leaves.
    private func loadDemandedPage(
        _ pageModel: FoundationBrowseModel, active: Bool, allowsNetwork: Bool
    ) async {
        guard active, allowsNetwork, !Task.isCancelled else { return }
        // Filter before the async bridge so a busy value cannot consume its demand.
        for await _ in pageModel.$isLoading.filter({ !$0 }).values {
            guard !Task.isCancelled else { return }
            await pageModel.loadNextPage(
                ifActive: active, allowsNetwork: allowsNetwork, using: loadPage)
            return
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

    /// Only explicit pull-to-refresh retries a failed probe; paging never does.
    private func retryAlphabetCapabilityIfNeeded() {
        if kind == .track, capability == .unavailable { capabilityRefreshRevision += 1 }
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
        if usesLoadedAlphabet { return }
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
            transition: FoundationCollectionTransitionContext?, viewport: CGSize,
            placeholderRows: Int
        ) -> some View {
            let window = selectedLetter ?? "All"
            let rows = displayed.items.map { item in
                FoundationAlphabetRow(id: "\(kind):\(item.id)", item: item)
            }
            let sectionTitle =
                selectedLetter.map {
                    $0 == "#"
                        ? (connectivity.localOnly
                            ? "Other downloaded names" : "Other display names")
                        : $0 + " and following"
                } ?? title
            return VStack(spacing: 0) {
                Text(
                    alphabetDescription
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
                    columnCount: isCoverGrid
                        ? gridColumnCount(width: viewport.width, nativeIndex: true) : 1,
                    isCoverGrid: isCoverGrid,
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
                        retryAlphabetCapabilityIfNeeded()
                        // Refresh complete source membership before applying another local window.
                        if usesLoadedAlphabet, selectedLetter != nil { chooseLetter("All") }
                        displayed.request(.refresh)
                        revision += 1
                    }
                ) { entry in
                    Group {
                        if isCoverGrid {
                            collectionTile(entry.item)
                        } else {
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
                        }
                    }
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
                        FoundationLoadingPlaceholder(
                            layout: isCoverGrid ? .albumGrid : .rows,
                            rowCount: isCoverGrid
                                ? gridPlaceholderCount(viewport: viewport, nativeIndex: true)
                                : placeholderRows,
                            rowSpacing: 24
                        )
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

/// Geometry policy shared by native hosted rows and viewport-sized cover placeholders.
enum FoundationLibraryGridLayout {
    static func rowCount(itemCount: Int, columns: Int) -> Int {
        guard itemCount > 0 else { return 0 }
        let count = max(1, columns)
        return itemCount / count + (itemCount % count == 0 ? 0 : 1)
    }

    static func itemRange(row: Int, itemCount: Int, columns: Int) -> Range<Int> {
        guard row >= 0, row < rowCount(itemCount: itemCount, columns: columns) else {
            return 0..<0
        }
        let count = max(1, columns)
        let start = row * count
        return start..<(start + min(count, itemCount - start))
    }

    static func columnCount(width: Double, accessibility: Bool, nativeIndex: Bool = false) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let usable = max(1, width - 32 - (nativeIndex ? 22 : 0))
        let minimum = accessibility ? 240.0 : 140.0
        return max(1, Int(min(100, (usable + 18) / (minimum + 18))))
    }

    static func placeholderCount(
        width: Double, height: Double, accessibility: Bool,
        textHeight: Double, nativeIndex: Bool = false
    ) -> Int {
        guard width.isFinite, width > 0, height.isFinite, height > 0, textHeight.isFinite else {
            return columnCount(width: width, accessibility: accessibility, nativeIndex: nativeIndex)
        }
        let columns = columnCount(
            width: width, accessibility: accessibility, nativeIndex: nativeIndex)
        let usable = max(1, width - 32 - (nativeIndex ? 22 : 0))
        let cover = min(
            accessibility ? 320 : 240, max(1, (usable - Double(columns - 1) * 18) / Double(columns))
        )
        let rowHeight = cover + max(1, textHeight) + 22
        let rows = max(1, Int(min(100, ceil(height / rowHeight))))
        return min(200, columns * rows)
    }
}
