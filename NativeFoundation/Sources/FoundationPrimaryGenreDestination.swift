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
            FoundationPrimaryGenreSongs(
                genre: genre, record: record, library: library, player: player, isActive: isActive
            ).id(record.snapshot.censusID)
        } else {
            ContentUnavailableView(
                "Primary genre index unavailable", systemImage: "music.note.list",
                description: Text(
                    "Return to Genres and select it again, or build or refresh the index for this music library."
                ))
        }
    }
}

private struct FoundationPrimaryGenreSongs: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    let genre: FoundationItem
    let record: FoundationPrimaryGenreRecord
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let songIDs: [String]
    @StateObject private var songs: FoundationBrowseModel

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

    var body: some View {
        FoundationCatalogView(
            title: genre.title, model: songs, library: library, player: player,
            isActive: isActive, showsTrackArtwork: true,
            coverageMessage:
                "Refresh primary genres if songs have changed on your server.",
            localItems: { readySongs }
        ) { offset in
            try await record.songPage(genreID: genre.id, startIndex: offset, library: library)
        }
        .accessibilityIdentifier("primary-genre-songs")
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
