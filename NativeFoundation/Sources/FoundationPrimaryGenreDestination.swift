import SwiftUI

/// Primary genre membership follows the saved per-song policy, including songs whose
/// album has no matching genre tag. The census order is retained without claiming an
/// atomic live-server order or substituting the provider's raw album-by-genre query.
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
            ).id(record.snapshot.censusID)
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
    let genre: FoundationItem
    let record: FoundationPrimaryGenreRecord
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let songIDs: [String]
    @StateObject private var songs: FoundationBrowseModel
    @State private var content = FoundationPrimaryGenreContent.albums

    init(
        genre: FoundationItem, record: FoundationPrimaryGenreRecord,
        library: any FoundationLibrary, player: FoundationPlayer, isActive: Bool
    ) {
        self.genre = genre
        self.record = record
        self.library = library
        self.player = player
        self.isActive = isActive
        songIDs = record.songIDs(for: genre.id)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        _songs = StateObject(wrappedValue: model)
    }

    private var readySongs: [FoundationItem] {
        record.readySongs(membershipIDs: songIDs, from: downloads.downloadedSongs)
    }

    private var projectedItems: [FoundationItem] {
        content.items(in: songs.items, source: record.snapshot.scope.source)
    }

    var body: some View {
        FoundationCatalogView(
            title: genre.title, model: songs, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true,
            automaticallyLoadsPages: true,
            automaticPageIdentity: content.pageDemandIdentity(for: projectedItems),
            itemProjection: { content.items(in: $0, source: record.snapshot.scope.source) },
            collectionGrid: content != .tracks, emptyMessage: content.emptyMessage,
            genreContentSelection: $content, localItems: { readySongs }
        ) { offset in
            try await record.songPage(genreID: genre.id, startIndex: offset, library: library)
        }
        .id(content)
        .accessibilityIdentifier("primary-genre-songs")
    }
}

/// Collection membership comes from the same canonical songs, not provider album genre tags.
/// A page with repeated/missing references never triggers a hidden search for a new collection.
enum FoundationPrimaryGenreContent: String, CaseIterable, Identifiable {
    case tracks = "Tracks"
    case albums = "Albums"
    case artists = "Artists"

    var id: Self { self }

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
