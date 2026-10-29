import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationPlaylistContentSearchTests: XCTestCase {
    func testContextMatchesOnlySelectedKindsAndActualRelationshipIDs() {
        var track = Self.item("track", kind: .track)
        track.album = .init(id: "album", title: "Unrelated album text")
        track.artist = .init(id: "artist", title: "Unrelated artist text")
        track.genres = [.init(id: "genre", title: "Unrelated genre text")]
        for context in [
            FoundationMusicSearchContext(trackIDs: ["track"]),
            FoundationMusicSearchContext(albumIDs: ["album"]),
            FoundationMusicSearchContext(artistIDs: ["artist"]),
            FoundationMusicSearchContext(genreIDs: ["genre"]),
        ] {
            XCTAssertTrue(context.matches(track: track))
        }
        XCTAssertFalse(FoundationMusicSearchContext(trackIDs: ["artist"]).matches(track: track))
        XCTAssertFalse(FoundationMusicSearchContext(albumIDs: ["track"]).matches(track: track))
        XCTAssertFalse(
            FoundationMusicSearchContext(artistIDs: [track.artist!.title]).matches(track: track))
        XCTAssertFalse(
            FoundationMusicSearchContext(genreIDs: [track.genres[0].title]).matches(track: track))
        XCTAssertFalse(
            FoundationMusicSearchContext(trackIDs: ["track"]).matches(
                track: Self.item("track", kind: .album)))
        let anotherSong = Self.item("other", kind: .track)
        XCTAssertFalse(
            FoundationMusicSearchContext(trackIDs: ["track"]).matches(track: anotherSong))
    }

    func testPlaylistTitleDoesNotInferContentAndCursorAdvancesAcrossUnmatchedCandidates()
        async throws
    {
        let playlist = Self.item("playlist", title: "Selected song", kind: .playlist)
        let harness = PlaylistContentHarness(
            candidates: .init(items: [playlist], nextStartIndex: 13),
            contents: [
                playlist.id: .success(
                    .init(items: [Self.item("different", kind: .track)], nextStartIndex: nil))
            ])
        let result = try await Self.resolve(
            .init(trackIDs: ["selected"]), startIndex: 12, harness: harness)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.nextStartIndex, 13)
        XCTAssertTrue(result.hasIncompleteCoverage)
        let calls = await harness.candidateCalls
        XCTAssertEqual(calls.map(\.offset), [12])
    }

    func testBatchReadsAtMostSixCandidatesAndOnlyFirstTrackPage() async throws {
        let playlists = (0..<6).map { Self.item("playlist-\($0)", kind: .playlist) }
        let tracks = (0..<100).map { Self.item("track-\($0)", kind: .track) }
        let harness = PlaylistContentHarness(
            candidates: .init(items: playlists, nextStartIndex: 6),
            contents: Dictionary(
                uniqueKeysWithValues: playlists.map {
                    ($0.id, .success(.init(items: tracks, nextStartIndex: 100)))
                }))
        let result = try await Self.resolve(.init(trackIDs: ["track-99"]), harness: harness)
        XCTAssertEqual(result.items.map(\.id), playlists.map(\.id))
        XCTAssertEqual(result.nextStartIndex, 6)
        XCTAssertTrue(result.hasIncompleteCoverage)
        let candidateCalls = await harness.candidateCalls
        let trackCalls = await harness.trackCalls
        XCTAssertEqual(candidateCalls.count, 1)
        XCTAssertEqual(candidateCalls.first?.limit, 6)
        XCTAssertEqual(trackCalls, playlists.map(\.id))
    }

    func testLongPlaylistIsIncompleteEvenWhenCandidateListingEnds() async throws {
        let playlist = Self.item("playlist", kind: .playlist)
        let harness = PlaylistContentHarness(
            candidates: .init(items: [playlist], nextStartIndex: nil),
            contents: [
                playlist.id: .success(
                    .init(items: [Self.item("other", kind: .track)], nextStartIndex: 100))
            ])
        let result = try await Self.resolve(.init(trackIDs: ["selected"]), harness: harness)
        XCTAssertTrue(result.hasIncompleteCoverage)
        XCTAssertNil(result.nextStartIndex)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testCompleteShortPlaylistDeduplicatesCandidateReadsAndReturnsOneMatch() async throws {
        let playlist = Self.item("playlist", kind: .playlist)
        let track = Self.item("selected", kind: .track)
        let harness = PlaylistContentHarness(
            candidates: .init(items: [playlist, playlist], nextStartIndex: nil),
            contents: [playlist.id: .success(.init(items: [track, track], nextStartIndex: nil))])
        let result = try await Self.resolve(.init(trackIDs: [track.id]), harness: harness)
        XCTAssertEqual(result.items.map(\.id), [playlist.id])
        XCTAssertFalse(result.hasIncompleteCoverage)
        XCTAssertEqual(result.partialFailureCount, 0)
        let calls = await harness.trackCalls
        XCTAssertEqual(calls, [playlist.id])
    }

    func testIndividualRecoverableFailureRetainsSuccessfulMatchesWithIncompleteCoverage()
        async throws
    {
        for failure in [FoundationLibraryError.network, .unavailable] {
            let first = Self.item("failed", kind: .playlist)
            let second = Self.item("match", kind: .playlist)
            let harness = PlaylistContentHarness(
                candidates: .init(items: [first, second], nextStartIndex: nil),
                contents: [
                    first.id: .failure(failure),
                    second.id: .success(
                        .init(items: [Self.item("selected", kind: .track)], nextStartIndex: nil)),
                ])
            let result = try await Self.resolve(.init(trackIDs: ["selected"]), harness: harness)
            XCTAssertEqual(result.items.map(\.id), [second.id])
            XCTAssertEqual(result.partialFailureCount, 1)
            XCTAssertTrue(result.hasIncompleteCoverage)
        }
    }

    func testAuthenticationAndCancelledErrorsPropagateWithoutReadingNextCandidate() async {
        for failure in [FoundationLibraryError.authentication, .credentials, .cancelled] {
            let first = Self.item("first", kind: .playlist)
            let harness = PlaylistContentHarness(
                candidates: .init(
                    items: [first, Self.item("second", kind: .playlist)], nextStartIndex: nil),
                contents: [first.id: .failure(failure)])
            do {
                _ = try await Self.resolve(.init(trackIDs: ["selected"]), harness: harness)
                XCTFail("Actionable failure must not be published as empty search")
            } catch {
                if failure == .cancelled {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? FoundationLibraryError, failure)
                }
            }
            let calls = await harness.trackCalls
            XCTAssertEqual(calls, [first.id])
        }
    }

    func testCancelledPlaylistListingPropagatesBeforeMembershipReads() async {
        do {
            _ = try await FoundationPlaylistContentSearch.resolve(
                context: .init(trackIDs: ["selected"]), startIndex: 0,
                playlists: { _, _ in throw FoundationLibraryError.cancelled },
                tracks: { _ in
                    XCTFail("Cancelled listing started a membership read")
                    return .init(items: [], nextStartIndex: nil)
                })
            XCTFail("Cancelled listing returned a result")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancelledNoncooperativeMembershipReadCannotPublishOrContinue() async {
        let gate = PlaylistContentGate()
        let task = Task {
            try await FoundationPlaylistContentSearch.resolve(
                context: .init(trackIDs: ["selected"]), startIndex: 0,
                playlists: { _, _ in
                    .init(
                        items: [
                            Self.item("first", kind: .playlist),
                            Self.item("second", kind: .playlist),
                        ], nextStartIndex: nil)
                },
                tracks: { _ in
                    await gate.wait()
                    return .init(items: [Self.item("selected", kind: .track)], nextStartIndex: nil)
                })
        }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancelled membership read returned a result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
    }

    func testEmptyContextDoesNotReadAndInvalidRequestsFailBeforeNetwork() async throws {
        let harness = PlaylistContentHarness(candidates: .init(items: [], nextStartIndex: nil))
        let empty = try await Self.resolve(.init(), harness: harness)
        XCTAssertFalse(empty.hasIncompleteCoverage)
        XCTAssertTrue(empty.items.isEmpty)
        for (context, offset) in [
            (FoundationMusicSearchContext(trackIDs: [""]), 0),
            (FoundationMusicSearchContext(trackIDs: [String(repeating: "x", count: 257)]), 0),
            (FoundationMusicSearchContext(trackIDs: Set((0..<201).map(String.init))), 0),
            (FoundationMusicSearchContext(trackIDs: ["selected"]), -1),
        ] {
            do {
                _ = try await Self.resolve(context, startIndex: offset, harness: harness)
                XCTFail("Invalid request")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        }
        let calls = await harness.candidateCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func testOversizedPagesAndNonadvancingCandidateCursorAreRejected() async {
        for candidates in [
            FoundationPage(
                items: (0..<7).map { Self.item("playlist-\($0)", kind: .playlist) },
                nextStartIndex: nil),
            FoundationPage(items: [Self.item("playlist", kind: .playlist)], nextStartIndex: 0),
        ] {
            let harness = PlaylistContentHarness(candidates: candidates)
            do {
                _ = try await Self.resolve(.init(trackIDs: ["selected"]), harness: harness)
                XCTFail("Invalid candidate response")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
            let calls = await harness.trackCalls
            XCTAssertTrue(calls.isEmpty)
        }
        let playlist = Self.item("playlist", kind: .playlist)
        let harness = PlaylistContentHarness(
            candidates: .init(items: [playlist], nextStartIndex: nil),
            contents: [
                playlist.id: .success(
                    .init(
                        items: (0..<101).map { Self.item("track-\($0)", kind: .track) },
                        nextStartIndex: nil))
            ])
        do {
            _ = try await Self.resolve(.init(trackIDs: ["selected"]), harness: harness)
            XCTFail("Oversized content page")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testSelectedLibraryOmitsSharedArtistGenreIdentitiesWithoutReadingPlaylists() async throws {
        let requests = PlaylistContentRequests()
        let library = Self.library(requests: requests).scoped(to: Self.id(4))
        let result = try await library.playlistsContainingMusic(
            context: .init(artistIDs: [Self.id(3)], genreIDs: [Self.id(5)]), startIndex: 0)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.hasIncompleteCoverage)
        let calls = await requests.values
        XCTAssertTrue(calls.isEmpty)
    }

    func testProviderUsesAccountPlaylistsAndBoundedUserVisibleMusicPages() async throws {
        for scoped in [false, true] {
            let requests = PlaylistContentRequests()
            let original = Self.library(requests: requests)
            let library = scoped ? original.scoped(to: Self.id(4)) : original
            let result = try await library.playlistsContainingMusic(
                context: .init(trackIDs: scoped ? [Self.id(2)] : [], artistIDs: [Self.id(3)]),
                startIndex: 0)
            XCTAssertEqual(result.items.map(\.id), [Self.id(1)])
            XCTAssertEqual(result.hasIncompleteCoverage, scoped)
            let calls = await requests.values
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(Self.query(calls[0], "includeItemTypes"), "Playlist")
            XCTAssertEqual(Self.query(calls[0], "limit"), "6")
            XCTAssertNil(Self.query(calls[0], "parentId"))
            XCTAssertTrue(calls[1].url!.path.hasSuffix("/Items"))
            XCTAssertEqual(Self.query(calls[1], "limit"), "100")
            XCTAssertEqual(Self.query(calls[1], "startIndex"), "0")
            XCTAssertEqual(Self.query(calls[1], "fields"), "Genres")
            XCTAssertTrue(calls.allSatisfy { Self.query($0, "userId") == Self.id(9) })
        }
    }

    func testProviderRejectsMalformedIdentitiesAndUnavailableScopeBeforeNetwork() async {
        let requests = PlaylistContentRequests()
        let original = Self.library(requests: requests)
        do {
            _ = try await original.playlistsContainingMusic(
                context: .init(trackIDs: ["../invalid"]), startIndex: 0)
            XCTFail("Malformed provider identity")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await original.scoped(to: Self.id(4), available: false)
                .playlistsContainingMusic(context: .init(trackIDs: [Self.id(2)]), startIndex: 0)
            XCTFail("Unavailable library")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let calls = await requests.values
        XCTAssertTrue(calls.isEmpty)
    }

    func testTypedContinuationFindsMatchBeyondFirstHundredWithoutReadingNextCandidates()
        async throws
    {
        let playlist = Self.item("long", kind: .playlist)
        let calls = TypedPlaylistCalls()
        let first = try await FoundationPlaylistContentSearch.continueSearch(
            context: .init(trackIDs: ["selected"]),
            cursor: .init(candidateOffset: 0, pending: []),
            playlists: { offset, limit in
                XCTAssertEqual(offset, 0)
                XCTAssertEqual(limit, 6)
                await calls.candidate()
                return .init(items: [playlist], nextStartIndex: 6)
            },
            tracks: { id, offset in
                await calls.track(offset)
                XCTAssertEqual(id, "long")
                XCTAssertEqual(offset, 0)
                return .init(items: [Self.item("other", kind: .track)], nextStartIndex: 100)
            })
        XCTAssertTrue(first.items.isEmpty)
        let cursor = try XCTUnwrap(first.continuation)
        XCTAssertEqual(cursor.pending.first?.trackOffset, 100)
        XCTAssertEqual(cursor.candidateOffset, 6)
        let second = try await FoundationPlaylistContentSearch.continueSearch(
            context: .init(trackIDs: ["selected"]), cursor: cursor,
            playlists: { _, _ in
                XCTFail("Pending page must precede candidate lookup")
                return .init(items: [], nextStartIndex: nil)
            },
            tracks: { _, offset in
                await calls.track(offset)
                XCTAssertEqual(offset, 100)
                return .init(items: [Self.item("selected", kind: .track)], nextStartIndex: 200)
            })
        XCTAssertEqual(second.items.map(\.id), ["long"])
        XCTAssertTrue(second.continuation?.pending.isEmpty == true)
        XCTAssertEqual(second.continuation?.candidateOffset, 6)
        let recorded = await calls.offsets
        XCTAssertEqual(recorded, [0, 100])
        let candidateCount = await calls.candidates
        XCTAssertEqual(candidateCount, 1)
    }

    func testTypedEmptyBatchesAdvanceThenCompleteWithoutAutomaticFollowing() async throws {
        let calls = TypedPlaylistCalls()
        for offset in [0, 6] {
            let result = try await FoundationPlaylistContentSearch.continueSearch(
                context: .init(trackIDs: ["selected"]),
                cursor: .init(candidateOffset: offset, pending: []),
                playlists: { actual, _ in
                    await calls.candidate()
                    XCTAssertEqual(actual, offset)
                    return .init(
                        items: [Self.item("playlist-\(offset)", kind: .playlist)],
                        nextStartIndex: offset == 0 ? 6 : nil)
                },
                tracks: { _, _ in
                    return .init(items: [Self.item("other", kind: .track)], nextStartIndex: nil)
                })
            XCTAssertTrue(result.items.isEmpty)
            XCTAssertEqual(result.continuation?.candidateOffset, offset == 0 ? 6 : nil)
            XCTAssertEqual(result.hasIncompleteCoverage, offset == 0)
        }
        let count = await calls.candidates
        XCTAssertEqual(count, 2)
    }

    func testTypedRecoverableFailureRetainsExactTrackCursorForExplicitRetry() async throws {
        let entry = FoundationPlaylistContentCursor.Pending(
            playlist: Self.item("long", kind: .playlist), trackOffset: 200)
        let result = try await FoundationPlaylistContentSearch.continueSearch(
            context: .init(trackIDs: ["selected"]),
            cursor: .init(candidateOffset: nil, pending: [entry]),
            playlists: { _, _ in
                XCTFail("No candidate read")
                return .init(items: [], nextStartIndex: nil)
            },
            tracks: { _, offset in
                XCTAssertEqual(offset, 200)
                throw FoundationLibraryError.network
            })
        XCTAssertEqual(result.continuation?.pending, [entry])
        XCTAssertEqual(result.partialFailureCount, 1)
        XCTAssertTrue(result.hasIncompleteCoverage)
    }

    @MainActor
    func testLookupOwnerDoesNotReadUntilExplicitLoadAndRejectsOtherAccount() async throws {
        let requests = PlaylistContentRequests()
        let library = Self.library(requests: requests)
        let cursor = FoundationPlaylistContentCursor(candidateOffset: 0, pending: [])
        let seed = FoundationPlaylistContentPage(
            items: [], nextStartIndex: 0,
            hasIncompleteCoverage: true, partialFailureCount: 0, continuation: cursor)
        let model = FoundationPlaylistLookupModel(scope: library.metadataScopeID, seed: seed)
        let initially = await requests.values
        XCTAssertTrue(initially.isEmpty)
        let other = FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://other.invalid")!, accessToken: "synthetic",
                userID: Self.id(9), deviceID: "synthetic"),
            load: { _ in
                XCTFail("Retired owner must not read another account")
                throw FoundationLibraryError.unavailable
            })
        await model.load(context: .init(trackIDs: [Self.id(2)]), library: other)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.cursor, cursor)
        await model.load(context: .init(trackIDs: [Self.id(2)]), library: library)
        XCTAssertEqual(model.items.map(\.id), [Self.id(1)])
        XCTAssertNil(model.cursor)
        XCTAssertFalse(model.incomplete)
        let final = await requests.values
        XCTAssertEqual(final.count, 2)
        await model.load(context: .init(trackIDs: [Self.id(2)]), library: library)
        let afterComplete = await requests.values
        XCTAssertEqual(afterComplete.count, 2)
    }

    @MainActor
    func testLookupCancellationRejectsLateNoncooperativeResultAndKeepsSeed() async {
        let gate = PlaylistContentGate()
        let seedItem = Self.item("seed", kind: .playlist)
        let library = FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: Self.id(9), deviceID: "synthetic"),
            load: { request in
                await gate.wait()
                let data = Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8)
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
        let cursor = FoundationPlaylistContentCursor(candidateOffset: 0, pending: [])
        let model = FoundationPlaylistLookupModel(
            scope: library.metadataScopeID,
            seed: .init(
                items: [seedItem], nextStartIndex: 0, hasIncompleteCoverage: true,
                partialFailureCount: 0, continuation: cursor))
        let task = Task {
            await model.load(context: .init(trackIDs: [Self.id(2)]), library: library)
        }
        while !(await gate.started) { await Task.yield() }
        model.cancel()
        await gate.release()
        await task.value
        XCTAssertEqual(model.items, [seedItem])
        XCTAssertEqual(model.cursor, cursor)
        XCTAssertFalse(model.loading)
    }

    func testTypedContinuationRejectsNonadvancingTrackCursorAndPropagatesCancellation() async {
        let pending = FoundationPlaylistContentCursor.Pending(
            playlist: Self.item("long", kind: .playlist), trackOffset: 100)
        for cancelled in [false, true] {
            do {
                _ = try await FoundationPlaylistContentSearch.continueSearch(
                    context: .init(trackIDs: ["selected"]),
                    cursor: .init(candidateOffset: nil, pending: [pending]),
                    playlists: { _, _ in
                        XCTFail("No listing while pending")
                        return .init(items: [], nextStartIndex: nil)
                    },
                    tracks: { _, _ in
                        if cancelled { throw FoundationLibraryError.cancelled }
                        return .init(items: [Self.item("other", kind: .track)], nextStartIndex: 100)
                    })
                XCTFail("Invalid/cancelled response cannot publish")
            } catch {
                if cancelled {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse)
                }
            }
        }
    }

    func testTypedProviderRejectsMalformedCursorBeforeTransport() async {
        let requests = PlaylistContentRequests()
        let library = Self.library(requests: requests)
        for cursor in [
            FoundationPlaylistContentCursor(candidateOffset: -1, pending: []),
            FoundationPlaylistContentCursor(
                candidateOffset: nil,
                pending: [.init(playlist: Self.item("../bad", kind: .playlist), trackOffset: 0)]),
            FoundationPlaylistContentCursor(
                candidateOffset: nil,
                pending: [.init(playlist: Self.item(Self.id(1), kind: .playlist), trackOffset: -1)]),
            FoundationPlaylistContentCursor(
                candidateOffset: nil,
                pending: (0..<7).map {
                    .init(playlist: Self.item(Self.id($0), kind: .playlist), trackOffset: 0)
                }),
        ] {
            do {
                _ = try await library.playlistsContainingMusic(
                    context: .init(trackIDs: [Self.id(2)]), cursor: cursor)
                XCTFail("Malformed cursor must fail before transport")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        }
        let calls = await requests.values
        XCTAssertTrue(calls.isEmpty)
    }

    @MainActor
    func testLookupSeedCountsTowardExistingRetentionBudget() async {
        let requests = PlaylistContentRequests()
        let library = Self.library(requests: requests)
        var limits = FoundationCatalogBudget()
        limits.maximumItems = 1
        let seedItem = Self.item(Self.id(1), kind: .playlist)
        let model = FoundationPlaylistLookupModel(
            scope: library.metadataScopeID,
            seed: .init(
                items: [seedItem], nextStartIndex: 6, hasIncompleteCoverage: true,
                partialFailureCount: 0), limits: limits)
        await model.load(context: .init(trackIDs: [Self.id(2)]), library: library)
        XCTAssertEqual(model.items, [seedItem])
        XCTAssertEqual(model.error, .invalidResponse)
        let calls = await requests.values
        XCTAssertTrue(calls.isEmpty, "Retained seed already exhausts the configured item budget")
    }

    @MainActor
    func testVisibleSearchAutomaticallyCrossesEmptyAndLongPlaylistPagesToMatch() async {
        let playlist = Self.item("day-drive", kind: .playlist)
        let library = AutomaticPlaylistLibrary { context, cursor in
            XCTAssertEqual(context.trackIDs, ["opalite"])
            if cursor.candidateOffset == 0 {
                return .init(
                    items: [], nextStartIndex: 6, hasIncompleteCoverage: true,
                    partialFailureCount: 0, continuation: .init(candidateOffset: 6, pending: []))
            }
            if cursor.pending.isEmpty {
                return .init(
                    items: [], nextStartIndex: nil, hasIncompleteCoverage: true,
                    partialFailureCount: 0,
                    continuation: .init(
                        candidateOffset: nil,
                        pending: [.init(playlist: playlist, trackOffset: 100)]))
            }
            XCTAssertEqual(cursor.pending.first?.trackOffset, 100)
            return .init(
                items: [playlist], nextStartIndex: nil, hasIncompleteCoverage: false,
                partialFailureCount: 0)
        }
        let model = Self.automaticModel()
        XCTAssertTrue(
            model.showsSearchProgress, "Pending empty results have visible progress before startup")
        await model.searchWhileVisible(context: .init(trackIDs: ["opalite"]), library: library)
        XCTAssertEqual(model.items.map(\.id), ["day-drive"])
        XCTAssertNil(model.cursor)
        XCTAssertFalse(model.searching)
        XCTAssertFalse(model.showsSearchProgress)
        XCTAssertNil(model.error)
        let calls = await library.calls
        XCTAssertEqual(calls, 3)
    }

    @MainActor
    func testVisibleSearchStopsOnFailureOrPartialFailureWithoutAutomaticRetry() async {
        for partial in [false, true] {
            let library = AutomaticPlaylistLibrary { _, cursor in
                if !partial { throw FoundationLibraryError.network }
                return .init(
                    items: [Self.item("found", kind: .playlist)], nextStartIndex: 6,
                    hasIncompleteCoverage: true, partialFailureCount: 1,
                    continuation: .init(candidateOffset: 6, pending: []))
            }
            let model = Self.automaticModel()
            await model.searchWhileVisible(context: .init(trackIDs: ["selected"]), library: library)
            XCTAssertEqual(model.error, .network)
            XCTAssertEqual(model.items.map(\.id), partial ? ["found"] : [])
            await model.searchWhileVisible(context: .init(trackIDs: ["selected"]), library: library)
            let calls = await library.calls
            XCTAssertEqual(calls, 1, "Visibility changes must not retry failed work")
        }
    }

    @MainActor
    func testVisibleSearchStopsAtExistingPageBudgetAndNonadvancingCursor() async {
        for advances in [false, true] {
            let library = AutomaticPlaylistLibrary { _, cursor in
                let next = (cursor.candidateOffset ?? 0) + (advances ? 6 : 0)
                return .init(
                    items: [], nextStartIndex: next, hasIncompleteCoverage: true,
                    partialFailureCount: 0, continuation: .init(candidateOffset: next, pending: []))
            }
            var limits = FoundationCatalogBudget()
            limits.maximumPages = 3
            let model = Self.automaticModel(limits: limits)
            await model.searchWhileVisible(context: .init(trackIDs: ["selected"]), library: library)
            XCTAssertEqual(model.error, .invalidResponse)
            XCTAssertFalse(model.searching)
            let calls = await library.calls
            XCTAssertEqual(calls, advances ? 2 : 1)
        }
    }

    @MainActor
    func testVisibleSearchCancellationRejectsOldQueryAndDoesNotStartNextBatch() async {
        let gate = PlaylistContentGate()
        let library = AutomaticPlaylistLibrary { context, _ in
            if context.trackIDs.contains("old-query") { await gate.wait() }
            return .init(
                items: [Self.item(context.trackIDs.first!, kind: .playlist)],
                nextStartIndex: 6, hasIncompleteCoverage: true, partialFailureCount: 0,
                continuation: .init(candidateOffset: 6, pending: []))
        }
        let old = Self.automaticModel()
        let task = Task {
            await old.searchWhileVisible(context: .init(trackIDs: ["old-query"]), library: library)
        }
        while !(await gate.started) { await Task.yield() }
        // Navigation, query replacement and Offline Mode all invalidate this same owner.
        old.cancel()
        task.cancel()
        await gate.release()
        await task.value
        XCTAssertTrue(old.items.isEmpty)
        XCTAssertEqual(old.cursor?.candidateOffset, 0)
        XCTAssertFalse(old.searching)
        let calls = await library.calls
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testPartialSeedCannotRestartAutomatically() async {
        let library = AutomaticPlaylistLibrary { _, _ in
            XCTFail("Failed seed cannot auto-retry")
            throw FoundationLibraryError.network
        }
        let model = FoundationPlaylistLookupModel(
            scope: "all",
            seed: .init(
                items: [], nextStartIndex: 6, hasIncompleteCoverage: true, partialFailureCount: 1))
        await model.searchWhileVisible(context: .init(trackIDs: ["selected"]), library: library)
        XCTAssertEqual(model.error, .network)
        let calls = await library.calls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    private static func automaticModel(limits: FoundationCatalogBudget = .init())
        -> FoundationPlaylistLookupModel
    {
        FoundationPlaylistLookupModel(
            scope: "all",
            seed: .init(
                items: [], nextStartIndex: 0, hasIncompleteCoverage: true, partialFailureCount: 0),
            limits: limits)
    }

    @MainActor
    func testVisibleClientsHandOverHeldPageInEitherOrderWithoutDuplicateReads() async {
        for registerSuccessorFirst in [false, true] {
            let gate = PlaylistContentGate()
            let library = AutomaticPlaylistLibrary { _, cursor in
                if cursor.candidateOffset == 0 {
                    await gate.wait()
                    return .init(
                        items: [], nextStartIndex: 6, hasIncompleteCoverage: true,
                        partialFailureCount: 0)
                }
                return .init(
                    items: [Self.item("day-drive", kind: .playlist)], nextStartIndex: nil,
                    hasIncompleteCoverage: false, partialFailureCount: 0)
            }
            let model = Self.automaticModel()
            let inline = UUID()
            let full = UUID()
            let context = FoundationMusicSearchContext(trackIDs: ["opalite"])
            let producer = model.registerVisible(inline, context: context, library: library)
            while !(await gate.started) { await Task.yield() }
            if registerSuccessorFirst {
                model.registerVisible(full, context: context, library: library)
                model.releaseVisible(inline)
            } else {
                model.releaseVisible(inline)
                model.registerVisible(full, context: context, library: library)
            }
            await gate.release()
            await producer?.value
            XCTAssertEqual(model.items.map(\.id), ["day-drive"])
            XCTAssertNil(model.cursor)
            XCTAssertNil(model.error)
            let reads = await library.calls
            XCTAssertEqual(reads, 2, "Handover shares the held request, then advances exactly once")
            model.releaseVisible(full)
        }
    }

    @MainActor
    func testLastVisibleClientLeavingCancelsAndRejectsLatePageWithoutContinuation() async {
        let gate = PlaylistContentGate()
        let library = AutomaticPlaylistLibrary { _, _ in
            await gate.wait()
            return .init(
                items: [Self.item("late", kind: .playlist)], nextStartIndex: 6,
                hasIncompleteCoverage: true, partialFailureCount: 0)
        }
        let model = Self.automaticModel()
        let client = UUID()
        let producer = model.registerVisible(
            client, context: .init(trackIDs: ["opalite"]), library: library)
        while !(await gate.started) { await Task.yield() }
        model.releaseVisible(client)
        while model.searching { await Task.yield() }
        await gate.release()
        await producer?.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.cursor?.candidateOffset, 0)
        let reads = await library.calls
        XCTAssertEqual(reads, 1)
    }

    @MainActor
    func testVisibleSearchCanRestartAfterClientLeavesBeforeProducerStarts() async {
        let library = AutomaticPlaylistLibrary { _, _ in
            .init(
                items: [Self.item("day-drive", kind: .playlist)], nextStartIndex: nil,
                hasIncompleteCoverage: false, partialFailureCount: 0)
        }
        let model = Self.automaticModel()
        let context = FoundationMusicSearchContext(trackIDs: ["opalite"])
        let first = UUID()
        let abandoned = model.registerVisible(first, context: context, library: library)
        model.releaseVisible(first)
        await abandoned?.value
        let beforeReentry = await library.calls
        XCTAssertEqual(beforeReentry, 0)
        let second = UUID()
        let restarted = model.registerVisible(second, context: context, library: library)
        await restarted?.value
        XCTAssertEqual(model.items.map(\.id), ["day-drive"])
        XCTAssertNil(model.cursor)
        let afterReentry = await library.calls
        XCTAssertEqual(afterReentry, 1)
        model.releaseVisible(second)
    }

    @MainActor
    func testUpstreamCancellationStopsVisibleProducerQuietlyWithoutAnotherRead() async {
        for categorized in [false, true] {
            let library = AutomaticPlaylistLibrary { _, _ in
                if categorized { throw FoundationLibraryError.cancelled }
                throw CancellationError()
            }
            let model = Self.automaticModel()
            let client = UUID()
            let producer = model.registerVisible(
                client,
                context: .init(trackIDs: ["opalite"]), library: library)
            await producer?.value
            XCTAssertFalse(
                Task.isCancelled, "Provider cancellation does not cancel the caller task")
            XCTAssertNil(model.error)
            XCTAssertFalse(model.searching)
            XCTAssertEqual(model.cursor?.candidateOffset, 0)
            XCTAssertFalse(
                model.showsSearchProgress, "Upstream cancellation must not leave a spinner")
            let reads = await library.calls
            XCTAssertEqual(reads, 1)
            model.releaseVisible(client)
        }
    }

    private static func id(_ suffix: Int) -> String { String(format: "%032x", suffix) }

    private static func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func library(requests: PlaylistContentRequests) -> FoundationJellyfinLibrary {
        FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://example.invalid/")!, accessToken: "synthetic",
                userID: id(9), deviceID: "synthetic"),
            load: { request in
                await requests.append(request)
                let item: [String: Any] =
                    request.url!.path.contains("/Playlists/")
                    ? [
                        "Id": id(2), "Name": "Other title", "Type": "Audio",
                        "AlbumArtists": [["Id": id(3), "Name": "Fixture artist"]],
                    ]
                    : ["Id": id(1), "Name": "Unrelated playlist name", "Type": "Playlist"]
                let body: [String: Any] = ["Items": [item], "TotalRecordCount": 1, "StartIndex": 0]
                return (
                    try JSONSerialization.data(withJSONObject: body),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            })
    }

    private static func item(_ id: String, title: String = "Fixture", kind: FoundationItem.Kind)
        -> FoundationItem
    {
        .init(id: id, title: title, subtitle: "", kind: kind, duration: nil)
    }

    private static func resolve(
        _ context: FoundationMusicSearchContext, startIndex: Int = 0,
        harness: PlaylistContentHarness
    ) async throws -> FoundationPlaylistContentPage {
        try await FoundationPlaylistContentSearch.resolve(
            context: context, startIndex: startIndex,
            playlists: { try await harness.playlists(offset: $0, limit: $1) },
            tracks: { try await harness.tracks(id: $0) })
    }
}

private actor PlaylistContentHarness {
    struct CandidateCall: Sendable {
        let offset: Int
        let limit: Int
    }
    let candidates: FoundationPage
    let contents: [String: Result<FoundationPage, FoundationLibraryError>]
    var candidateCalls: [CandidateCall] = []
    var trackCalls: [String] = []
    init(
        candidates: FoundationPage,
        contents: [String: Result<FoundationPage, FoundationLibraryError>] = [:]
    ) {
        self.candidates = candidates
        self.contents = contents
    }
    func playlists(offset: Int, limit: Int) throws -> FoundationPage {
        candidateCalls.append(.init(offset: offset, limit: limit))
        return candidates
    }
    func tracks(id: String) throws -> FoundationPage {
        trackCalls.append(id)
        return try (contents[id] ?? .success(.init(items: [], nextStartIndex: nil))).get()
    }
}

private actor PlaylistContentGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var started = false
    var calls = 0
    func wait() async {
        calls += 1
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PlaylistContentRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}

private actor TypedPlaylistCalls {
    var candidates = 0
    var offsets: [Int] = []
    func candidate() { candidates += 1 }
    func track(_ offset: Int) { offsets.append(offset) }
}

private actor AutomaticPlaylistLibrary: FoundationLibrary {
    let response:
        @Sendable (FoundationMusicSearchContext, FoundationPlaylistContentCursor) async throws ->
            FoundationPlaylistContentPage
    var calls = 0
    init(
        response:
            @escaping @Sendable (FoundationMusicSearchContext, FoundationPlaylistContentCursor)
            async throws -> FoundationPlaylistContentPage
    ) {
        self.response = response
    }
    func playlistsContainingMusic(
        context: FoundationMusicSearchContext, cursor: FoundationPlaylistContentCursor
    ) async throws -> FoundationPlaylistContentPage {
        calls += 1
        return try await response(context, cursor)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        throw FoundationLibraryError.unavailable
    }
}
