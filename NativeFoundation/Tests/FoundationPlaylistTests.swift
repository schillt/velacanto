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

    @MainActor
    func testContextRemovalUsesSelectedMembershipAndInvalidatesPlaylist() async throws {
        let fixture = PlaylistRemovalFixture()
        let library = FoundationJellyfinLibrary(session: session) { request in
            if request.url!.path.contains("/Users/") {
                return (
                    Data(#"{"UserId":"00000000000000000000000000000003","CanEdit":true}"#.utf8),
                    Self.response(request)
                )
            }
            if request.url!.path.hasPrefix("/Items/") {
                return (
                    Data(
                        #"{"Id":"00000000000000000000000000000001","Type":"Playlist","Name":"Fixture"}"#
                            .utf8), Self.response(request)
                )
            }
            return (await fixture.data(request: request), Self.response(request))
        }
        let changes = FoundationPlaylistChanges()
        var selected = track
        selected.playlistEntryID = "target"
        try await changes.remove(playlistID: playlistID, track: selected, library: library)
        let remaining = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        XCTAssertEqual(remaining.map(\.mutationID), ["sibling"])
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testContextRemovalRejectsReadOnlyPermissionWithoutMutation() async throws {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let json =
                request.url!.path.contains("/Users/")
                ? #"{"UserId":"00000000000000000000000000000003","CanEdit":false}"#
                : #"{"Id":"00000000000000000000000000000001","Type":"Playlist","Name":"Fixture"}"#
            return (Data(json.utf8), Self.response(request))
        }
        let changes = FoundationPlaylistChanges()
        var selected = track
        selected.playlistEntryID = "target"
        do {
            try await changes.remove(playlistID: playlistID, track: selected, library: library)
            XCTFail("Read-only playlists must not be mutated")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .readOnly) }
        XCTAssertEqual(changes.revision(for: playlistID), 0)
        let last = await recorder.last()
        XCTAssertEqual(last?.httpMethod, "GET")
        let count = await recorder.count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testContextRemovalRequiresMembershipIdentityWithoutAnyRequest() async {
        let recorder = PlaylistRecorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request))
        }
        let changes = FoundationPlaylistChanges()
        do {
            try await changes.remove(playlistID: playlistID, track: track, library: library)
            XCTFail("A song ID cannot stand in for its playlist membership")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .changed) }
        let count = await recorder.count
        XCTAssertEqual(count, 0)
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

    @MainActor
    func testEditorProjectionRetainsExactMutationIdentityAndCanonicalRepeats() {
        var first = track
        first.album = .init(id: "album", title: "Album")
        first.trackNumber = 1
        var alternate = FoundationItem(
            id: "alternate", title: first.title, subtitle: first.subtitle, kind: .track,
            duration: 10)
        alternate.album = first.album
        alternate.trackNumber = 1
        let entries = [
            FoundationPlaylistEntry(id: "one", mutationID: "remove-one", item: first),
            FoundationPlaylistEntry(id: "other", mutationID: "remove-other", item: alternate),
            FoundationPlaylistEntry(id: "repeat", mutationID: "remove-repeat", item: first),
        ]
        var showDuplicates = false
        let changes = FoundationPlaylistChanges { items, albumID in
            FoundationAlbumTrackPolicy.visibleTracks(
                items, albumID: albumID, showDuplicates: showDuplicates)
        }
        let visible = changes.visibleEntries(entries)
        XCTAssertEqual(visible.map(\.id), ["one", "repeat"])
        XCTAssertEqual(visible.map(\.mutationID), ["remove-one", "remove-repeat"])
        XCTAssertEqual(visible.map { $0.item }, [first, first])
        XCTAssertEqual(entries.count, 3)
        showDuplicates = true
        XCTAssertEqual(changes.visibleEntries(entries).map(\.mutationID), entries.map(\.mutationID))
    }

    @MainActor
    func testAlbumAdditionProjectsAlternateCopiesBeforeBatchesAndHonorsLivePreference() async throws
    {
        var showDuplicates = true
        let changes = FoundationPlaylistChanges { items, albumID in
            FoundationAlbumTrackPolicy.visibleTracks(
                items, albumID: albumID, showDuplicates: showDuplicates)
        }
        // Change after constructing the account owner: the commit must read the live preference.
        showDuplicates = false
        let fixture = PlaylistAlbumFixture(count: 3, duplicateAlbumTracks: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let result = try await changes.add(playlistID: playlistID, source: album, library: library)
        XCTAssertEqual(result.added, 2)
        let hiddenBatches = await fixture.batches
        XCTAssertEqual(
            hiddenBatches.flatMap { $0 }, [PlaylistAlbumFixture.id(1), PlaylistAlbumFixture.id(3)])
        showDuplicates = true
        let restored = try await changes.add(
            playlistID: playlistID, source: album, library: library)
        XCTAssertEqual(restored.added, 1)
        let restoredBatches = await fixture.batches
        XCTAssertEqual(restoredBatches.last, [PlaylistAlbumFixture.id(2)])
    }

    @MainActor
    func testBulkRemovalUsesStableMembershipsAndOnlyTwoSnapshots() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 205)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        await fixture.resetCounts()
        let changes = FoundationPlaylistChanges()
        // Keep the unselected first occurrence of the same song as the second entry.
        let selected = [original[1], original[100], original[201]].map {
            FoundationPlaylistEntry(
                id: "stale-offset:" + $0.id, mutationID: $0.mutationID, item: $0.item)
        }
        try await changes.remove(playlistID: playlistID, entries: selected, library: library)
        let remaining = await fixture.membershipIDs
        XCTAssertEqual(remaining.count, 202)
        XCTAssertTrue(remaining.contains("entry-0"))
        XCTAssertFalse(remaining.contains("entry-1"))
        let reads = await fixture.snapshotReads
        let permissions = await fixture.permissionReads
        let writes = await fixture.removalRequests
        XCTAssertEqual(reads, 6)  // Three pages before and three after, not per selected song.
        XCTAssertEqual(permissions, 2)
        XCTAssertEqual(writes, ["entry-1", "entry-100", "entry-201"])
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testBulkRemovalReadOnlyAndHiddenSelectionsNeverWrite() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 3, canEdit: false)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let entries = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        await fixture.resetCounts()
        let changes = FoundationPlaylistChanges()
        do {
            try await changes.remove(playlistID: playlistID, entries: entries, library: library)
            XCTFail("Read-only selection must not be mutated")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .readOnly) }
        let writes = await fixture.removalRequests
        let reads = await fixture.snapshotReads
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(changes.revision(for: playlistID), 0)

        let editable = PlaylistBulkRemovalFixture(count: 3)
        let editableLibrary = FoundationJellyfinLibrary(session: session) { request in
            try await editable.response(request)
        }
        let projected = FoundationPlaylistChanges { _, _ in [] }
        do {
            try await projected.remove(
                playlistID: playlistID, entries: entries, library: editableLibrary)
            XCTFail("Hidden tracks must not be manageable")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .changed) }
        let hiddenWrites = await editable.removalRequests
        XCTAssertTrue(hiddenWrites.isEmpty)
    }

    @MainActor
    func testBulkRemovalRejectsStaleSongPairingAndDuplicateSelection() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 3)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let entries = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        let stale = FoundationPlaylistEntry(
            id: entries[0].id, mutationID: entries[0].mutationID, item: entries[2].item)
        do {
            try await changes.remove(playlistID: playlistID, entries: [stale], library: library)
            XCTFail("An entry ID must still identify the selected song")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .changed) }
        do {
            try await changes.remove(
                playlistID: playlistID, entries: [entries[0], entries[0]], library: library)
            XCTFail("Duplicate membership selection must not send duplicate deletes")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .changed) }
        let writes = await fixture.removalRequests
        XCTAssertTrue(writes.isEmpty)
    }

    @MainActor
    func testBulkRemovalPartialWriteInvalidatesWithoutRetry() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 3, failRemoval: 2)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let entries = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        do {
            try await changes.remove(playlistID: playlistID, entries: entries, library: library)
            XCTFail("A partial removal must not claim success")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .partialRemoval) }
        let writes = await fixture.removalRequests
        let remaining = await fixture.membershipIDs
        XCTAssertEqual(writes, ["entry-0", "entry-1"])
        XCTAssertEqual(remaining, ["entry-1", "entry-2"])
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testBulkRemovalCancellationAfterSentWriteInvalidatesAndStops() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 3, cancelAfterRemoval: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let entries = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        do {
            try await changes.remove(playlistID: playlistID, entries: entries, library: library)
            XCTFail("Cancellation cannot claim rollback")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .cancelled) }
        let writes = await fixture.removalRequests
        let remaining = await fixture.membershipIDs
        XCTAssertEqual(writes, ["entry-0"])
        XCTAssertEqual(remaining, ["entry-1", "entry-2"])
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testBulkRemovalRejectsLostUnselectedMembership() async throws {
        let fixture = PlaylistBulkRemovalFixture(count: 3, removeUnselected: true)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let entries = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        do {
            try await changes.remove(
                playlistID: playlistID, entries: [entries[0]], library: library)
            XCTFail("Removal must preserve unselected memberships")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .partialRemoval) }
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testBulkAdditionUsesOneActionForMultipleSelectedSongs() async throws {
        let fixture = PlaylistAlbumFixture(count: 102, existing: [1])
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let selected = (1...102).map {
            FoundationItem(
                id: PlaylistAlbumFixture.id($0), title: "Track", subtitle: "", kind: .track,
                duration: 10)
        }
        let changes = FoundationPlaylistChanges()
        let result = try await changes.add(
            playlistID: playlistID, tracks: selected + [selected[1]], library: library)
        XCTAssertEqual(result.added, 101)
        XCTAssertEqual(result.alreadyPresent, 2)
        let batches = await fixture.batches
        XCTAssertEqual(batches.map(\.count), [100, 1])
        XCTAssertEqual(batches.flatMap { $0 }, (2...102).map(PlaylistAlbumFixture.id))
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    @MainActor
    func testBulkAdditionProjectsHiddenCopiesBeforeAnyWrite() async throws {
        let fixture = PlaylistAlbumFixture(count: 3)
        let library = FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
        let selected = (1...3).map {
            FoundationItem(
                id: PlaylistAlbumFixture.id($0), title: "Track", subtitle: "", kind: .track,
                duration: 10)
        }
        let changes = FoundationPlaylistChanges { items, _ in
            items.filter { $0.id != PlaylistAlbumFixture.id(2) }
        }
        let result = try await changes.add(
            playlistID: playlistID, tracks: selected, library: library)
        XCTAssertEqual(result.added, 2)
        let batches = await fixture.batches
        XCTAssertEqual(
            batches.flatMap { $0 }, [PlaylistAlbumFixture.id(1), PlaylistAlbumFixture.id(3)])
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
    let duplicateAlbumTracks: Bool
    private var members: [String]
    private(set) var batches: [[String]] = []

    init(
        count: Int, existing: [Int] = [], failBatch: Int? = nil, cancelExpansion: Bool = false,
        duplicateAlbumTracks: Bool = false
    ) {
        self.count = count
        self.duplicateAlbumTracks = duplicateAlbumTracks
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
                var row: [String: Any] = ["Id": id, "Type": "Audio"]
                if isAlbum, duplicateAlbumTracks {
                    let number = id == Self.id(3) ? 2 : 1
                    row["Name"] = number == 1 ? "Same Song" : "Next Song"
                    row["IndexNumber"] = number
                    row["ParentIndexNumber"] = 1
                }
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

private actor PlaylistBulkRemovalFixture {
    private var members: [(membership: String, song: String)]
    let canEdit: Bool
    let failRemoval: Int?
    let cancelAfterRemoval: Bool
    let removeUnselected: Bool
    private(set) var snapshotReads = 0
    private(set) var permissionReads = 0
    private(set) var removalRequests: [String] = []
    var membershipIDs: [String] { members.map(\.membership) }

    init(
        count: Int, canEdit: Bool = true, failRemoval: Int? = nil,
        cancelAfterRemoval: Bool = false, removeUnselected: Bool = false
    ) {
        self.canEdit = canEdit
        self.failRemoval = failRemoval
        self.cancelAfterRemoval = cancelAfterRemoval
        self.removeUnselected = removeUnselected
        members = (0..<count).map { index in
            ("entry-\(index)", PlaylistAlbumFixture.id(index == 1 ? 0 : index))
        }
    }

    func resetCounts() {
        snapshotReads = 0
        permissionReads = 0
        removalRequests = []
    }

    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let data: Data
        if url.path.contains("/Users/"), url.path.hasPrefix("/Playlists") {
            permissionReads += 1
            data = Data(
                "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":\(canEdit)}".utf8)
        } else if url.path == "/Items/00000000000000000000000000000001" {
            permissionReads += 1
            data = Data(
                #"{"Id":"00000000000000000000000000000001","Type":"Playlist","Name":"Fixture"}"#
                    .utf8)
        } else if request.httpMethod == "DELETE" {
            let id = query.first { $0.name == "entryIds" }!.value!
            removalRequests.append(id)
            if removalRequests.count == failRemoval { throw URLError(.networkConnectionLost) }
            members.removeAll { $0.membership == id }
            if removeUnselected, !members.isEmpty { members.removeLast() }
            if cancelAfterRemoval { throw CancellationError() }
            data = Data()
        } else {
            snapshotReads += 1
            let offset = Int(query.first { $0.name == "startIndex" }?.value ?? "0") ?? 0
            let rows = members.dropFirst(offset).prefix(100).map {
                ["Id": $0.song, "Type": "Audio", "PlaylistItemId": $0.membership]
            }
            data = try JSONSerialization.data(withJSONObject: [
                "Items": rows, "StartIndex": offset, "TotalRecordCount": members.count,
            ])
        }
        return (
            data,
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}
