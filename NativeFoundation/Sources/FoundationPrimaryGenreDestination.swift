import SwiftUI

/// Primary genre membership follows the saved per-song policy, including songs whose
/// album has no matching genre tag. Complete census names establish logical order before
/// paging, without claiming atomic live-server metadata or raw album-by-genre membership.
struct FoundationPrimaryGenreDestination: View {
    @EnvironmentObject private var genres: FoundationPrimaryGenresModel
    let genre: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool

    var body: some View {
        if let record = genres.canonicalRecord(
            for: genre, libraryScope: library.primaryGenreIndexScope)
        {
            FoundationPrimaryGenreContentView(
                genre: genre, record: record, library: library, player: player, isActive: isActive
            ).id(
                FoundationGenreIdentity(
                    source: record.snapshot.scope.source, itemID: genre.id,
                    censusID: record.snapshot.censusID))
        } else {
            ContentUnavailableView(
                "Genre unavailable", systemImage: "music.note.list",
                description: Text(
                    "Return to Genres and select it again."
                ))
        }
    }
}

private struct FoundationPrimaryGenreContentView: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var genres: FoundationPrimaryGenresModel
    let genre: FoundationItem
    let record: FoundationPrimaryGenreRecord
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    private let membership: [String]
    private let trackSorts: [FoundationPrimaryGenreSort]
    @State private var content = FoundationPrimaryGenreContent.albums
    @State private var sort = FoundationPrimaryGenreSort.name
    @State private var descending = false
    @State private var downloadedOnly = false
    @State private var prepared: Prepared?

    private struct Prepared {
        let key: String
        let source: FoundationPrimaryGenreContentPageSource
        let localItems: [FoundationItem]
    }

    init(
        genre: FoundationItem, record: FoundationPrimaryGenreRecord,
        library: any FoundationLibrary, player: FoundationPlayer, isActive: Bool
    ) {
        self.genre = genre
        self.record = record
        self.library = library
        self.player = player
        self.isActive = isActive
        let membership = record.songIDs(for: genre.id)
        self.membership = membership
        self.trackSorts =
            record.contentIndex?.supportedSorts(kind: .track, membership: membership) ?? [.name]
    }

    private var readySongs: [FoundationItem] {
        record.readySongs(membershipIDs: membership, from: downloads.downloadedSongs)
    }
    private var supportedSorts: [FoundationPrimaryGenreSort] {
        content == .tracks ? trackSorts : [.name]
    }
    private var effectiveSort: FoundationPrimaryGenreSort {
        supportedSorts.contains(sort) ? sort : .name
    }
    private var queryKey: String {
        let readyRevision =
            downloadedOnly || connectivity.localOnly
            ? "\(downloads.verifiedReadyRevision):\(downloads.catalogRevision)" : "all"
        return
            "\(record.snapshot.censusID):\(content.rawValue):\(effectiveSort.rawValue):\(descending):\(downloadedOnly):\(connectivity.localOnly):\(readyRevision)"
    }

    var body: some View {
        Group {
            if let prepared, prepared.key == queryKey {
                FoundationPrimaryGenreContentPage(
                    title: genre.title, source: prepared.source, localItems: prepared.localItems,
                    library: library, player: player, isActive: isActive
                ).id(prepared.key)
            } else if record.contentIndex != nil || connectivity.localOnly || downloadedOnly
                || genres.isBuilding
            {
                ProgressView("Preparing genre…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foundationCatalogHeader(genre.title)
            } else {
                ContentUnavailableView(
                    "Genre view unavailable", systemImage: "music.note.list",
                    description: Text("Your music is still available from Library.")
                )
                .foundationCatalogHeader(genre.title)
            }
        }
        .accessibilityIdentifier("primary-genre-songs")
        .toolbar {
            #if os(macOS)
                ToolbarItemGroup(placement: .primaryAction) {
                    contentSelector
                    sortAndFilter
                }
            #else
                ToolbarItemGroup(placement: .topBarTrailing) {
                    contentSelector
                    sortAndFilter
                }
            #endif
        }
        .task(id: "\(queryKey):\(isActive)") {
            guard isActive, !Task.isCancelled,
                library.primaryGenreIndexScope == record.snapshot.scope
            else { return }
            let key = queryKey
            let ready = readySongs
            let local = record.offlineContent(
                genreID: genre.id, kind: content.kind, downloaded: ready,
                sort: effectiveSort, descending: descending)
            let source: FoundationPrimaryGenreContentPageSource
            if connectivity.localOnly || downloadedOnly {
                source = .init(
                    scope: record.snapshot.scope, kind: content.kind, ids: local.map(\.id))
            } else {
                guard
                    let next = record.contentSource(
                        genreID: genre.id, kind: content.kind, sort: effectiveSort,
                        descending: descending)
                else { return }
                source = next
            }
            guard !Task.isCancelled, key == queryKey else { return }
            prepared = .init(key: key, source: source, localItems: local)
        }
    }

    private var contentSelector: some View {
        Picker(
            "Genre content",
            selection: Binding(
                get: { content },
                set: {
                    content = $0
                    sort = .name
                    descending = false
                }
            )
        ) {
            ForEach([FoundationPrimaryGenreContent.albums, .tracks, .artists]) { kind in
                Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                    .accessibilityLabel(kind.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .labelsHidden()
        .frame(width: 144)
        .help("Albums, Tracks, or Artists")
        .accessibilityIdentifier("primary-genre-content-picker")
    }

    private var sortAndFilter: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(supportedSorts) { field in
                    Text(field.title(for: content.kind)).tag(field)
                }
            }.pickerStyle(.inline)
            Toggle("Descending", isOn: $descending)
            Divider()
            Picker(
                "Show",
                selection: Binding(
                    get: { downloadedOnly || connectivity.localOnly },
                    set: { downloadedOnly = $0 }
                )
            ) {
                Text("All").tag(false)
                Text("Downloaded").tag(true)
            }
            .pickerStyle(.inline)
            .disabled(connectivity.localOnly)
        } label: {
            Label("Sort and filter", systemImage: "line.3.horizontal.decrease")
        }
        .menuIndicator(.hidden)
        .help("Sort and filter")
        .accessibilityLabel("Sort and filter")
        .accessibilityIdentifier("primary-genre-sort-filter")
    }
}

