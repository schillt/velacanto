import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCarPlayCatalogTests: XCTestCase {
    func testClippedProviderPageContinuesAtFirstOmittedOffset() async throws {
        let library = CarPlayCatalogLibrary()
        let page = try await FoundationCarPlayCatalog.page(
            route: .songs, startIndex: 12, library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(page.items.count, 40)
        XCTAssertEqual(page.items.first?.id, "song-12")
        XCTAssertEqual(page.items.last?.id, "song-51")
        XCTAssertEqual(page.nextStartIndex, 52)
        let calls = await library.calls
        XCTAssertEqual(calls, ["songs:12"])
    }

    func testCollectionRoutesPreserveProviderIdentityOrderAndDuplicateTracks() async throws {
        let library = CarPlayCatalogLibrary()
        for kind in [FoundationItem.Kind.album, .artist, .playlist] {
            let collection = Self.item("collection", kind: kind)
            let page = try await FoundationCarPlayCatalog.page(
                route: .collection(collection), startIndex: 7, library: library,
                downloads: nil, localOnly: false)
            XCTAssertEqual(page.items.map(\.id), ["duplicate", "duplicate"])
            XCTAssertEqual(page.nextStartIndex, 9)
        }
        let calls = await library.calls
        XCTAssertEqual(
            calls, ["album:collection:7", "artistTracks:collection:7", "playlist:collection:7"])
    }

    func testArtistAndGenreBrowseRoutesUseAlbums() async throws {
        let library = CarPlayCatalogLibrary()
        _ = try await FoundationCarPlayCatalog.page(
            route: .artistAlbums(Self.item("artist", kind: .artist)), startIndex: 3,
            library: library, downloads: nil, localOnly: false)
        _ = try await FoundationCarPlayCatalog.page(
            route: .genre(Self.item("genre", kind: .genre)), startIndex: 4,
            library: library, downloads: nil, localOnly: false)
        let calls = await library.calls
        XCTAssertEqual(calls, ["artistAlbums:artist:3", "genre:genre:4"])
    }

    func testOfflineEntryPointsNeverInvokeProviderAndDoNotInventHistory() async throws {
        let library = CarPlayCatalogLibrary()
        for route in [
            FoundationCarPlayCatalog.Route.playlists, .favorites, .albums, .artists, .songs,
            .genres, .downloads,
        ] {
            let page = try await FoundationCarPlayCatalog.page(
                route: route, startIndex: 0, library: library, downloads: nil, localOnly: true)
            XCTAssertTrue(page.items.isEmpty)
            XCTAssertNil(page.nextStartIndex)
        }
        let snapshot = try await FoundationCarPlayCatalog.snapshot(
            library: library, downloads: nil, localOnly: true)
        let matches = try await FoundationCarPlayCatalog.resolve(
            query: "Synthetic", library: library, downloads: nil, localOnly: true)
        XCTAssertTrue(matches.isEmpty)
        XCTAssertTrue(snapshot.recentlyPlayed.isEmpty)
        XCTAssertTrue(snapshot.recentMusic.isEmpty)
        XCTAssertTrue(snapshot.mostPlayedAlbums.isEmpty)
        XCTAssertEqual(snapshot.errors.count, 3)
        XCTAssertTrue(snapshot.favorites.isEmpty)
        XCTAssertNil(snapshot.errors[.favorites])
        let calls = await library.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testShelfFailurePreservesIndependentRankingAndDoesNotWalkPages() async throws {
        let library = CarPlayCatalogLibrary()
        let snapshot = try await FoundationCarPlayCatalog.snapshot(
            library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(snapshot.errors[.recentMusic], .network)
        XCTAssertEqual(snapshot.recentlyPlayed.map(\.id), ["history"])
        XCTAssertEqual(snapshot.mostPlayedAlbums.map(\.id), ["ranked-b", "ranked-a"])
        let calls = await library.calls
        XCTAssertEqual(calls, ["history:0", "recentMusic", "ranking", "favorites:0"])
    }

    func testSnapshotFavoritesAreBoundedAndRemainIndependentOfOtherShelfFailures() async throws {
        let library = CarPlayCatalogLibrary()
        let snapshot = try await FoundationCarPlayCatalog.snapshot(
            library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(snapshot.favorites.count, 12)
        XCTAssertEqual(snapshot.favorites.first?.id, "favorite-0")
        XCTAssertEqual(snapshot.favorites.last?.id, "favorite-11")
        XCTAssertNil(snapshot.errors[.favorites])
        XCTAssertEqual(snapshot.errors[.recentMusic], .network)
        let calls = await library.calls
        XCTAssertEqual(calls.filter { $0.hasPrefix("favorites:") }, ["favorites:0"])
    }

    func testFavoriteSnapshotFailureDoesNotEraseOtherShelves() async throws {
        let library = CarPlayCatalogLibrary()
        await library.failFavorites()
        let snapshot = try await FoundationCarPlayCatalog.snapshot(
            library: library, downloads: nil, localOnly: false)
        XCTAssertTrue(snapshot.favorites.isEmpty)
        XCTAssertEqual(snapshot.errors[.favorites], .authentication)
        XCTAssertEqual(snapshot.recentlyPlayed.map(\.id), ["history"])
        XCTAssertEqual(snapshot.mostPlayedAlbums.map(\.id), ["ranked-b", "ranked-a"])
    }

    func testCancelledRequestDoesNotReadCatalog() async throws {
        let library = CarPlayCatalogLibrary()
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await FoundationCarPlayCatalog.page(
                route: .songs, startIndex: 0, library: library, downloads: nil, localOnly: false)
        }
        do {
            _ = try await request.value
            XCTFail("Cancelled request succeeded")
        } catch is CancellationError {}
        let calls = await library.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testRelationshipFailureKeepsSuccessfulDirectMatchesAndReportsPartialStatus() async throws {
        let library = CarPlaySearchLibrary(mode: .relationshipFailure)
        let result = try await FoundationCarPlayCatalog.search(
            query: "Synthetic", library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(Set(result.items.map { $0.kind.rawValue }), Set(["track", "album"]))
        XCTAssertEqual(result.items.map(\.id), ["match", "match"])
        XCTAssertNotNil(result.partialFailure)
    }

    func testPlaylistContentMatchesAppearOnceAlongsideDirectSearchResults() async throws {
        let library = CarPlaySearchLibrary(mode: .playlistMatches)
        let result = try await FoundationCarPlayCatalog.search(
            query: "Synthetic", library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(Set(result.items.map(\.id)), Set(["match", "related-playlist"]))
        XCTAssertEqual(result.items.first { $0.id == "related-playlist" }?.kind, .playlist)
        XCTAssertNil(result.partialFailure)
        let calls = await library.contentCalls
        XCTAssertEqual(calls, 1)
    }

    func testExactPlaylistSurvivesFortyRowCapAndDuplicateIdentityIsRemoved() async throws {
        let library = CarPlaySearchLibrary(mode: .manyWeakerMatches)
        let result = try await FoundationCarPlayCatalog.search(
            query: "Synthetic", library: library, downloads: nil, localOnly: false)
        XCTAssertEqual(result.items.count, 40)
        XCTAssertEqual(result.items.first?.id, "exact-playlist")
        XCTAssertEqual(result.items.first?.kind, .playlist)
        XCTAssertEqual(result.items.filter { $0.id == "exact-playlist" }.count, 1)
        XCTAssertEqual(Set(result.items.map { $0.kind.rawValue + ":" + $0.id }).count, 40)
    }

    func testProviderSearchCancellationPropagatesInsteadOfReturningPartialSuccess() async throws {
        let library = CarPlaySearchLibrary(mode: .cancelled)
        do {
            _ = try await FoundationCarPlayCatalog.search(
                query: "Synthetic", library: library, downloads: nil, localOnly: false)
            XCTFail("Provider cancellation returned a search snapshot")
        } catch is CancellationError {}
        let calls = await library.searchCalls
        XCTAssertEqual(calls, 1)
    }

    private static func item(_ id: String, kind: FoundationItem.Kind) -> FoundationItem {
        FoundationItem(id: id, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
    }
}

private actor CarPlayCatalogLibrary: FoundationLibrary {
    private(set) var calls: [String] = []
    private var favoritesFailed = false
    func failFavorites() { favoritesFailed = true }
    func favorites(startIndex: Int) async throws -> FoundationPage {
        if favoritesFailed {
            calls.append("favorites:\(startIndex)")
            throw FoundationLibraryError.authentication
        }
        return page(
            "favorites:\(startIndex)", items: (0..<20).map { item("favorite-\($0)", kind: .album) },
            next: 20)
    }
    private func page(_ call: String, items: [FoundationItem] = [], next: Int? = nil)
        -> FoundationPage
    {
        calls.append(call)
        return .init(items: items, nextStartIndex: next)
    }
    private func item(_ id: String, kind: FoundationItem.Kind = .track) -> FoundationItem {
        .init(id: id, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
    }
    func albums(startIndex: Int) async throws -> FoundationPage { page("albums:\(startIndex)") }
    func songs(startIndex: Int) async throws -> FoundationPage {
        page(
            "songs:\(startIndex)",
            items: (startIndex..<(startIndex + 80)).map { item("song-\($0)") },
            next: startIndex + 80)
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        page(
            "album:\(albumID):\(startIndex)", items: [item("duplicate"), item("duplicate")],
            next: startIndex + 2)
    }
    func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage {
        page(
            "artistTracks:\(artistID):\(startIndex)",
            items: [item("duplicate"), item("duplicate")], next: startIndex + 2)
    }
    func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage {
        page(
            "playlist:\(playlistID):\(startIndex)", items: [item("duplicate"), item("duplicate")],
            next: startIndex + 2)
    }
    func albums(artistID: String, startIndex: Int) async throws -> FoundationPage {
        page("artistAlbums:\(artistID):\(startIndex)")
    }
    func albums(genreID: String, startIndex: Int) async throws -> FoundationPage {
        page("genre:\(genreID):\(startIndex)")
    }
    func recentlyPlayed(startIndex: Int) async throws -> FoundationPage {
        page("history:\(startIndex)", items: [item("history")], next: 1)
    }
    func recentMusicSuggestions() async throws -> FoundationPage {
        calls.append("recentMusic")
        throw FoundationLibraryError.network
    }
    func mostPlayedAlbums() async throws -> FoundationPage {
        page("ranking", items: [item("ranked-b", kind: .album), item("ranked-a", kind: .album)])
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        throw FoundationLibraryError.unavailable
    }
}

private actor CarPlaySearchLibrary: FoundationLibrary {
    enum Mode: Sendable { case relationshipFailure, playlistMatches, cancelled, manyWeakerMatches }
    private let mode: Mode
    private(set) var contentCalls = 0
    private(set) var searchCalls = 0

    init(mode: Mode) { self.mode = mode }

    private func item(_ id: String, kind: FoundationItem.Kind) -> FoundationItem {
        .init(id: id, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
    }

    func search(query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int) async throws
        -> FoundationPage
    {
        searchCalls += 1
        if mode == .cancelled { throw CancellationError() }
        if mode == .manyWeakerMatches {
            if kind == .track {
                return .init(
                    items: (0..<50).map {
                        FoundationItem(
                            id: "weaker-\($0)", title: "Synthetic music \($0)", subtitle: "",
                            kind: .track, duration: nil)
                    }, nextStartIndex: 50)
            }
            if kind == .playlist {
                let exact = item("exact-playlist", kind: .playlist)
                return .init(items: [exact, exact], nextStartIndex: nil)
            }
        }
        let matches = kind == .track || (mode == .relationshipFailure && kind == .album)
        return .init(items: matches ? [item("match", kind: kind)] : [], nextStartIndex: nil)
    }

    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.network
    }
    func albums(startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func playlistsContainingMusic(context: FoundationMusicSearchContext, startIndex: Int)
        async throws -> FoundationPlaylistContentPage
    {
        contentCalls += 1
        let playlist = item("related-playlist", kind: .playlist)
        return .init(
            items: mode == .playlistMatches ? [playlist, playlist] : [], nextStartIndex: nil,
            hasIncompleteCoverage: false, partialFailureCount: 0)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        throw FoundationLibraryError.unavailable
    }
}
