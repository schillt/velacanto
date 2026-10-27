import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLyricsTests: XCTestCase {
    private let item = FoundationItem(
        id: "00000000000000000000000000000001", title: "Synthetic", subtitle: "",
        kind: .track, duration: nil)
    private let session = FoundationSession(
        serverURL: URL(string: "https://example.invalid/proxy/")!, accessToken: "synthetic",
        userID: "00000000000000000000000000000002", deviceID: "synthetic")

    func testGeneratedRequestAndTimedUntimedBlankMapping() async throws {
        for body in [
            #"{"Lyrics":[{"Text":"First","Start":0},{"Text":"Second","Start":10000000}]}"#,
            #"{"Lyrics":[{"Text":"First"},{"Text":"Second"}]}"#,
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(
                    request.url?.path, "/proxy/Audio/00000000000000000000000000000001/Lyrics")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
                return (Data(body.utf8), Self.response(request, status: 200))
            }
            let lyrics = try await library.lyrics(for: item)
            XCTAssertEqual(lyrics?.text, "First\nSecond")
        }
        for body in [#"{"Lyrics":[]}"#, #"{"Lyrics":[{"Text":" \n "}]}"#, "{}"] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (Data(body.utf8), Self.response(request, status: 200))
            }
            let lyrics = try await library.lyrics(for: item)
            XCTAssertNil(lyrics)
        }
    }

    func testMissingResourceDoesNotSwallowAuthenticationSecurityOrMalformedResponses() async throws
    {
        for (status, expected) in [
            (404, nil), (401, FoundationLibraryError.authentication), (403, .authentication),
            (302, .secureConnection), (500, .unavailable), (200, .invalidResponse),
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (Data("invalid".utf8), Self.response(request, status: status))
            }
            do {
                let lyrics = try await library.lyrics(for: item)
                XCTAssertNil(expected)
                XCTAssertNil(lyrics)
            } catch {
                XCTAssertEqual(error as? FoundationLibraryError, expected)
            }
        }
    }

    func testVisibleLoadDoesNotRepeatAndOnlyExplicitRetryRequestsAgain() async {
        let probe = Probe()
        let library = FoundationJellyfinLibrary(session: session) { request in
            let count = await probe.increment()
            return (
                Data(#"{"Lyrics":[{"Text":"Available"}]}"#.utf8),
                Self.response(request, status: count == 1 ? 500 : 200)
            )
        }
        let model = FoundationLyricsModel()
        await model.load(item: item, library: library) { true }
        XCTAssertEqual(model.state, .failed(.unavailable))
        await model.load(item: item, library: library) { true }
        var count = await probe.count
        XCTAssertEqual(count, 1)
        model.prepareRetry()
        await model.load(item: item, library: library) { true }
        XCTAssertEqual(model.state, .loaded(FoundationLyrics(text: "Available")))
        await model.load(item: item, library: library) { true }
        count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testDismissedOrObsoleteSelectionRejectsLateCompletion() async {
        for dismissed in [false, true] {
            let probe = Probe()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await probe.wait()
                return (
                    Data(#"{"Lyrics":[{"Text":"Obsolete"}]}"#.utf8),
                    Self.response(request, status: 200)
                )
            }
            let model = FoundationLyricsModel()
            var current = true
            let task = Task { await model.load(item: item, library: library) { current } }
            while !(await probe.waiting) { await Task.yield() }
            if dismissed {
                model.cancel()
                task.cancel()
            } else {
                current = false
            }
            await probe.finish()
            await task.value
            XCTAssertNotEqual(model.state, .loaded(FoundationLyrics(text: "Obsolete")))
        }
    }

    func testPendingVisibleLoadIsCoalescedAndCancellationStopsPublication() async {
        let probe = Probe()
        let library = FoundationJellyfinLibrary(session: session) { request in
            _ = await probe.increment()
            await probe.wait()
            return (
                Data(#"{"Lyrics":[{"Text":"Late"}]}"#.utf8), Self.response(request, status: 200)
            )
        }
        let model = FoundationLyricsModel()
        let task = Task { await model.load(item: item, library: library) { true } }
        while !(await probe.waiting) { await Task.yield() }
        await model.load(item: item, library: library) { true }
        let count = await probe.count
        XCTAssertEqual(count, 1)
        model.cancel()
        task.cancel()
        await probe.finish()
        await task.value
        XCTAssertEqual(model.state, .idle)
    }

    func testNonLyricsMissingRemainsFailureAndOversizedLyricsAreRejected() async {
        let missing = FoundationJellyfinLibrary(session: session) { request in
            (Data(), Self.response(request, status: 404))
        }
        do {
            _ = try await missing.albums(startIndex: 0)
            XCTFail("Catalog 404 must remain a failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let oversized = FoundationJellyfinLibrary(session: session) { request in
            (Data(repeating: 32, count: 262_145), Self.response(request, status: 200))
        }
        do {
            _ = try await oversized.lyrics(for: item)
            XCTFail("Oversized lyrics must not publish")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testActiveLineUsesTimestampThenIDIndependentOfSourceOrder() {
        let lyrics = FoundationLyrics(lines: [
            .init(id: 90, text: "Earlier", start: 2),
            .init(id: 2, text: "Later", start: 8),
            .init(id: 8, text: "Same earlier time", start: 2),
            .init(id: 12, text: "Same later time", start: 8),
            .init(id: -3, text: "", start: 12),
        ])
        XCTAssertEqual(lyrics.activeLine(at: 2, duration: 20), 90)
        XCTAssertEqual(lyrics.activeLine(at: 8, duration: 20), 12)
        XCTAssertEqual(lyrics.activeLine(at: 8, duration: 8), 90)
        XCTAssertEqual(lyrics.activeLine(at: 12, duration: 20), -3)
        XCTAssertEqual(lyrics.activeLine(at: 3, duration: 20), 90)
    }

    func testActiveLinePreservesUnknownAndNonfiniteDurationEligibility() {
        let lyrics = FoundationLyrics(lines: [
            .init(id: 0, text: "First", start: 0),
            .init(id: 1, text: "Second", start: 2),
            .init(id: 2, text: "Third", start: 5),
        ])
        for duration in [0, -1, -Double.infinity, Double.infinity] {
            XCTAssertEqual(lyrics.activeLine(at: 5, duration: duration), 2)
        }
        XCTAssertNil(lyrics.activeLine(at: 5, duration: .nan))
        XCTAssertEqual(lyrics.activeLine(at: 5, duration: 5), 1)
        XCTAssertEqual(lyrics.activeLine(at: 5, duration: Double(5).nextUp), 2)
        for elapsed in [-0.1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(lyrics.activeLine(at: elapsed, duration: 20))
        }
    }

    func testActiveLineInvalidStartsCannotHideEligibleBoundaryOrExtremeIDs() {
        let lyrics = FoundationLyrics(lines: [
            .init(id: Int.min, text: "First boundary", start: 0),
            .init(id: 1, text: "Untimed", start: nil),
            .init(id: 2, text: "Negative", start: -1),
            .init(id: 3, text: "Not finite", start: Double.nan),
            .init(id: 4, text: "Not finite", start: Double.infinity),
            .init(id: 5, text: "Not finite", start: -Double.infinity),
            .init(id: Int.max, text: "Same boundary", start: -0.0),
            .init(id: 6, text: "Next boundary", start: 0.5),
        ])
        XCTAssertEqual(lyrics.activeLine(at: 0, duration: 1), Int.max)
        XCTAssertEqual(lyrics.activeLine(at: 0.5, duration: 0.5), Int.max)
        XCTAssertEqual(lyrics.activeLine(at: 0.5, duration: Double(0.5).nextUp), 6)
        XCTAssertNil(FoundationLyrics(lines: []).activeLine(at: 0, duration: 1))
    }

    func testActiveLineMatchesPreviousSelectionContractAcrossLargeMixedTimeline() {
        let lines: [FoundationLyrics.Line] = (0..<1_024).map { index in
            let start: Double?
            switch index % 13 {
            case 0: start = nil
            case 1: start = Double.nan
            case 2: start = -Double.infinity
            case 3: start = Double.infinity
            case 4: start = -1
            default: start = Double((index * 11) % 128) / 4
            }
            return .init(
                id: (index * 37) % 1_024, text: index % 11 == 0 ? "" : "Synthetic line",
                start: start)
        }
        let lyrics = FoundationLyrics(lines: lines)
        // Two-pass reference preserves the pre-change selection contract. The explicit
        // cases above independently name its timestamp, ID and eligibility boundaries.
        func reference(elapsed: Double, duration: Double) -> Int? {
            guard elapsed.isFinite, elapsed >= 0 else { return nil }
            return lines.filter {
                guard let start = $0.start, start.isFinite, start >= 0 else { return false }
                return start <= elapsed && (duration <= 0 || start < duration)
            }.max {
                if $0.start == $1.start { return $0.id < $1.id }
                return ($0.start ?? 0) < ($1.start ?? 0)
            }?.id
        }
        for elapsed in [-1, -0.0, 0.01, 1.75, 3.5, 31.75, 32, 100, .nan, .infinity] {
            for duration in [0, -2, 3.5, 12, 32, .nan, .infinity, -.infinity] {
                XCTAssertEqual(
                    lyrics.activeLine(at: elapsed, duration: duration),
                    reference(elapsed: elapsed, duration: duration),
                    "elapsed=\(elapsed), duration=\(duration)")
            }
        }
    }

    func testTimingBoundariesDuplicatesBlankMarkersAndBackwardsPosition() {
        let lyrics = FoundationLyrics(lines: [
            .init(id: 0, text: "Later", start: 10),
            .init(id: 1, text: "First", start: 2),
            .init(id: 2, text: "Duplicate", start: 2),
            .init(id: 3, text: "", start: 5),
            .init(id: 4, text: "Untimed", start: nil),
            .init(id: 5, text: "Invalid", start: -1),
        ])
        XCTAssertNil(lyrics.activeLine(at: 1.99, duration: 20))
        XCTAssertEqual(lyrics.activeLine(at: 2, duration: 20), 2)
        XCTAssertEqual(lyrics.activeLine(at: 4.99, duration: 20), 2)
        XCTAssertEqual(lyrics.activeLine(at: 5, duration: 20), 3)
        XCTAssertEqual(lyrics.activeLine(at: 12, duration: 20), 0)
        XCTAssertEqual(lyrics.activeLine(at: 3, duration: 20), 2)
        XCTAssertNil(lyrics.activeLine(at: .nan, duration: 20))
    }

    func testTimedSeekTargetsRequireCurrentOccurrenceAndValidDuration() {
        let occurrence = UUID()
        let lyrics = FoundationLyrics(lines: [
            .init(id: 0, text: "Timed", start: 5),
            .init(id: 1, text: "Untimed", start: nil),
            .init(id: 2, text: "", start: 7),
            .init(id: 3, text: "Beyond", start: 90),
        ])
        XCTAssertEqual(
            lyrics.seekTarget(
                lineID: 0, entryID: occurrence, currentEntryID: occurrence, duration: 20), 5)
        XCTAssertNil(
            lyrics.seekTarget(lineID: 0, entryID: occurrence, currentEntryID: UUID(), duration: 20))
        XCTAssertNil(
            lyrics.seekTarget(
                lineID: 0, entryID: occurrence, currentEntryID: occurrence, duration: 0))
        for line in [1, 2, 3] {
            XCTAssertNil(
                lyrics.seekTarget(
                    lineID: line, entryID: occurrence, currentEntryID: occurrence, duration: 20))
        }
    }

    func testTickConversionUsesServerPositionsAndRetainsInvalidLinesAsText() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            let body =
                #"{"Metadata":{"Offset":10000000,"IsSynced":false},"Lyrics":[{"Text":"First","Start":12500000},{"Text":"Negative","Start":-1},{"Text":"Untimed"},{"Text":"","Start":30000000},{"Text":"Huge","Start":9223372036854775807}]}"#
            return (Data(body.utf8), Self.response(request, status: 200))
        }
        let boundedItem = FoundationItem(
            id: item.id, title: item.title, subtitle: "", kind: .track, duration: 60)
        let result = try await library.lyrics(for: boundedItem)
        let lyrics = try XCTUnwrap(result)
        XCTAssertEqual(lyrics.lines.map(\.start), [1.25, nil, nil, 3, nil])
        XCTAssertEqual(lyrics.lines.map(\.id), [0, 1, 2, 3, 4])
        XCTAssertEqual(lyrics.lines[1].text, "Negative")
        XCTAssertEqual(lyrics.activeLine(at: 3, duration: 60), 3)
    }

    func testRapidReopenKeepsOutgoingPresentationCancellationIndependent() async {
        let entry = FoundationQueueEntry(item: item)
        let outgoing = FoundationLyricsPresentation(entry: entry)
        let current = FoundationLyricsPresentation(entry: entry)
        XCTAssertNotEqual(outgoing.id, current.id)
        let library = FoundationJellyfinLibrary(session: session) { request in
            (Data(#"{"Lyrics":[{"Text":"Current"}]}"#.utf8), Self.response(request, status: 200))
        }
        await current.model.load(item: item, library: library) { true }
        outgoing.model.cancel()
        XCTAssertFalse(outgoing.model.isActive)
        await outgoing.model.load(item: item, library: library) { true }
        XCTAssertEqual(outgoing.model.state, .idle)
        XCTAssertEqual(current.model.state, .loaded(FoundationLyrics(text: "Current")))
    }

    nonisolated private static func response(_ request: URLRequest, status: Int) -> HTTPURLResponse
    {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private actor Probe {
        var count = 0
        var waiting: Bool { continuation != nil }
        private var continuation: CheckedContinuation<Void, Never>?
        func increment() -> Int {
            count += 1
            return count
        }
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }
}