private struct FoundationPrimaryGenreContentPage: View {
    let title: String
    let source: FoundationPrimaryGenreContentPageSource
    let localItems: [FoundationItem]
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    @StateObject private var items: FoundationBrowseModel

    init(
        title: String, source: FoundationPrimaryGenreContentPageSource,
        localItems: [FoundationItem],
        library: any FoundationLibrary, player: FoundationPlayer, isActive: Bool
    ) {
        self.title = title
        self.source = source
        self.localItems = localItems
        self.library = library
        self.player = player
        self.isActive = isActive
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        _items = StateObject(wrappedValue: model)
    }

    var body: some View {
        FoundationCatalogView(
            title: title, model: items, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true, automaticallyLoadsPages: true,
            collectionGrid: source.kind != .track, localItems: { localItems },
            loader: { try await source.page(startIndex: $0, library: library) })
    }
}

/// A complete, immutable logical order; one visible page still makes at most one bounded read.
struct FoundationPrimaryGenreContentPageSource: Sendable {
    let scope: FoundationPrimaryGenreIndex.Scope
    let kind: FoundationItem.Kind
    let ids: [String]

    func page(startIndex: Int, library: any FoundationLibrary) async throws -> FoundationPage {
        guard scope == library.primaryGenreIndexScope, startIndex >= 0,
            [.track, .album, .artist].contains(kind)
        else { throw FoundationLibraryError.unavailable }
        try Task.checkCancellation()
        guard startIndex < ids.count else { return .init(items: [], nextStartIndex: nil) }
        let end = startIndex + min(50, ids.count - startIndex)
        let selected = Array(ids[startIndex..<end])
        guard Set(selected).count == selected.count else {
            throw FoundationLibraryError.invalidResponse
        }
        let items =
            kind == .track
            ? try await library.primaryGenreSongs(ids: selected)
            : try await library.primaryGenreCollections(ids: selected, kind: kind)
        try Task.checkCancellation()
        guard items.count == selected.count, Set(items.map(\.id)) == Set(selected),
            items.allSatisfy({
                $0.kind == kind && ($0.catalogSource == nil || $0.catalogSource == scope.source)
            })
        else { throw FoundationLibraryError.unavailable }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let ordered = selected.compactMap { id -> FoundationItem? in
            guard var item = byID[id] else { return nil }
            item.catalogSource = scope.source
            return item
        }
        return .init(items: ordered, nextStartIndex: end < ids.count ? end : nil)
    }
}

/// Collection membership comes from the same canonical songs, not provider album genre tags.
/// A page with repeated/missing references never triggers a hidden search for a new collection.
enum FoundationPrimaryGenreContent: String, CaseIterable, Identifiable {
    case tracks = "Tracks"
    case albums = "Albums"
    case artists = "Artists"

