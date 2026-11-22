import Foundation
import SwiftUI
import XCTest

@testable import VelacantoFoundation

/// Observes the captured production task, including bounded failure cleanup.
/// Cancellation cannot force arbitrary production work to terminate.
@MainActor
private func requireSearchTask<Success: Sendable, Failure: Error>(
    _ task: Task<Success, Failure>, context: String,
    stopOnCancellation: Bool = true, cleanup: @MainActor () async -> Void
) async -> Bool {
    var returnedAt: ContinuousClock.Instant?
    let observer = Task {
        _ = await task.result
        returnedAt = .now
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while returnedAt == nil, ContinuousClock.now < deadline,
        !stopOnCancellation || !Task.isCancelled
    {
        await Task.yield()
    }
    if let returnedAt, returnedAt <= deadline, !stopOnCancellation || !Task.isCancelled {
        return true
    }
    task.cancel()
    await cleanup()
    let cleanupDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while returnedAt == nil, ContinuousClock.now < cleanupDeadline { await Task.yield() }
    observer.cancel()
    XCTFail("Timed out or cancelled waiting for \(context)")
    if !(returnedAt.map { $0 <= cleanupDeadline } ?? false) {
        XCTFail("Captured task did not return during cleanup: \(context)")
    }
    return false
}

final class FoundationSearchResolverTests: XCTestCase {
    @MainActor
    func testDirectProgressPublishesBeforeHeldLaterCategoryWithOriginalCursor() async throws {
        let gate = SearchCancellationGate()
        let harness = SearchHarness()
        let first = Self.item("first", "Garden")
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [first], nextStartIndex: 50))
        let resolver = FoundationSearchResolver(search: { query, kind, limit in
            if kind == .album { await gate.wait() }
            return try await harness.search(query, kind, limit)
        })
        var snapshots: [FoundationSearchResolver.DirectResolution] = []
        let entered = expectation(description: "later category held after first direct publication")
        await gate.acknowledgeEntry(entered)
        let task = Task {
            try await resolver.resolve(
                query: "Garden", onDirectSection: { snapshots.append($0) })
        }
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else {
            XCTFail("Later category did not enter its bounded hold")
            task.cancel()
            await gate.close()
            _ = await requireSearchTask(
                task, context: "direct progress entry cleanup", stopOnCancellation: false,
                cleanup: { await gate.close() })
            return
        }
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.section.kind, .track)
        XCTAssertEqual(snapshots.first?.section.page.items.map(\.id), [first.id])
        XCTAssertEqual(snapshots.first?.section.page.nextStartIndex, 50)
        XCTAssertEqual(snapshots.first?.section.originalIDs, Set([first.id]))
        await gate.close()
        guard
            await requireSearchTask(
                task, context: "progressive direct completion", cleanup: { await gate.close() })
        else { return }
        let result = try await task.value
        XCTAssertEqual(snapshots.map { $0.section.kind }, result.direct.map(\.kind))
        XCTAssertEqual(result.direct.first?.page.items.map(\.id), [first.id])
        XCTAssertEqual(result.direct.first?.page.nextStartIndex, 50)
        let calls = await harness.calls
        XCTAssertLessThanOrEqual(calls.count, 10)
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
        XCTAssertEqual(calls.filter { $0.kind == .track }.map(\.query), ["Garden"])
    }

    @MainActor
    func testRetiredHeldQueryCannotPublishDirectProgressAfterReplacement() async throws {
        let gate = SearchCancellationGate()
        let old = Self.item("old", "Old")
        let newest = Self.item("new", "New")
        let oldResolver = FoundationSearchResolver(search: { _, kind, _ in
            if kind == .track { await gate.wait() }
            return .init(items: kind == .track ? [old] : [], nextStartIndex: nil)
        })
        let newResolver = FoundationSearchResolver(search: { _, kind, _ in
            .init(items: kind == .track ? [newest] : [], nextStartIndex: nil)
        })
        var publications: [String] = []
        let entered = expectation(description: "retired query's noncooperative transport entered")
        await gate.acknowledgeEntry(entered)
        let retired = Task {
            try await oldResolver.resolve(
                query: "Old", onDirectSection: { publications += $0.section.page.items.map(\.id) })
        }
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 5) == .completed else {
            XCTFail("Retired query did not enter its bounded hold")
            retired.cancel()
            await gate.close()
            _ = await requireSearchTask(
                retired, context: "retired query entry cleanup", stopOnCancellation: false,
                cleanup: { await gate.close() })
            return
        }
        retired.cancel()
        let current = try await newResolver.resolve(
            query: "New", onDirectSection: { publications += $0.section.page.items.map(\.id) })
        XCTAssertEqual(current.direct.first?.page.items.map(\.id), [newest.id])
        XCTAssertEqual(publications, [newest.id])
        await gate.close()
        guard
            await requireSearchTask(
                retired, context: "retired direct progress completion",
                cleanup: { await gate.close() })
        else { return }
        do {
            _ = try await retired.value
            XCTFail("A retired query must not return its late direct result")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(publications, [newest.id])
        let calls = await gate.count
        XCTAssertEqual(calls, 1, "Retired query cannot start another category or fallback")
    }

    @MainActor
    func testSameQueryResumeReplacesRetainedProgressWithCompletedSnapshotAndCursor() async throws {
        let model = FoundationBrowseModel()
        let harness = SearchHarness()
        let old = Self.item("old", "Garden")
        let fresh = Self.item("fresh", "Garden")
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [old], nextStartIndex: 50))
        let oldGate = SearchCancellationGate()
        let oldEntered = expectation(description: "partial query held after publishing tracks")
        await oldGate.acknowledgeEntry(oldEntered)
        let oldResolver = FoundationSearchResolver(search: { query, kind, limit in
            let page = try await harness.search(query, kind, limit)
            if kind == .album { await oldGate.wait() }
            return page
        })
        var oldPublications = 0
        let retired = Task {
            try await oldResolver.resolve(
                query: "Garden",
                onDirectSection: { direct in
                    oldPublications += 1
                    if direct.section.kind == .track {
                        await model.loadPending { _ in direct.section.page }
                    }
                })
        }
        guard await XCTWaiter.fulfillment(of: [oldEntered], timeout: 5) == .completed else {
            XCTFail("Partial query did not reach the later-category hold")
            retired.cancel()
            await oldGate.close()
            _ = await requireSearchTask(
                retired, context: "partial query entry cleanup", stopOnCancellation: false,
                cleanup: { await oldGate.close() })
            return
        }
        XCTAssertEqual(model.items, [old])
        XCTAssertEqual(model.nextStartIndex, 50)
        retired.cancel()
        await oldGate.close()
        guard
            await requireSearchTask(
                retired, context: "partial query retirement", cleanup: { await oldGate.close() })
        else { return }
        do {
            _ = try await retired.value
            XCTFail("Retired resolver must not finish or publish later categories")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(oldPublications, 1)

        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [fresh], nextStartIndex: 100))
        let resumeGate = SearchCancellationGate()
        let resumeEntered = expectation(description: "replacement query awaits complete snapshot")
        await resumeGate.acknowledgeEntry(resumeEntered)
        let resumedResolver = FoundationSearchResolver(search: { query, kind, limit in
            let page = try await harness.search(query, kind, limit)
            if kind == .album { await resumeGate.wait() }
            return page
        })
        let resumed = Task { try await resumedResolver.resolve(query: "Garden") }
        guard await XCTWaiter.fulfillment(of: [resumeEntered], timeout: 5) == .completed else {
            XCTFail("Replacement query did not reach the later-category hold")
            resumed.cancel()
            await resumeGate.close()
            _ = await requireSearchTask(
                resumed, context: "replacement entry cleanup", stopOnCancellation: false,
                cleanup: { await resumeGate.close() })
            return
        }
        XCTAssertEqual(
            model.items, [old], "Keep the accepted partial rows until replacement is ready")
        XCTAssertEqual(model.nextStartIndex, 50)
        await resumeGate.close()
        guard
            await requireSearchTask(
                resumed, context: "same-query replacement", cleanup: { await resumeGate.close() })
        else { return }
        let result = try await resumed.value
        let direct = try XCTUnwrap(result.direct.first { $0.kind == .track })
        let beforeInstall = await harness.calls.count
        try await FoundationSearchView<EmptyView>.replaceDirectSnapshot(direct, in: model)
        XCTAssertEqual(model.items, [fresh])
        XCTAssertEqual(model.nextStartIndex, 100)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(direct.originalIDs, Set([fresh.id]))
        let seed = try XCTUnwrap(FoundationSearchResolver.categorySeed(direct.page, kind: .track))
        XCTAssertEqual(seed.page.items, model.items)
        XCTAssertEqual(seed.page.nextStartIndex, model.nextStartIndex)
        let calls = await harness.calls
        XCTAssertEqual(
            calls.count, beforeInstall, "Snapshot replacement performs no provider reads")
        XCTAssertEqual(calls.filter { $0.kind == .track }.count, 2)
        XCTAssertLessThanOrEqual(
            calls.count, 12, "Only one bounded attempt per original query owner")
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
    }

    @MainActor
    func testDirectProgressOwnerRetirementStopsBeforeAnotherCategory() async {
        let harness = SearchHarness()
        let resolver = FoundationSearchResolver(search: { try await harness.search($0, $1, $2) })
        do {
            _ = try await resolver.resolve(
                query: "New", onDirectSection: { _ in throw CancellationError() })
            XCTFail("A retired progress owner must stop resolution")
        } catch { XCTAssertTrue(error is CancellationError) }
        let calls = await harness.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.kind, .track)
    }

    func testTypingSubmitFlushesOnlyThePendingExactQueryAndScope() {
        var typing = FoundationSearchTypingState()
        typing.submit(
            .init(query: "Other", metadataScope: "first"), query: "Garden", metadataScope: "first")
        typing.submit(
            .init(query: "Garden", metadataScope: "retired"), query: "Garden",
            metadataScope: "first")
        XCTAssertFalse(typing.immediate)
        XCTAssertEqual(typing.revision, 0)
        typing.submit(
            .init(query: " Garden ", metadataScope: "first"), query: "Garden",
            metadataScope: "first")
        XCTAssertTrue(typing.immediate)
        XCTAssertEqual(typing.revision, 1)
        typing.submit(
            .init(query: "Garden", metadataScope: "first"), query: "Garden", metadataScope: "first")
        XCTAssertEqual(
            typing.revision, 1, "Repeated Enter cannot enqueue multiple pending searches")
    }

    func testTypingSubmitDoesNotRestartAnAlreadyRunningOrCompletedQuery() {
        var typing = FoundationSearchTypingState()
        typing.begin()
        typing.submit(
            .init(query: "Garden", metadataScope: "first"), query: "Garden", metadataScope: "first")
        XCTAssertTrue(typing.hasStarted)
        XCTAssertFalse(typing.immediate)
        XCTAssertEqual(typing.revision, 0, "Enter must not cancel and duplicate a live resolver")
        let replacement = FoundationSearchTypingState()
        XCTAssertFalse(replacement.hasStarted, "A replacement query owns a fresh typing delay")
    }

    func testEmptyCategoryContinuationEntryVisibility() {
        XCTAssertTrue(
            FoundationSearchResolver.showsCategoryContinuationPlaceholder(
                hasOriginalPage: true, hasFallbackPage: false, hasVisibleSection: false))
        XCTAssertTrue(
            FoundationSearchResolver.showsCategoryContinuationPlaceholder(
                hasOriginalPage: false, hasFallbackPage: true, hasVisibleSection: false))
        XCTAssertFalse(
            FoundationSearchResolver.showsCategoryContinuationPlaceholder(
                hasOriginalPage: false, hasFallbackPage: false, hasVisibleSection: false))
        XCTAssertFalse(
            FoundationSearchResolver.showsCategoryContinuationPlaceholder(
                hasOriginalPage: true, hasFallbackPage: true, hasVisibleSection: true))
    }

    func testPossibleTitleMatchExplanationDoesNotMislabelStrongOrUnrelatedTitles() {
        XCTAssertEqual(
            FoundationSearchResolver.titleMatchExplanation("Cafe Artis", query: "Cafe Artist"),
            "Possible match")
        XCTAssertNil(
            FoundationSearchResolver.titleMatchExplanation("CAFÉ ARTIST", query: "cafe artist"))
        XCTAssertNil(
            FoundationSearchResolver.titleMatchExplanation("Garden Moon", query: "Moon Garden"))
        XCTAssertNil(FoundationSearchResolver.titleMatchExplanation("Unrelated", query: "Garden"))
        let item = Self.item("fuzzy", "Cafe Artis", artist: "Artist")
        XCTAssertEqual(
            FoundationSearchResolver.explainedSubtitle(nil, item: item, query: "Cafe Artist"),
            "Possible match")
        XCTAssertEqual(
            FoundationSearchResolver.explainedSubtitle("Song", item: item, query: "Cafe Artist"),
            "Possible match · Song")
        let longSubtitle = String(repeating: "Long artist and album description ", count: 20)
        let explained = FoundationSearchResolver.explainedSubtitle(
            longSubtitle, item: item, query: "Cafe Artist")
        XCTAssertTrue(explained?.hasPrefix("Possible match · ") == true)
        XCTAssertTrue(explained?.hasSuffix(longSubtitle) == true)
    }

    func testCategorySnapshotKeepsTopAndAllDirectRowsBeforeProviderCursor() throws {
        let songTop = Self.item("song-top", "Garden")
        let songOther = Self.item("song-other", "Garden Live")
        let albumTop = Self.item("album-top", "Garden", kind: .album)
        let albumOther = Self.item("album-other", "Garden Live", kind: .album)
        let artistTop = Self.item("artist-top", "Garden", kind: .artist)
        let artistOther = Self.item("artist-other", "Garden Live", kind: .artist)
        let relatedSong = Self.item("related-song", "Different Song")
        let direct: [FoundationSearchResolver.DirectSection] = [
            .init(
                kind: .track, page: .init(items: [songTop, songOther], nextStartIndex: 50),
                includesFuzzyMatches: false, error: nil, originalIDs: ["song-top", "song-other"]),
            .init(
                kind: .album, page: .init(items: [albumTop, albumOther], nextStartIndex: 50),
                includesFuzzyMatches: false, error: nil,
                originalIDs: ["album-top", "album-other"]),
            .init(
                kind: .artist, page: .init(items: [artistTop, artistOther], nextStartIndex: 50),
                includesFuzzyMatches: false, error: nil,
                originalIDs: ["artist-top", "artist-other"]),
        ]
        let related: [FoundationSearchResolver.RelatedSection] = [
            .init(role: .albumTracks, source: albumTop, items: [songTop, relatedSong])
        ]
        for (kind, expected) in [
            (FoundationItem.Kind.track, Set(["song-top", "song-other", "related-song"])),
            (.album, Set(["album-top", "album-other"])),
            (.artist, Set(["artist-top", "artist-other"])),
        ] {
            let items = FoundationSearchResolver.categoryItems(
                direct: direct, related: related, kind: kind, query: "Garden")
            XCTAssertEqual(Set(items.map(\.id)), expected)
            XCTAssertEqual(items.count, expected.count, "A top/related duplicate must appear once")
            XCTAssertEqual(direct.first { $0.kind == kind }?.page.nextStartIndex, 50)
        }
    }

    func testCategoryCoverageReportsFailedFallbackAndOverflowWithoutSilentTruncation() {
        XCTAssertNil(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: false, itemCount: 200))
        XCTAssertTrue(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: true, itemCount: 5)?.contains("could not be loaded") == true)
        XCTAssertNil(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: false, itemCount: 201))
        XCTAssertTrue(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: false, itemCount: FoundationCatalogComposition.itemLimit + 1)?
                .contains("too large") == true)
        let both = FoundationSearchResolver.categoryCoverageMessage(
            hasPartialFailure: true, itemCount: FoundationCatalogComposition.itemLimit + 1)
        XCTAssertTrue(both?.contains("could not be loaded") == true)
        XCTAssertTrue(both?.contains("too large") == true)
        XCTAssertTrue(
            FoundationSearchResolver.canSeedCategory(
                directSucceeded: true, itemCount: 200, hasNextPage: true))
        XCTAssertTrue(
            FoundationSearchResolver.canSeedCategory(
                directSucceeded: true, itemCount: 201, hasNextPage: true))
        XCTAssertFalse(
            FoundationSearchResolver.canSeedCategory(
                directSucceeded: true, itemCount: FoundationCatalogComposition.itemLimit + 1,
                hasNextPage: true))
        XCTAssertTrue(
            FoundationSearchResolver.canSeedCategory(
                directSucceeded: true, itemCount: 0, hasNextPage: true))
        XCTAssertFalse(
            FoundationSearchResolver.canSeedCategory(
                directSucceeded: false, itemCount: 5, hasNextPage: false))
    }

    func testFailedFallbackProducesVisibleCategoryCoverage() async throws {
        let resolver = FoundationSearchResolver(localSearch: { query, kind, _ in
            if query == "gar", kind == .track { throw FoundationLibraryError.network }
            return .init(items: [], nextStartIndex: nil)
        })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertTrue(result.failures.contains(.fallback(.track)))
        XCTAssertTrue(result.unwalkedFallbackKinds.isEmpty)
        let hasPartialFailure = result.failures.contains {
            if case .direct = $0 { return false }
            return true
        }
        XCTAssertNotNil(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: hasPartialFailure, itemCount: 0))
    }

    func testCategoryCoverageIncludesOtherDirectKindFailure() {
        let track = FoundationSearchResolver.DirectSection(
            kind: .track, page: .init(items: [], nextStartIndex: nil),
            includesFuzzyMatches: false, error: nil)
        let failedAlbum = FoundationSearchResolver.DirectSection(
            kind: .album, page: .init(items: [], nextStartIndex: nil),
            includesFuzzyMatches: false, error: .network)
        XCTAssertTrue(
            FoundationSearchResolver.categoryHasPartialFailure(
                direct: [track, failedAlbum], kind: .track, hasOtherFailures: false))
        XCTAssertFalse(
            FoundationSearchResolver.categoryHasPartialFailure(
                direct: [track], kind: .track, hasOtherFailures: false))
        XCTAssertTrue(
            FoundationSearchResolver.categoryHasPartialFailure(
                direct: [track], kind: .album, hasOtherFailures: false))
        XCTAssertTrue(
            FoundationSearchResolver.categoryHasPartialFailure(
                direct: [track], kind: .track, hasOtherFailures: true))
    }

    @MainActor
    func testCancelledOfferedSeedRemainsAvailableUntilBrowsePublication() async throws {
        let page = FoundationPage(items: [Self.item("seed", "Garden")], nextStartIndex: nil)
        let lease = FoundationSearchSeedLease(page: page)
        let model = FoundationBrowseModel(onLoadSettled: { lease.settle() })
        let entered = expectation(description: "seed loader entered")
        let gate = SearchSeedGate(entered: entered)
        let loading = Task {
            await model.load(.initial) { _ in
                let offered = try XCTUnwrap(lease.offer(eligible: true))
                await gate.hold()
                return offered
            }
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard entry == .completed else {
            loading.cancel()
            await gate.release()
            guard
                await requireSearchTask(
                    loading, context: "loading completion",
                    cleanup: {
                        model.clearRetainedData()
                        await gate.release()
                    })
            else { return }
            await loading.value
            XCTFail("Seed loader did not enter")
            return
        }
        loading.cancel()
        await gate.release()
        guard
            await requireSearchTask(
                loading, context: "loading completion",
                cleanup: {
                    model.clearRetainedData()
                    await gate.release()
                })
        else { return }
        await loading.value
        XCTAssertTrue(lease.pending)
        XCTAssertFalse(model.loaded)
        await model.load(.initial) { _ in try XCTUnwrap(lease.offer(eligible: true)) }
        XCTAssertEqual(model.items.map(\.id), ["seed"])
        XCTAssertFalse(lease.pending)
        let fresh = Self.item("fresh", "Garden refreshed")
        await model.load(.refresh) { _ in .init(items: [fresh], nextStartIndex: nil) }
        XCTAssertEqual(model.items.map(\.id), ["fresh"])
    }

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
        XCTAssertEqual(
            FoundationSearchResolver.titleScore("Taylor Swift", query: "Taylr Swfit"), 60)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Taylor Swift", query: "Taylr Swfti"), 0)
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

    func testAdjacentTranspositionsAndTokenOrderHaveBoundedFormattedScoreParity() {
        for query in ["Swfit", " SWFÍT ", "swfit!", "swfit—"] {
            XCTAssertEqual(FoundationSearchResolver.titleScore("Swift", query: query), 60)
            XCTAssertEqual(
                FoundationSearchResolver.titleMatchExplanation("Swift", query: query),
                "Possible match")
        }
        for query in ["Garden Gardan", "Gardan Garden", " GÁRDAN—GARDEN! "] {
            for title in ["Garden Gorden", "Gorden Garden"] {
                XCTAssertEqual(FoundationSearchResolver.titleScore(title, query: query), 60)
            }
        }
        for (title, query) in [
            ("Cat", "Cta"), ("The Cat", "The Cta"),
            ("Taylor Swift", "Taylr Swfti"), ("Garden Gorden", "Gxrdxn Gardxn"),
            ("Different Music", "Swfit"),
            (String(repeating: "a", count: 129), String(repeating: "b", count: 129)),
            (
                "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii",
                "aaax bbbb cccc dddd eeee ffff gggg hhhh iiii"
            ),
        ] {
            XCTAssertEqual(FoundationSearchResolver.titleScore(title, query: query), 0)
            XCTAssertNil(FoundationSearchResolver.titleMatchExplanation(title, query: query))
        }
        for (title, query, expected) in [
            ("Garden Other", "Gardan Gardan", 0),
            ("Garden Garden", "Gardan Gardan", 60),
            ("Garden Gorden", "Gardan Gardan", 0),
            ("Garden Garden Garden Gorden", "Gardan Gardan Garden Gorden", 60),
            ("Garden Garden", "Gardan Gardan Gardan", 0),
        ] {
            XCTAssertEqual(FoundationSearchResolver.titleScore(title, query: query), expected)
        }
        let longTitle = "b" + String(repeating: "a", count: 127)
        XCTAssertEqual(
            FoundationSearchResolver.titleScore(
                longTitle, query: "ab" + String(repeating: "a", count: 126)), 60)
        XCTAssertEqual(
            FoundationSearchResolver.titleScore(
                longTitle, query: "b" + String(repeating: "a", count: 125) + "xy"), 60)
        XCTAssertEqual(
            FoundationSearchResolver.titleScore(
                longTitle, query: "b" + String(repeating: "a", count: 124) + "xyz"), 0)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Swift", query: "Swift"), 100)
        XCTAssertEqual(FoundationSearchResolver.titleScore("Swift Live", query: "Swift"), 90)
    }

    func testTransposedFallbackMatchesAcrossKindsWithinExistingTwoReadLimit() async throws {
        for kind in [FoundationItem.Kind.track, .album, .artist, .playlist, .genre] {
            let harness = SearchHarness()
            await harness.install(
                query: "tay", kind: kind,
                page: .init(
                    items: [
                        Self.item("match", "Taylor Swift", kind: kind),
                        Self.item("other", "Different Music", kind: kind),
                    ],
                    nextStartIndex: 50))
            let resolver = FoundationSearchResolver(localSearch: {
                try await harness.search($0, $1, $2)
            })
            let result = try await resolver.resolveDirect(query: "Taylr Swfit", kind: kind)
            XCTAssertEqual(result.section.page.items.map(\.id), ["match"])
            XCTAssertTrue(result.section.includesFuzzyMatches)
            XCTAssertEqual(result.section.fallbackCursor?.term, "tay")
            XCTAssertEqual(result.section.fallbackCursor?.nextStartIndex, 50)
            XCTAssertNil(result.section.page.nextStartIndex)
            XCTAssertEqual(
                FoundationSearchResolver.titleMatchExplanation(
                    try XCTUnwrap(result.section.page.items.first).title, query: "Taylr Swfit"),
                "Possible match")
            let calls = await harness.calls
            XCTAssertEqual(calls.map(\.query), ["Taylr Swfit", "tay"])
            XCTAssertTrue(calls.allSatisfy { $0.limit == 50 && $0.kind == kind })
        }
    }

    func testDirectOfflineResolutionReportsUnwalkedFallbackPageWithinTwoReads() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "gar", kind: .track,
            page: .init(items: [Self.item("fuzzy", "Garden")], nextStartIndex: 50))
        let resolver = FoundationSearchResolver(localSearch: {
            try await harness.search($0, $1, $2)
        })
        let result = try await resolver.resolveDirect(query: "Gardenx", kind: .track)
        XCTAssertEqual(result.section.page.items.map(\.id), ["fuzzy"])
        XCTAssertTrue(result.fallbackHasMore)
        XCTAssertNil(result.section.page.nextStartIndex)
        let calls = await harness.calls
        XCTAssertEqual(calls.map(\.query), ["Gardenx", "gar"])
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
    }

    func testOverviewRetainsFallbackCoverageWithoutWalkingOrReplacingOriginalCursor() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Gardenx", kind: .track,
            page: .init(items: [Self.item("original", "Provider match")], nextStartIndex: 50))
        await harness.install(
            query: "gar", kind: .track,
            page: .init(items: [Self.item("fuzzy", "Garden")], nextStartIndex: 50))
        let resolver = FoundationSearchResolver(localSearch: {
            try await harness.search($0, $1, $2)
        })
        let result = try await resolver.resolve(query: "Gardenx")
        XCTAssertEqual(result.unwalkedFallbackKinds, [.track])
        let track = try XCTUnwrap(result.direct.first { $0.kind == .track })
        XCTAssertEqual(Set(track.page.items.map(\.id)), ["original", "fuzzy"])
        XCTAssertEqual(track.page.nextStartIndex, 50)
        XCTAssertEqual(track.fallbackCursor?.term, "gar")
        XCTAssertEqual(track.fallbackCursor?.nextStartIndex, 50)
        let calls = await harness.calls
        XCTAssertEqual(calls.count, 10)
        XCTAssertEqual(calls.filter { $0.kind == .track }.map(\.query), ["Gardenx", "gar"])
    }

    func testFallbackCoverageContextAndCombinedNoticeRemainHonest() {
        let coverage = FoundationSearchFallbackCoverage(
            query: "Garden", metadataScope: "account-a", localOnly: false, kinds: [.album])
        XCTAssertTrue(
            coverage.hasUnwalkedPages(
                query: "Garden", metadataScope: "account-a", localOnly: false))
        XCTAssertFalse(
            coverage.hasUnwalkedPages(
                query: "Other", metadataScope: "account-a", localOnly: false))
        XCTAssertFalse(
            coverage.hasUnwalkedPages(
                query: "Garden", metadataScope: "account-b", localOnly: false))
        XCTAssertFalse(
            coverage.hasUnwalkedPages(
                query: "Garden", metadataScope: "account-a", localOnly: true))
        let combined = FoundationSearchResolver.categoryCoverageMessage(
            hasPartialFailure: true, itemCount: 201, hasUnwalkedFallback: true)
        XCTAssertTrue(combined?.contains("could not be loaded") == true)
        XCTAssertFalse(
            combined?.contains("too large") == true, "Retained overflow is now explicitly pageable")
        XCTAssertTrue(combined?.contains("More close matches may exist") == true)
        XCTAssertNil(
            FoundationSearchResolver.categoryCoverageMessage(
                hasPartialFailure: false, itemCount: 5, hasUnwalkedFallback: false))
    }

    func testOriginalContinuationDoesNotClaimUnwalkedFallback() async throws {
        let harness = SearchHarness()
        await harness.install(
            query: "Garden", kind: .track,
            page: .init(items: [Self.item("exact", "Garden")], nextStartIndex: 50))
        let resolver = FoundationSearchResolver(localSearch: {
            try await harness.search($0, $1, $2)
        })
        let result = try await resolver.resolve(query: "Garden")
        XCTAssertFalse(result.unwalkedFallbackKinds.contains(.track))
        XCTAssertEqual(result.direct.first { $0.kind == .track }?.page.nextStartIndex, 50)
        let calls = await harness.calls
        XCTAssertEqual(calls.filter { $0.kind == .track }.map(\.query), ["Garden"])
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

    func testMissingSearchEntryTimesOutAndDrainsHeldAndLateWork() async {
        let gate = SearchCancellationGate()
        let entered = expectation(description: "deliberately missing search entry")
        await gate.acknowledgeEntry(entered)
        let task = Task { await gate.wait(announce: false) }
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 0.1)
        XCTAssertEqual(result, .timedOut, "Missing search entry must time out")
        let held = await gate.waiting
        XCTAssertTrue(held, "Timeout must exercise a held search request")
        task.cancel()
        await gate.close()
        await task.value
        let stillHeld = await gate.waiting
        XCTAssertFalse(stillHeld, "Timeout cleanup must drain the search request")
        await gate.wait()
        let lateHeld = await gate.waiting
        XCTAssertFalse(lateHeld, "A request starting after cleanup must not become stranded")
    }

    private func waitForHeldSearch(
        _ entered: XCTestExpectation, gate: SearchCancellationGate,
        task: Task<FoundationSearchResolver.Result, Error>
    ) async -> Bool {
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        guard result == .completed, !Task.isCancelled else {
            XCTFail("Timed out or cancelled waiting for \(entered.expectationDescription)")
            task.cancel()
            await gate.close()
            _ = await requireSearchTask(
                task, context: "search entry cleanup", stopOnCancellation: false,
                cleanup: { await gate.close() })
            return false
        }
        return true
    }

    func testCancelledTransportCannotReturnResultOrStartNextRequest() async {
        let gate = SearchCancellationGate()
        let resolver = FoundationSearchResolver(search: { _, _, _ in
            await gate.wait()
            return .init(items: [], nextStartIndex: nil)
        })
        let entered = expectation(description: "search request entered held operation")
        await gate.acknowledgeEntry(entered)
        let task = Task { try await resolver.resolve(query: "Garden") }
        guard await waitForHeldSearch(entered, gate: gate, task: task) else { return }
        task.cancel()
        await gate.release()
        do {
            guard
                await requireSearchTask(
                    task, context: "task completion", cleanup: { await gate.close() })
            else { return }
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
        let entered = expectation(description: "search request entered held operation")
        await gate.acknowledgeEntry(entered)
        let task = Task { try await resolver.resolve(query: "Garden") }
        guard await waitForHeldSearch(entered, gate: gate, task: task) else { return }
        task.cancel()
        await gate.release()
        do {
            guard
                await requireSearchTask(
                    task, context: "task completion", cleanup: { await gate.close() })
            else { return }
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
        let entered = expectation(description: "search request entered held operation")
        await gate.acknowledgeEntry(entered)
        let task = Task { try await resolver.resolve(query: "Garden") }
        guard await waitForHeldSearch(entered, gate: gate, task: task) else { return }
        task.cancel()
        await gate.release()
        do {
            guard
                await requireSearchTask(
                    task, context: "task completion", cleanup: { await gate.close() })
            else { return }
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

    func testFreshCategoryRefreshRebuildsAlbumAndArtistRelationsWithinTypedBudget() async throws {
        let harness = SearchHarness()
        var song = Self.item("song", "Garden")
        song.album = .init(id: "track-album", title: "Track collection")
        song.artist = .init(id: "track-artist", title: "Track performer")
        var album = Self.item("album", "Garden", kind: .album)
        album.artist = .init(id: "album-artist", title: "Album performer")
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [song], nextStartIndex: nil))
        await harness.install(
            query: "Garden", kind: .album, page: .init(items: [album], nextStartIndex: 50))
        await harness.install(
            query: "Garden", kind: .artist,
            page: .init(items: [Self.item("artist", "Garden", kind: .artist)], nextStartIndex: nil))
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistAlbums: { _ in
                await harness.recordRelation("artistAlbums")
                return .init(
                    items: [Self.item("related-album", "Separate collection", kind: .album)],
                    nextStartIndex: 50)
            },
            artistTracks: { _ in
                XCTFail("Albums/Artists must not fetch artist tracks")
                return .init(items: [], nextStartIndex: nil)
            },
            artistMostPlayed: { _ in
                XCTFail("Albums/Artists must not fetch most played")
                return .init(items: [], nextStartIndex: nil)
            },
            albumTracks: { _ in
                XCTFail("Albums/Artists must not fetch album tracks")
                return .init(items: [], nextStartIndex: nil)
            })
        let albums = try await resolver.resolveCategory(query: "Garden", kind: .album)
        XCTAssertEqual(Set(albums.page.items.map(\.id)), ["album", "track-album", "related-album"])
        XCTAssertEqual(albums.page.nextStartIndex, 50)
        XCTAssertEqual(albums.direct.originalIDs, ["album"])
        XCTAssertTrue(
            albums.incomplete, "A retained first relationship page must disclose its continuation")
        let artists = try await resolver.resolveCategory(query: "Garden", kind: .artist)
        XCTAssertEqual(
            Set(artists.page.items.map(\.id)), ["artist", "track-artist", "album-artist"])
        song.album = .init(id: "new-album", title: "Replacement collection")
        await harness.install(
            query: "Garden", kind: .track, page: .init(items: [song], nextStartIndex: nil))
        let refreshed = try await resolver.resolveCategory(query: "Garden", kind: .album)
        XCTAssertTrue(refreshed.page.items.contains { $0.id == "new-album" })
        XCTAssertFalse(refreshed.page.items.contains { $0.id == "track-album" })
        let calls = await harness.calls
        let relations = await harness.relations
        XCTAssertEqual(
            calls.count, 9, "Three resolutions use three bounded strong-match anchors each")
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
        XCTAssertEqual(relations, ["artistAlbums", "artistAlbums"])
    }

    @MainActor
    func testFreshCategoryRefreshPreservesIndependentCursorsAndNeverCachesMixedSeed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        let cache = FoundationCatalogPageCache(scope: "fresh-search", root: root)
        addTeardownBlock {
            let retired = await cache.invalidate()
            XCTAssertTrue(retired)
            if retired { try? FileManager.default.removeItem(at: root) }
        }
        let old = Self.item("old", "Garden", kind: .album)
        let fresh = Self.item("fresh", "Garden", kind: .album)
        let related = Self.item("relation", "Another collection", kind: .album)
        let seed = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(
                .init(items: [fresh, related], nextStartIndex: 50), kind: .album))
        await cache.write(.init(items: [old], nextStartIndex: 50), key: "raw")
        let beforeRecord = await cache.read("raw")
        let before = try XCTUnwrap(beforeRecord)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureCache(cache, key: "raw")
        var refreshes = 0
        var fallbackReads = 0
        model.configureSearchContinuation(
            query: "Garden", kind: .album, metadataScope: "synthetic", fallback: nil,
            refresh: {
                refreshes += 1
                return .init(
                    seed: seed, fallback: .init(term: "gar", nextStartIndex: 100),
                    coverageMessage: "Bounded related page")
            },
            fetch: { term, kind, cursor in
                fallbackReads += 1
                XCTAssertEqual(term, "gar")
                XCTAssertEqual(kind, .album)
                XCTAssertEqual(cursor, 100)
                return .init(
                    items: [Self.item("fallback", "Garden", kind: .album)], nextStartIndex: nil)
            })
        await model.load(.refresh) { _ in
            XCTFail("Typed refresh must own the first page")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["fresh", "relation"])
        XCTAssertEqual(model.nextStartIndex, 50)
        XCTAssertEqual(model.searchFallbackCursor?.nextStartIndex, 100)
        XCTAssertEqual(model.searchRefreshCoverageMessage, "Bounded related page")
        let afterRecord = await cache.read("raw")
        let after = try XCTUnwrap(afterRecord)
        XCTAssertEqual(after.page.items, before.page.items)
        XCTAssertEqual(
            after.savedAt, before.savedAt, "Mixed membership is not a raw cache refresh")
        await model.load(.more) { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(
                items: [Self.item("provider", "Garden", kind: .album)], nextStartIndex: nil)
        }
        await model.load(.more) { _ in
            XCTFail("Fallback must retain its separate query cursor")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(fallbackReads, 1)
        XCTAssertEqual(Set(model.items.map(\.id)), ["fresh", "relation", "provider", "fallback"])
        XCTAssertFalse(model.hasMorePages)
    }

    @MainActor
    func testFreshCategoryRefreshFailureAndRetirementCannotReplaceCurrentRows() async throws {
        let model = FoundationBrowseModel()
        let old = Self.item("old", "Garden", kind: .artist)
        let replacement = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(
                .init(items: [Self.item("late", "Garden", kind: .artist)], nextStartIndex: nil),
                kind: .artist))
        let entered = XCTestExpectation(description: "held fresh category entered")
        let gate = SearchSeedGate(entered: entered)
        var shouldFail = true
        model.configureSearchContinuation(
            query: "Garden", kind: .artist, metadataScope: "synthetic", fallback: nil,
            refresh: {
                if shouldFail { throw FoundationLibraryError.network }
                await gate.hold()
                return .init(seed: replacement, fallback: nil, coverageMessage: nil)
            },
            fetch: { _, _, _ in
                XCTFail()
                return .init(items: [], nextStartIndex: nil)
            })
        model.installSnapshot([old])
        await model.load(.refresh) { _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["old"])
        XCTAssertEqual(model.errorCategory, .network)
        shouldFail = false
        let task = Task {
            await model.load(.refresh) { _ in
                XCTFail()
                return .init(items: [], nextStartIndex: nil)
            }
        }
        let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
        if entry != .completed { XCTFail("Fresh category entry did not arrive") }
        model.clearRetainedData()
        await gate.release()
        guard
            await requireSearchTask(
                task, context: "retired fresh category", cleanup: { await gate.release() })
        else { return }
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.nextStartIndex)
        XCTAssertNil(model.searchFallbackCursor)
        XCTAssertFalse(model.hasRefreshedSearchRelations)
    }

    func testFreshTrackCategoryUsesAtMostNineReadsWithoutWalkingPages() async throws {
        let harness = SearchHarness()
        for kind in [FoundationItem.Kind.track, .album, .artist] {
            await harness.install(
                query: "gar", kind: kind,
                page: .init(
                    items: [Self.item(kind.rawValue, "Garden", kind: kind)], nextStartIndex: 50))
        }
        let resolver = FoundationSearchResolver(
            search: { try await harness.search($0, $1, $2) },
            artistAlbums: { _ in
                XCTFail("Track refresh must not fetch artist albums")
                return .init(items: [], nextStartIndex: nil)
            },
            artistTracks: { _ in
                await harness.recordRelation("artistTracks")
                return .init(
                    items: [Self.item("artist-song", "Separate song")], nextStartIndex: 100)
            },
            artistMostPlayed: { _ in
                await harness.recordRelation("mostPlayed")
                return .init(items: [], nextStartIndex: nil)
            },
            albumTracks: { _ in
                await harness.recordRelation("albumTracks")
                return .init(items: [Self.item("album-song", "Separate song")], nextStartIndex: 100)
            })
        let result = try await resolver.resolveCategory(query: "Garden", kind: .track)
        let calls = await harness.calls
        let relations = await harness.relations
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(relations, ["mostPlayed", "artistTracks", "albumTracks"])
        XCTAssertEqual(calls.count + relations.count, 9)
        XCTAssertTrue(calls.allSatisfy { $0.limit == 50 })
        XCTAssertNil(result.page.nextStartIndex)
        XCTAssertEqual(result.direct.fallbackCursor?.nextStartIndex, 50)
        XCTAssertTrue(result.incomplete)
        XCTAssertEqual(Set(result.page.items.map(\.id)), ["track", "artist-song", "album-song"])
    }

    func testFreshComposedTrackBindingRetainsRelationshipsAndProviderProvenance() async throws {
        let harness = SearchHarness()
        let trackID = String(repeating: "1", count: 32)
        let albumID = String(repeating: "2", count: 32)
        let artistID = String(repeating: "3", count: 32)
        let relatedID = String(repeating: "4", count: 32)
        let albumTrackID = String(repeating: "5", count: 32)
        let session = FoundationSession(
            serverURL: URL(string: "https://synthetic.invalid")!, accessToken: "synthetic",
            userID: String(repeating: "6", count: 32), deviceID: "synthetic")
        let library = FoundationJellyfinLibrary(session: session) { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
            await harness.recordRelation(url.path + ":" + (value("searchTerm") ?? "relation"))
            let id: String
            let type: String
            let name: String
            if url.path.hasSuffix("/Artists/AlbumArtists") {
                id = artistID
                type = "MusicArtist"
                name = "Garden"
            } else if value("includeItemTypes") == "MusicAlbum" {
                XCTAssertNotNil(value("searchTerm"), "Track refresh cannot fetch artist albums")
                id = albumID
                type = "MusicAlbum"
                name = "Garden"
            } else if value("searchTerm") != nil {
                id = trackID
                type = "Audio"
                name = "Garden"
            } else if value("parentId") == albumID {
                id = albumTrackID
                type = "Audio"
                name = "Album relationship"
            } else {
                id = relatedID
                type = "Audio"
                name = "Artist relationship"
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": [["Id": id, "Type": type, "Name": name]], "StartIndex": 0,
                "TotalRecordCount": 1,
            ])
            return (
                data,
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let binding = try FoundationCatalogFetchBinding(
            query: .search(text: "Garden", kind: .track), jellyfin: library, local: nil,
            localID: nil, refreshSearchRelations: true)
        try await binding.loadJellyfin()
        let snapshots = await binding.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(Set(snapshot.items.map(\.id)), [trackID, relatedID, albumTrackID])
        XCTAssertTrue(snapshot.isSeededSearch)
        XCTAssertTrue(
            snapshot.freshKeys.isEmpty, "Related/fallback membership is not a raw provider page")
        XCTAssertFalse(snapshot.searchCoverageIncomplete)
        XCTAssertNil(snapshot.nextStartIndex)
        let calls = await harness.relations
        XCTAssertEqual(calls.count, 5)
        await binding.retire(snapshot.source)
        do {
            try await binding.loadJellyfin()
            XCTFail("Retired binding cannot refresh")
        } catch {}
        let afterRetirement = await harness.relations
        XCTAssertEqual(afterRetirement.count, calls.count)
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

private actor SearchSeedGate {
    private let entered: XCTestExpectation
    private var continuation: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var announced = false

    init(entered: XCTestExpectation) { self.entered = entered }

    func hold() async {
        guard !released else { return }
        await withCheckedContinuation {
            continuation.append($0)
            if !announced {
                announced = true
                entered.fulfill()
            }
        }
    }

    func release() {
        released = true
        let pending = continuation
        continuation.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

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
    var count = 0
    var waiting: Bool { !continuation.isEmpty }
    private var continuation: [CheckedContinuation<Void, Never>] = []
    private var entry: XCTestExpectation?
    private var closed = false

    func acknowledgeEntry(_ expectation: XCTestExpectation) {
        entry = expectation
    }

    func wait(announce: Bool = true) async {
        guard !closed else { return }
        count += 1
        await withCheckedContinuation { continuation in
            self.continuation.append(continuation)
            if announce { entry?.fulfill() }
            entry = nil
        }
    }

    func release() {
        let pending = continuation
        continuation.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func close() {
        closed = true
        entry = nil
        release()
    }
}

extension FoundationSearchResolverTests {
    @MainActor
    func testNativeEmptyFallbackSeedMakesOneExplicitReadAndClearsNotice() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        var reads: [Int] = []
        model.configureSearchContinuation(
            query: "Gardenx", kind: .track, metadataScope: "account/folder",
            fallback: .init(term: "gar", nextStartIndex: 50)
        ) { term, kind, offset in
            XCTAssertEqual(term, "gar")
            XCTAssertEqual(kind, .track)
            reads.append(offset)
            return .init(
                items: [
                    FoundationItem(
                        id: "match", title: "Garden", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: nil)
        }
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: nil) }
        XCTAssertTrue(reads.isEmpty)
        XCTAssertTrue(model.hasMorePages)
        XCTAssertNil(model.nextStartIndex)
        await model.load(.more) { _ in
            XCTFail("Fallback must use scoped request")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, [50])
        XCTAssertEqual(model.items.map(\.id), ["match"])
        XCTAssertFalse(model.hasMorePages)
        XCTAssertNil(
            FoundationSearchResolver.continuationCoverageMessage(
                "More close matches may exist. Narrow your search.",
                hasFallback: model.searchFallbackCursor != nil))
    }

    @MainActor
    func testNativeOriginalAndFallbackCursorsRetryIndependently() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        var reads: [Int] = []
        model.configureSearchContinuation(
            query: "Gardenx", kind: .track, metadataScope: "scope",
            fallback: .init(term: "gar", nextStartIndex: 50)
        ) { _, _, cursor in
            reads.append(cursor)
            if reads.count == 1 { throw FoundationLibraryError.network }
            return .init(items: [], nextStartIndex: nil)
        }
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: 100) }
        await model.load(.more) { cursor in
            XCTAssertEqual(cursor, 100)
            return .init(
                items: [
                    FoundationItem(
                        id: "direct", title: "Garden", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: nil)
        }
        XCTAssertTrue(reads.isEmpty)
        await model.load(.more) { _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.searchFallbackCursor?.nextStartIndex, 50)
        await model.load(.more) { _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, [50, 50])
        XCTAssertEqual(model.items.map(\.id), ["direct"])
        XCTAssertFalse(model.hasMorePages)
    }
    @MainActor
    func testNativeRetirementRejectsLateFallbackResult() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureSearchContinuation(
            query: "Gardenx", kind: .track, metadataScope: "old-account/folder",
            fallback: .init(term: "gar", nextStartIndex: 50)
        ) { _, _, _ in
            model.clearRetainedData()
            return .init(
                items: [
                    FoundationItem(
                        id: "late", title: "Garden", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: nil)
        }
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: nil) }
        await model.load(.more) { _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertTrue(model.rawItems.isEmpty)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.hasMorePages)
    }

    @MainActor
    func testNativeFilteredPageRetainsContinuationWithoutWalking() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        var reads = 0
        model.configureSearchContinuation(
            query: "Gardenx", kind: .track, metadataScope: "scope",
            fallback: .init(term: "gar", nextStartIndex: 50)
        ) { _, _, cursor in
            reads += 1
            XCTAssertEqual(cursor, 50)
            return .init(
                items: [
                    FoundationItem(
                        id: "unrelated", title: "Other", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: 100)
        }
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: nil) }
        await model.load(.more) { _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.searchFallbackCursor?.nextStartIndex, 100)
        XCTAssertNil(model.nextStartIndex)
        XCTAssertTrue(model.hasMorePages)
    }

    @MainActor
    func testEmptyOriginalSeedWithoutFallbackContinuesExplicitly() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "scope", fallback: nil
        ) { _, _, _ in
            XCTFail("No fallback stream exists")
            return .init(items: [], nextStartIndex: nil)
        }
        await model.load(.initial) { _ in .init(items: [], nextStartIndex: 50) }
        XCTAssertTrue(model.hasMorePages)
        XCTAssertNil(model.searchFallbackCursor)
        await model.load(.more) { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(
                items: [
                    FoundationItem(
                        id: "found", title: "Garden", subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["found"])
        XCTAssertFalse(model.hasMorePages)
    }

    @MainActor
    func testNativeSeedOverflowPreservesAllKindsAndIndependentProviderCursors() async throws {
        for kind in [FoundationItem.Kind.track, .album, .artist, .playlist] {
            let items = (0..<401).map {
                var item = Self.item("seed-\(kind)-\($0)", "Garden", kind: kind)
                item.isFavorite = false
                return item
            }
            let seed = try XCTUnwrap(
                FoundationSearchResolver.categorySeed(
                    .init(items: items, nextStartIndex: 50)))
            XCTAssertEqual(seed.page.items.count, 200)
            XCTAssertEqual(seed.remaining.count, 201)
            let model = FoundationBrowseModel(catalogLimits: .init(maximumPages: 2))
            model.configureCatalogPagination()
            let actions = FoundationLibraryActions(
                sourceScope: String(repeating: "a", count: 64),
                read: { _ in nil }, write: { _, _ in }, mutateFavorite: { _, _ in })
            model.configureFavoriteObservations(actions)
            let last = try XCTUnwrap(items.last)
            var fallbackReads = 0
            model.configureSearchContinuation(
                query: "Gardenx", kind: kind, metadataScope: "scope",
                fallback: .init(term: "gar", nextStartIndex: 100), seed: seed
            ) { term, requestedKind, cursor in
                fallbackReads += 1
                XCTAssertEqual(term, "gar")
                XCTAssertEqual(requestedKind, kind)
                XCTAssertEqual(cursor, 100)
                return .init(items: [Self.item("fuzzy", "Garden", kind: kind)], nextStartIndex: nil)
            }
            await model.load(.initial) { _ in seed.page }
            XCTAssertEqual(model.items.count, 200)
            XCTAssertEqual(model.searchSeedOverflowCount, 201)
            await actions.setFavorite(for: last, isFavorite: true)
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await model.load(.more) { _ in
                    XCTFail("Cancelled overflow called provider")
                    return .init(items: [], nextStartIndex: nil)
                }
            }
            await cancelled.value
            XCTAssertEqual(model.items.count, 200)
            XCTAssertEqual(model.searchSeedOverflowCount, 201)
            for expected in [400, 401] {
                await model.load(.more) { _ in
                    XCTFail("Retained overflow must not call the provider")
                    return .init(items: [], nextStartIndex: nil)
                }
                XCTAssertEqual(model.items.count, expected)
                XCTAssertEqual(model.nextStartIndex, 50)
                XCTAssertEqual(model.searchFallbackCursor?.nextStartIndex, 100)
                XCTAssertEqual(fallbackReads, 0)
                XCTAssertEqual(
                    actions.favoriteState(for: last, initial: false), true,
                    "Retained pages must not replay old favorite metadata as a fresh read")
            }
            XCTAssertEqual(model.items.map(\.id), items.map(\.id))
            await model.load(.more) { cursor in
                XCTAssertEqual(cursor, 50)
                return .init(
                    items: [Self.item("direct", "Garden", kind: kind)], nextStartIndex: nil)
            }
            XCTAssertEqual(model.items.count, 402)
            XCTAssertEqual(fallbackReads, 0)
            await model.load(.more) { _ in
                XCTFail("Fallback must use its scoped request")
                return .init(items: [], nextStartIndex: nil)
            }
            XCTAssertEqual(fallbackReads, 1)
            XCTAssertEqual(model.items.count, 403)
            XCTAssertEqual(Set(model.items.map(\.id)).count, 403)
            XCTAssertFalse(model.hasMorePages)
        }
    }

    @MainActor
    func testNativeOverflowRetiresWithScopeAndSuccessfulRefreshReplacesIt() async throws {
        let items = (0..<201).map { Self.item("seed-\($0)", "Garden") }
        let seed = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(.init(items: items, nextStartIndex: nil)))
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "scope", fallback: nil, seed: seed
        ) { _, _, _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        // A failed explicit replacement cannot turn an unpublished overview into
        // a continuation tail. Cancellation must leave the first prefix uncommitted.
        let unpublished = FoundationBrowseModel()
        unpublished.configureCatalogPagination()
        unpublished.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "unpublished-scope", fallback: nil,
            seed: seed
        ) { _, _, _ in
            XCTFail("Unpublished membership must not continue through fallback")
            return .init(items: [], nextStartIndex: nil)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await unpublished.load(.initial) { _ in
                XCTFail("Cancelled initial demand must not fetch")
                return seed.page
            }
        }
        await cancelled.value
        XCTAssertFalse(unpublished.loaded)
        await unpublished.load(.refresh) { _ in throw FoundationLibraryError.network }
        XCTAssertNotNil(unpublished.errorMessage)
        await unpublished.load(.more) { _ in
            XCTFail("A failed refresh cannot authorize an unpublished continuation")
            return seed.page
        }
        XCTAssertFalse(unpublished.loaded)
        XCTAssertTrue(unpublished.items.isEmpty)
        XCTAssertEqual(unpublished.searchSeedOverflowCount, 1)

        await model.load(.initial) { _ in seed.page }
        await model.load(.refresh) { _ in throw FoundationLibraryError.network }
        XCTAssertEqual(model.items.count, 200)
        XCTAssertEqual(
            model.searchSeedOverflowCount, 1, "Failed replacement preserves the retained stream")
        await model.load(.more) { _ in
            XCTFail("The committed prefix may reveal retained overflow without a provider read")
            return seed.page
        }
        XCTAssertEqual(model.items.map(\.id), items.map(\.id))
        XCTAssertEqual(model.searchSeedOverflowCount, 0)
        await model.load(.refresh) { _ in
            .init(items: [Self.item("fresh", "Garden")], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["fresh"])
        XCTAssertEqual(model.searchSeedOverflowCount, 0)
        XCTAssertFalse(model.hasMorePages)
        let retired = FoundationBrowseModel()
        retired.configureCatalogPagination()
        retired.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "retired-scope", fallback: nil, seed: seed
        ) { _, _, _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        await retired.load(.initial) { _ in seed.page }
        XCTAssertEqual(retired.searchSeedOverflowCount, 1)
        retired.clearRetainedData()
        XCTAssertEqual(retired.searchSeedOverflowCount, 0)
        XCTAssertTrue(retired.items.isEmpty)
        XCTAssertFalse(retired.hasMorePages)
        await retired.load(.more) { _ in
            XCTFail("Retired overflow called provider")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertTrue(retired.items.isEmpty)
    }

    func testCategorySeedKeepsProviderOffsetAndRejectsBeyondRetainedLimit() throws {
        let items = (0..<FoundationCatalogComposition.itemLimit).map {
            Self.item("seed-\($0)", "Garden")
        }
        let seed = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(.init(items: items, nextStartIndex: 50)))
        XCTAssertEqual(seed.page.nextStartIndex, 50)
        XCTAssertEqual(seed.page.items.count, 200)
        XCTAssertEqual(seed.page.items + seed.remaining, items)
        XCTAssertNil(
            FoundationSearchResolver.categorySeed(
                .init(items: items + [Self.item("extra", "Garden")], nextStartIndex: nil)))
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let foreign = try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64))
        let prefix = Array(items.prefix(200))
        var foreignTail = Self.item("foreign", "Garden")
        foreignTail.catalogSource = foreign
        var foreignReference = Self.item("foreign-reference", "Garden")
        foreignReference.album = .init(id: "album", title: "Album", catalogSource: foreign)
        for tail in [
            Self.item("", "Garden"), Self.item(String(repeating: "x", count: 4097), "Garden"),
            Self.item("wrong-kind", "Garden", kind: .album), items[0], foreignTail,
            foreignReference,
        ] {
            XCTAssertNil(
                FoundationSearchResolver.categorySeed(
                    .init(items: prefix + [tail], nextStartIndex: nil), kind: .track, source: source
                ),
                "A malformed tail must prevent prefix admission")
        }
        let complete = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(
                .init(items: prefix + [Self.item("tail", "Garden")], nextStartIndex: nil),
                kind: .track, source: source))
        XCTAssertNil(
            FoundationSearchResolver.categorySeed(
                .init(items: complete.page.items + complete.remaining, nextStartIndex: nil),
                kind: .track, source: source,
                limits: .init(maximumBytes: complete.cost.bytes - 1)),
            "Whole retained-byte validation includes the tail")

    }

    @MainActor
    func testNativeSeedOverflowDoesNotSpendProviderPagesOrRewriteProviderCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = FoundationSearchOverflowFixtureClock()
        let cache = FoundationCatalogPageCache(
            scope: "synthetic-search-overflow", root: root, now: { clock.now() })
        let items = (0..<201).map {
            var item = Self.item("cache-\($0)", "Garden")
            item.isFavorite = false
            return item
        }
        let seed = try XCTUnwrap(
            FoundationSearchResolver.categorySeed(.init(items: items, nextStartIndex: 50)))
        // A real provider page has 50 raw rows and owns cursor 50. The combined
        // overview has 201 rows, but does not acquire that provider provenance.
        await cache.write(
            .init(items: Array(items.prefix(50)), nextStartIndex: 50), key: "overflow")
        let beforeRecord = await cache.read("overflow")
        let before = try XCTUnwrap(beforeRecord)
        let lease = FoundationSearchSeedLease(page: seed.page)
        let model = FoundationBrowseModel(catalogLimits: .init(maximumPages: 1))
        let actions = FoundationLibraryActions(
            sourceScope: String(repeating: "a", count: 64),
            read: { _ in nil }, write: { _, _ in }, mutateFavorite: { _, _ in })
        model.configureFavoriteObservations(actions)
        let first = try XCTUnwrap(items.first)
        await actions.setFavorite(for: first, isFavorite: true)
        model.configureCache(cache, key: "overflow")
        model.configureCatalogPagination()
        model.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "scope", fallback: nil, seed: seed,
            seedLease: lease
        ) { _, _, _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        await model.load(.more) { _ in
            XCTFail("More cannot skip the unpublished seed prefix")
            return seed.page
        }
        XCTAssertTrue(model.items.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(.initial) { _ in
                XCTFail("Cancelled initial demand must not call the provider")
                return seed.page
            }
        }
        await cancelled.value
        XCTAssertTrue(lease.pending)
        clock.advance()
        await model.loadPending { _ in
            XCTFail("The validated seed, rather than disk or a new read, owns initial demand")
            return seed.page
        }
        XCTAssertEqual(model.items.count, 200)
        XCTAssertFalse(lease.pending)
        XCTAssertEqual(actions.favoriteState(for: first, initial: false), true)
        let initialRecord = await cache.read("overflow")
        let initial = try XCTUnwrap(initialRecord)
        XCTAssertEqual(initial.savedAt, before.savedAt)
        XCTAssertEqual(initial.page.items, before.page.items)
        XCTAssertEqual(initial.page.nextStartIndex, 50)
        clock.advance()
        await model.load(.more) { _ in
            XCTFail("Retained overflow is not a provider read")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.count, 201)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.nextStartIndex, 50)
        XCTAssertEqual(actions.favoriteState(for: first, initial: false), true)
        let afterRecord = await cache.read("overflow")
        let after = try XCTUnwrap(afterRecord)
        XCTAssertEqual(after.savedAt, before.savedAt)
        XCTAssertEqual(after.page.items, before.page.items)
        XCTAssertEqual(after.page.nextStartIndex, before.page.nextStartIndex)
        // The only page permit remains available to the genuine original stream.
        var providerReads = 0
        await model.load(.more) { cursor in
            providerReads += 1
            XCTAssertEqual(cursor, 50)
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(providerReads, 1)
        XCTAssertNil(model.errorMessage)
        let continuedRecord = await cache.read("overflow")
        let continued = try XCTUnwrap(continuedRecord)
        XCTAssertEqual(continued.savedAt, before.savedAt)
        XCTAssertEqual(continued.page.items, before.page.items)
        XCTAssertEqual(continued.page.nextStartIndex, 50)
        clock.advance()
        model.request(.refresh)
        await model.loadPending { cursor in
            providerReads += 1
            XCTAssertEqual(cursor, 0)
            XCTAssertNil(lease.offer(eligible: true), "Refresh must retire the overview lease")
            return .init(items: Array(items.prefix(50)), nextStartIndex: nil)
        }
        XCTAssertEqual(providerReads, 2)
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(actions.favoriteState(for: first, initial: true), false)
        let refreshedRecord = await cache.read("overflow")
        let refreshed = try XCTUnwrap(refreshedRecord)
        XCTAssertGreaterThan(refreshed.savedAt, before.savedAt)
        XCTAssertEqual(refreshed.page.items, Array(items.prefix(50)))
        XCTAssertNil(refreshed.page.nextStartIndex)
        _ = await cache.invalidate()

        let bounded = FoundationBrowseModel(catalogLimits: .init(maximumBytes: seed.cost.bytes - 1))
        bounded.configureCatalogPagination()
        bounded.configureSearchContinuation(
            query: "Garden", kind: .track, metadataScope: "bounded-scope", fallback: nil, seed: seed
        ) { _, _, _ in
            XCTFail()
            return .init(items: [], nextStartIndex: nil)
        }
        await bounded.load(.initial) { _ in
            XCTFail("An over-budget whole seed must not publish a prefix")
            return seed.page
        }
        XCTAssertNotNil(bounded.errorMessage)
        XCTAssertTrue(bounded.items.isEmpty)
        XCTAssertEqual(bounded.searchSeedOverflowCount, 0)
    }

}

private final class FoundationSearchOverflowFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 0)
    func now() -> Date { lock.withLock { instant } }
    func advance() { lock.withLock { instant = instant.addingTimeInterval(1) } }
}
