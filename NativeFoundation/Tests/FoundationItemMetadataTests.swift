import Foundation
import JellyfinAPI
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationItemMetadataTests: XCTestCase {
    private let item = FoundationItem(
        id: "00000000000000000000000000000001", title: "Synthetic", subtitle: "",
        kind: .track, duration: nil)
    private let session = FoundationSession(
        serverURL: URL(string: "https://example.invalid/proxy/")!, accessToken: "synthetic",
        userID: "00000000000000000000000000000002", deviceID: "synthetic")

    func testSingleItemReadPreservesDistinctRolesWithoutArtistLinks() async throws {
        let body =
            #"{"Id":"00000000000000000000000000000001","Type":"Audio","People":[{"Name":" Person ","Type":"Composer","Id":"private-person"},{"Name":"Person","Type":"Engineer","Role":"Mix engineering"},{"Name":"Person","Type":"Composer"},{"Name":" ","Type":"Producer"},{"Name":"Guest","Role":"Guitar"}],"ProductionYear":2024,"Genres":[" Rock ","Rock","Jazz"]}"#
        let library = FoundationJellyfinLibrary(session: session) { request in
            XCTAssertFalse(FoundationRequestIntent.isPlayback)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/Items/00000000000000000000000000000001")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(
                query?.first(where: { $0.name == "userId" })?.value,
                "00000000000000000000000000000002")
            return (Data(body.utf8), Self.response(request))
        }
        let loaded = try await FoundationRequestIntent.$isPlayback.withValue(true) {
            try await library.itemMetadata(for: item)
        }
        let result = try XCTUnwrap(loaded)
        XCTAssertEqual(
            result.credits,
            [
                .init(name: "Person", role: "Composer", detail: nil),
                .init(name: "Person", role: "Engineer", detail: "Mix engineering"),
                .init(name: "Guest", role: "Contributor", detail: "Guitar"),
            ])
        XCTAssertEqual(result.year, 2024)
        XCTAssertEqual(result.genres, ["Rock", "Jazz"])
        XCTAssertFalse(String(describing: result).contains("private-person"))
    }

    func testMissingMetadataIsEmptyAndRejectsWrongItemOrKind() async throws {
        for body in [
            #"{"Id":"00000000000000000000000000000001","Type":"Audio"}"#,
            #"{"Id":"00000000000000000000000000000009","Type":"Audio"}"#,
            #"{"Id":"00000000000000000000000000000001","Type":"MusicAlbum"}"#,
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (Data(body.utf8), Self.response(request))
            }
            if body.contains("00000000000000000000000000000009") || body.contains("MusicAlbum") {
                do {
                    _ = try await library.itemMetadata(for: item)
                    XCTFail("Expected identity rejection")
                } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
            } else {
                let result = try await library.itemMetadata(for: item)
                XCTAssertEqual(result?.isEmpty, true)
            }
        }
    }

    func testDisplayBoundsAndNoInventedYear() throws {
        let people = Array(
            repeating: ["Name": String(repeating: "x", count: 300), "Type": "Composer"], count: 129)
        let data = try JSONSerialization.data(withJSONObject: [
            "People": people, "ProductionYear": -1,
            "Genres": (0..<40).map { "Genre \($0)" },
        ])
        let result = FoundationItemMetadata.jellyfin(
            try JSONDecoder().decode(BaseItemDto.self, from: data))
        XCTAssertEqual(result.credits.count, 1)
        XCTAssertEqual(result.credits.first?.name.count, 256)
        XCTAssertTrue(result.hasAdditionalCredits)
        XCTAssertEqual(result.genres.count, 32)
        XCTAssertTrue(result.hasAdditionalGenres)
        XCTAssertNil(result.year)
    }

    func testFailuresRemainFailuresRatherThanMissingCredits() async throws {
        for status in [401, 500] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (
                    Data("{}".utf8),
                    HTTPURLResponse(
                        url: request.url!, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
                )
            }
            do {
                _ = try await library.itemMetadata(for: item)
                XCTFail("Expected failure, not empty credits")
            } catch {
                XCTAssertEqual(
                    error as? FoundationLibraryError, status == 401 ? .authentication : .unavailable
                )
            }
        }
    }

    func testCancelledLoadCannotReturnOptionalMetadata() async throws {
        let gate = Gate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await gate.wait()
            return (
                Data(#"{"Id":"00000000000000000000000000000001","Type":"Audio"}"#.utf8),
                Self.response(request)
            )
        }
        let item = item
        let task = Task { try await library.itemMetadata(for: item) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.finish()
        do {
            _ = try await task.value
            XCTFail("Cancelled optional work must not publish")
        } catch {
            XCTAssertEqual(FoundationLibraryError.category(error), .cancelled)
        }
    }

    func testMetadataScopeSeparatesAccountsAndLibrariesWithoutCredentials() {
        let first = FoundationJellyfinLibrary(session: session)
        let second = FoundationJellyfinLibrary(
            session: FoundationSession(
                serverURL: session.serverURL, accessToken: "other-secret", userID: "other-user",
                deviceID: "synthetic"))
        XCTAssertNotEqual(first.metadataScopeID, second.metadataScopeID)
        XCTAssertNotEqual(first.metadataScopeID, first.scoped(to: "other-library").metadataScopeID)
        XCTAssertFalse(first.metadataScopeID.contains(session.accessToken))
        XCTAssertFalse(first.metadataScopeID.contains("example.invalid"))
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        func wait() async {
            await withCheckedContinuation {
                continuation = $0
                started?.resume()
                started = nil
            }
        }
        func waitUntilStarted() async {
            if continuation != nil { return }
            await withCheckedContinuation { started = $0 }
        }
        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }

    nonisolated private static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
    }
}
