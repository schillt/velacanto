import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationPlaylistTests: XCTestCase {
    private let playlistID = "00000000000000000000000000000001"
    private let trackID = "00000000000000000000000000000002"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid")!,
            accessToken: "synthetic", userID: "00000000000000000000000000000003",
            deviceID: "synthetic-device")
    }
    private var track: FoundationItem {
        FoundationItem(id: trackID, title: "Fixture", subtitle: "", kind: .track, duration: 10)
    }

    func testDuplicateTracksKeepDistinctMembershipsAndRemovalUsesEntryID() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let data =
                request.httpMethod == "GET"
                ? Data(
                    """
                    {"Items":[
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"entry-one"},
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"entry-two"}],
                    "StartIndex":0,"TotalRecordCount":2}
                    """.utf8) : Data()
            return (data, Self.response(request))
        }
        let page = try await library.playlistEntries(id: playlistID, startIndex: 0)
        XCTAssertEqual(page.entries.map(\.id), ["entry-one", "entry-two"])
        XCTAssertEqual(page.entries.map(\.item.id), [trackID, trackID])
        try await library.removeEntry(from: playlistID, entryID: page.entries[1].id)
        let requestValue = await recorder.last()
        let request = try XCTUnwrap(requestValue)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "entryIds" })?.value, "entry-two")
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic") ?? true)
    }

    func testCreateIsPrivateRenamePreservesMembershipAndAddKeepsDuplicates() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let data =
                request.url?.path == "/Playlists"
                ? Data("{\"Id\":\"00000000000000000000000000000001\"}".utf8) : Data()
            return (data, Self.response(request))
        }
        let playlist = try await library.createPlaylist(name: "  Fixture  ")
        XCTAssertEqual(playlist.title, "Fixture")
        let createValue = await recorder.last()
        let create = try XCTUnwrap(createValue)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(create.httpBody)) as? [String: Any])
        XCTAssertEqual(body["IsPublic"] as? Bool, false)
        try await library.renamePlaylist(id: playlistID, name: "Changed")
        let renameValue = await recorder.last()
        let rename = try XCTUnwrap(renameValue)
        let renameBody = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(rename.httpBody)) as? [String: Any])
        XCTAssertEqual(renameBody["Name"] as? String, "Changed")
        XCTAssertNil(renameBody["Ids"])
        XCTAssertNil(renameBody["Users"])
        try await library.addTracks(to: playlistID, tracks: [track, track])
        let addValue = await recorder.last()
        let add = try XCTUnwrap(addValue)
        let query = URLComponents(url: try XCTUnwrap(add.url), resolvingAgainstBaseURL: false)?
            .queryItems
        XCTAssertEqual(query?.filter { $0.name == "ids" }.compactMap(\.value), [trackID, trackID])
    }

    func testPermissionFailureHasSafeCategoryAndDoesNotRetry() async {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data("private diagnostic".utf8), Self.response(request, status: 403))
        }
        do {
            try await library.deletePlaylist(id: playlistID)
            XCTFail("Expected permission failure")
        } catch {
            XCTAssertEqual(error as? FoundationLibraryError, .authentication)
        }
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testPlaylistPermissionsSeparateEditingFromDeletion() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            let json =
                request.url?.path.contains("/Users/") == true
                    && request.url?.path.hasPrefix("/Playlists") == true
                ? "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":true}"
                : "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Playlist\",\"Name\":\"Fixture\",\"CanDelete\":false}"
            return (Data(json.utf8), Self.response(request))
        }
        let permission = try await library.playlistPermissions(id: playlistID)
        XCTAssertTrue(permission.canEdit)
        XCTAssertFalse(permission.canDelete)
        XCTAssertEqual(permission.name, "Fixture")
    }

    func testBlankCreateRejectsBeforeSendingRequest() async {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request))
        }
        do {
            _ = try await library.createPlaylist(name: " \n ")
            XCTFail("Expected validation failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let count = await recorder.count
        XCTAssertEqual(count, 0)
    }

    func testMissingOccurrenceIdentityRejectsEditorPage() async {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":0,"TotalRecordCount":1}
                    """.utf8), Self.response(request)
            )
        }
        do {
            _ = try await library.playlistEntries(id: playlistID, startIndex: 0)
            XCTFail("Expected missing entry rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testReconciliationLimitStopsBeforeMutation() async {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    """
                    {"Items":[
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"one"},
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"two"}],
                    "StartIndex":0,"TotalRecordCount":3}
                    """.utf8), Self.response(request)
            )
        }
        do {
            _ = try await FoundationPlaylistSnapshot.load(
                id: playlistID, library: library, limit: 2)
            XCTFail("Expected finite verification limit")
        } catch { XCTAssertTrue(error is FoundationPlaylistError) }
        let count = await recorder.count
        XCTAssertEqual(count, 1)
    }

    func testRemovalChecksLaterPagesAndPreservesDuplicateSibling() async throws {
        let fixture = PlaylistRemovalFixture()
        let library = FoundationJellyfinLibrary(session: session) { request in
            let data = await fixture.data(request: request)
            return (data, Self.response(request))
        }
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        XCTAssertEqual(before.map(\.id), ["sibling", "target"])
        try await FoundationPlaylistMutation.remove(
            playlistID: playlistID, entry: before[1], library: library)
        let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        XCTAssertEqual(after.map(\.id), ["sibling"])
    }

    func testRemovalRejectsSuccessfulAckWhenLaterPageStillContainsTarget() async throws {
        let fixture = PlaylistRemovalFixture(ignoreRemoval: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            let data = await fixture.data(request: request)
            return (data, Self.response(request))
        }
        let before = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        do {
            try await FoundationPlaylistMutation.remove(
                playlistID: playlistID, entry: before[1], library: library)
            XCTFail("Acknowledgement alone must not confirm removal")
        } catch { XCTAssertTrue(error is FoundationPlaylistError) }
    }

    @MainActor
    func testCancelledLateCompletionCannotReplaceNewOperationState() async {
        let operation = FoundationPlaylistOperation()
        let suspended = PlaylistSuspension()
        operation.run { await suspended.wait() }
        await Task.yield()
        operation.cancel()
        operation.run { throw FoundationLibraryError.authentication }
        for _ in 0..<10 { await Task.yield() }
        let message = operation.message
        await suspended.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(operation.succeeded)
        XCTAssertFalse(operation.isPending)
        XCTAssertEqual(operation.message, message)
        XCTAssertTrue(message?.contains("permissions") ?? false)
    }

    private static func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private actor PlaylistRecorder {
    private var requests: [URLRequest] = []
    var count: Int { requests.count }
    func append(_ request: URLRequest) { requests.append(request) }
    func last() -> URLRequest? { requests.last }
}

private actor PlaylistSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private actor PlaylistRemovalFixture {
    private var removed = false
    let ignoreRemoval: Bool
    init(ignoreRemoval: Bool = false) { self.ignoreRemoval = ignoreRemoval }
    func data(request: URLRequest) -> Data {
        if request.httpMethod == "DELETE" {
            removed = !ignoreRemoval
            return Data()
        }
        let offset =
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "startIndex" })?.value ?? "0"
        let entry = offset == "0" ? "sibling" : "target"
        let total = removed ? 1 : 2
        return Data(
            """
            {"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"\(entry)"}],
            "StartIndex":\(offset),"TotalRecordCount":\(total)}
            """.utf8)
    }
}
