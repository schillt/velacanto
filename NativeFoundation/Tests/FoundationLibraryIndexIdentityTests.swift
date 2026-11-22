import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLibraryIndexIdentityTests: XCTestCase {
    func testHeldUniqueActionResolvesCurrentPositionAfterPrependAndEarlierDeletion() throws {
        let a = item("a")
        let selected = item("selected")
        let c = item("c")
        let fixture = Fixture(items: [a, selected, c])
        let row = try fixture.row("selected")
        let held = { fixture.selection(row.intent) }
        let prepended = item("prepended")

        fixture.model.installSnapshot([prepended, a, selected, c])
        let afterPrepend = try XCTUnwrap(held())
        XCTAssertEqual(afterPrepend.items, [prepended, a, selected, c])
        XCTAssertEqual(afterPrepend.index, 2)
        XCTAssertEqual(try fixture.row("selected").id, row.id)

        fixture.model.installSnapshot([prepended, selected, c])
        let afterDelete = try XCTUnwrap(held())
        XCTAssertEqual(afterDelete.items, [prepended, selected, c])
        XCTAssertEqual(afterDelete.index, 1)
        XCTAssertEqual(afterDelete.items[afterDelete.index], selected)
    }

    func testHeldRemovedItemCannotSelectTheReplacementAtItsOldPosition() throws {
        let a = item("a")
        let removed = item("removed")
        let next = item("next")
        let fixture = Fixture(items: [a, removed, next])
        let row = try fixture.row("removed")

        fixture.model.installSnapshot([a, next])

        XCTAssertNil(fixture.resolve(row.intent))
        XCTAssertNil(fixture.selection(row.intent))
        XCTAssertEqual(fixture.model.items, [a, next])
    }

    func testMetadataRefreshKeepsRowIdentityAndResolvesTheUpdatedItem() throws {
        let original = item("selected")
        let fixture = Fixture(items: [original])
        let row = try fixture.row("selected")
        let lifetime = fixture.model.catalogIdentityContext
        fixture.model.request(.refresh)
        XCTAssertEqual(fixture.model.catalogIdentityContext, lifetime)
        XCTAssertNotNil(fixture.resolve(row.intent))
        var updated = original
        updated.title = "Updated title"
        updated.primaryImageTag = "new-image-tag"
        fixture.model.installSnapshot([updated])

        XCTAssertEqual(fixture.model.catalogIdentityContext, lifetime)
        XCTAssertEqual(try fixture.row("selected").id, row.id)
        XCTAssertEqual(try XCTUnwrap(fixture.resolve(row.intent)).item, updated)
        let selection = try XCTUnwrap(fixture.selection(row.intent))
        XCTAssertEqual(selection.items, [updated])
        XCTAssertEqual(selection.index, 0)
    }

    func testClearedCatalogRejectsOldActionEvenWhenTheSameItemReturns() throws {
        let selected = item("selected")
        let fixture = Fixture(items: [selected])
        let row = try fixture.row("selected")
        let oldLifetime = fixture.model.catalogIdentityContext
        fixture.model.clearRetainedData()
        fixture.model.installSnapshot([selected])

        XCTAssertNotEqual(fixture.model.catalogIdentityContext, oldLifetime)
        XCTAssertEqual(
            try fixture.row("selected").id, row.id, "Logical identity is not a load token")
        XCTAssertNil(fixture.resolve(row.intent))
        XCTAssertNil(fixture.selection(row.intent))
        XCTAssertNotNil(fixture.selection(try fixture.row("selected").intent))
    }

    func testClearPublicationCannotGiveOldRowsTheNewActionLifetime() throws {
        let selected = item("selected")
        let fixture = Fixture(items: [selected])
        var duringClear: FoundationLibraryIndexSelection.Intent?
        let observation = fixture.model.objectWillChange.first().sink {
            guard let context = fixture.context, let item = fixture.model.items.first else {
                return
            }
            duringClear = FoundationLibraryIndexSelection.intent(for: item, context: context)
        }
        defer { observation.cancel() }

        fixture.model.clearRetainedData()
        let captured = try XCTUnwrap(duringClear, "Observe the actual pre-change item publication")
        fixture.model.installSnapshot([selected])

        XCTAssertNil(fixture.selection(captured))
        XCTAssertNotNil(fixture.selection(try fixture.row("selected").intent))
    }

    func testRetiredAndReplacementAccountOwnersCannotReviveHeldActions() throws {
        let selected = item("selected")
        let fixture = Fixture(items: [selected])
        let row = try fixture.row("selected")
        let savedContext = try XCTUnwrap(fixture.context)
        fixture.actions.invalidate()
        XCTAssertNil(fixture.context)
        XCTAssertNil(
            FoundationLibraryIndexSelection.resolve(
                row.intent, current: savedContext, model: fixture.model, actions: fixture.actions))

        for scope in ["synthetic-index-owner", "synthetic-other-owner"] {
            let replacement = Fixture.actions(scope: scope)
            let context = FoundationLibraryIndexSelection.context(
                model: fixture.model, actions: replacement, catalogScope: "all",
                query: "", letter: nil)
            XCTAssertNil(
                FoundationLibraryIndexSelection.trackQueue(
                    row.intent, current: context, model: fixture.model, actions: replacement))
            let replacementRows = FoundationLibraryIndexSelection.rows(
                in: fixture.model, context: try XCTUnwrap(context))
            XCTAssertEqual(replacementRows.count, 1)
            XCTAssertEqual(replacementRows[0].id == row.id, scope == "synthetic-index-owner")
        }
        XCTAssertEqual(
            fixture.model.items, [selected], "Identity checks cannot mutate retained data")
    }

    func testQueryLetterCatalogAndModelReplacementRejectHeldContext() throws {
        let selected = item("selected")
        let fixture = Fixture(items: [selected])
        let row = try fixture.row("selected")
        let contexts = [
            FoundationLibraryIndexSelection.context(
                model: fixture.model, actions: fixture.actions, catalogScope: "different-library",
                query: "", letter: nil),
            FoundationLibraryIndexSelection.context(
                model: fixture.model, actions: fixture.actions, catalogScope: "all",
                query: "different-query", letter: nil),
            FoundationLibraryIndexSelection.context(
                model: fixture.model, actions: fixture.actions, catalogScope: "all",
                query: "", letter: "S"),
        ]
        for context in contexts {
            XCTAssertNil(
                FoundationLibraryIndexSelection.trackQueue(
                    row.intent, current: context, model: fixture.model, actions: fixture.actions))
        }
        let otherModel = FoundationBrowseModel()
        otherModel.configureCatalogPagination()
        otherModel.installSnapshot([selected])
        XCTAssertNil(
            FoundationLibraryIndexSelection.resolve(
                row.intent, current: fixture.context, model: otherModel, actions: fixture.actions))
        fixture.model.clearRetainedData()
        fixture.model.installSnapshot([selected])
        XCTAssertNil(
            fixture.selection(row.intent),
            "Returning to the same query cannot revive a cleared action")
    }

    func testTypedUniqueKeyResolvesBeforeUnchangedOfflinePositionRemapping() throws {
        let unavailable = item("unavailable")
        let first = item("first")
        let albumWithSameID = item("selected", kind: .album)
        let selected = item("selected")
        let last = item("last")
        let fixture = Fixture(items: [unavailable, first, albumWithSameID, selected, last])
        let row = try fixture.row("selected")
        let albumRow = try fixture.row("selected", kind: .album)
        XCTAssertNotEqual(row.id, albumRow.id)
        XCTAssertEqual(try XCTUnwrap(fixture.resolve(row.intent)).sourceIndex, 3)

        let selection = try XCTUnwrap(
            FoundationLibraryIndexSelection.trackQueue(
                row.intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions,
                isAvailable: { $0.id != "unavailable" }))
        XCTAssertEqual(selection.items, [first, selected, last])
        XCTAssertEqual(selection.index, 1)
        XCTAssertNil(
            FoundationLibraryIndexSelection.trackQueue(
                row.intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions,
                isAvailable: { $0.id != "selected" }))
        XCTAssertNil(fixture.selection(albumRow.intent))
    }

    func testHeldActionPreservesHoleyOfflineSourcePositionAndOnlineReturn() throws {
        let a = item("a")
        let b = item("b")
        let c = item("c")
        let fixture = Fixture(items: [a, b, c])
        let row = try fixture.row("c")
        // The current input to the unchanged queue helper is still [A, B, C].
        // C's source index is2, even when unavailable B leaves visible offset1.
        XCTAssertEqual(try XCTUnwrap(fixture.resolve(row.intent)).sourceIndex, 2)
        let offline = try XCTUnwrap(
            FoundationLibraryIndexSelection.trackQueue(
                row.intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions,
                isAvailable: { $0.id != "b" }))
        XCTAssertEqual(offline.items, [a, c])
        XCTAssertEqual(offline.index, 1)
        XCTAssertEqual(offline.items[offline.index], c)

        let online = try XCTUnwrap(fixture.selection(row.intent))
        XCTAssertEqual(online.items, [a, b, c])
        XCTAssertEqual(online.index, 2)
        XCTAssertEqual(try fixture.row("c").id, row.id)
        fixture.model.installSnapshot([c, a])
        let changedOrder = try XCTUnwrap(fixture.selection(row.intent))
        XCTAssertEqual(changedOrder.items, [c, a])
        XCTAssertEqual(changedOrder.index, 0)
    }

    func testOccurrenceModelIsRejectedWithoutDeduplicationOrItemMutation() throws {
        let repeated = item("same")
        let fixture = Fixture(items: [repeated, repeated], uniqueCatalog: false)
        let intent = FoundationLibraryIndexSelection.intent(
            for: repeated, context: try XCTUnwrap(fixture.context))

        XCTAssertFalse(fixture.model.hasUniqueCatalogIdentity)
        XCTAssertNil(fixture.resolve(intent))
        XCTAssertNil(fixture.selection(intent))
        XCTAssertEqual(fixture.model.rawItems, [repeated, repeated])
        XCTAssertEqual(fixture.model.items, [repeated, repeated])
    }

    func testHeldMenuAdmissionUsesCurrentRowContextForEveryCapability() throws {
        let selected = item("selected")
        let fixture = Fixture(items: [selected])
        let intent = try fixture.row("selected").intent
        // This is the same capability callback supplied by both index row routes.
        let canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = { _ in
            FoundationLibraryIndexSelection.admits(
                intent, current: fixture.context, model: fixture.model, actions: fixture.actions,
                isActive: fixture.isActive && fixture.isVisible)
        }
        let capabilities: [FoundationCatalogCapabilities] = [
            .catalogPresence, .favorites, .downloads, .playback, .playlistManagement,
        ]
        var performed = 0
        let performHeldActions = {
            for capability in capabilities where canPerform(capability) { performed += 1 }
        }
        performHeldActions()
        XCTAssertEqual(performed, 5)
        fixture.model.installSnapshot([item("prepended"), selected])
        performHeldActions()
        XCTAssertEqual(performed, 10, "A surviving unique row still admits its held menu")

        fixture.isVisible = false
        performHeldActions()
        fixture.isVisible = true
        fixture.isActive = false
        performHeldActions()
        fixture.isActive = true
        fixture.query = "other query"
        performHeldActions()
        fixture.query = ""
        fixture.model.installSnapshot([item("replacement")])
        performHeldActions()
        XCTAssertEqual(
            performed, 10, "Hidden, inactive, changed-query and removed rows reject work")

        fixture.model.clearRetainedData()
        fixture.model.installSnapshot([selected])
        performHeldActions()
        XCTAssertEqual(performed, 10, "Returning to a cleared row cannot revive its menu")
        let fresh = try fixture.row("selected").intent
        XCTAssertTrue(
            FoundationLibraryIndexSelection.admits(
                fresh, current: fixture.context, model: fixture.model, actions: fixture.actions,
                isActive: true))
        fixture.actions.invalidate()
        XCTAssertFalse(
            FoundationLibraryIndexSelection.admits(
                fresh, current: fixture.context, model: fixture.model, actions: fixture.actions,
                isActive: true))
    }

    func testHeldRelatedNavigationRefreshesSameTargetAndRejectsChangedRelations() throws {
        var selected = item("selected")
        selected.album = .init(id: "album", title: "Old album", primaryImageTag: "old-album")
        selected.artist = .init(id: "artist", title: "Old artist", primaryImageTag: "old-artist")
        let fixture = Fixture(items: [selected])
        let intent = try fixture.row("selected").intent
        let oldAlbum = try XCTUnwrap(selected.relatedAlbum)
        let oldArtist = try XCTUnwrap(selected.relatedArtist)
        let destination = { (target: FoundationItem) -> FoundationItem? in
            FoundationLibraryIndexSelection.relatedDestination(
                target, from: intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions)
        }
        selected.album = .init(id: "album", title: "Current album", primaryImageTag: "new-album")
        selected.artist = .init(
            id: "artist", title: "Current artist", primaryImageTag: "new-artist")
        fixture.model.installSnapshot([item("prepended"), selected])
        XCTAssertEqual(try XCTUnwrap(destination(oldAlbum)), try XCTUnwrap(selected.relatedAlbum))
        XCTAssertEqual(try XCTUnwrap(destination(oldArtist)), try XCTUnwrap(selected.relatedArtist))
        XCTAssertNil(destination(selected), "Only the actual typed related route is accepted")

        selected.album = .init(id: "other-album", title: "Other album")
        selected.artist = .init(id: "other-artist", title: "Other artist")
        fixture.model.installSnapshot([selected])
        XCTAssertNil(destination(oldAlbum), "Do not follow the formerly related album")
        XCTAssertNil(destination(oldArtist), "Do not follow the formerly related artist")
        selected.album = nil
        selected.artist = nil
        fixture.model.installSnapshot([selected])
        XCTAssertNil(destination(oldAlbum))
        XCTAssertNil(destination(oldArtist))

        selected.album = .init(id: "album", title: "Returned album")
        fixture.model.installSnapshot([selected])
        fixture.query = "changed query"
        XCTAssertNil(
            destination(oldAlbum), "Related routes retain the source action's context fence")
        fixture.query = ""
        fixture.model.installSnapshot([])
        XCTAssertNil(destination(oldAlbum), "A removed source cannot open its captured destination")
        fixture.model.installSnapshot([selected])
        fixture.actions.invalidate()
        XCTAssertNil(destination(oldAlbum))
    }

    func testCatalogProjectionKeepsTypedAccountIdentityAndSourcePositions() throws {
        let actions = Fixture.actions(scope: "synthetic-catalog-owner")
        let album = item("same", kind: .album)
        let track = item("same")
        let initial = FoundationLibraryIndexSelection.positionedItems(
            [album, track], actions: actions)
        XCTAssertEqual(initial.map(\.sourceIndex), [0, 1])
        XCTAssertNotEqual(initial[0].id, initial[1].id)
        var updated = track
        updated.title = "Updated song"
        updated.primaryImageTag = "current-artwork"
        let current = FoundationLibraryIndexSelection.positionedItems(
            [item("prepend"), updated, album], actions: actions)
        XCTAssertEqual(current[1].id, initial[1].id)
        XCTAssertEqual(current[2].id, initial[0].id)
        XCTAssertEqual(current[1].item, updated)
        let other = FoundationLibraryIndexSelection.positionedItems(
            [updated], actions: Fixture.actions(scope: "other-catalog-owner"))
        XCTAssertNotEqual(other[0].id, initial[1].id)
        actions.invalidate()
        XCTAssertTrue(
            FoundationLibraryIndexSelection.positionedItems([updated], actions: actions).isEmpty)
    }

    func testHeldCatalogKeyResolvesActualQueueInputBeforeHoleyOfflineRemapping() throws {
        let a = item("a")
        let b = item("b")
        let c = item("c")
        let actions = Fixture.actions(scope: "synthetic-catalog-owner")
        let held = FoundationLibraryIndexSelection.positionedItems([a, b, c], actions: actions)[2]
            .id
        let current = [item("unavailable-prefix"), a, b, c]
        let match = try XCTUnwrap(
            FoundationLibraryIndexSelection.resolve(held, in: current, actions: actions))
        XCTAssertEqual(match.sourceIndex, 3)
        let offline = try XCTUnwrap(
            FoundationTrackQueueSelection(
                in: current, selecting: match.sourceIndex,
                isAvailable: { $0.id == "a" || $0.id == "c" }))
        XCTAssertEqual(offline.items, [a, c])
        XCTAssertEqual(offline.index, 1)
        XCTAssertEqual(offline.items[offline.index], c)
        let reordered = [c, a]
        let moved = try XCTUnwrap(
            FoundationLibraryIndexSelection.resolve(held, in: reordered, actions: actions))
        XCTAssertEqual(moved.sourceIndex, 0)
        XCTAssertNil(FoundationLibraryIndexSelection.resolve(held, in: [a, b], actions: actions))
        actions.invalidate()
        XCTAssertNil(FoundationLibraryIndexSelection.resolve(held, in: current, actions: actions))
    }

    func testCatalogArrayLookupRejectsAmbiguityWithoutCollapsingInput() throws {
        let repeated = item("same")
        let album = item("same", kind: .album)
        let actions = Fixture.actions(scope: "synthetic-catalog-owner")
        let input = [repeated, album, repeated]
        let rows = FoundationLibraryIndexSelection.positionedItems(input, actions: actions)
        XCTAssertEqual(
            rows.map(\.item), input, "Projection cannot silently deduplicate occurrences")
        XCTAssertEqual(rows.map(\.sourceIndex), [0, 1, 2])
        XCTAssertNil(
            FoundationLibraryIndexSelection.resolve(rows[0].id, in: input, actions: actions))
        XCTAssertEqual(
            try XCTUnwrap(
                FoundationLibraryIndexSelection.resolve(rows[1].id, in: input, actions: actions)
            ).sourceIndex, 1)
        let occurrenceModel = FoundationBrowseModel()
        occurrenceModel.installSnapshot(input)
        XCTAssertEqual(occurrenceModel.rawItems, input)
        XCTAssertFalse(occurrenceModel.hasUniqueCatalogIdentity)
        let catalogModel = FoundationBrowseModel()
        catalogModel.configureCatalogPagination()
        catalogModel.installSnapshot(input)
        XCTAssertEqual(
            catalogModel.rawItems, [repeated, album],
            "Only an explicitly unique catalog admits one entity per key")
    }

    func testCatalogArrayRelatedRouteUsesCurrentMetadataAndRejectsChangedTarget() throws {
        var track = item("song")
        track.album = .init(id: "album", title: "Old album")
        let actions = Fixture.actions(scope: "synthetic-catalog-owner")
        let row = try XCTUnwrap(
            FoundationLibraryIndexSelection.positionedItems([track], actions: actions).first)
        let captured = try XCTUnwrap(track.relatedAlbum)
        track.album = .init(id: "album", title: "Current album", primaryImageTag: "current-image")
        XCTAssertEqual(
            FoundationLibraryIndexSelection.relatedDestination(
                captured, from: row.id, in: [track], actions: actions),
            track.relatedAlbum)
        track.album = .init(id: "different-album", title: "Different album")
        XCTAssertNil(
            FoundationLibraryIndexSelection.relatedDestination(
                captured, from: row.id, in: [track], actions: actions))
        XCTAssertNil(
            FoundationLibraryIndexSelection.relatedDestination(
                captured, from: row.id, in: [], actions: actions))
    }

    func testHeldMenuSnapshotRejectsMetadataChangesWhileFreshMenuAndRowIdentitySurvive() throws {
        var original = item("selected", kind: .album)
        original.title = "Old title"
        original.primaryImageTag = "old-artwork"
        original.artist = .init(id: "artist", title: "Old artist")
        let fixture = Fixture(items: [original])
        let held = try fixture.row("selected", kind: .album)
        XCTAssertTrue(
            FoundationLibraryIndexSelection.admits(
                held.item, current: fixture.resolve(held.intent)?.item))
        var updated = original
        updated.title = "Current title"
        updated.primaryImageTag = "current-artwork"
        updated.artist = .init(id: "artist", title: "Current artist")
        fixture.model.installSnapshot([updated])
        let fresh = try fixture.row("selected", kind: .album)
        XCTAssertEqual(fresh.id, held.id, "Metadata does not change logical row identity")
        XCTAssertEqual(try XCTUnwrap(fixture.resolve(held.intent)).item, updated)
        // Exercise the actual captured-item mutation, with only its storage closure
        // isolated in memory. An ID-presence gate would save the old title/artwork.
        if FoundationLibraryIndexSelection.admits(
            held.item, current: fixture.resolve(held.intent)?.item)
        {
            fixture.actions.togglePin(held.item)
        }
        XCTAssertTrue(
            fixture.actions.pinnedRows.isEmpty, "A held menu cannot persist its old snapshot")
        guard fixture.actions.pinnedRows.isEmpty else { return }
        XCTAssertFalse(
            FoundationLibraryIndexSelection.admits(
                held.intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions,
                isActive: true))
        XCTAssertTrue(
            FoundationLibraryIndexSelection.admits(
                fresh.intent, current: fixture.context, model: fixture.model,
                actions: fixture.actions,
                isActive: true))
        if FoundationLibraryIndexSelection.admits(
            fresh.item, current: fixture.resolve(fresh.intent)?.item)
        {
            fixture.actions.togglePin(fresh.item)
        }
        XCTAssertEqual(fixture.actions.pinnedRows.map(\.item), [updated])
        XCTAssertNil(fixture.actions.pinErrorMessage)
        XCTAssertFalse(FoundationLibraryIndexSelection.admits(fresh.item, current: nil))
    }

    private func item(_ id: String, kind: FoundationItem.Kind = .track) -> FoundationItem {
        FoundationItem(id: id, title: id, subtitle: "", kind: kind, duration: nil)
    }

    @MainActor
    private final class Fixture {
        let model = FoundationBrowseModel()
        let actions: FoundationLibraryActions
        var isActive = true
        var isVisible = true
        var query = ""
        var context: FoundationLibraryIndexSelection.Context? {
            FoundationLibraryIndexSelection.context(
                model: model, actions: actions, catalogScope: "all",
                query: query, letter: nil)
        }

        init(items: [FoundationItem], uniqueCatalog: Bool = true) {
            actions = Self.actions(scope: "synthetic-index-owner")
            if uniqueCatalog { model.configureCatalogPagination() }
            model.installSnapshot(items)
        }

        static func actions(scope: String) -> FoundationLibraryActions {
            FoundationLibraryActions(
                sourceScope: scope, read: { _ in nil }, write: { _, _ in },
                mutateFavorite: { _, _ in XCTFail("Index identity must not call a provider") })
        }

        func row(_ id: String, kind: FoundationItem.Kind = .track) throws
            -> FoundationLibraryIndexSelection.Row
        {
            let context = try XCTUnwrap(context)
            return try XCTUnwrap(
                FoundationLibraryIndexSelection.rows(in: model, context: context)
                    .first { $0.item.id == id && $0.item.kind == kind })
        }

        func resolve(_ intent: FoundationLibraryIndexSelection.Intent)
            -> FoundationLibraryIndexSelection.Match?
        {
            FoundationLibraryIndexSelection.resolve(
                intent, current: context, model: model, actions: actions)
        }

        func selection(_ intent: FoundationLibraryIndexSelection.Intent)
            -> FoundationTrackQueueSelection?
        {
            FoundationLibraryIndexSelection.trackQueue(
                intent, current: context, model: model, actions: actions)
        }
    }
}