    var id: Self { self }
    var kind: FoundationItem.Kind {
        switch self {
        case .tracks: .track
        case .albums: .album
        case .artists: .artist
        }
    }
    var symbol: String {
        switch self {
        case .tracks: "music.note.list"
        case .albums: "square.stack"
        case .artists: "music.mic"
        }
    }

    var emptyMessage: String? {
        switch self {
        case .tracks: nil
        case .albums: "No album information in the loaded tracks."
        case .artists: "No artist information in the loaded tracks."
        }
    }

    /// A raw cursor advancing through duplicate/missing references cannot start a crawl.
    func pageDemandIdentity(for items: [FoundationItem]) -> String? {
        self == .tracks ? nil : "\(rawValue)-\(items.count)-\(items.last?.id ?? "")"
    }

    func items(in songs: [FoundationItem], source: FoundationCatalogSource) -> [FoundationItem] {
        let scoped = songs.filter {
            $0.kind == .track && ($0.catalogSource == nil || $0.catalogSource == source)
        }
        guard self != .tracks else { return scoped }
        var seen: Set<String> = []
        return scoped.compactMap { song in
            let item = self == .albums ? song.relatedAlbum : song.relatedArtist
            guard let item, seen.insert(item.id).inserted else { return nil }
            return item
        }
    }
}

extension FoundationPrimaryGenreRecord {
    func contentSource(
        genreID: String, kind: FoundationItem.Kind, sort: FoundationPrimaryGenreSort = .name,
        descending: Bool = false, readySongIDs: Set<String>? = nil
    ) -> FoundationPrimaryGenreContentPageSource? {
        guard [.track, .album, .artist].contains(kind),
            snapshot.eligibleGenreIDs.contains(genreID), let contentIndex,
            contentMetadataVersion == FoundationPrimaryGenreContentIndex.version,
            contentIndex.supportedSorts(kind: kind, membership: songIDs(for: genreID)).contains(
                sort)
        else { return nil }
        return .init(
            scope: snapshot.scope, kind: kind,
            ids: contentIndex.orderedIDs(
                membership: songIDs(for: genreID), kind: kind, sort: sort,
                descending: descending, readySongIDs: readySongIDs))
    }

    /// Complete ready membership remains usable offline even for a legacy saved genre record.
    func offlineContent(
        genreID: String, kind: FoundationItem.Kind, downloaded: [FoundationItem],
        sort: FoundationPrimaryGenreSort = .name, descending: Bool = false
    ) -> [FoundationItem] {
        let members = readySongs(membershipIDs: songIDs(for: genreID), from: downloaded)
        let media: FoundationPrimaryGenreContent
        switch kind {
        case .track: media = .tracks
        case .album: media = .albums
        case .artist: media = .artists
        default: return []
        }
        let projected = media.items(in: members, source: snapshot.scope.source)
        if kind == .track, sort != .name, let contentIndex {
            let byID = Dictionary(uniqueKeysWithValues: projected.map { ($0.id, $0) })
            return contentIndex.orderedIDs(
                membership: songIDs(for: genreID), kind: kind, sort: sort,
                descending: descending, readySongIDs: Set(members.map(\.id))
            ).compactMap { byID[$0] }
        }
        return projected.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            if order == .orderedSame { return $0.id < $1.id }
            return order == (descending ? .orderedDescending : .orderedAscending)
        }
    }

    func readySongs(membershipIDs: [String], from downloaded: [FoundationItem]) -> [FoundationItem]
    {
        var ready: [String: FoundationItem] = [:]
        for song in downloaded
        where song.catalogSource == nil
            || song.catalogSource == snapshot.scope.source
        {
            ready[song.id] = song
        }
        return membershipIDs.compactMap { id in
            guard snapshot.primaryBySongID[id] != nil else { return nil }
            return ready[id]
        }
    }

    /// One ordinary bounded read for a visible page; no raw genre-content scan.
    func songPage(
        genreID: String, startIndex: Int, limit: Int = 50, library: any FoundationLibrary
    ) async throws
        -> FoundationPage
    {
        guard library.primaryGenreIndexScope == snapshot.scope, startIndex >= 0,
            (1...50).contains(limit),
            snapshot.eligibleGenreIDs.contains(genreID)
        else {
            throw FoundationLibraryError.unavailable
        }
        let ids = songIDs(for: genreID)
        guard startIndex < ids.count else { return .init(items: [], nextStartIndex: nil) }
        let end = startIndex + min(limit, ids.count - startIndex)
        let requested = Array(ids[startIndex..<end])
        let items = try await library.primaryGenreSongs(ids: requested)
        try Task.checkCancellation()
        return .init(items: items, nextStartIndex: end < ids.count ? end : nil)
    }
}
