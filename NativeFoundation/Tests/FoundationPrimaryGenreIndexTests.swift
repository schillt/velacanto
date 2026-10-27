import XCTest

@testable import VelacantoFoundation

final class FoundationPrimaryGenreIndexTests: XCTestCase {
    private typealias Index = FoundationPrimaryGenreIndex

    private func scope(_ library: String? = nil) throws -> Index.Scope {
        .init(source: try .jellyfin(scope: String(repeating: "a", count: 64)), libraryID: library)
    }

    private func page(_ sets: [[String]?], start: Int = 0, total: Int? = nil, next: Int? = nil)
        -> Index.Page
    {
        .init(
            startIndex: start, total: total ?? sets.count,
            songs: sets.enumerated().map {
                .init(id: "song-\(start + $0.offset)", genreIDs: $0.element)
            },
            nextStartIndex: next)
    }

    private func snapshot(_ sets: [[String]?]) async throws -> Index.Snapshot {
        let index = Index()
        let generation = try await index.begin(scope: scope())
        try await index.append(page(sets), generation: generation)
        return try await index.finish(generation: generation)
    }

    func testSameMarginalCountsDifferentCooccurrenceProduceDifferentEligibleUnion() async throws {
        let together = try await snapshot([["A", "B", "C"], ["A", "B"], ["A"], []])
        let separate = try await snapshot([["A", "B"], ["A", "B"], ["A"], ["C"]])
        XCTAssertEqual(together.songCountsByGenre, ["A": 3, "B": 2, "C": 1])
        XCTAssertEqual(together.songCountsByGenre, separate.songCountsByGenre)
        XCTAssertEqual(together.eligibleGenreIDs, ["A", "B"])
        XCTAssertEqual(together.primaryBySongID["song-0"], ["A", "B"])
        XCTAssertEqual(together.orderedSongIDs, ["song-0", "song-1", "song-2", "song-3"])
        XCTAssertEqual(separate.primaryBySongID["song-3"], ["C"])
        XCTAssertEqual(together.primaryBySongID["song-3"], [])
        XCTAssertEqual(separate.eligibleGenreIDs, ["A", "B", "C"])
        XCTAssertEqual(separate.primaryGenreIDs(for: ["C"]), ["C"])
    }

    func testPerSongSelectionDeduplicatesCountsAndUsesStableIDTiesWithoutChangingRawInput()
        async throws
    {
        let raw = ["C", "A", "B", "A"]
        let result = try await snapshot([raw, ["C"], ["B"]])
        XCTAssertEqual(result.songCountsByGenre, ["A": 1, "B": 2, "C": 2])
        XCTAssertEqual(result.primaryGenreIDs(for: raw), ["B", "C"])
        XCTAssertEqual(result.primaryGenreIDs(for: Array(raw.reversed())), ["B", "C"])
        XCTAssertEqual(raw, ["C", "A", "B", "A"])
        XCTAssertNil(result.primaryGenreIDs(for: ["unknown", "B", "C"]))
        XCTAssertNil(result.primaryGenreIDs(for: nil))
        XCTAssertEqual(result.primaryGenreIDs(for: []), [])
    }

    func testExplicitUntaggedCatalogIsCompleteButOmittedMetadataIsNot() async throws {
        let empty = try await snapshot([[], []])
        XCTAssertEqual(empty.songCount, 2)
        XCTAssertTrue(empty.eligibleGenreIDs.isEmpty)
        let index = Index()
        let token = try await index.begin(scope: scope())
        do {
            try await index.append(page([nil]), generation: token)
            XCTFail("Omitted genres were counted as an untagged song")
        } catch { XCTAssertEqual(error as? Index.Failure, .unknownMetadata) }
        let absent = await index.snapshot(for: try scope())
        XCTAssertNil(absent)
        do {
            _ = try await index.finish(generation: token)
            XCTFail("Failed metadata was published")
        } catch { XCTAssertEqual(error as? Index.Failure, .stale) }
    }

    func testOnlyContiguousCompleteStableTotalCanPublishAndPreviousSnapshotSurvivesFailure()
        async throws
    {
        let index = Index()
        let first = try await index.begin(scope: scope())
        try await index.append(page([["A"]]), generation: first)
        let accepted = try await index.finish(generation: first)
        let refresh = try await index.begin(scope: scope())
        try await index.append(page([["B"]], total: 2, next: 1), generation: refresh)
        do {
            _ = try await index.finish(generation: refresh)
            XCTFail("Partial census was published")
        } catch { XCTAssertEqual(error as? Index.Failure, .incomplete) }
        do {
            try await index.append(page([["C"]], start: 1, total: 3, next: 2), generation: refresh)
            XCTFail("Catalog changed during the census")
        } catch { XCTAssertEqual(error as? Index.Failure, .invalidPage) }
        let retained = await index.snapshot(for: try scope())
        XCTAssertEqual(retained, accepted)
    }

