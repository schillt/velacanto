import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationOfflineCatalogProjectionTests: XCTestCase {
    private func item(
        _ id: String, title: String = "Song", subtitle: String = "",
        kind: FoundationItem.Kind = .track
    ) -> FoundationItem {
        FoundationItem(
            id: id, title: title, subtitle: subtitle, kind: kind, duration: nil)
    }

    func testUniqueSongsKeepFirstMetadataWithoutChangingOccurrenceInputs() {
        let first = item("shared", title: "First copy")
        let later = item("shared", title: "Later copy")
        let next = item("next")
        let occurrences = [first, later, first, next]
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.uniqueSongs(occurrences), [first, next])
        XCTAssertEqual(occurrences, [first, later, first, next])
    }

    func testExpandedContainersRetainOrderAndMetadataBeforeRememberedSeeds() {
        let expanded = item("shared", title: "Expanded", kind: .playlist)
        let remembered = item("shared", title: "Remembered", kind: .playlist)
        let other = item("other", title: "Other", kind: .playlist)
        let result = FoundationOfflineCatalogProjection.containers(
            expanded: [expanded, expanded], remembered: [remembered, other, other])
        XCTAssertEqual(result, [expanded, expanded, other])
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.containers(expanded: [expanded], remembered: []),
            [expanded])
    }

    func testDerivedAlbumAndArtistMetadataPreserveSeedAndSongPrecedence() {
        var seed = item("album", title: "Saved album", kind: .album)
        seed.primaryImageTag = "saved-art"
        seed.artist = .init(id: "seed-artist", title: "Saved artist", primaryImageTag: "seed-art")
        var song = item("song", subtitle: "Song subtitle")
        song.album = .init(id: "album", title: "Song album", primaryImageTag: "other-art")
        song.artist = .init(id: "song-artist", title: "Song artist", primaryImageTag: "song-art")
        var second = item("second", subtitle: "Second subtitle")
        second.album = .init(id: "derived", title: "Derived album", primaryImageTag: "derived-art")
        second.artist = song.artist
        let songs = [song, second]
        let albums = FoundationOfflineCatalogProjection.albums(seeds: [seed], songs: songs)
        XCTAssertEqual(albums.map(\.id), ["album", "derived"])
        XCTAssertEqual(albums[0], seed)
        XCTAssertEqual(albums[1].title, "Derived album")
        XCTAssertEqual(albums[1].subtitle, "Second subtitle")
        XCTAssertEqual(albums[1].primaryImageTag, "derived-art")
        XCTAssertEqual(albums[1].artist, second.artist)
        let artists = FoundationOfflineCatalogProjection.artists(songs: songs, albums: albums)
        XCTAssertEqual(artists.map(\.id), ["song-artist", "seed-artist"])
        XCTAssertEqual(artists.map(\.primaryImageTag), ["song-art", "seed-art"])
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.albums(
                artistID: "song-artist", songs: songs, albums: albums), albums)
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.albums(
                artistID: "seed-artist", songs: songs, albums: albums), [seed])
        XCTAssertEqual(songs, [song, second])
    }

    func testCatalogKeepsKindIdentityFirstMetadataAndCandidateOrder() {
        let song = item("shared", title: "First song")
        let duplicate = item("shared", title: "Later song")
        let album = item("shared", title: "Album", kind: .album)
        let playlist = item("shared", title: "Playlist", kind: .playlist)
        let containers = [album, playlist, album]
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.catalogItems(
                songs: [song, duplicate], availableContainers: containers, kind: nil),
            [song, album, playlist])
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.catalogItems(
                songs: [song], availableContainers: containers, kind: .playlist), [playlist])
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.catalogItems(
                songs: [], availableContainers: [], kind: nil), [])
        XCTAssertEqual(containers, [album, playlist, album])
    }

    func testSearchMatchesEveryExistingFieldAndUsesKindIdentityForTitleTies() {
        let byTitle = item("title", title: "Needle title")
        let bySubtitle = item("subtitle", title: "A", subtitle: "Needle subtitle")
        var byAlbum = item("album-field", title: "B")
        byAlbum.album = .init(id: "album", title: "Needle album")
        var byArtist = item("artist-field", title: "C")
        byArtist.artist = .init(id: "artist", title: "Needle artist")
        let unrelated = item("unrelated", title: "Other")
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.searchItems(
                matching: "NEEDLE", in: [byArtist, unrelated, byTitle, byAlbum, bySubtitle]),
            [bySubtitle, byAlbum, byArtist, byTitle])
        let track = item("same", title: "Tie")
        let album = item("same", title: "Tie", kind: .album)
        let artist = item("same", title: "Tie", kind: .artist)
        let playlist = item("same", title: "Tie", kind: .playlist)
        XCTAssertEqual(
            FoundationOfflineCatalogProjection.searchItems(
                matching: "tie", in: [track, playlist, artist, album]),
            [album, artist, playlist, track])
    }

    func testPagingClampsExtremesWithoutLosingCursorOrOverflowing() {
        let songs = [item("first"), item("second"), item("third")]
        let first = FoundationOfflineCatalogProjection.page(
            of: songs, startIndex: Int.min, limit: 0)
        XCTAssertEqual(first.items, [songs[0]])
        XCTAssertEqual(first.nextStartIndex, 1)
        let remaining = FoundationOfflineCatalogProjection.page(
            of: songs, startIndex: 1, limit: Int.max)
        XCTAssertEqual(remaining.items, Array(songs[1...]))
        XCTAssertNil(remaining.nextStartIndex)
        let pastEnd = FoundationOfflineCatalogProjection.page(
            of: songs, startIndex: Int.max, limit: Int.max)
        XCTAssertTrue(pastEnd.items.isEmpty)
        XCTAssertNil(pastEnd.nextStartIndex)
        let empty = FoundationOfflineCatalogProjection.page(
            of: [], startIndex: 0, limit: -1)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.nextStartIndex)
        let many = (0..<10_001).map { item(String($0)) }
        let bounded = FoundationOfflineCatalogProjection.page(
            of: many, startIndex: 0, limit: Int.max)
        XCTAssertEqual(bounded.items.count, 10_000)
        XCTAssertEqual(bounded.nextStartIndex, 10_000)
    }
}
