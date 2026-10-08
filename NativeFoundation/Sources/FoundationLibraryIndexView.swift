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
    @State private var selectedLetter: String?
    @State private var anchorRowID: String?
    @State private var anchorRevision = 0
    @State private var demandRevision = 0
    @State private var consumedDemandRevision = 0
    @State private var usesNativeAlphabet = false
    @StateObject private var searchModel = FoundationBrowseModel()
    @State private var query = ""
    @State private var isVisible = false
    @State private var revision = 0
    @State private var openedItem: FoundationItem?
    @ScaledMetric(relativeTo: .body) private var rowHeight = 72.0

    private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var displayed: FoundationBrowseModel { term.isEmpty ? model : searchModel }
    private var alphabetAvailable: Bool { kind == .track && term.isEmpty }
    private var wantsNativeAlphabet: Bool { alphabetAvailable }
    private var alphabetTitles: [String] {
        FoundationAlphabetAnchors.titles
    }
    private var windowDescription: String { selectedLetter ?? "All" }
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
        let requestRevision = revision
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
            .toolbar {
                if alphabetAvailable, openedItem == nil {
                    ToolbarItem(placement: .navigation) {
                        Menu("Jump to letter", systemImage: "textformat.abc") {
                            Picker(
                                "Jump to letter",
                                selection: Binding(
                                    get: { selectedLetter ?? "A" }, set: chooseLetter)
                            ) {
                                ForEach(alphabetTitles, id: \.self) { letter in
                                    Text(letter).tag(letter)
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
            model.configureCatalogPagination(sortByTitle: kind == .track)
            searchModel.configureCatalogPagination()
            isVisible = true
            if openedItem == nil { usesNativeAlphabet = wantsNativeAlphabet }
        }
        .onChange(of: model.items, initial: true) { _, items in
            if !model.isRetainedSnapshot { actions.observeFavorites(in: items) }
        }
        .onChange(of: searchModel.items, initial: true) { _, items in
            if !searchModel.isRetainedSnapshot { actions.observeFavorites(in: items) }
        }
        .onChange(of: wantsNativeAlphabet) { _, desired in
            // Keep the actual matched source hierarchy in place until navigation returns.
            guard openedItem == nil else { return }
            usesNativeAlphabet = desired
        }
        .onChange(of: openedItem) { _, item in
            if item == nil { usesNativeAlphabet = wantsNativeAlphabet }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: query) { old, new in
            guard
                old.trimmingCharacters(in: .whitespacesAndNewlines)
                    != new.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            searchModel.clearRetainedData()
            selectedLetter = nil
        }
        .onChange(of: refreshToken) { _, _ in
            selectedLetter = nil
            model.request(.refresh)
            if !term.isEmpty { searchModel.request(.refresh) }
            revision += 1
        }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            guard isActive, isVisible else { return }
            selectedLetter = nil
            displayed.request(.refresh)
            revision += 1
        }
        .onChange(of: connectivity.localOnly) { _, _ in
            selectedLetter = nil
            anchorRowID = nil
            revision += 1
        }
        .onReceive(downloads.objectWillChange) {
            if connectivity.localOnly { revision += 1 }
        }
        .onChange(of: library.catalogScopeID) { _, _ in
            demandRevision = 0
            consumedDemandRevision = 0
            selectedLetter = nil
            searchModel.clearRetainedData()
            revision += 1
        }
        .task(
            id: "\(active)-\(!allowsNetwork)-\(library.catalogScopeID)-\(term)-\(requestRevision)"
        ) {
            guard active, !Task.isCancelled else { return }
            if !allowsNetwork {
                let items =
                    term.isEmpty
                    ? localItems
                    : localItems.filter {
                        [$0.title, $0.subtitle, $0.album?.title ?? "", $0.artist?.title ?? ""]
                            .contains { $0.localizedStandardContains(term) }
                    }
                displayed.installSnapshot(
                    items.sorted { offlineSortKey($0) < offlineSortKey($1) })
            } else if alphabetAvailable {
                await model.loadCatalogPage(using: loadPage)
            } else {
                if !term.isEmpty {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                }
                if displayed.isRetainedSnapshot { displayed.request(.refresh) }
                await displayed.loadPending(
                    ifActive: active, allowsNetwork: allowsNetwork, using: loadPage)
            }

        }
    }

    private func indexList(placeholderRows: Int) -> some View {
        let active = isActive && isVisible
        let allowsNetwork = !connectivity.localOnly
        let pageModel = displayed
        return ScrollViewReader { proxy in
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
                        .id("\(kind):\(item.id)")
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
                            selectedLetter = nil
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
                selectedLetter = nil
                displayed.request(.refresh)
                revision += 1
            }
            .onChange(of: anchorRevision) { _, _ in
                if let anchorRowID { proxy.scrollTo(anchorRowID, anchor: .top) }
            }
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
        switch kind {
        case .album: return try await library.albums(startIndex: offset)
        case .artist: return try await library.artists(startIndex: offset)
        case .track: return try await library.songs(startIndex: offset)
        case .playlist: return try await library.playlists(startIndex: offset)
        case .genre: return try await library.genres(startIndex: offset)
        }
    }

    private func offlineSortKey(_ item: FoundationItem) -> String {
        FoundationAlphabetAnchors.key(for: item)
    }

    private func chooseLetter(_ letter: String) {
        // Selection changes only the scroll position of the existing full list.
        guard let index = FoundationAlphabetAnchors.index(for: letter, in: model.items) else {
            return
        }
        selectedLetter = letter
        anchorRowID = "\(kind):\(model.items[index].id)"
        anchorRevision += 1
    }

    #if os(iOS)
        private func alphabetList(
            transition: FoundationCollectionTransitionContext?, viewport: CGSize,
            placeholderRows: Int
        ) -> some View {
            let rows = displayed.items.map { item in
                FoundationAlphabetRow(id: "\(kind):\(item.id)", item: item)
            }
            var sections: [FoundationAlphabetSection] = []
            for row in rows {
                let letter = FoundationAlphabetAnchors.letter(for: row.item)
                if let last = sections.indices.last, sections[last].title == letter {
                    sections[last].rows.append(row)
                } else {
                    sections.append(
                        .init(
                            id: letter + ":" + row.id, title: letter,
                            availability: .loaded, rows: [row]))
                }
            }
            if sections.isEmpty {
                sections = [.init(id: "All", title: title, availability: .loaded, rows: [])]
            }
            return VStack(spacing: 0) {
                FoundationLibraryAlphabetIndex(
                    contextID: library.catalogScopeID,
                    sections: sections,
                    columnCount: isCoverGrid
                        ? gridColumnCount(width: viewport.width, nativeIndex: true) : 1,
                    isCoverGrid: isCoverGrid,
                    rowHeight: rowHeight,
                    allowsDemand: isActive && isVisible && !connectivity.localOnly
                        && displayed.errorMessage == nil,
                    isRefreshing: displayed.isLoading,
                    nextPageIdentity: displayed.nextStartIndex.map { "\($0):\(revision)" },
                    anchorRowID: anchorRowID,
                    anchorRevision: anchorRevision,
                    onDemandNextPage: { demandRevision += 1 },
                    onRefresh: {
                        guard isActive, isVisible, !connectivity.localOnly else { return }
                        selectedLetter = nil
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
                            .lineLimit(1)
                        }
                    }
                    .environmentObject(downloads)
                    .environmentObject(connectivity)
                    .environmentObject(actions)
                    .environment(\.foundationCollectionTransition, transition)
                    .environment(
                        \.foundationCollectionOccurrence,
                        library.catalogScopeID + ":" + entry.id
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
                .task(
                    id:
                        "\(demandRevision)-\(isActive)-\(isVisible)-\(connectivity.localOnly)-\(library.catalogScopeID)"
                ) {
                    let demand = demandRevision
                    guard demand > consumedDemandRevision else { return }
                    await loadDemandedPage(
                        displayed, active: isActive && isVisible,
                        allowsNetwork: !connectivity.localOnly)
                    if !Task.isCancelled, isActive, isVisible, !connectivity.localOnly {
                        consumedDemandRevision = max(consumedDemandRevision, demand)
                    }
                }
                .accessibilityIdentifier("library-index-\(kind)")
                .padding(.trailing, 36)
                .overlay(alignment: .trailing) {
                    FoundationAlphabetRail(onChooseLetter: chooseLetter)
                        .frame(width: 36)
                }
                if connectivity.hasConnectionIssue || displayed.hasConnectionIssue {
                    FoundationOfflineNotice()
                }
                if displayed.loaded, displayed.items.isEmpty {
                    Text("No \(title.lowercased()) found.").foregroundStyle(
                        .secondary)
                }
                if let error = displayed.errorMessage, !displayed.hasConnectionIssue {
                    Text(error).foregroundStyle(.red)
                    Button("Retry") {
                        selectedLetter = nil
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

/// Songs use actual display titles for both ordering and section anchors, independent of server order.
enum FoundationAlphabetAnchors {
    static func key(for item: FoundationItem) -> String {
        item.title.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    static func sorted(_ items: [FoundationItem]) -> [FoundationItem] {
        items.sorted { lhs, rhs in
            let leftOther = letter(for: lhs) == "#"
            let rightOther = letter(for: rhs) == "#"
            if leftOther != rightOther { return leftOther }
            let order = key(for: lhs).compare(
                key(for: rhs), options: .numeric, locale: Locale(identifier: "en_US_POSIX"))
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id == rhs.id ? lhs.kind.rawValue < rhs.kind.rawValue : lhs.id < rhs.id
        }
    }

    static func letter(for item: FoundationItem) -> String {
        guard let scalar = key(for: item).unicodeScalars.first,
            (97...122).contains(scalar.value)
        else { return "#" }
        return String(scalar).uppercased()
    }

    static let titles = ["#"] + (65...90).compactMap { UnicodeScalar($0).map { String($0) } }

    static func index(for letter: String, in items: [FoundationItem]) -> Int? {
        guard titles.contains(letter) else { return nil }
        return items.firstIndex(where: { self.letter(for: $0) == letter })
            ?? followingIndex(for: letter, in: items)
            ?? items.indices.last
    }

    static func followingIndex(for letter: String, in items: [FoundationItem]) -> Int? {
        items.firstIndex {
            let group = self.letter(for: $0)
            return group != "#" && group >= letter
        }
    }
}

/// Rail geometry is independent of table scrolling and uses one equal hit region per letter.
enum FoundationAlphabetRailGeometry {
    static func bubbleTop(index: Int, height: Double, count: Int) -> Double {
        guard count > 0, height.isFinite, height > 0 else { return 0 }
        let center = (Double(max(0, min(count - 1, index))) + 0.5) * height / Double(count)
        return min(max(0, height - 54), max(0, center - 27))
    }

    static func index(y: Double, height: Double, count: Int) -> Int? {
        guard count > 0, height.isFinite, height > 0, y.isFinite else { return nil }
        let fraction = min(1, max(0, y / height))
        return min(count - 1, Int(fraction * Double(count)))
    }
}

#if os(iOS)
    private struct FoundationAlphabetRail: View {
        let onChooseLetter: (String) -> Void
        @State private var scrubbedLetter: String?
        @GestureState private var isScrubbing = false

        var body: some View {
            GeometryReader { geometry in
                let height = min(594, max(1, geometry.size.height - 16))
                let titles = FoundationAlphabetAnchors.titles
                VStack(spacing: 0) {
                    ForEach(titles, id: \.self) { letter in
                        Text(letter)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(maxWidth: .infinity)
                            .frame(height: height / Double(titles.count))
                            .accessibilityLabel(letter == "#" ? "Numbers and symbols" : letter)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("library-alphabet-letter-" + letter)
                            .accessibilityAction { onChooseLetter(letter) }
                    }
                }
                .frame(width: geometry.size.width, height: height)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($isScrubbing) { _, active, _ in active = true }
                        .onChanged { value in
                            guard
                                let index = FoundationAlphabetRailGeometry.index(
                                    y: value.location.y, height: height, count: titles.count)
                            else { return }
                            let letter = titles[index]
                            guard scrubbedLetter != letter else { return }
                            scrubbedLetter = letter
                            onChooseLetter(letter)
                        }
                        .onEnded { _ in scrubbedLetter = nil }
                )
                .sensoryFeedback(.selection, trigger: scrubbedLetter) { old, new in
                    new != nil && old != new
                }
                .overlay(alignment: .topLeading) {
                    if isScrubbing, let scrubbedLetter,
                        let index = titles.firstIndex(of: scrubbedLetter)
                    {
                        Text(scrubbedLetter)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .frame(width: 54, height: 54)
                            .glassEffect(.regular, in: Circle())
                            .offset(
                                x: -64,
                                y: FoundationAlphabetRailGeometry.bubbleTop(
                                    index: index, height: height, count: titles.count)
                            )
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onChange(of: isScrubbing) { _, active in
                    if !active { scrubbedLetter = nil }
                }
                .onDisappear { scrubbedLetter = nil }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Section index")
                .accessibilityIdentifier("library-alphabet-rail")
                .frame(maxHeight: .infinity)
            }
        }
    }
#endif
