import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPlaylistReorderTests: XCTestCase {
    private let playlistID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
            userID: "00000000000000000000000000000003", deviceID: "synthetic")
    }

    func testMovingFirstDuplicateOccurrenceToEndUsesOneMembershipMove() throws {
        let original = entries(5)
        let plan = try FoundationPlaylistReorderPlan(
            entries: original, from: IndexSet(integer: 0), to: original.count)
        XCTAssertEqual(
            plan.entries.map(\.mutationID), ["entry-1", "entry-2", "entry-3", "entry-4", "entry-0"])
        XCTAssertEqual(plan.moves, [.init(entryID: "entry-0", destination: 4)])
        XCTAssertEqual(plan.entries.filter { $0.item.id == original[0].item.id }.count, 2)
    }

    func testNoncontiguousMovesPreserveSourceOrderAcrossDestination() throws {
        let plan = try FoundationPlaylistReorderPlan(
            entries: entries(5), from: IndexSet([0, 3, 4]), to: 2)
        XCTAssertEqual(
            plan.entries.map(\.mutationID), ["entry-1", "entry-0", "entry-3", "entry-4", "entry-2"])
        XCTAssertEqual(
            plan.moves,
            [
                .init(entryID: "entry-0", destination: 1),
                .init(entryID: "entry-3", destination: 2),
                .init(entryID: "entry-4", destination: 3),
            ])
    }

    func testNativeMovePlansPreserveEveryOccurrenceForAllSmallSelections() throws {
        for count in 1...7 {
            let original = entries(count)
            for mask in 1..<(1 << count) {
                let source = IndexSet((0..<count).filter { mask & (1 << $0) != 0 })
                for destination in 0...count {
                    let plan = try FoundationPlaylistReorderPlan(
                        entries: original, from: source, to: destination)
                    let selected = source.map { original[$0].mutationID }
                    var expected = original.enumerated().filter { !source.contains($0.offset) }
                        .map { $0.element.mutationID }
                    expected.insert(
                        contentsOf: selected,
                        at: destination - source.filter { $0 < destination }.count)
                    var serverOrder = original.map(\.mutationID)
                    for move in plan.moves {
                        XCTAssertTrue(selected.contains(move.entryID))
                        let index = try XCTUnwrap(serverOrder.firstIndex(of: move.entryID))
                        serverOrder.insert(serverOrder.remove(at: index), at: move.destination)
                    }
                    XCTAssertEqual(serverOrder, expected)
                    XCTAssertEqual(plan.entries.map(\.mutationID), expected)
                    XCTAssertLessThanOrEqual(plan.moves.count, source.count)
                }
            }
        }
    }

    func testAmbiguousMembershipRowsRemainDistinctWithoutChangingMutationIdentity() {
        let original = entries(3)
        let ambiguous = [
            original[0],
            FoundationPlaylistEntry(
                id: "local-second", mutationID: original[0].mutationID, item: original[1].item),
            original[2],
        ]
        let rows = FoundationPlaylistReorderRow.make(ambiguous)
        XCTAssertEqual(rows.count, ambiguous.count)
        XCTAssertEqual(Set(rows.map(\.id)).count, ambiguous.count)
        XCTAssertEqual(rows.map(\.id), ambiguous.map(\.id))
        XCTAssertEqual(rows.map { $0.entry.mutationID }, ambiguous.map(\.mutationID))
        XCTAssertEqual(rows.map(\.index), [0, 1, 2])
        XCTAssertTrue(FoundationPlaylistSnapshot.hasAmbiguousMemberships(ambiguous))

        let renamedLocals = original.enumerated().map { index, entry in
            FoundationPlaylistEntry(
                id: "new-position-\(index)", mutationID: entry.mutationID, item: entry.item)
        }
        XCTAssertEqual(
            FoundationPlaylistReorderRow.make(original).map(\.id),
            FoundationPlaylistReorderRow.make(renamedLocals).map(\.id))
    }

    func testInvalidOrAmbiguousMoveCannotProduceAWritePlan() throws {
        let original = entries(3)
        for (source, destination) in [
            (IndexSet(), 0), (IndexSet(integer: 3), 0), (IndexSet(integer: 0), -1),
            (IndexSet(integer: 0), 4),
        ] {
            XCTAssertThrowsError(
                try FoundationPlaylistReorderPlan(entries: original, from: source, to: destination))
        }
        let repeated = [original[0], original[0]]
        XCTAssertThrowsError(
            try FoundationPlaylistReorderPlan(entries: repeated, from: IndexSet(integer: 0), to: 2))
        let noChange = try FoundationPlaylistReorderPlan(
            entries: original, from: IndexSet(integer: 1), to: 2)
        XCTAssertTrue(noChange.moves.isEmpty)
    }

    func testAdapterMoveUsesMembershipRouteAndRejectsUnsafeInputsWithoutRequests() async throws {
        let fixture = PlaylistReorderFixture(count: 3)
        let library = library(fixture)
        XCTAssertTrue(library.supportsPlaylistReordering)
        try await library.moveEntry(in: playlistID, entryID: "entry-0", to: 2)
        let requestValue = await fixture.lastMoveRequest()
        let request = try XCTUnwrap(requestValue)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/Playlists/\(playlistID)/Items/entry-0/Move/2")
        XCTAssertTrue(request.url?.query?.isEmpty ?? true)
        XCTAssertFalse(request.url?.absoluteString.contains("synthetic") ?? true)
        for (id, index) in [("../private", 0), ("entry-0", -1), ("entry-0", 10_000)] {
            do {
                try await library.moveEntry(in: playlistID, entryID: id, to: index)
                XCTFail("An invalid membership/index must never be sent")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        }
        let count = await fixture.moveCount
        XCTAssertEqual(count, 1)
    }

    func testAuthoritativeReorderPreservesDuplicatesAndInvalidatesOnlyItsPlaylist() async throws {
        let fixture = PlaylistReorderFixture(count: 5)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        let otherAccount = FoundationPlaylistChanges()
        let confirmed = try await changes.reorder(
            playlistID: playlistID, entries: original, from: IndexSet(integer: 0), to: 5,
            library: library)
        XCTAssertEqual(
            confirmed.map(\.mutationID), ["entry-1", "entry-2", "entry-3", "entry-4", "entry-0"])
        XCTAssertEqual(confirmed.filter { $0.item.id == original[0].item.id }.count, 2)
        XCTAssertEqual(changes.revision(for: playlistID), 1)
        XCTAssertEqual(changes.revision(for: "unrelated"), 0)
        XCTAssertEqual(otherAccount.revision(for: playlistID), 0)
        let moves = await fixture.moveCount
        XCTAssertEqual(moves, 1)
    }

    func testReadOnlyPermissionStopsBeforeAnyReorderWrite() async throws {
        let fixture = PlaylistReorderFixture(count: 3, canEdit: false)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        do {
            _ = try await FoundationPlaylistMutation.reorder(
                playlistID: playlistID, entries: original, from: IndexSet(integer: 0), to: 3,
                library: library)
            XCTFail("Read-only order must not be changed")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .readOnly) }
        let moves = await fixture.moveCount
        XCTAssertEqual(moves, 0)
    }

    func testStaleMembershipOrderOrTrackIdentityStopsBeforeAnyWrite() async throws {
        for replaceTrack in [false, true] {
            let fixture = PlaylistReorderFixture(count: 3)
            let library = library(fixture)
            let original = try await FoundationPlaylistSnapshot.load(
                id: playlistID, library: library)
            await fixture.externalChange(replaceTrack: replaceTrack)
            do {
                _ = try await FoundationPlaylistMutation.reorder(
                    playlistID: playlistID, entries: original, from: IndexSet(integer: 0), to: 3,
                    library: library)
                XCTFail("A stale snapshot must not issue a server move")
            } catch { XCTAssertEqual(error as? FoundationPlaylistError, .changed) }
            let moves = await fixture.moveCount
            XCTAssertEqual(moves, 0)
        }
    }

    func testAcknowledgementWithoutMatchingAuthoritativeOrderRemainsUnconfirmed() async throws {
        let fixture = PlaylistReorderFixture(count: 3, ignoreMoves: true)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        do {
            _ = try await FoundationPlaylistMutation.reorder(
                playlistID: playlistID, entries: original, from: IndexSet(integer: 0), to: 3,
                library: library)
            XCTFail("A successful HTTP acknowledgement alone must not claim reorder success")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .partialReorder) }
        let moves = await fixture.moveCount
        XCTAssertEqual(moves, 1, "There is no automatic write retry or rollback")
    }

    func testPartialMultipleMoveFailureInvalidatesWithoutRetryOrRollback() async throws {
        let fixture = PlaylistReorderFixture(count: 5, failMove: 2)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let changes = FoundationPlaylistChanges()
        do {
            _ = try await changes.reorder(
                playlistID: playlistID, entries: original, from: IndexSet([0, 1]), to: 5,
                library: library)
            XCTFail("A partial reorder must remain uncertain")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .partialReorder) }
        let moves = await fixture.moveCount
        let order = await fixture.membershipIDs
        XCTAssertEqual(moves, 2)
        XCTAssertEqual(order, ["entry-0", "entry-2", "entry-3", "entry-4", "entry-1"])
        XCTAssertEqual(changes.revision(for: playlistID), 1)
    }

    func testCancellationAfterSentMoveDoesNotContinueRemainingMoves() async throws {
        let fixture = PlaylistReorderFixture(count: 5, cancelAfterMove: 1)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        do {
            _ = try await FoundationPlaylistMutation.reorder(
                playlistID: playlistID, entries: original, from: IndexSet([0, 1]), to: 5,
                library: library)
            XCTFail("Cancellation cannot claim success or rollback")
        } catch {
            XCTAssertTrue(
                error is CancellationError || (error as? FoundationLibraryError) == .cancelled)
        }
        let moves = await fixture.moveCount
        XCTAssertEqual(moves, 1)
    }

    func testConcurrentPostflightMembershipAdditionCannotClaimSuccess() async throws {
        let fixture = PlaylistReorderFixture(count: 3, appendOnConfirmation: true)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        do {
            _ = try await FoundationPlaylistMutation.reorder(
                playlistID: playlistID, entries: original, from: IndexSet(integer: 0), to: 3,
                library: library)
            XCTFail("A concurrent membership change must remain unconfirmed")
        } catch { XCTAssertEqual(error as? FoundationPlaylistError, .partialReorder) }
        let order = await fixture.membershipIDs
        XCTAssertTrue(
            order.contains("external"), "Never erase a concurrent membership to force confirmation")
    }

    func testReorderVerifiesFullPaginatedMembershipSnapshot() async throws {
        let fixture = PlaylistReorderFixture(count: 205)
        let library = library(fixture)
        let original = try await FoundationPlaylistSnapshot.load(id: playlistID, library: library)
        let confirmed = try await FoundationPlaylistMutation.reorder(
            playlistID: playlistID, entries: original, from: IndexSet(integer: 204), to: 0,
            library: library)
        XCTAssertEqual(confirmed.first?.mutationID, "entry-204")
        XCTAssertEqual(confirmed.count, 205)
        let reads = await fixture.snapshotReads
        let moves = await fixture.moveCount
        XCTAssertEqual(reads, 9, "Initial, preflight and postflight snapshots include every page")
        XCTAssertEqual(moves, 1)
    }

    private func entries(_ count: Int) -> [FoundationPlaylistEntry] {
        (0..<count).map { index in
            FoundationPlaylistEntry(
                id: "\(index):entry-\(index)", mutationID: "entry-\(index)",
                item: FoundationItem(
                    id: PlaylistReorderFixture.trackID(index), title: "Synthetic", subtitle: "",
                    kind: .track, duration: nil))
        }
    }

    private func library(_ fixture: PlaylistReorderFixture) -> FoundationJellyfinLibrary {
        FoundationJellyfinLibrary(session: session) { request in
            try await fixture.response(request)
        }
    }
}

