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
        XCTAssertEqual(page.entries.map(\.id), ["0:entry-one", "1:entry-two"])
        XCTAssertEqual(page.entries.map(\.item.id), [trackID, trackID])
        try await library.removeEntry(from: playlistID, entryID: page.entries[1].mutationID)
        let requestValue = await recorder.last()
        let request = try XCTUnwrap(requestValue)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "entryIds" })?.value, "entry-two")
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic") ?? true)
    }

    func testCreateIsPrivateRenamePreservesMembershipAndAddUsesGeneratedEncoding() async throws {
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

    func testCreateRejectsAcknowledgementWithoutAuthoritativePlaylist() async {
        let library = FoundationJellyfinLibrary(session: session) { request in
            if request.httpMethod == "POST" {
                return (
                    Data("{\"Id\":\"00000000000000000000000000000001\"}".utf8),
                    Self.response(request)
                )
            }
            return (Data(), Self.response(request, status: 404))
        }
        do {
            try await FoundationPlaylistMutation.create(name: "Fixture", library: library)
            XCTFail("Acknowledgement alone must not confirm creation")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
    }

    func testCreateConfirmsReturnedIdentityAndRequestedName() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let json: String
            if request.httpMethod == "POST" {
                json = "{\"Id\":\"00000000000000000000000000000001\"}"
            } else if request.url?.path.contains("/Users/") == true {
                json = "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":true}"
            } else {
                json =
                    "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Playlist\",\"Name\":\"Fixture\",\"CanDelete\":true}"
            }
            return (Data(json.utf8), Self.response(request))
        }
        try await FoundationPlaylistMutation.create(name: " Fixture ", library: library)
        let confirmedRequest = await recorder.last()
        XCTAssertEqual(confirmedRequest?.url?.path, "/Items/\(playlistID)")
        let count = await recorder.count
        XCTAssertEqual(count, 3)
    }

    func testDeleteRejectsAcknowledgementWhenTargetRemainsOnLaterPage() async {
        let library = FoundationJellyfinLibrary(session: session) { request in
            guard request.httpMethod == "GET" else { return (Data(), Self.response(request)) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let later = query?.first(where: { $0.name == "startIndex" })?.value == "1"
            let id = later ? "00000000000000000000000000000001" : "00000000000000000000000000000004"
            let json =
                "{\"Items\":[{\"Id\":\"\(id)\",\"Type\":\"Playlist\"}],\"StartIndex\":\(later ? 1 : 0),\"TotalRecordCount\":2}"
            return (Data(json.utf8), Self.response(request))
        }
        do {
            try await FoundationPlaylistMutation.delete(id: playlistID, library: library)
            XCTFail("Acknowledgement alone must not confirm deletion")
        } catch { XCTAssertTrue(error is FoundationPlaylistError) }
    }

    func testDeleteCompletesOnlyAfterFullEnumerationProvesAbsence() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            guard request.httpMethod == "GET" else { return (Data(), Self.response(request)) }
            let offset =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "startIndex" })?.value ?? "0"
            let id =
                offset == "0"
                ? "00000000000000000000000000000004" : "00000000000000000000000000000005"
            return (
                Data(
                    """
                    {"Items":[{"Id":"\(id)","Type":"Playlist"}],"StartIndex":\(offset),"TotalRecordCount":2}
                    """.utf8), Self.response(request)
            )
        }
        try await FoundationPlaylistMutation.delete(id: playlistID, library: library)
        let count = await recorder.count
        XCTAssertEqual(count, 3)
        let last = await recorder.last()
        XCTAssertEqual(
            URLComponents(url: try XCTUnwrap(last?.url), resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "startIndex" })?.value, "1")
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
        XCTAssertEqual(before.map(\.mutationID), ["sibling", "target"])
        var displayedTrack = before[1].item
        displayedTrack.title = "Previously loaded title"
        let selected = FoundationPlaylistEntry(
            id: before[1].id, mutationID: before[1].mutationID, item: displayedTrack)
        try await FoundationPlaylistMutation.remove(
            playlistID: playlistID, entry: selected, library: library)
        let after = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        XCTAssertEqual(after.map(\.mutationID), ["sibling"])
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

    func testAmbiguousServerIDsRenderOccurrencesAndPreventRemoval() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    """
                    {"Items":[
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"same"},
                    {"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"same"}],
                    "StartIndex":0,"TotalRecordCount":2}
                    """.utf8), Self.response(request)
            )
        }
        let snapshot = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        XCTAssertEqual(snapshot.map(\.id), ["0:same", "1:same"])
        XCTAssertTrue(FoundationPlaylistSnapshot.hasAmbiguousMemberships(snapshot))
        do {
            try await FoundationPlaylistMutation.remove(
                playlistID: playlistID, entry: snapshot[1], library: library)
            XCTFail("Ambiguous membership must not be removed")
        } catch { XCTAssertTrue(error is FoundationPlaylistError) }
        let last = await recorder.last()
        XCTAssertEqual(last?.httpMethod, "GET")
        let count = await recorder.count
        XCTAssertEqual(count, 2)
    }

    func testAlreadyPresentTrackIsHonestWithoutSendingMutation() async {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let json: String
            if request.url?.path.hasPrefix("/Playlists") == true
                && request.url?.path.contains("/Users/") == true
            {
                json = "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":true}"
            } else if request.url?.path.hasPrefix("/Items/") == true {
                json =
                    "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Playlist\",\"Name\":\"Fixture\",\"CanDelete\":true}"
            } else {
                json = """
                    {"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"present"}],
                    "StartIndex":0,"TotalRecordCount":1}
                    """
            }
            return (Data(json.utf8), Self.response(request))
        }
        do {
            try await FoundationPlaylistMutation.add(
                playlistID: playlistID, track: track, library: library)
            XCTFail("Already-present track must not be claimed added")
        } catch {
            XCTAssertEqual(
                (error as? FoundationPlaylistError)?.errorDescription,
                FoundationPlaylistError.alreadyPresent.errorDescription)
        }
        let last = await recorder.last()
        XCTAssertEqual(last?.httpMethod, "GET")
        let count = await recorder.count
        XCTAssertEqual(count, 3)
    }

    private var album: FoundationItem {
        FoundationItem(
            id: "00000000000000000000000000000005", title: "Fixture Album", subtitle: "",
            kind: .album, duration: nil)
    }

    func testAlbumAdditionLoadsAllPagesSkipsPresentAndBatchesInOrder() async throws {
        let fixture = PlaylistAlbumFixture(count: 102, existing: [1])
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let result = try await FoundationPlaylistMutation.add(
            playlistID: playlistID, source: album, library: library)
        XCTAssertEqual(result.added, 101)
        XCTAssertEqual(result.alreadyPresent, 1)
        let batches = await fixture.batches
        XCTAssertEqual(batches.map(\.count), [100, 1])
        XCTAssertEqual(batches.flatMap { $0 }, (2...102).map(PlaylistAlbumFixture.id))
    }

    func testAlbumPartialFailureIsTruthfulAndDoesNotRetry() async {
        let fixture = PlaylistAlbumFixture(count: 101, failBatch: 2)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        do {
            _ = try await FoundationPlaylistMutation.add(
                playlistID: playlistID, source: album, library: library)
            XCTFail("Partial addition must not claim completion")
        } catch {
            XCTAssertEqual(
                (error as? FoundationPlaylistError)?.errorDescription,
                FoundationPlaylistError.partialAddition.errorDescription)
        }
        let batches = await fixture.batches
        XCTAssertEqual(batches.map(\.count), [100, 1])
    }

    func testAlbumCancellationDuringExpansionPreventsMutation() async {
        let fixture = PlaylistAlbumFixture(count: 101, cancelExpansion: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        do {
            _ = try await FoundationPlaylistMutation.add(
                playlistID: playlistID, source: album, library: library)
            XCTFail("Cancelled expansion must not write")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .cancelled) }
        let batches = await fixture.batches
        XCTAssertTrue(batches.isEmpty)
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

    @MainActor
    func testAdditionInvalidatesOnlyItsPlaylistAndAccount() async throws {
        let fixture = PlaylistAlbumFixture(count: 2)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let changes = FoundationPlaylistChanges()
        let otherAccount = FoundationPlaylistChanges()
        let result = try await changes.add(playlistID: playlistID, source: album, library: library)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(changes.revision(for: playlistID), 1)
        XCTAssertEqual(changes.revision(for: "another-playlist"), 0)
        XCTAssertEqual(otherAccount.revision(for: playlistID), 0)

        do {
            _ = try await changes.add(playlistID: playlistID, source: album, library: library)
            XCTFail("Already-present tracks should not trigger another invalidation")
        } catch {
            XCTAssertEqual(error as? FoundationPlaylistError, .alreadyPresent)
        }
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testPartialAdditionInvalidatesWithoutClaimingSuccess() async {
        let fixture = PlaylistAlbumFixture(count: 101, failBatch: 2)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let changes = FoundationPlaylistChanges()
        do {
            _ = try await changes.add(playlistID: playlistID, source: album, library: library)
            XCTFail("Partial addition must remain a failure")
        } catch {
            XCTAssertEqual(error as? FoundationPlaylistError, .partialAddition)
        }
        XCTAssertEqual(changes.revision(for: playlistID), 1)
        let batches = await fixture.batches
        XCTAssertEqual(batches.map(\.count), [100, 1])
    }

    @MainActor
    func testCancellationInvalidatesConservativelyWithoutMutationRetry() async {
        let fixture = PlaylistAlbumFixture(count: 101, cancelExpansion: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let changes = FoundationPlaylistChanges()
        do {
            _ = try await changes.add(playlistID: playlistID, source: album, library: library)
            XCTFail("Cancellation must remain visible")
        } catch {
            XCTAssertEqual(error as? FoundationLibraryError, .cancelled)
        }
        XCTAssertEqual(changes.revision(for: playlistID), 1)
        let batches = await fixture.batches
        XCTAssertTrue(batches.isEmpty)
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

private actor PlaylistAlbumFixture {
    let count: Int
    let failBatch: Int?
    let cancelExpansion: Bool
    private var members: [String]
    private(set) var batches: [[String]] = []

    init(count: Int, existing: [Int] = [], failBatch: Int? = nil, cancelExpansion: Bool = false) {
        self.count = count
        self.failBatch = failBatch
        self.cancelExpansion = cancelExpansion
        members = existing.map(Self.id)
    }

    nonisolated static func id(_ number: Int) -> String {
        String(format: "%032x", number + 100)
    }

    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = Int(query.first(where: { $0.name == "startIndex" })?.value ?? "0") ?? 0
        let json: String
        if url.path.contains("/Users/"), url.path.hasPrefix("/Playlists") {
            json = "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":true}"
        } else if url.path == "/Items/00000000000000000000000000000001" {
            json =
                "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Playlist\",\"Name\":\"Fixture\"}"
        } else if request.httpMethod == "POST" {
            let ids = query.filter { $0.name == "ids" }.compactMap(\.value)
            batches.append(ids)
            if batches.count == failBatch { throw URLError(.networkConnectionLost) }
            members.append(contentsOf: ids)
            json = ""
        } else {
            let isAlbum = query.contains { $0.name == "parentId" }
            if isAlbum, offset > 0, cancelExpansion { throw CancellationError() }
            let ids = isAlbum ? (1...count).map(Self.id) : members
            let page = Array(ids.dropFirst(offset).prefix(100))
            let rows = page.map { id in
                var row = ["Id": id, "Type": "Audio"]
                if !isAlbum { row["PlaylistItemId"] = id }
                return row
            }
            let object: [String: Any] = [
                "Items": rows, "StartIndex": offset, "TotalRecordCount": ids.count,
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            return (
                data,
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
        return (
            Data(json.utf8),
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}
