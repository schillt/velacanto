import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPinnedRowIdentityTests: XCTestCase {
    private let firstScope = String(repeating: "a", count: 64)
    private let otherScope = String(repeating: "b", count: 64)
    private let album = FoundationItem(
        id: "same-item", title: "Album", subtitle: "Artist", kind: .album, duration: nil)
    private let playlist = FoundationItem(
        id: "playlist", title: "Playlist", subtitle: "", kind: .playlist, duration: nil)
    private let artist = FoundationItem(
        id: "same-item", title: "Artist", subtitle: "", kind: .artist, duration: nil)

    func testRemovingEarlierPinPreservesSurvivingRowIdentity() throws {
        let storage = Storage()
        let actions = makeActions(scope: firstScope, storage: storage)
        for item in [album, playlist, artist] { actions.togglePin(item) }
        let original = actions.pinnedRows
        XCTAssertEqual(Set(original.map(\.id)).count, 3)

        actions.togglePin(album)

        XCTAssertEqual(actions.pinnedRows.map(\.item), [playlist, artist])
        XCTAssertEqual(actions.pinnedRows.map(\.id), original.dropFirst().map(\.id))
        XCTAssertEqual(
            try XCTUnwrap(actions.pinnedRows.last).id, try XCTUnwrap(original.last).id,
            "A surviving pin must not acquire the removed row's position identity")
        XCTAssertNil(actions.pinErrorMessage)
    }

    func testMovingPinKeepsItsIdentityAcrossPositions() {
        let storage = Storage()
        let actions = makeActions(scope: firstScope, storage: storage)
        for item in [album, playlist, artist] { actions.togglePin(item) }
        let original = actions.pinnedRows.map(\.id)

        actions.movePin(artist, earlier: true)
        XCTAssertEqual(actions.pinnedRows.map(\.item), [album, artist, playlist])
        XCTAssertEqual(actions.pinnedRows.map(\.id), [original[0], original[2], original[1]])
        actions.movePin(artist, earlier: true)
        XCTAssertEqual(actions.pinnedRows.map(\.item), [artist, album, playlist])
        XCTAssertEqual(actions.pinnedRows.map(\.id), [original[2], original[0], original[1]])
        XCTAssertNil(actions.pinErrorMessage)
    }

    func testPinnedRowsSeparateItemKindsAndAccountScopes() throws {
        let storage = Storage()
        let first = makeActions(scope: firstScope, storage: storage)
        let other = makeActions(scope: otherScope, storage: storage)
        first.togglePin(album)
        first.togglePin(artist)
        other.togglePin(album)
        let rows = first.pinnedRows

        XCTAssertEqual(rows.map(\.item.id), [album.id, album.id])
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "Kinds remain distinct within an account")
        XCTAssertNotEqual(
            try XCTUnwrap(rows.first).id, try XCTUnwrap(other.pinnedRows.first).id,
            "The same provider item cannot inherit another account's row state")
        XCTAssertEqual(first.pins, [album, artist])
        XCTAssertEqual(other.pins, [album])
    }

    func testRestoringUpdatedPinMetadataPreservesIdentityWithoutWriting() throws {
        let storage = Storage()
        let first = makeActions(scope: firstScope, storage: storage)
        first.togglePin(album)
        let originalID = try XCTUnwrap(first.pinnedRows.first).id
        var updated = album
        updated.title = "Updated album title"
        updated.primaryImageTag = "updated-image"
        // Another saved snapshot may contain refreshed metadata. Use the actual
        // pin serializer and restore path, with no cloud owner or transport.
        let writer = FoundationLibraryActions(
            sourceScope: firstScope, read: { _ in nil },
            write: { key, data in
                storage.writes += 1
                storage.values[key] = data
            },
            mutateFavorite: { _, _ in XCTFail("Pin projection must not call the provider") })
        writer.togglePin(updated)
        let saved = storage.values
        let writes = storage.writes

        let restored = makeActions(scope: firstScope, storage: storage)
        let row = try XCTUnwrap(restored.pinnedRows.first)

        XCTAssertEqual(row.id, originalID)
        XCTAssertEqual(row.item.title, updated.title)
        XCTAssertEqual(row.item.primaryImageTag, updated.primaryImageTag)
        XCTAssertEqual(storage.values, saved)
        XCTAssertEqual(storage.writes, writes, "Restoring and projecting pins is read-only")
        XCTAssertEqual(restored.pinnedRows.map(\.id), [originalID])
    }

    func testFailedOrRetiredPinMutationCannotReplacePublishedRowIdentity() {
        let storage = Storage()
        let actions = makeActions(scope: firstScope, storage: storage)
        actions.togglePin(album)
        actions.togglePin(playlist)
        let original = actions.pinnedRows.map(\.id)
        let saved = storage.values
        storage.rejectWrites = true

        actions.movePin(playlist, earlier: true)
        actions.togglePin(album)

        XCTAssertEqual(actions.pinnedRows.map(\.id), original)
        XCTAssertEqual(actions.pinnedRows.map(\.item), [album, playlist])
        XCTAssertEqual(storage.values, saved)
        XCTAssertNotNil(actions.pinErrorMessage)
        actions.invalidate()
        let writes = storage.writes
        actions.togglePin(artist)
        actions.movePin(playlist, earlier: true)
        XCTAssertEqual(actions.pinnedRows.map(\.id), original)
        XCTAssertEqual(storage.values, saved)
        XCTAssertEqual(storage.writes, writes, "A retired owner cannot mutate pin storage")
    }

    private func makeActions(scope: String, storage: Storage) -> FoundationLibraryActions {
        FoundationLibraryActions(
            sourceScope: scope, read: { storage.values[$0] },
            write: { key, data in
                storage.writes += 1
                if storage.rejectWrites { throw Storage.Failure.write }
                storage.values[key] = data
            }, mutateFavorite: { _, _ in XCTFail("Pin projection must not call the provider") })
    }

    private final class Storage {
        enum Failure: Error { case write }
        var values: [String: Data] = [:]
        var writes = 0
        var rejectWrites = false
    }
}