    func testTwoPagesPublishExactWholeScopeAndEmptyCatalogIsSupported() async throws {
        let index = Index()
        let token = try await index.begin(scope: scope())
        try await index.append(page([["A", "B", "C"]], total: 3, next: 1), generation: token)
        try await index.append(page([["B"], ["C"]], start: 1, total: 3), generation: token)
        let result = try await index.finish(generation: token)
        XCTAssertEqual(result.songCount, 3)
        XCTAssertEqual(result.eligibleGenreIDs, ["B", "C"])
        let empty = try await snapshot([])
        XCTAssertEqual(empty.songCount, 0)
        XCTAssertTrue(empty.songCountsByGenre.isEmpty)
    }

    func testDuplicateSongAndResourceLimitDoNotProducePartialSnapshot() async throws {
        let index = Index()
        let token = try await index.begin(scope: scope())
        let duplicate = Index.Song(id: "same", genreIDs: ["A"])
        do {
            try await index.append(
                .init(startIndex: 0, total: 2, songs: [duplicate, duplicate], nextStartIndex: nil),
                generation: token)
            XCTFail("Duplicate song inflated frequencies")
        } catch { XCTAssertEqual(error as? Index.Failure, .duplicateSong) }
        var limits = Index.Limits()
        limits.genres = 1
        let bounded = Index(limits: limits)
        let boundedToken = try await bounded.begin(scope: scope())
        do {
            try await bounded.append(page([["A", "B"]]), generation: boundedToken)
            XCTFail("Resource limit silently truncated genre metadata")
        } catch { XCTAssertEqual(error as? Index.Failure, .resourceLimit) }
        let absent = await bounded.snapshot(for: try scope())
        XCTAssertNil(absent)
    }

    func testCancelledRefreshRetainsCompleteSnapshotAndCannotPublish() async throws {
        let index = Index()
        let first = try await index.begin(scope: scope())
        try await index.append(page([["A"]]), generation: first)
        let accepted = try await index.finish(generation: first)
        let refresh = try await index.begin(scope: scope())
        try await index.append(page([["B"]], total: 2, next: 1), generation: refresh)
        await index.cancel(generation: refresh)
        do {
            try await index.append(page([["C"]], start: 1, total: 2), generation: refresh)
            XCTFail("Cancelled generation accepted late metadata")
        } catch { XCTAssertEqual(error as? Index.Failure, .stale) }
        let retained = await index.snapshot(for: try scope())
        XCTAssertEqual(retained, accepted)
        let encoded = try PropertyListEncoder().encode(accepted)
        let decoded = try PropertyListDecoder().decode(Index.Snapshot.self, from: encoded)
        XCTAssertEqual(decoded, accepted)
    }

    func testTaskCancellationInvalidatesCandidateWithoutReplacingCompleteSnapshot() async throws {
        let index = Index()
        let first = try await index.begin(scope: scope())
        try await index.append(page([["A"]]), generation: first)
        let accepted = try await index.finish(generation: first)
        let refresh = try await index.begin(scope: scope())
        let incoming = page([["B"]])
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await index.append(incoming, generation: refresh)
                return false
            } catch { return error is CancellationError }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        let retained = await index.snapshot(for: try scope())
        XCTAssertEqual(retained, accepted)
        do {
            _ = try await index.finish(generation: refresh)
            XCTFail("Cancelled task left a publishable candidate")
        } catch { XCTAssertEqual(error as? Index.Failure, .stale) }
    }

    func testScopeSwitchAndRetirementRejectLateResultsAndStaleCancellation() async throws {
        let index = Index()
        let first = try await index.begin(scope: scope("first"))
        let second = try await index.begin(scope: scope("second"))
        await index.cancel(generation: first)
        do {
            try await index.append(page([["A"]]), generation: first)
            XCTFail("Late page crossed scope")
        } catch { XCTAssertEqual(error as? Index.Failure, .stale) }
        try await index.append(page([["B"]]), generation: second)
        let current = try await index.finish(generation: second)
        let wrongScope = await index.snapshot(for: try scope("first"))
        XCTAssertNil(wrongScope)
        XCTAssertEqual(current.scope, try scope("second"))
        await index.retire()
        let retired = await index.snapshot(for: try scope("second"))
        XCTAssertNil(retired)
        do {
            _ = try await index.begin(scope: scope("second"))
            XCTFail("Retired account lifetime restarted")
        } catch { XCTAssertEqual(error as? Index.Failure, .stale) }
    }
}
