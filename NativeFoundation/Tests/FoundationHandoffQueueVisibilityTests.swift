import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationHandoffQueueVisibilityTests: XCTestCase {
    func testTransferredVisibleOccurrencesOverrideReceiverCopyPreferenceWithoutDroppingRawQueue() {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        XCTAssertTrue(player.continueSession(value.snapshot, position: 2, wasPlaying: false))
        XCTAssertEqual(player.persistedQueue, value.entries)
        XCTAssertEqual(player.queue.map(\.id), value.visible)
        XCTAssertEqual(
            player.queue.map(\.item.id), ["current", "source-copy", "source-copy", "last"])
        player.refreshTrackVisibility()
        XCTAssertEqual(player.queue.map(\.id), value.visible)
        XCTAssertNil(player.nativePlayer.currentItem)
    }

    func testShuffleAndRepeatPreserveVisibilityWithoutResurrectingHiddenCopy() {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        player.restoreSession(value.snapshot)
        player.setShuffle(true)
        player.setRepeat(.one)
        assertVisibility(player, visible: Set(value.visible), hidden: value.entries[1].id)
        player.setShuffle(false)
        player.setRepeat(.all)
        assertVisibility(player, visible: Set(value.visible), hidden: value.entries[1].id)
        XCTAssertEqual(player.persistedQueue.count, value.entries.count)
        XCTAssertEqual(player.selectedEntryID, value.entries[0].id)
    }

    func testReorderRemoveAndExplicitAdditionUpdateOnlyTheirOwnOccurrences() {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        player.restoreSession(value.snapshot)
        let last = value.entries[4].id
        player.reorderUpcoming([last], before: value.entries[2].id)
        XCTAssertEqual(
            player.queue.map(\.id),
            [value.entries[0].id, last, value.entries[2].id, value.entries[3].id])
        XCTAssertFalse(player.queue.contains { $0.id == value.entries[1].id })
        player.removeUpcoming(value.entries[2].id)
        XCTAssertEqual(player.queue.map(\.id), [value.entries[0].id, last, value.entries[3].id])
        XCTAssertEqual(player.persistedQueue.count, 4)
        player.enqueue([Fixture.item("new", track: 4)], position: .next)
        let added = player.persistedQueue.first { $0.item.id == "new" }?.id
        XCTAssertNotNil(added)
        XCTAssertEqual(player.queue.map(\.item.id), ["current", "new", "last", "source-copy"])
        XCTAssertEqual(player.persistedVisibleEntryIDs, player.queue.map(\.id))
        XCTAssertTrue(player.persistedQueue.contains { $0.id == value.entries[1].id })
        XCTAssertFalse(player.queue.contains { $0.id == value.entries[1].id })
    }

    func testPausedDiskPersistenceAndRelaunchKeepSourceVisibleSubsequence() throws {
        let value = Fixture()
        // Match the production directory URL contract used by the store's protection helper.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FoundationPlaybackSessionStore(scope: "handoff-test", root: root)
        let first = makePlayer()
        defer { first.stop() }
        first.restoreSession(value.snapshot)
        first.setRepeat(.one)
        XCTAssertTrue(root.hasDirectoryPath)
        XCTAssertTrue(store.save(FoundationPlaybackSnapshot(player: first)))
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.visibleEntryIDs, value.visible)
        let second = makePlayer()
        defer { second.stop() }
        second.restoreSession(loaded)
        XCTAssertEqual(second.persistedQueue, value.entries)
        XCTAssertEqual(second.queue.map(\.id), value.visible)
        XCTAssertEqual(second.selectedEntryID, value.entries[0].id)
        XCTAssertEqual(second.repeatMode, .one)
        XCTAssertEqual(second.state, .paused)
        XCTAssertFalse(second.wantsPlayback)
        XCTAssertNil(second.nativePlayer.currentItem)
        XCTAssertNil(second.selectionTask)
    }

    func testExplicitCopyPreferenceChangeRetiresOverrideAndPersistsItsRemoval() throws {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        player.restoreSession(value.snapshot)
        player.clearContinuationVisibilityForPreferenceChange()
        XCTAssertNil(player.persistedVisibleEntryIDs)
        XCTAssertEqual(player.queue.map(\.item.id), ["current", "receiver-copy", "last"])
        let data = try JSONEncoder().encode(FoundationPlaybackSnapshot(player: player))
        let reloaded = try JSONDecoder().decode(FoundationPlaybackSnapshot.self, from: data)
        XCTAssertNil(reloaded.visibleEntryIDs)
        XCTAssertTrue(reloaded.isValid)
    }

    func testWholeQueueAndContextRestorationRetirePreviousOverride() {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        player.restoreSession(value.snapshot)
        player.setQueue([Fixture.item("replacement", track: 5)], selectedIndex: 0)
        XCTAssertNil(player.persistedVisibleEntryIDs)
        let ordinary = FoundationPlaybackSnapshot(
            entries: value.entries,
            selectedEntryID: value.entries[0].id, shuffleEnabled: false, repeatMode: .off)
        player.restoreSession(ordinary)
        XCTAssertNil(player.persistedVisibleEntryIDs)
        XCTAssertEqual(player.queue.map(\.item.id), ["current", "receiver-copy", "last"])
        player.restoreSession(value.snapshot)
        player.setQueue([], selectedIndex: 0)
        XCTAssertNil(player.persistedVisibleEntryIDs)
        XCTAssertTrue(player.queue.isEmpty)
    }

    func testMalformedVisibleSubsequenceCannotReplaceCurrentSession() throws {
        let value = Fixture()
        let player = makePlayer()
        defer { player.stop() }
        player.restoreSession(value.snapshot)
        let malformed = [
            [value.entries[0].id, value.entries[0].id],
            [value.entries[0].id, UUID()],
            [value.entries[2].id, value.entries[0].id],
            [value.entries[2].id],
        ]
        for ids in malformed {
            let invalid = FoundationPlaybackSnapshot(
                entries: value.entries,
                selectedEntryID: value.entries[0].id, shuffleEnabled: false,
                repeatMode: .off, visibleEntryIDs: ids)
            XCTAssertFalse(invalid.isValid)
            XCTAssertFalse(player.continueSession(invalid, position: 2, wasPlaying: false))
            XCTAssertEqual(player.queue.map(\.id), value.visible)
            XCTAssertEqual(player.persistedQueue, value.entries)
        }
        // Historical snapshots omit the optional override and retain local preference semantics.
        let ordinary = FoundationPlaybackSnapshot(
            entries: value.entries,
            selectedEntryID: value.entries[0].id, shuffleEnabled: false, repeatMode: .off)
        let data = try JSONEncoder().encode(ordinary)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("visibleEntryIDs"))
        XCTAssertTrue(try JSONDecoder().decode(FoundationPlaybackSnapshot.self, from: data).isValid)
    }

    private func assertVisibility(
        _ player: FoundationPlayer, visible: Set<UUID>, hidden: UUID,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Set(player.queue.map(\.id)), visible, file: file, line: line)
        XCTAssertEqual(
            player.queue.map(\.id),
            player.persistedQueue.filter { visible.contains($0.id) }.map(\.id), file: file,
            line: line)
        XCTAssertEqual(
            player.persistedVisibleEntryIDs, player.queue.map(\.id), file: file, line: line)
        XCTAssertFalse(player.queue.contains { $0.id == hidden }, file: file, line: line)
    }

    private func makePlayer() -> FoundationPlayer {
        let player = FoundationPlayer(
            resolve: { _ in throw CancellationError() },
            activateSession: {}, deactivateSession: {})
        player.configureTrackProjection(project: {
            FoundationAlbumTrackPolicy.visibleTracks($0, showDuplicates: false)
        })
        return player
    }

    private struct Fixture {
        let entries = [
            FoundationQueueEntry(item: Fixture.item("current", track: 1)),
            FoundationQueueEntry(item: Fixture.item("receiver-copy", track: 2)),
            FoundationQueueEntry(item: Fixture.item("source-copy", track: 2)),
            FoundationQueueEntry(item: Fixture.item("source-copy", track: 2)),
            FoundationQueueEntry(item: Fixture.item("last", track: 3)),
        ]
        var visible: [UUID] { [entries[0].id, entries[2].id, entries[3].id, entries[4].id] }
        var snapshot: FoundationPlaybackSnapshot {
            .init(
                entries: entries, selectedEntryID: entries[0].id, shuffleEnabled: false,
                repeatMode: .off, visibleEntryIDs: visible)
        }
        static func item(_ id: String, track: Int) -> FoundationItem {
            .init(
                id: id, title: "Song \(track)", subtitle: "Artist", kind: .track, duration: 20,
                album: .init(id: "album", title: "Album"), trackNumber: track, discNumber: 1)
        }
    }
}
