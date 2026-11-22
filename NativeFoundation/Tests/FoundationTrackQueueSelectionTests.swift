import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationTrackQueueSelectionTests: XCTestCase {
    func testRepeatedTrackIDsPreserveTheSelectedSourceOccurrence() throws {
        let first = track("same", entry: "first")
        let second = track("same", entry: "second")
        let third = track("same", entry: "third")
        let selection = try XCTUnwrap(
            FoundationTrackQueueSelection(in: [first, second, third], selecting: 2))

        XCTAssertEqual(selection.items, [first, second, third])
        XCTAssertEqual(selection.index, 2)
        XCTAssertEqual(selection.items[selection.index].playlistEntryID, "third")
    }

    func testOfflineFilteringRemapsOnlyByRetainedPrecedingOccurrences() throws {
        let unavailable = track("unavailable")
        let first = track("same", entry: "first")
        let selected = track("same", entry: "selected")
        let later = track("later")
        let selection = try XCTUnwrap(
            FoundationTrackQueueSelection(
                in: [unavailable, first, unavailable, selected, later], selecting: 3,
                isAvailable: { $0.id != "unavailable" }))

        XCTAssertEqual(selection.items, [first, selected, later])
        XCTAssertEqual(selection.index, 1)
        XCTAssertEqual(selection.items[selection.index], selected)
    }

    func testUnavailableSelectedOccurrenceNeverFallsBackToAnotherCopy() {
        let first = track("same", entry: "first")
        let selected = track("same", entry: "selected")
        XCTAssertNil(
            FoundationTrackQueueSelection(
                in: [first, selected], selecting: 1,
                isAvailable: { $0.playlistEntryID == "first" }))
        XCTAssertNil(
            FoundationTrackQueueSelection(
                in: [first, selected], selecting: 0, isAvailable: { _ in false }))
    }

    func testMixedKindsAreFilteredWithoutChangingTheSelectedTrackOccurrence() throws {
        let album = item("album", kind: .album)
        let artist = item("artist", kind: .artist)
        let first = track("same", entry: "first")
        let selected = track("same", entry: "selected")
        let source = [album, first, artist, selected, item("playlist", kind: .playlist)]
        let selection = try XCTUnwrap(FoundationTrackQueueSelection(in: source, selecting: 3))

        XCTAssertEqual(selection.items, [first, selected])
        XCTAssertEqual(selection.index, 1)
        for index in [0, 2, 4] {
            XCTAssertNil(FoundationTrackQueueSelection(in: source, selecting: index))
        }
    }

    func testInvalidSourceIndicesAreRejectedBeforeReadingAvailability() {
        var reads = 0
        let available: (FoundationItem) -> Bool = { _ in
            reads += 1
            return true
        }
        for index in [-1, 1, Int.max] {
            XCTAssertNil(
                FoundationTrackQueueSelection(
                    in: [track("track")], selecting: index, isAvailable: available))
        }
        XCTAssertNil(
            FoundationTrackQueueSelection(in: [], selecting: 0, isAvailable: available))
        XCTAssertEqual(reads, 0)
    }

    func testOnlineAndFullyAvailableOfflineSelectionsHaveIdenticalOrderAndCursor() throws {
        let source = [track("same"), item("album", kind: .album), track("same"), track("later")]
        let online = try XCTUnwrap(FoundationTrackQueueSelection(in: source, selecting: 2))
        let offline = try XCTUnwrap(
            FoundationTrackQueueSelection(in: source, selecting: 2, isAvailable: { _ in true }))

        XCTAssertEqual(online.items, offline.items)
        XCTAssertEqual(online.index, offline.index)
        XCTAssertEqual(online.index, 1)
    }

    func testBrowseModelAppliesAvailabilityToLoadedOccurrencesOnly() throws {
        let model = FoundationBrowseModel()
        let first = track("same", entry: "first")
        let selected = track("same", entry: "selected")
        model.installSnapshot([track("unavailable"), first, selected])
        let selection = try XCTUnwrap(
            model.trackQueue(selecting: 2, isAvailable: { $0.id != "unavailable" }))

        XCTAssertEqual(selection.items, [first, selected])
        XCTAssertEqual(selection.index, 1)
        XCTAssertNil(model.trackQueue(selecting: 0, isAvailable: { $0.id != "unavailable" }))
        XCTAssertEqual(model.items.count, 3)
    }

    func testFavoriteAndOfflineFiltersComposeWithoutCollapsingDuplicateOccurrences() throws {
        let actions = FoundationLibraryActions(
            sourceScope: "synthetic", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        var removedFavorite = track("removed")
        removedFavorite.isFavorite = false
        let unavailable = track("unavailable")
        let first = track("same", entry: "first")
        let selected = track("same", entry: "selected")
        let source = [removedFavorite, first, item("album", kind: .album), unavailable, selected]
        let selection = try XCTUnwrap(
            actions.favoriteTrackQueue(
                in: source, selecting: 4, isAvailable: { $0.id != "unavailable" }))

        XCTAssertEqual(selection.items, [first, selected])
        XCTAssertEqual(selection.index, 1)
        XCTAssertNil(actions.favoriteTrackQueue(in: source, selecting: 0))
        XCTAssertNil(
            actions.favoriteTrackQueue(
                in: source, selecting: 3, isAvailable: { $0.id != "unavailable" }))
    }

    private func track(_ id: String, entry: String? = nil) -> FoundationItem {
        var value = item(id, kind: .track)
        value.playlistEntryID = entry
        return value
    }

    private func item(_ id: String, kind: FoundationItem.Kind) -> FoundationItem {
        FoundationItem(id: id, title: id, subtitle: "", kind: kind, duration: nil)
    }
}
