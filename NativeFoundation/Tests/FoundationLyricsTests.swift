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
