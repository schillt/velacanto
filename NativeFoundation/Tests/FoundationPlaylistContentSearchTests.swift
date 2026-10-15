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
