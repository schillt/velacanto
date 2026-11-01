import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationSearchResolverTests: XCTestCase {
    func testRankingPreservesProviderMatchesAndPrefersNormalizedTitle() {
        let items = [
            Self.item("other", "Unrelated provider match"),
            Self.item("metadata", "Different song", artist: "Café Artist"),
            Self.item("typo", "Cafe Artis"),
            Self.item("prefix", "Cafe Artist Live"),
            Self.item("exact", "CAFÉ ARTIST"),
        ]
        XCTAssertEqual(
            FoundationSearchResolver.ranked(items, query: " cafe artist ").map(\.id),
            ["exact", "prefix", "typo", "metadata", "other"])
        XCTAssertEqual(FoundationSearchResolver.titleScore("Cafe Artis", query: "Cafe Artist"), 60)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Cat", query: "Car"), 0)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Moon Garden", query: "Garden Moon"), 80)
    }

    func testPerWordFuzzyRecoveryUsesThreeCharacterPrefixAndRejectsAmbiguousTypos() async throws {
        XCTAssertEqual(
            FoundationSearchResolver.titleScore("Taylor Swift Live", query: "Taylr Swift"), 60)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Taylor Swift", query: "Taylr Swfit"), 0)
        XCTAssertEqual(FoundationSearchResolver.titleScore("The Cat", query: "The Car"), 0)
        let harness = SearchHarness()
        await harness.install(
            query: "tay", kind: .artist,
            page: .init(
                items: [Self.item("artist", "Taylor Swift", kind: .artist)], nextStartIndex: nil))
        let resolver = FoundationSearchResolver(localSearch: {
            try await harness.search($0, $1, $2)
        })
        let result = try await resolver.resolve(query: "Taylr Swift")
        XCTAssertEqual(result.direct.first { $0.kind == .artist }?.page.items.first?.id, "artist")
        XCTAssertTrue(result.direct.first { $0.kind == .artist }?.includesFuzzyMatches == true)
        let calls = await harness.calls
        XCTAssertEqual(calls.count, 10)
        XCTAssertEqual(Set(calls.map(\.query)), ["Taylr Swift", "tay"])
    }

    func testTypedDirectFailuresDoNotTriggerFallbackRequests() async throws {
        let harness = SearchHarness()
        let resolver = FoundationSearchResolver(search: { query, kind, limit in
            await harness.recordRelation(query + ":" + kind.rawValue + ":" + String(limit))
            if kind == .artist { throw FoundationLibraryError.authentication }
            throw URLError(.notConnectedToInternet)
        })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.direct.first { $0.kind == .artist }?.error, .authentication)
        XCTAssertEqual(result.direct.first { $0.kind == .track }?.error, .network)
        XCTAssertEqual(result.failures.count, 5)
        let calls = await harness.relations
        XCTAssertEqual(calls.count, 5)
    }

    func testFallbackBudgetDedupAndOriginalCursorRemainSeparate() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Gardenx", kind: .track,
            page: .init(items: [Self.item("direct", "Provider choice")], nextStartIndex: 50))
        await harness.install(
            query: "gar", kind: .track,
            page: .init(
                items: [
                    Self.item("fuzzy", "Garden"), Self.item("fuzzy", "Garden"),
                    Self.item("noise", "Garden Party"),
                ], nextStartIndex: 50))
        let resolver = FoundationSearchResolver(search: { try await harness.search($0, $1, $2) })
        let result = try await resolver.resolve(query: "Gardenx")
        let tracks = try XCTUnwrap(result.direct.first { $0.kind == .track })
        XCTAssertEqual(tracks.page.items.map(\.id), ["fuzzy", "direct"])
        XCTAssertEqual(tracks.page.nextStartIndex, 50)
        XCTAssertTrue(tracks.includesFuzzyMatches)
        let calls = await harness.calls
        XCTAssertEqual(calls.count, 10)
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
    }

    func testStrongArtistAndAlbumExpandOnlyOneIdentityWithBoundedRows() async throws {
        let harness = SearchHarness()
        let artist = Self.item("artist-a", "Garden", kind: .artist)
        var album = Self.item("album-a", "Garden", kind: .album)
        album.artist = .init(id: "artist-a", title: "Garden")
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(
                items: [artist, Self.item("artist-b", "Garden Live", kind: .artist)],
                nextStartIndex: nil))
        await harness.install(
            query: "Garden", kind: .album,
            page: .init(
                items: [album, Self.item("album-b", "Garden Live", kind: .album)],
                nextStartIndex: nil))
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistAlbums: { id in
                await harness.recordRelation("albums:" + id)
                return .init(
                    items: (0..<60).map { Self.item("album-\($0)", "Related", kind: .album) },
                    nextStartIndex: 50)
            },
            artistTracks: { id in
                await harness.recordRelation("tracks:" + id)
                return .init(items: [], nextStartIndex: nil)
            },
            artistMostPlayed: { id in
                await harness.recordRelation("most:" + id)
                var low = Self.item("low", "Low")
                low.playCount = 1
                var high = Self.item("high", "High")
                high.playCount = 9
                return .init(items: [low, high, high], nextStartIndex: nil)
            },
            albumTracks: { id in
                await harness.recordRelation("album-tracks:" + id)
                return .init(
                    items: (0..<120).map { Self.item("track-\($0)", "Track") }, nextStartIndex: 100)
            })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.related.first { $0.role == .artistAlbums }?.items.count, 12)
        XCTAssertEqual(
            result.related.first { $0.role == .artistTracks }?.items.map(\.id), ["high", "low"])
        XCTAssertEqual(result.related.first { $0.role == .albumTracks }?.items.count, 20)
        XCTAssertEqual(
            result.related.first { $0.role == .albumArtist }?.items.first?.id, "artist-a")
        let relations = await harness.relations
        XCTAssertEqual(relations, ["albums:artist-a", "most:artist-a", "album-tracks:album-a"])
    }

    func testPartialFailureRetainsDirectMatchesAndArtistTrackFallback() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(items: [Self.item("artist", "Garden", kind: .artist)], nextStartIndex: nil))
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistAlbums: { _ in throw SearchFailure.synthetic },
            artistTracks: { _ in .init(items: [Self.item("track", "Fallback")], nextStartIndex: nil)
            },
            artistMostPlayed: { _ in throw SearchFailure.synthetic })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.direct.first { $0.kind == .artist }?.page.items.first?.id, "artist")
        XCTAssertTrue(result.failures.contains(.artistAlbums))
        XCTAssertTrue(result.failures.contains(.artistMostPlayed))
        XCTAssertEqual(result.related.first { $0.role == .artistTracks }?.items.first?.id, "track")
    }

    func testLocalModeDoesNotInvokeRelationsAndEmptyQueryDoesNotSearch() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(items: [Self.item("artist", "Garden", kind: .artist)], nextStartIndex: nil))
        await harness.install(
            query: "Garden", kind: .playlist,
            page: .init(
                items: [Self.item("playlist", "Garden", kind: .playlist)], nextStartIndex: nil))
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistAlbums: { _ in
                XCTFail("Remote relation in local mode")
                throw SearchFailure.synthetic
            },
            artistTracks: { _ in
                XCTFail("Remote relation in local mode")
                throw SearchFailure.synthetic
            },
            artistMostPlayed: { _ in
                XCTFail("Remote relation in local mode")
                throw SearchFailure.synthetic
            },
            albumTracks: { _ in
                XCTFail("Remote relation in local mode")
                throw SearchFailure.synthetic
            },
            similarItems: { _ in
                XCTFail("Remote discovery in local mode")
                throw SearchFailure.synthetic
            },
            localOnly: true)
        let empty = try await resolver.resolve(query: " \n ")
        XCTAssertTrue(empty.direct.isEmpty)
        let initialCalls = await harness.calls
        XCTAssertTrue(initialCalls.isEmpty)
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertTrue(result.related.isEmpty)
        XCTAssertTrue(result.discovery.isEmpty)
        XCTAssertEqual(result.direct.first { $0.kind == .artist }?.page.items.count, 1)
        XCTAssertEqual(
            result.direct.first { $0.kind == .playlist }?.page.items.first?.id, "playlist")
    }

    func testCancelledTransportCannotReturnResultOrStartNextRequest() async {
        let gate = SearchCancellationGate()
        let resolver = FoundationSearchResolver(search: { _, _, _ in
            await gate.wait()
            return .init(items: [], nextStartIndex: nil)
        })
        let task = Task { try await resolver.resolve(query: "Garden") }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled query published result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await gate.count
        XCTAssertEqual(calls, 1)
    }

    func testDisplayGroupingDeduplicatesRelationshipsWithoutCollapsingCrossKindIDs() {
        let sharedTrack = Self.item("shared", "Garden", kind: .track)
        let sharedArtist = Self.item("shared", "Garden", kind: .artist)
        let sharedAlbum = Self.item("shared", "Garden", kind: .album)
        let direct = [
            Self.direct(
                .track,
                [
                    sharedTrack, Self.item("track-2", "Garden Live"),
                    Self.item("track-3", "Unrelated song"),
                ]),
            Self.direct(
                .artist, [sharedArtist, Self.item("artist-2", "Other artist", kind: .artist)]),
            Self.direct(
                .album, [sharedAlbum, Self.item("album-2", "Garden Session", kind: .album)]),
        ]
        let related = [
            FoundationSearchResolver.RelatedSection(
                role: .artistTracks, source: sharedArtist,
                items: [
                    sharedTrack, Self.item("track-3", "Unrelated song"),
                    Self.item("track-4", "Another song"),
                ]),
            FoundationSearchResolver.RelatedSection(
                role: .albumArtist, source: sharedAlbum, items: [sharedArtist]),
            FoundationSearchResolver.RelatedSection(
                role: .artistAlbums, source: sharedArtist,
                items: [sharedAlbum, Self.item("album-3", "Another album", kind: .album)]),
        ]
        let display = FoundationSearchResolver.displaySections(
            direct: direct, related: related, query: "Garden")
        let top = display.first { $0.role == .top }
        XCTAssertEqual(top?.items.count, 3)
        XCTAssertNil(top?.kind)
        XCTAssertEqual(top?.items.filter { $0.id == "shared" }.count, 3)
        XCTAssertEqual(display.first { $0.role == .relatedSongs }?.items.count, 3)
        XCTAssertEqual(display.first { $0.role == .relatedArtists }?.items.count, 1)
        XCTAssertEqual(display.first { $0.role == .relatedAlbums }?.items.count, 2)
        let identities = display.flatMap(\.items).map { $0.kind.rawValue + ":" + $0.id }
        XCTAssertEqual(identities.count, Set(identities).count)
        XCTAssertEqual(identities.count, 9)
    }

    func testDisplayGroupsRetainAllRowsForCategoryAndPlayCountBreaksRelevanceTies() {
        var popular = Self.item("popular", "Other popular")
        popular.playCount = 50
        let source = Self.item("artist", "Garden", kind: .artist)
        let exact = (0..<8).map { Self.item("exact-\($0)", "Garden") }
        let relatedTracks = (0..<22).map { Self.item("related-\($0)", "Other song \($0)") }
        let display = FoundationSearchResolver.displaySections(
            direct: [
                Self.direct(.track, exact),
                Self.direct(.playlist, [Self.item("playlist", "Other playlist", kind: .playlist)]),
            ],
            related: [.init(role: .artistTracks, source: source, items: relatedTracks + [popular])],
            query: "Garden")
        XCTAssertEqual(display.first { $0.role == .top }?.items.count, 1)
        let songs = display.first { $0.role == .relatedSongs }
        XCTAssertEqual(songs?.kind, .track)
        XCTAssertEqual(songs?.items.count, 30)
        XCTAssertEqual(songs?.items.prefix(7).map(\.title), Array(repeating: "Garden", count: 7))
        XCTAssertEqual(songs?.items.dropFirst(7).first?.id, "popular")
        XCTAssertEqual(display.first { $0.role == .relatedPlaylists }?.items.count, 1)
        XCTAssertFalse(display.contains { $0.role == .relatedArtists || $0.role == .relatedAlbums })
    }

    func testTopHierarchyIncludesBestOfEachTypeAndAllFiveKindsAreSearched() async throws {
        let harness = SearchHarness()
        let kinds: [FoundationItem.Kind] = [.track, .album, .artist, .playlist, .genre]
        for kind in kinds {
            await harness.install(
                query: "Garden", kind: kind,
                page: .init(
                    items: [
                        Self.item(kind.rawValue + "-weak", "Garden Live", kind: kind),
                        Self.item(kind.rawValue, "Garden", kind: kind),
                    ], nextStartIndex: nil))
        }
        let result = try await FoundationSearchResolver(search: {
            try await harness.search($0, $1, $2)
        }).resolve(query: "Garden")
        let display = FoundationSearchResolver.displaySections(
            direct: result.direct, related: result.related, query: "Garden")
        let topKinds: [FoundationItem.Kind] = [.track, .album, .artist]
        XCTAssertEqual(display.first { $0.role == .top }?.items.map(\.kind), topKinds)
        XCTAssertEqual(display.first { $0.role == .top }?.items.map(\.id), topKinds.map(\.rawValue))
        XCTAssertEqual(display.first { $0.role == .relatedGenres }?.items.count, 2)
        XCTAssertEqual(display.first { $0.role == .relatedPlaylists }?.items.count, 2)
        let onlyCollections = FoundationSearchResolver.displaySections(
            direct: [
                Self.direct(.playlist, [Self.item("playlist", "Garden", kind: .playlist)]),
                Self.direct(.genre, [Self.item("genre", "Garden", kind: .genre)]),
            ],
            related: [], query: "Garden")
        XCTAssertFalse(onlyCollections.contains { $0.role == .top })
        XCTAssertEqual(onlyCollections.first { $0.role == .relatedPlaylists }?.items.count, 1)
        XCTAssertEqual(onlyCollections.first { $0.role == .relatedGenres }?.items.count, 1)
        let calls = await harness.calls
        XCTAssertEqual(calls.count, 5)
    }

    func testSparseArtistDiscoveryMatchesKindIsBoundedAndExcludesVisibleMatches() async throws {
        let harness = SearchHarness()
        var artist = Self.item("artist", "Garden", kind: .artist)
        artist.genres = [.init(id: "genre", title: "Synthetic genre")]
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(items: [artist], nextStartIndex: nil))
        let samples = (0..<12).map { Self.item("song-\($0)", "Song \($0)") }
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistMostPlayed: { _ in .init(items: samples, nextStartIndex: nil) },
            similarItems: { source in
                await harness.recordRelation("similar:" + source.id)
                return .init(
                    items: [source, samples[0]]
                        + (0..<15).map {
                            Self.item("related-artist-\($0)", "Artist \($0)", kind: .artist)
                        }, nextStartIndex: 12)
            })
        let result = try await resolver.resolve(query: "Garden")
        let display = FoundationSearchResolver.displaySections(
            direct: result.direct, related: result.related, query: "Garden")
        let visible = Set(
            display.flatMap { $0.items.prefix(5) }.map { $0.kind.rawValue + ":" + $0.id })
        XCTAssertEqual(result.discovery.count, 8)
        XCTAssertTrue(
            result.discovery.allSatisfy { !visible.contains($0.kind.rawValue + ":" + $0.id) })
        XCTAssertEqual(Set(result.discovery.map(\.kind)), [.artist])
        let relations = await harness.relations
        XCTAssertEqual(relations, ["similar:artist"])
    }

    func testDiscoveryDoesNotReadForRichOrEmptyQueriesAndUnavailableIsGraceful() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(
                items: (0..<6).map { Self.item("artist-\($0)", "Garden", kind: .artist) },
                nextStartIndex: nil))
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            similarItems: { _ in
                XCTFail("Rich query must not read similar")
                throw SearchFailure.synthetic
            })
        let rich = try await resolver.resolve(query: "Garden")
        XCTAssertTrue(rich.discovery.isEmpty)
        let empty = try await resolver.resolve(query: "No matches")
        XCTAssertTrue(empty.discovery.isEmpty)
        let unavailable = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .artist ? [Self.item("artist", "Garden", kind: .artist)] : [],
                    nextStartIndex: nil)
            },
            similarItems: { _ in throw FoundationLibraryError.unavailable })
        let sparse = try await unavailable.resolve(query: "Garden")
        XCTAssertTrue(sparse.discovery.isEmpty)
        XCTAssertFalse(sparse.failures.contains(.discovery))
    }

    func testCancellationDuringSimilarReadCannotPublishDiscovery() async {
        let gate = SearchCancellationGate()
        let resolver = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .artist ? [Self.item("artist", "Garden", kind: .artist)] : [],
                    nextStartIndex: nil)
            },
            similarItems: { _ in
                await gate.wait()
                return .init(
                    items: [Self.item("late", "Late album", kind: .album)], nextStartIndex: nil)
            })
        let task = Task { try await resolver.resolve(query: "Garden") }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled discovery published")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDiscoverySkipsDirectFailuresAndReportsRealSimilarFailure() async throws {
        let partial = FoundationSearchResolver(
            search: { _, kind, _ in
                if kind == .track { throw FoundationLibraryError.network }
                return .init(
                    items: kind == .artist ? [Self.item("artist", "Garden", kind: .artist)] : [],
                    nextStartIndex: nil)
            },
            similarItems: { _ in
                XCTFail("Direct failure must suppress discovery")
                throw SearchFailure.synthetic
            })
        let partialResult = try await partial.resolve(query: "Garden")
        XCTAssertTrue(partialResult.discovery.isEmpty)
        let failed = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .artist ? [Self.item("artist", "Garden", kind: .artist)] : [],
                    nextStartIndex: nil)
            },
            similarItems: { _ in throw FoundationLibraryError.network })
        let failedResult = try await failed.resolve(query: "Garden")
        XCTAssertTrue(failedResult.failures.contains(.discovery))
        XCTAssertTrue(failedResult.discovery.isEmpty)
    }

    func testSongDiscoveryUsesRealContextPagesAndNeverRequestsTrackSimilarity() async throws {
        let harness = SearchHarness()
        var source = Self.item("song", "Garden")
        source.album = .init(id: "album", title: "Context album")
        source.artist = .init(id: "artist", title: "Context artist")
        source.genres = [.init(id: "genre", title: "Context genre")]
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [source], nextStartIndex: nil))
        var sameAlbum = Self.item("same-album", "Other song")
        sameAlbum.album = source.album
        sameAlbum.artist = source.artist
        var sameArtist = Self.item("same-artist", "Another song")
        sameArtist.artist = source.artist
        sameArtist.genres = source.genres
        let albumRows = [source, sameAlbum]
        var sameGenre = Self.item("same-genre", "Genre-related song")
        sameGenre.genres = source.genres
        let artistRows = [source, sameGenre, sameArtist]
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistMostPlayed: { id in
                await harness.recordRelation("most:" + id)
                return .init(items: artistRows, nextStartIndex: nil)
            },
            albumTracks: { id in
                await harness.recordRelation("album:" + id)
                return .init(items: albumRows, nextStartIndex: nil)
            },
            similarItems: { _ in
                XCTFail("Track similarity is unsupported")
                throw FoundationLibraryError.unavailable
            })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.discovery.map(\.id), ["same-album", "same-artist", "same-genre"])
        XCTAssertTrue(result.discovery.allSatisfy { $0.kind == .track })
        let calls = await harness.relations
        XCTAssertEqual(calls, ["album:album", "most:artist"])
    }

    func testSongDiscoveryReusesExpandedRelationshipPages() async throws {
        let harness = SearchHarness()
        var song = Self.item("song", "Garden")
        song.artist = .init(id: "artist", title: "Garden")
        song.album = .init(id: "album", title: "Garden")
        let artist = Self.item("artist", "Garden", kind: .artist)
        let album = Self.item("album", "Garden", kind: .album)
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [song], nextStartIndex: nil))
        await harness.install(
            query: "Garden", kind: .artist, page: .init(items: [artist], nextStartIndex: nil))
        await harness.install(
            query: "Garden", kind: .album, page: .init(items: [album], nextStartIndex: nil))
        let tracks = (0..<12).map { Self.item("song-\($0)", "Other song \($0)") }
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistMostPlayed: { id in
                await harness.recordRelation("most:" + id)
                return .init(items: tracks, nextStartIndex: nil)
            },
            albumTracks: { id in
                await harness.recordRelation("album:" + id)
                return .init(items: [], nextStartIndex: nil)
            })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.discovery.count, 7)
        XCTAssertTrue(result.discovery.allSatisfy { $0.kind == .track })
        let calls = await harness.relations
        XCTAssertEqual(calls, ["most:artist", "album:album"])
    }

    func testAlbumDiscoveryFiltersMixedSimilarityToAlbums() async throws {
        let resolver = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .album ? [Self.item("album", "Garden", kind: .album)] : [],
                    nextStartIndex: nil)
            },
            similarItems: { source in
                XCTAssertEqual(source.kind, .album)
                return .init(
                    items: [
                        source, Self.item("artist", "Other artist", kind: .artist),
                        Self.item("song", "Other song"),
                        Self.item("album-2", "Other album", kind: .album),
                    ], nextStartIndex: nil)
            })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.discovery.map(\.id), ["album-2"])
        XCTAssertTrue(result.discovery.allSatisfy { $0.kind == .album })
    }

    func testPlaylistContentsUseSongIdentityWithoutExpandingArtistOrAlbum() async throws {
        var song = Self.item("song", "Garden")
        song.artist = .init(id: "artist", title: "Other artist")
        song.album = .init(id: "album", title: "Other album")
        let source = song
        let resolver = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(items: kind == .track ? [source] : [], nextStartIndex: nil)
            },
            playlistContents: { context, offset in
                XCTAssertEqual(offset, 0)
                XCTAssertEqual(context.trackIDs, ["song"])
                XCTAssertTrue(context.albumIDs.isEmpty)
                XCTAssertTrue(context.artistIDs.isEmpty)
                XCTAssertTrue(context.genreIDs.isEmpty)
                return .init(
                    items: [Self.item("playlist", "Unrelated playlist title", kind: .playlist)],
                    nextStartIndex: 6, hasIncompleteCoverage: true, partialFailureCount: 0)
            })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertEqual(result.playlistContents?.items.map(\.id), ["playlist"])
        XCTAssertEqual(result.playlistContents?.nextStartIndex, 6)
        XCTAssertEqual(result.musicContext.trackIDs, ["song"])
    }

    func testPlaylistContentsContextRetainsMatchedCollectionTrackSamples() {
        let artist = Self.item("artist", "Garden", kind: .artist)
        let unrelatedArtist = Self.item("other", "Other artist", kind: .artist)
        let context = FoundationSearchResolver.musicContext(
            direct: [Self.direct(.artist, [artist])],
            related: [
                .init(role: .artistTracks, source: artist, items: [Self.item("matching", "Song")]),
                .init(
                    role: .artistTracks, source: unrelatedArtist,
                    items: [Self.item("unrelated", "Song")]),
            ], query: "Garden")
        XCTAssertEqual(context.artistIDs, ["artist"])
        XCTAssertEqual(context.trackIDs, ["matching"])
    }

    func testPlaylistContentsPreserveAuthenticationAndPartialFailureOutcomes() async throws {
        let resolver = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .track ? [Self.item("song", "Garden")] : [],
                    nextStartIndex: nil)
            }, playlistContents: { _, _ in throw FoundationLibraryError.authentication })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertNil(result.playlistContents)
        XCTAssertEqual(result.playlistContentError, .authentication)
        XCTAssertTrue(result.failures.contains(.playlistContents))
        let partial = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .track ? [Self.item("song", "Garden")] : [],
                    nextStartIndex: nil)
            },
            playlistContents: { _, _ in
                .init(
                    items: [], nextStartIndex: 6, hasIncompleteCoverage: true,
                    partialFailureCount: 1)
            })
        let partialResult = try await partial.resolve(query: "Garden")
        XCTAssertEqual(partialResult.playlistContents?.partialFailureCount, 1)
        XCTAssertTrue(partialResult.failures.contains(.playlistContents))
    }

    func testPlaylistContentsDoNotReadOfflineOrAfterDirectFailure() async throws {
        let local = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .track ? [Self.item("song", "Garden")] : [],
                    nextStartIndex: nil)
            },
            playlistContents: { _, _ in
                XCTFail("Offline playlist search must not read the server")
                throw FoundationLibraryError.network
            }, localOnly: true)
        let localResult = try await local.resolve(query: "Garden")
        XCTAssertNil(localResult.playlistContents)
        let failed = FoundationSearchResolver(
            search: { _, kind, _ in
                if kind == .artist { throw FoundationLibraryError.authentication }
                return .init(
                    items: kind == .track ? [Self.item("song", "Garden")] : [],
                    nextStartIndex: nil)
            },
            playlistContents: { _, _ in
                XCTFail("Direct failure must suppress playlist content reads")
                throw FoundationLibraryError.network
            })
        let failedResult = try await failed.resolve(query: "Garden")
        XCTAssertNil(failedResult.playlistContents)
    }

    func testCancellationDuringPlaylistContentReadCannotPublishMatches() async {
        let gate = SearchCancellationGate()
        let resolver = FoundationSearchResolver(
            search: { _, kind, _ in
                .init(
                    items: kind == .track ? [Self.item("song", "Garden")] : [],
                    nextStartIndex: nil)
            },
            playlistContents: { _, _ in
                await gate.wait()
                return .init(
                    items: [Self.item("late", "Late playlist", kind: .playlist)],
                    nextStartIndex: nil, hasIncompleteCoverage: false, partialFailureCount: 0)
            })
        let task = Task { try await resolver.resolve(query: "Garden") }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled playlist lookup published")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTrackTitleMatchesExposeTheirAlbumsAndArtistsWithoutNameSearchMatches() async throws {
        var song = Self.item("song", "Garden")
        song.album = .init(id: "album", title: "Different album")
        song.artist = .init(id: "artist", title: "Different artist")
        let source = song
        let resolver = FoundationSearchResolver(search: { _, kind, _ in
            .init(items: kind == .track ? [source, source] : [], nextStartIndex: nil)
        })
        let result = try await resolver.resolve(query: "Garden")
        let display = FoundationSearchResolver.displaySections(
            direct: result.direct, related: result.related, query: "Garden")
        XCTAssertEqual(display.first { $0.role == .top }?.items.map(\.id), ["song"])
        XCTAssertEqual(display.first { $0.role == .relatedAlbums }?.items.map(\.id), ["album"])
        XCTAssertEqual(display.first { $0.role == .relatedArtists }?.items.map(\.id), ["artist"])
        XCTAssertTrue(result.musicContext.albumIDs.isEmpty)
        XCTAssertTrue(result.musicContext.artistIDs.isEmpty)
        XCTAssertEqual(result.musicContext.trackIDs, ["song"])
    }

    private static func direct(_ kind: FoundationItem.Kind, _ items: [FoundationItem])
        -> FoundationSearchResolver.DirectSection
    {
        .init(
            kind: kind, page: .init(items: items, nextStartIndex: nil), includesFuzzyMatches: false,
            error: nil)
    }

    private static func item(
        _ id: String, _ title: String, kind: FoundationItem.Kind = .track,
        artist: String? = nil
    ) -> FoundationItem {
        var value = FoundationItem(id: id, title: title, subtitle: "", kind: kind, duration: nil)
        if let artist { value.artist = .init(id: "related", title: artist) }
        return value
    }
}

private enum SearchFailure: Error { case synthetic }

private actor SearchHarness {
    struct Call: Sendable {
        let query: String
        let kind: FoundationItem.Kind
        let limit: Int
    }
    var calls: [Call] = []
    var relations: [String] = []
    private var pages: [String: FoundationPage] = [:]
    func install(query: String, kind: FoundationItem.Kind, page: FoundationPage) {
        pages[query + ":" + kind.rawValue] = page
    }
    func search(_ query: String, _ kind: FoundationItem.Kind, _ limit: Int) throws -> FoundationPage
    {
        calls.append(.init(query: query, kind: kind, limit: limit))
        return pages[query + ":" + kind.rawValue] ?? .init(items: [], nextStartIndex: nil)
    }
    func recordRelation(_ value: String) { relations.append(value) }
}

private actor SearchCancellationGate {
    var started = false
    var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        count += 1
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
