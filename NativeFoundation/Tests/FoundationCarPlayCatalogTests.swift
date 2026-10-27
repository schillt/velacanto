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

    func testArtistBrowseUsesAlbumsAndUnindexedGenreNeverFallsBackToRawAlbums() async throws {
        let library = CarPlayCatalogLibrary()
        _ = try await FoundationCarPlayCatalog.page(
            route: .artistAlbums(Self.item("artist", kind: .artist)), startIndex: 3,
            library: library, downloads: nil, localOnly: false)
        do {
            _ = try await FoundationCarPlayCatalog.page(
                route: .genre(Self.item("genre", kind: .genre)), startIndex: 4,
                library: library, downloads: nil, localOnly: false)
            XCTFail("Unindexed genre used raw album membership")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let calls = await library.calls
        XCTAssertEqual(calls, ["artistAlbums:artist:3"])
    }

    func testOfflineEntryPointsNeverInvokeProviderAndDoNotInventHistory() async throws {
        let library = CarPlayCatalogLibrary()
        for route in [
            FoundationCarPlayCatalog.Route.playlists, .favorites, .albums, .artists, .songs,
            .downloads,
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
        do {
            _ = try await FoundationCarPlayCatalog.page(
                route: .genres, startIndex: 0, library: library, downloads: nil, localOnly: true)
            XCTFail("Missing offline genre index was presented as a completed empty catalog")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
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
        XCTAssertEqual(result.partialFailure, .unavailable, "The genre index is not built")
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

    func testCompletedGenreCatalogAndSearchContinueBeyondFortyWithoutRawQueries() async throws {
        let library = PrimaryCarPlayLibrary(songCount: 85, genreCount: 85)
        let model = FoundationPrimaryGenresModel(library: library)
        let unbuilt = try await FoundationCarPlayCatalog.search(
            query: "Synthetic Genre", library: library, downloads: nil, localOnly: false,
            primaryGenres: model)
        XCTAssertTrue(unbuilt.items.isEmpty)
        XCTAssertEqual(unbuilt.partialFailure, .unavailable)
        let before = await library.metadataReads
        XCTAssertEqual(before, 0, "CarPlay must never start a census")
        model.start()
        await model.buildCompletion?.value
        XCTAssertNotNil(model.record)
        var browsed: [String] = []
        var searched: [String] = []
        for offset in [0, 40, 80] {
            let page = try await FoundationCarPlayCatalog.page(
                route: .genres, startIndex: offset, library: library, downloads: nil,
                localOnly: false, primaryGenres: model)
            XCTAssertEqual(page.items.count, offset == 80 ? 5 : 40)
            XCTAssertEqual(page.nextStartIndex, offset == 80 ? nil : offset + 40)
            browsed += page.items.map(\.id)
            let search = try await FoundationCarPlayCatalog.search(
                query: "Synthetic Genre", library: library, downloads: nil, localOnly: false,
                primaryGenres: model, startIndex: offset)
            XCTAssertNil(search.partialFailure)
            XCTAssertEqual(search.items.count, offset == 80 ? 5 : 40)
            XCTAssertEqual(search.nextStartIndex, offset == 80 ? nil : offset + 40)
            searched += search.items.map(\.id)
        }
        XCTAssertEqual(browsed, searched)
        XCTAssertEqual(Set(browsed).count, 85)
        let rawQueries = await library.rawGenreReads
        let metadataReads = await library.metadataReads
        XCTAssertEqual(rawQueries, 0)
        XCTAssertEqual(metadataReads, 1)
    }

    func testCanonicalGenreSongsPageInCensusOrderAndColdOfflineUsesOnlyReadyMembers() async throws {
        let library = PrimaryCarPlayLibrary(songCount: 85, genreCount: 1)
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let genre = try XCTUnwrap(model.items(localOnly: false).first)
        for route in [FoundationCarPlayCatalog.Route.genre(genre), .collection(genre)] {
            var ids: [String] = []
            for offset in [0, 40, 80] {
                let page = try await FoundationCarPlayCatalog.page(
                    route: route, startIndex: offset, library: library, downloads: nil,
                    localOnly: false, primaryGenres: model)
                XCTAssertTrue(page.items.allSatisfy { $0.kind == .track })
                XCTAssertEqual(page.nextStartIndex, offset == 80 ? nil : offset + 40)
                ids += page.items.map(\.id)
            }
            XCTAssertEqual(ids, (0..<85).map { "song-\($0)" })
        }
        let requests = await library.songRequests
        XCTAssertEqual(requests.map(\.count), [40, 40, 5, 40, 40, 5])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = FoundationItem(
            id: "song-84", title: "Synthetic standalone", subtitle: "", kind: .track,
            duration: 1, genres: [.init(id: "raw-only", title: "Raw only")])
        let downloads = FoundationDownloads(
            scope: "cp-primary", library: library, root: root,
            transfer: { _, destination, _, progress in
                try Data("synthetic audio".utf8).write(to: destination)
                progress(15, 15)
            }, monitorConnectivity: false)
        defer { downloads.invalidate() }
        model.bindDownloads(downloads)
        downloads.updateConnectivity(isAllowed: true)
        downloads.download(track)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.readySongIDs != [track.id], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.readySongIDs, [track.id])
        let offlineGenres = try await FoundationCarPlayCatalog.page(
            route: .genres, startIndex: 0, library: library, downloads: downloads,
            localOnly: true, primaryGenres: model)
        XCTAssertEqual(offlineGenres.items, [genre], "Offline cannot reclassify raw download tags")
        for route in [FoundationCarPlayCatalog.Route.genre(genre), .collection(genre)] {
            let offline = try await FoundationCarPlayCatalog.page(
                route: route, startIndex: 0, library: library, downloads: downloads,
                localOnly: true, primaryGenres: model)
            XCTAssertEqual(offline.items.map(\.id), [track.id])
            XCTAssertNil(offline.nextStartIndex)
        }
        let after = await library.songRequests
        XCTAssertEqual(after, requests, "Offline genre navigation must not read provider songs")
        let foreignLibrary = PrimaryCarPlayLibrary(songCount: 85, genreCount: 1, libraryID: "other")
        do {
            _ = try await FoundationCarPlayCatalog.page(
                route: .genre(genre), startIndex: 0, library: foreignLibrary,
                downloads: downloads, localOnly: true, primaryGenres: model)
            XCTFail("Canonical membership crossed the selected music library")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
    }

    func testRefreshedCensusRejectsStaleOpenGenreWhilePinsResolveCurrentDescriptor() async throws {
        let library = PrimaryCarPlayLibrary(songCount: 2, genreCount: 1)
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let previous = try XCTUnwrap(model.items(localOnly: false).first)
        model.start()
        await model.buildCompletion?.value
        let current = try XCTUnwrap(model.items(localOnly: false).first)
        XCTAssertNotEqual(previous.primaryGenreCensusID, current.primaryGenreCensusID)
        do {
            _ = try await FoundationCarPlayCatalog.page(
                route: .genre(previous), startIndex: 0, library: library, downloads: nil,
                localOnly: false, primaryGenres: model)
            XCTFail("A stale open route silently adopted a new census")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let saved = Self.item(previous.id, kind: .genre)
        XCTAssertEqual(
            model.resolvePinnedGenre(saved, libraryScope: library.primaryGenreIndexScope), current)
        let page = try await FoundationCarPlayCatalog.page(
            route: .genre(current), startIndex: 0, library: library, downloads: nil,
            localOnly: false, primaryGenres: model)
        XCTAssertEqual(page.items.map(\.id), ["song-0", "song-1"])
        let requests = await library.songRequests
        XCTAssertEqual(requests.count, 1, "The stale route must not issue a provider request")
    }

    func testLateGenreSongAndSearchResultsCannotPublishAfterCensusRefresh() async throws {
        for searching in [false, true] {
            let library = PrimaryCarPlayLibrary(songCount: 2, genreCount: 1)
            let model = FoundationPrimaryGenresModel(library: library)
            model.start()
            await model.buildCompletion?.value
            let genre = try XCTUnwrap(model.items(localOnly: false).first)
            let gate = PrimaryCarPlayGate()
            await library.holdNextRead(gate, searching: searching)
            let pending = Task {
                if searching {
                    _ = try await FoundationCarPlayCatalog.search(
                        query: "Synthetic Genre", library: library, downloads: nil,
                        localOnly: false, primaryGenres: model)
                } else {
                    _ = try await FoundationCarPlayCatalog.page(
                        route: .genre(genre), startIndex: 0, library: library, downloads: nil,
                        localOnly: false, primaryGenres: model)
                }
            }
            await gate.started()
            model.start()
            await model.buildCompletion?.value
            await gate.release()
            do {
                try await pending.value
                XCTFail("A departed census published a late CarPlay result")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        }
    }

    private static func item(_ id: String, kind: FoundationItem.Kind) -> FoundationItem {
        FoundationItem(id: id, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
    }
}

private actor PrimaryCarPlayLibrary: FoundationLibrary {
    nonisolated let primaryGenreIndexScope: FoundationPrimaryGenreIndex.Scope?
    private let songCount: Int
    private let genreCount: Int
    private(set) var metadataReads = 0
    private(set) var rawGenreReads = 0
    private(set) var songRequests: [[String]] = []
    private var songGate: PrimaryCarPlayGate?
    private var searchGate: PrimaryCarPlayGate?

    func holdNextRead(_ gate: PrimaryCarPlayGate, searching: Bool) {
        if searching { searchGate = gate } else { songGate = gate }
    }

    init(songCount: Int, genreCount: Int, libraryID: String = "selected") {
        self.songCount = songCount
        self.genreCount = genreCount
        primaryGenreIndexScope = .init(
            source: try! .jellyfin(scope: String(repeating: "a", count: 64)), libraryID: libraryID)
    }

    func primaryGenreMetadataPage(startIndex: Int) async throws
        -> FoundationPrimaryGenreMetadataPage
    {
        metadataReads += 1
        guard startIndex == 0 else { throw FoundationLibraryError.invalidResponse }
        return .init(
            startIndex: 0, total: songCount,
            songs: (0..<songCount).map {
                let genre = $0 % genreCount
                return .init(
                    id: "song-\($0)",
                    genres: [
                        .init(
                            id: "genre-\(genre)",
                            title: String(format: "Synthetic Genre %03d", genre))
                    ])
            }, nextStartIndex: nil)
    }
    func primaryGenreSongs(ids: [String]) async throws -> [FoundationItem] {
        songRequests.append(ids)
        if let gate = songGate {
            songGate = nil
            await gate.wait()
        }
        return ids.map {
            .init(id: $0, title: "Synthetic standalone", subtitle: "", kind: .track, duration: 1)
        }
    }
    func genres(startIndex: Int) async throws -> FoundationPage {
        rawGenreReads += 1
        throw FoundationLibraryError.unavailable
    }
    func albums(genreID: String, startIndex: Int) async throws -> FoundationPage {
        rawGenreReads += 1
        throw FoundationLibraryError.unavailable
    }
    func search(query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int) async throws
        -> FoundationPage
    {
        if kind == .genre { rawGenreReads += 1 }
        if let gate = searchGate {
            searchGate = nil
            await gate.wait()
        }
        return .init(items: [], nextStartIndex: nil)
    }
    func albums(startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        URL(string: "https://example.invalid/synthetic")!
    }
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        .init(
            request: URLRequest(url: URL(string: "https://example.invalid/synthetic")!),
            fileExtension: "mp3", expectedBytes: nil)
    }
}

private actor PrimaryCarPlayGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false
    func wait() async {
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func started() async {
        if didStart { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
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