private actor PlaylistReorderFixture {
    private var members: [(entry: String, track: String)]
    private let canEdit: Bool
    private let ignoreMoves: Bool
    private let failMove: Int?
    private let cancelAfterMove: Int?
    private var appendOnConfirmation: Bool
    private var moveRequests: [URLRequest] = []
    private(set) var snapshotReads = 0
    var moveCount: Int { moveRequests.count }
    var membershipIDs: [String] { members.map(\.entry) }
    func lastMoveRequest() -> URLRequest? { moveRequests.last }

    init(
        count: Int, canEdit: Bool = true, ignoreMoves: Bool = false, failMove: Int? = nil,
        cancelAfterMove: Int? = nil, appendOnConfirmation: Bool = false
    ) {
        members = (0..<count).map { ("entry-\($0)", Self.trackID($0)) }
        self.canEdit = canEdit
        self.ignoreMoves = ignoreMoves
        self.failMove = failMove
        self.cancelAfterMove = cancelAfterMove
        self.appendOnConfirmation = appendOnConfirmation
    }

    nonisolated static func trackID(_ index: Int) -> String {
        String(format: "%032x", (index == 1 ? 0 : index) + 100)
    }

    func externalChange(replaceTrack: Bool) {
        if replaceTrack {
            members[0].track = Self.trackID(999)
        } else {
            members.swapAt(0, 2)
        }
    }

    func response(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let data: Data
        if request.httpMethod == "POST", url.path.contains("/Move/") {
            moveRequests.append(request)
            if moveRequests.count == failMove { throw URLError(.networkConnectionLost) }
            let components = url.path.split(separator: "/")
            let entry = String(components[3])
            guard let index = Int(components[5]),
                let source = members.firstIndex(where: { $0.entry == entry }),
                members.indices.contains(index)
            else { throw FoundationLibraryError.invalidResponse }
            if !ignoreMoves { members.insert(members.remove(at: source), at: index) }
            if moveRequests.count == cancelAfterMove { throw CancellationError() }
            data = Data()
        } else if url.path.contains("/Users/") {
            data = Data(
                "{\"UserId\":\"00000000000000000000000000000003\",\"CanEdit\":\(canEdit)}".utf8)
        } else if url.path.hasPrefix("/Items/") {
            data = Data(
                "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Playlist\",\"Name\":\"Synthetic\"}"
                    .utf8)
        } else {
            snapshotReads += 1
            if appendOnConfirmation, !moveRequests.isEmpty {
                appendOnConfirmation = false
                members.append(("external", Self.trackID(999)))
            }
            let offset =
                Int(
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "startIndex" })?.value ?? "0") ?? 0
            let rows = members.dropFirst(offset).prefix(100).map {
                ["Id": $0.track, "Type": "Audio", "Name": "Synthetic", "PlaylistItemId": $0.entry]
            }
            data = try JSONSerialization.data(withJSONObject: [
                "Items": rows, "StartIndex": offset, "TotalRecordCount": members.count,
            ])
        }
        return (
            data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
