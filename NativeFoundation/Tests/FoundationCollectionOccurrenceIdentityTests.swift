import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCollectionOccurrenceIdentityTests: XCTestCase {
    func testReliablePlaylistMembershipReorderAndRemovalKeepExactOccurrence() throws {
        let model = collectionModel(.playlist)
        let actions = makeActions()
        let first = track("same", membership: "m1")
        var second = track("same", membership: "m2")
        let b = track("b", membership: "m3")
        model.installSnapshot([first, second, b])
        let original = model.collectionOccurrences
        XCTAssertNotEqual(original[0].id, original[1].id)
        second.title = "Current second occurrence"
        model.installSnapshot([b, second, first])
        XCTAssertEqual(
            model.collectionOccurrences.map(\.id), [original[2].id, original[1].id, original[0].id])
        XCTAssertEqual(model.collectionOccurrences[1].item, second)
        let selected = try XCTUnwrap(
            model.collectionTrackQueue(
                selecting: original[1].id, using: actions, isAvailable: { $0.id != "b" }))
        XCTAssertEqual(selected.items, [second, first])
        XCTAssertEqual(selected.index, 0)
        XCTAssertEqual(selected.items[selected.index].playlistEntryID, "m2")
        model.installSnapshot([b, second])
        XCTAssertNil(model.collectionTrackQueue(selecting: original[0].id, using: actions))
        XCTAssertEqual(model.collectionOccurrences[1].id, original[1].id)
        XCTAssertFalse(FoundationLibraryIndexSelection.admits(original[1].item, current: second))
    }

    func testAnonymousReplacementNeverMapsOldFirstOrSecondToRemainingSong() throws {
        let model = collectionModel(.playlist)
        let actions = makeActions()
        let a = track("same")
        let b = track("b")
        model.installSnapshot([a, a, b])
        let old = model.collectionOccurrences
        XCTAssertEqual(Set(old.map(\.id)).count, 3)
        model.installSnapshot([a, b])
        XCTAssertEqual(model.rawItems, [a, b])
        XCTAssertEqual(model.collectionOccurrences.map(\.item), [a, b])
        XCTAssertNil(model.collectionTrackQueue(selecting: old[0].id, using: actions))
        XCTAssertNil(model.collectionTrackQueue(selecting: old[1].id, using: actions))
        XCTAssertFalse(old.map(\.id).contains(model.collectionOccurrences[0].id))
        let fresh = try XCTUnwrap(
            model.collectionTrackQueue(
                selecting: model.collectionOccurrences[0].id, using: actions))
        XCTAssertEqual(fresh.items[fresh.index], a)
    }

    func testAmbiguousMembershipRecoveryCannotReviveRetiredProviderAction() {
        let model = collectionModel(.playlist)
        let actions = makeActions()
        let a = track("a", membership: "reused")
        let b = track("b", membership: "reused")
        model.installSnapshot([a])
        let old = model.collectionOccurrences[0].id
        model.installSnapshot([a, b])
        XCTAssertEqual(Set(model.collectionOccurrences.map(\.id)).count, 2)
        XCTAssertNil(model.collectionTrackQueue(selecting: old, using: actions))
        model.installSnapshot([a])
        XCTAssertNotEqual(model.collectionOccurrences[0].id, old)
        XCTAssertNil(model.collectionTrackQueue(selecting: old, using: actions))
    }

    func testAlbumProjectionCarriesActualAlternateAndRepeatedOccurrenceProvenance() throws {
        let model = collectionModel(.album)
        let actions = makeActions()
        var a = track("a")
        a.trackNumber = 1
        a.discNumber = 1
        a.title = "Same logical album track"
        let alternate = FoundationItem(
            id: "alternate", title: a.title, subtitle: "", kind: .track,
            duration: nil, trackNumber: 1, discNumber: 1)
        model.installSnapshot([a, a, alternate])
        let raw = model.collectionOccurrences
        let available: (FoundationItem) -> Bool = { $0.id == "alternate" }
        let expected = FoundationAlbumTrackPolicy.visibleTracks(
            [a, a, alternate], albumID: "collection", showDuplicates: false, isAvailable: available)
        XCTAssertEqual(expected, [alternate, a])
        XCTAssertEqual(
            FoundationAlbumTrackPolicy.visibleSourceIndices(
                [a, a, alternate], albumID: "collection", showDuplicates: false,
                isAvailable: available), [2, 1])
        let projected = model.visibleCollectionOccurrences(
            using: actions, albumID: "collection", isAvailable: available)
        XCTAssertEqual(projected.map(\.item), expected)
        XCTAssertEqual(projected.map(\.id), [raw[2].id, raw[1].id])
        let playable = try XCTUnwrap(
            model.collectionTrackQueue(
                selecting: raw[2].id, using: actions, albumID: "collection", isAvailable: available)
        )
        XCTAssertEqual(playable.items, [alternate])
        XCTAssertEqual(playable.index, 0)
        XCTAssertNil(
            model.collectionTrackQueue(
                selecting: raw[0].id, using: actions, albumID: "collection", isAvailable: available)
        )
        XCTAssertNil(
            model.collectionTrackQueue(
                selecting: raw[1].id, using: actions, albumID: "collection", isAvailable: available)
        )
    }

    func testActualAppendRetainsOwnedTokensAndRawPublisherRemainsCoherent() async {
        let model = collectionModel(.playlist)
        let a = track("same")
        let b = track("b")
        var received: [[FoundationItem]] = []
        var pairedAtRawPublication: [[FoundationItem]] = []
        var previousRawValues: [[FoundationItem]] = []
        let observation = model.$rawItems.dropFirst().sink { incoming in
            received.append(incoming)
            pairedAtRawPublication.append(model.collectionOccurrences.map(\.item))
            previousRawValues.append(model.rawItems)
        }
        defer { observation.cancel() }
        await model.load(.initial) { offset in
            XCTAssertEqual(offset, 0)
            return .init(items: [a, a], nextStartIndex: 2)
        }
        let owned = model.collectionOccurrences.map(\.id)
        await model.load(.more) { offset in
            XCTAssertEqual(offset, 2)
            return .init(items: [b], nextStartIndex: nil)
        }
        XCTAssertEqual(Array(model.collectionOccurrences.prefix(2)).map(\.id), owned)
        XCTAssertEqual(Set(model.collectionOccurrences.map(\.id)).count, 3)
        XCTAssertEqual(received, [[a, a], [a, a, b]])
        XCTAssertEqual(pairedAtRawPublication, received)
        XCTAssertEqual(
            previousRawValues, [[], [a, a]], "Keep the existing Published willSet seam")
        model.configureCatalogPagination()
        XCTAssertFalse(model.hasUniqueCatalogIdentity)
        XCTAssertEqual(model.rawItems, [a, a, b], "Collection mode must not deduplicate songs")
    }

    func testLegacyMetadataClearAndAccountReplacementRetireOldTokens() throws {
        let model = collectionModel(.playlist)
        let actions = makeActions()
        let online = track("same", membership: "membership")
        model.installSnapshot([online])
        let onlineID = model.collectionOccurrences[0].id
        let data = try JSONEncoder().encode(FoundationStoredDownloadItem(online))
        let restored = try JSONDecoder().decode(FoundationStoredDownloadItem.self, from: data).item
        XCTAssertNil(restored.playlistEntryID)
        model.installSnapshot([restored, restored])
        XCTAssertNil(model.collectionTrackQueue(selecting: onlineID, using: actions))
        let admitted = model.collectionOccurrences.map(\.id)
        XCTAssertEqual(model.visibleCollectionOccurrences(using: actions).map(\.id), admitted)
        XCTAssertEqual(model.visibleCollectionOccurrences(using: actions).map(\.id), admitted)
        model.clearRetainedData()
        XCTAssertTrue(model.collectionOccurrences.isEmpty)
        model.installSnapshot([online])
        XCTAssertNotEqual(model.collectionOccurrences[0].id, onlineID)
        XCTAssertNil(model.collectionTrackQueue(selecting: onlineID, using: actions))
        let beforeAccount = model.collectionOccurrences[0].id
        model.configureCollectionOccurrences(
            sourceScope: "other-account", collection: collection(.playlist))
        model.installSnapshot([online])
        XCTAssertNotEqual(model.collectionOccurrences[0].id, beforeAccount)
        XCTAssertEqual(model.collectionOccurrences[0].id.owner.sourceScope, "other-account")
        XCTAssertNil(model.collectionTrackQueue(selecting: beforeAccount, using: actions))
        let current = model.collectionOccurrences[0].id
        actions.invalidate()
        XCTAssertNil(model.collectionTrackQueue(selecting: current, using: actions))
    }

    func testSynchronousWillChangeCannotResolveRetiredAnonymousOrOldMetadataPayload() throws {
        let actions = makeActions()
        let model = collectionModel(.playlist)
        let repeated = track("same")
        model.installSnapshot([repeated, repeated])
        let held = model.collectionOccurrences[0].id
        var attemptedAnonymousRead = false
        var anonymousSelected: FoundationTrackQueueSelection?
        let anonymousObservation = model.objectWillChange.first().sink {
            attemptedAnonymousRead = true
            anonymousSelected = model.collectionTrackQueue(selecting: held, using: actions)
        }
        model.installSnapshot([repeated])
        anonymousObservation.cancel()
        XCTAssertTrue(attemptedAnonymousRead)
        XCTAssertNil(anonymousSelected, "Retire admission before Published exposes its old payload")

        var reliable = track("reliable", membership: "stable")
        model.installSnapshot([reliable])
        let reliableID = model.collectionOccurrences[0].id
        reliable.title = "Current metadata"
        var currentDuringWillChange: FoundationTrackQueueSelection?
        let metadataObservation = model.objectWillChange.first().sink {
            currentDuringWillChange = model.collectionTrackQueue(
                selecting: reliableID, using: actions)
        }
        model.installSnapshot([reliable])
        metadataObservation.cancel()
        XCTAssertEqual(try XCTUnwrap(currentDuringWillChange).items, [reliable])

        var selectedDuringClear: FoundationTrackQueueSelection?
        let clearObservation = model.objectWillChange.first().sink {
            selectedDuringClear = model.collectionTrackQueue(selecting: reliableID, using: actions)
        }
        model.clearRetainedData()
        clearObservation.cancel()
        XCTAssertNil(selectedDuringClear)
    }

    func testForeignActiveAccountAndRetiredActionsCannotAdmitHeldOccurrence() throws {
        let model = collectionModel(.playlist)
        let accountA = makeActions()
        let accountB = makeActions(sourceScope: "other-account")
        let item = track("same", membership: "stable-membership")
        model.installSnapshot([item])
        let held = model.collectionOccurrences[0].id
        XCTAssertEqual(model.visibleCollectionOccurrences(using: accountA).map(\.item), [item])
        XCTAssertNotNil(model.collectionTrackQueue(selecting: held, using: accountA))
        XCTAssertNotNil(accountB.catalogIdentityScope, "The foreign account is active")
        XCTAssertTrue(model.visibleCollectionOccurrences(using: accountB).isEmpty)
        XCTAssertNil(model.collectionTrackQueue(selecting: held, using: accountB))
        accountA.invalidate()
        XCTAssertTrue(model.visibleCollectionOccurrences(using: accountA).isEmpty)
        XCTAssertNil(model.collectionTrackQueue(selecting: held, using: accountA))
        XCTAssertEqual(
            model.collectionOccurrences[0].id, held, "Rejection does not rewrite retained data")
    }

    func testUnconfiguredCatalogModelDoesNotGainCollectionPublications() {
        let model = FoundationBrowseModel()
        var payloadEvents = 0
        let observation = model.$collectionOccurrences.dropFirst().sink { _ in payloadEvents += 1 }
        defer { observation.cancel() }
        model.configureCatalogPagination()
        model.installSnapshot([track("a")])
        model.request(.refresh)
        model.clearRetainedData()
        XCTAssertEqual(payloadEvents, 0)
        XCTAssertTrue(model.collectionOccurrences.isEmpty)
    }

    private func collection(_ kind: FoundationItem.Kind) -> FoundationItem {
        FoundationItem(
            id: "collection", title: "Collection", subtitle: "", kind: kind, duration: nil)
    }

    private func collectionModel(_ kind: FoundationItem.Kind) -> FoundationBrowseModel {
        let model = FoundationBrowseModel()
        model.configureCollectionOccurrences(
            sourceScope: "synthetic-account", collection: collection(kind))
        return model
    }

    private func track(_ id: String, membership: String? = nil) -> FoundationItem {
        FoundationItem(
            id: id, title: id, subtitle: "", kind: .track, duration: nil,
            playlistEntryID: membership)
    }

    private func makeActions(sourceScope: String = "synthetic-account") -> FoundationLibraryActions
    {
        FoundationLibraryActions(
            sourceScope: sourceScope, read: { _ in nil }, write: { _, _ in },
            showDuplicateAlbumTracks: { false },
            mutateFavorite: { _, _ in XCTFail("Occurrence identity must not call a provider") })
    }
}
