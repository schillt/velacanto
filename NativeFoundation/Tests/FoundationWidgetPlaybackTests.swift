import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationWidgetPlaybackTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func snapshot(occurrence: UUID = UUID()) -> FoundationWidgetSnapshot {
        .init(
            version: 1, presentation: .track, scope: scope, occurrence: occurrence,
            collection: nil, title: "Synthetic song", detail: "Synthetic artist", isPlaying: false)
    }

    func testWidgetCommandRejectsForeignAccountAndStaleOccurrenceWithoutToggling() {
        let current = snapshot()
        XCTAssertTrue(
            FoundationWidgetCommand(
                scope: scope, occurrence: current.occurrence, collectionID: nil, action: .play
            ).matches(current))
        XCTAssertTrue(
            FoundationWidgetCommand(
                scope: scope, occurrence: current.occurrence, collectionID: nil, action: .pause
            ).matches(current))
        XCTAssertFalse(
            FoundationWidgetCommand(
                scope: String(repeating: "b", count: 64), occurrence: current.occurrence,
                collectionID: nil, action: .play
            ).matches(current))
        XCTAssertFalse(
            FoundationWidgetCommand(
                scope: scope, occurrence: UUID(), collectionID: nil, action: .pause
            ).matches(current))
        XCTAssertFalse(
            FoundationWidgetCommand(
                scope: scope, occurrence: nil, collectionID: "collection", action: .collection
            ).matches(current))
        XCTAssertFalse(
            FoundationWidgetCommand(
                scope: scope, occurrence: current.occurrence, collectionID: nil, action: .play
            ).matches(.empty))
    }

    func testWidgetStorePublishesMatchingBoundedArtworkAndClearsOnlyItsAccount() throws {
        let root = try root().appendingPathComponent("widgets")
        let store = FoundationWidgetStore(location: .directory(root))
        let first = snapshot()
        let bytes = Data(repeating: 42, count: 128)
        try store.save(first, artwork: bytes)
        let loaded = try store.load()
        XCTAssertEqual(loaded.occurrence, first.occurrence)
        XCTAssertEqual(store.artwork(for: loaded), bytes)
        XCTAssertFalse(store.clear(scope: String(repeating: "b", count: 64)))
        XCTAssertEqual(try store.load(), loaded)
        let next = snapshot()
        try store.save(next, artwork: Data(repeating: 55, count: 64))
        XCTAssertLessThanOrEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
        XCTAssertEqual(store.artwork(for: loaded), bytes)
        try store.save(next, artwork: nil)
        XCTAssertNil(store.artwork(for: loaded))
        XCTAssertTrue(store.clear(scope: scope))
        XCTAssertEqual(try store.load(), .empty)
    }

    func testWidgetStoreRecoversBoundedCrashOrphansBeforeRepeatedPublication() throws {
        let root = try root()
        let store = FoundationWidgetStore(location: .directory(root))
        let bytes = Data(repeating: 42, count: 128)
        try store.save(snapshot(), artwork: bytes)
        let committed = try store.load()
        for _ in 0..<7 {
            try Data(repeating: 99, count: 32).write(
                to: root.appendingPathComponent(UUID().uuidString + ".jpg"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 9)
        let next = snapshot()
        XCTAssertThrowsError(try store.save(next, artwork: Data(repeating: 55, count: 64)))
        XCTAssertEqual(try store.load(), committed)
        XCTAssertEqual(store.artwork(for: committed), bytes)
        // The refused bounded batch removed only known unreferenced files. The next
        // defined publication completes maintenance without increasing the scan limit.
        try store.save(next, artwork: Data(repeating: 55, count: 64))
        for byte: UInt8 in [56, 57, 58] {
            let image = Data(repeating: byte, count: 64)
            try store.save(next, artwork: image)
            let saved = try store.load()
            XCTAssertEqual(saved.occurrence, next.occurrence)
            XCTAssertEqual(store.artwork(for: saved), image)
            XCTAssertLessThanOrEqual(
                try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
        }
    }

    func testWidgetStoreRejectsOversizedAndUnsafeRecords() throws {
        let root = try root()
        let store = FoundationWidgetStore(location: .directory(root))
        try Data(repeating: 65, count: FoundationWidgetSnapshot.maximumBytes + 1)
            .write(to: root.appendingPathComponent("snapshot.json"))
        XCTAssertThrowsError(try store.load())
        let other = try self.root()
        let link = other.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(
            try FoundationWidgetStore(location: .directory(link)).save(
                snapshot(), artwork: nil))
        var bad = snapshot()
        bad.artworkName = "../private.jpg"
        XCTAssertFalse(bad.isValid)
        XCTAssertThrowsError(try store.save(bad, artwork: nil))
        XCTAssertFalse(
            FoundationWidgetSnapshot.Collection(
                id: "playlist", kind: "playlist", title: "Bad\nTitle", subtitle: "", imageTag: nil
            ).isValid)
    }

    func testWidgetStorageRejectsRetiredPublisherAndDoesNotOverwriteNewAccount() async throws {
        let root = try root()
        let storage = FoundationWidgetStorage(location: .directory(root), reload: {})
        let store = FoundationWidgetStore(location: .directory(root))
        let dormant = UUID()
        await storage.retire(owner: dormant, generation: 1)
        do {
            try await storage.activate(owner: dormant, scope: scope, generation: 1)
            XCTFail("A publisher retired before activation must stay retired")
        } catch {}
        let old = UUID()
        try await storage.activate(owner: old, scope: scope, generation: 2)
        await storage.publishMetadata(
            owner: old, sequence: 1, snapshot: snapshot(), currentRevision: nil)
        let next = UUID()
        let nextScope = String(repeating: "b", count: 64)
        try await storage.activate(owner: next, scope: nextScope, generation: 3)
        let current = FoundationWidgetSnapshot(
            version: 1, presentation: .track, scope: nextScope, occurrence: UUID(), collection: nil,
            title: "New account", detail: "Synthetic", isPlaying: true)
        await storage.publishMetadata(
            owner: next, sequence: 1, snapshot: current, currentRevision: nil)
        await storage.publishMetadata(
            owner: old, sequence: 1, snapshot: snapshot(), currentRevision: nil)
        await storage.retire(owner: old, generation: 2)
        XCTAssertEqual(try store.load(), current)
        let rejected = await storage.clear(scope: scope)
        XCTAssertFalse(rejected)
        XCTAssertEqual(try store.load(), current)
        let cleared = await storage.clear(scope: nextScope)
        XCTAssertTrue(cleared)
    }

    private func imageData() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 32,
                bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    private func recent(_ title: String = "Recent playlist", tag: String = "art-1")
        -> FoundationWidgetSnapshot.Collection
    {
        .init(
            id: "recent-playlist", kind: "playlist", title: title, subtitle: "Synthetic",
            imageTag: tag)
    }

    private func paired(
        _ title: String = "Current song", occurrence: UUID = UUID(),
        collection: FoundationWidgetSnapshot.Collection? = nil,
        recent: FoundationWidgetSnapshot.Collection? = nil
    ) -> FoundationWidgetSnapshot {
        .init(
            version: 1, presentation: .track, scope: scope, occurrence: occurrence,
            collection: collection, title: title, detail: "Current artist", isPlaying: false,
            recentCollection: recent ?? self.recent())
    }

    func testWidgetModesKeepCurrentAndRecentReachableDuringActiveQueue() async throws {
        let player = FoundationPlayer(
            resolve: { _ in throw FoundationLibraryError.unavailable },
            activateSession: {}, deactivateSession: {}, observeSystemEvents: false)
        defer { player.stop() }
        let track = FoundationItem(
            id: "song", title: "Selected song", subtitle: "Artist", kind: .track, duration: nil)
        let entry = FoundationQueueEntry(item: track)
        var saved = FoundationPlaybackSnapshot(
            entries: [entry], selectedEntryID: entry.id,
            shuffleEnabled: false, repeatMode: .off)
        saved.lastCollection = recent()
        player.restoreSession(saved)
        let record = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
        XCTAssertEqual(record.display(.currentSong).title, track.title)
        XCTAssertEqual(record.display(.currentSong).occurrence, entry.id)
        XCTAssertEqual(record.display(.recentCollection).title, recent().title)
        XCTAssertEqual(record.display(.recentCollection).action, .collection)
        XCTAssertEqual(player.selectedEntryID, entry.id)
        XCTAssertEqual(player.state, .paused)
        XCTAssertEqual(FoundationWidgetConfigurationIntent().displayMode, .currentSong)
        saved.collection = saved.lastCollection
        player.restoreSession(saved)
        let matching = FoundationWidgetPlayback.snapshot(scope: scope, player: player).display(
            .recentCollection)
        XCTAssertEqual(matching.occurrence, entry.id)
        XCTAssertEqual(matching.action, .play)
        XCTAssertEqual(matching.collection?.id, recent().id)
        player.enqueue([], position: .last)
        XCTAssertEqual(player.playbackCollection?.id, recent().id)
        let unrelated = FoundationItem(
            id: "unrelated", title: "Unrelated queued song",
            subtitle: "Other artist", kind: .track, duration: nil)
        player.enqueue([unrelated], position: .last)
        XCTAssertNil(player.playbackCollection)
        XCTAssertEqual(player.lastPlaybackCollection?.id, recent().id)
        XCTAssertEqual(player.queue.map(\.item.id), [track.id, unrelated.id])
        XCTAssertEqual(player.selectedEntryID, entry.id)
        XCTAssertEqual(player.state, .paused)
        let mixed = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
        XCTAssertEqual(mixed.display(.recentCollection).action, .collection)
        XCTAssertEqual(mixed.display(.currentSong).occurrence, entry.id)
        // The existing saved-queue schema carries the conservative unknown origin.
        let savedMixed = FoundationPlaybackSnapshot(player: player)
        XCTAssertNil(savedMixed.collection)
        XCTAssertEqual(savedMixed.lastCollection?.id, recent().id)
        let appended = try XCTUnwrap(player.queue.last)
        var selectedMixed = FoundationPlaybackSnapshot(
            entries: player.queue,
            selectedEntryID: appended.id, shuffleEnabled: false, repeatMode: .off)
        selectedMixed.lastCollection = savedMixed.lastCollection
        player.restoreSession(selectedMixed)
        let onUnrelated = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
        XCTAssertEqual(onUnrelated.display(.currentSong).occurrence, appended.id)
        XCTAssertEqual(onUnrelated.display(.currentSong).title, unrelated.title)
        XCTAssertEqual(onUnrelated.display(.recentCollection).collection?.id, recent().id)
        XCTAssertEqual(onUnrelated.display(.recentCollection).action, .collection)
        XCTAssertNil(onUnrelated.display(.recentCollection).occurrence)
        XCTAssertEqual(player.queue.map(\.item.id), [track.id, unrelated.id])
        try await checkWidgetBackwardCollectionOrigin()
    }

    private func joinWidgetSelectionTasks(_ tasks: [Task<Void, Never>]) async throws {
        // All selections use a throwing resolver and are cancelled before this first yield.
        // No resource/network/audio producer is admitted; still join exact owned handles.
        for task in tasks { task.cancel() }
        let done = XCTestExpectation(description: "isolated widget selection owners joined")
        let join = Task {
            for task in tasks { await task.value }
            done.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [done], timeout: 5)
        if result != .completed || Task.isCancelled {
            join.cancel()
            XCTFail("Timed out/cancelled while joining isolated widget selection owners")
            throw CancellationError()
        }
        await join.value
    }

    private func checkWidgetBackwardCollectionOrigin() async throws {
        let player = FoundationPlayer(
            resolve: { _ in throw FoundationLibraryError.unavailable },
            activateSession: {}, deactivateSession: {}, observeSystemEvents: false)
        var owned: [Task<Void, Never>] = []
        func captureSelection() { if let task = player.selectionTask { owned.append(task) } }
        func stop() {
            player.stop()
            if let task = player.sessionTask { owned.append(task) }
        }
        let older = FoundationQueueEntry(
            item: .init(
                id: "old-B", title: "Older history B",
                subtitle: "", kind: .track, duration: nil))
        let album = FoundationItem(
            id: "album-A", title: "Album A", subtitle: "Artist",
            kind: .album, duration: nil)
        let songs = [
            FoundationItem(id: "A-one", title: "A one", subtitle: "", kind: .track, duration: nil),
            FoundationItem(id: "A-two", title: "A two", subtitle: "", kind: .track, duration: nil),
        ]
        do {
            player.restoreSession(
                .init(
                    entries: [older], selectedEntryID: older.id,
                    shuffleEnabled: false, repeatMode: .off))
            player.setQueue(songs, selectedIndex: 0, collection: album)
            captureSelection()
            player.pause()
            let first = try XCTUnwrap(player.selectedEntryID)
            XCTAssertEqual(player.queue.map(\.item.id), [older.item.id, songs[0].id, songs[1].id])
            XCTAssertEqual(
                FoundationWidgetPlayback.snapshot(scope: scope, player: player)
                    .display(.recentCollection).action, .play)
            player.select(first)
            captureSelection()
            XCTAssertEqual(
                player.playbackCollection?.id, album.id,
                "Same-occurrence restart keeps known origin")
            player.previous()
            captureSelection()
            let backward = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
            XCTAssertEqual(player.selectedEntryID, older.id)
            XCTAssertNil(player.playbackCollection)
            XCTAssertEqual(player.lastPlaybackCollection?.id, album.id)
            XCTAssertEqual(backward.display(.currentSong).occurrence, older.id)
            XCTAssertEqual(backward.display(.recentCollection).action, .collection)
            XCTAssertNil(backward.display(.recentCollection).occurrence)
            XCTAssertEqual(player.queue.map(\.item.id), [older.item.id, songs[0].id, songs[1].id])
            stop()
            try await joinWidgetSelectionTasks(owned)
            owned.removeAll()
            player.restoreSession(
                .init(
                    entries: [older], selectedEntryID: older.id,
                    shuffleEnabled: false, repeatMode: .off))
            player.setQueue(songs, selectedIndex: 0, collection: album)
            captureSelection()
            let last = try XCTUnwrap(player.queue.last?.id)
            player.select(last)
            captureSelection()
            player.pause()
            XCTAssertEqual(
                player.playbackCollection?.id, album.id,
                "Forward pure-collection selection stays known")
            player.setRepeat(.all)
            player.next()
            captureSelection()
            let wrapped = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
            XCTAssertEqual(player.selectedEntryID, older.id)
            XCTAssertNil(player.playbackCollection)
            XCTAssertEqual(wrapped.display(.currentSong).occurrence, older.id)
            XCTAssertEqual(wrapped.display(.recentCollection).collection?.id, album.id)
            XCTAssertEqual(wrapped.display(.recentCollection).action, .collection)
            XCTAssertEqual(player.queue.map(\.item.id), [older.item.id, songs[0].id, songs[1].id])
            stop()
            try await joinWidgetSelectionTasks(owned)
        } catch {
            captureSelection()
            stop()
            try await joinWidgetSelectionTasks(owned)
            throw error
        }
    }

    func testWidgetRecentCommandsUseTargetIdentityAndOccurrenceOnlyForCurrentControl() throws {
        let initial = paired()
        let changed = paired(occurrence: UUID())
        let start = FoundationWidgetCommand(
            scope: scope, occurrence: nil, collectionID: recent().id,
            action: .collection, mode: .recentCollection, collectionKind: "playlist")
        XCTAssertTrue(start.matches(initial))
        XCTAssertTrue(
            start.matches(changed), "An unchanged recent target remains valid before the tap")
        var wrongKind = start
        wrongKind.collectionKind = "album"
        XCTAssertFalse(wrongKind.matches(changed))
        var missingTarget = changed
        missingTarget.recentCollection = .init(
            id: "other", kind: "playlist", title: "Other", subtitle: "", imageTag: nil)
        XCTAssertFalse(start.matches(missingTarget))
        let initialOccurrence = try XCTUnwrap(initial.occurrence)
        let known = paired(occurrence: initialOccurrence, collection: recent())
        let pause = FoundationWidgetCommand(
            scope: scope, occurrence: initial.occurrence,
            collectionID: recent().id, action: .pause, mode: .recentCollection,
            collectionKind: "playlist")
        XCTAssertTrue(pause.matches(known))
        XCTAssertFalse(pause.matches(changed))
        XCTAssertFalse(pause.matches(initial), "Matching track IDs never imply playlist origin")
    }

    func testWidgetLegacyCacheDropsMalformedOptionalRecentPairWithoutLosingCurrent() throws {
        let original = snapshot()
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "recentCollection")
        json.removeValue(forKey: "recentArtworkName")
        let legacy = try JSONDecoder().decode(
            FoundationWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy, original)
        json["recentCollection"] = [
            "id": "recent", "kind": "playlist", "title": "Recent", "subtitle": "",
        ]
        json["recentArtworkName"] = "../foreign.jpg"
        let malformed = try JSONDecoder().decode(
            FoundationWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(malformed, original)
        XCTAssertNil(malformed.recentArtworkName)
        json["occurrence"] = "not-a-UUID"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                FoundationWidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(paired()).count, FoundationWidgetSnapshot.maximumBytes)
    }

    func testWidgetStoreCommitsTwoSlotsAndRecoversBoundedCrashOrphans() throws {
        let directory = try root()
        let store = FoundationWidgetStore(location: .directory(directory))
        let record = paired()
        let current = Data(repeating: 12, count: 128)
        let recent = Data(repeating: 24, count: 96)
        try store.save(record, artwork: current, recentArtwork: recent)
        let committed = try store.load()
        XCTAssertEqual(committed.referencedArtwork.count, 2)
        XCTAssertEqual(store.artwork(for: committed), current)
        XCTAssertEqual(store.artwork(for: committed, mode: .recentCollection), recent)
        for _ in 0..<6 {
            try Data([3]).write(to: directory.appendingPathComponent(UUID().uuidString + ".jpg"))
        }
        XCTAssertThrowsError(try store.save(record, artwork: Data([4]), recentArtwork: Data([5])))
        XCTAssertEqual(try store.load(), committed)
        XCTAssertEqual(store.artwork(for: committed), current)
        XCTAssertEqual(store.artwork(for: committed, mode: .recentCollection), recent)
        try store.save(record, artwork: Data([4]), recentArtwork: Data([5]))
        let recovered = try store.load()
        XCTAssertEqual(store.artwork(for: recovered), Data([4]))
        XCTAssertEqual(store.artwork(for: recovered, mode: .recentCollection), Data([5]))
        XCTAssertLessThanOrEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 5)
        XCTAssertTrue(store.clear(scope: scope))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    #if FOUNDATION_ISOLATED_TEST_HOST
        func testWidgetTwoImageFailurePreservesCommittedPairAndMetadataFirstUpdate() throws {
            let directory = try root()
            let store = FoundationWidgetStore(location: .directory(directory))
            try store.save(paired(), artwork: Data([1]), recentArtwork: Data([2]))
            let committed = try store.load()
            for failure in [
                FoundationWidgetStore.PublicationFailure.afterFirstArtwork, .beforeMetadata,
            ] {
                let fault = FoundationWidgetStore(
                    location: .directory(directory), testFailure: failure)
                XCTAssertThrowsError(
                    try fault.save(paired(), artwork: Data([3]), recentArtwork: Data([4])))
                XCTAssertEqual(try store.load(), committed)
                XCTAssertEqual(store.artwork(for: committed), Data([1]))
                XCTAssertEqual(store.artwork(for: committed, mode: .recentCollection), Data([2]))
            }
            let updated = paired("New metadata")
            try store.save(updated, artwork: nil)
            let metadata = try store.load()
            XCTAssertEqual(metadata.title, "New metadata")
            XCTAssertNil(store.artwork(for: metadata))
            let fault = FoundationWidgetStore(
                location: .directory(directory), testFailure: .beforeMetadata)
            XCTAssertThrowsError(
                try fault.save(updated, artwork: Data([3]), recentArtwork: Data([4])))
            XCTAssertEqual(try store.load(), metadata)
            XCTAssertEqual(store.artwork(for: metadata, mode: .recentCollection), Data([2]))
        }
    #endif

    func testWidgetArtworkEnrichmentPreservesNewMetadataAndRejectsRetiredGeneration() async throws {
        let directory = try root()
        let storage = FoundationWidgetStorage(location: .directory(directory), reload: {})
        let store = FoundationWidgetStore(location: .directory(directory))
        let owner = UUID()
        try await storage.activate(owner: owner, scope: scope, generation: 1)
        let first = paired()
        let firstOccurrence = try XCTUnwrap(first.occurrence)
        let oldRevision = UUID()
        let revision = UUID()
        _ = await storage.publishMetadata(
            owner: owner, sequence: 1, snapshot: first, currentRevision: oldRevision)
        let image = try imageData()
        let initialArt = await storage.publishCurrentArtwork(
            owner: owner, occurrence: firstOccurrence, revision: oldRevision, data: image)
        XCTAssertTrue(initialArt)
        XCTAssertNotNil(store.artwork(for: try store.load()))
        let newest = paired(
            "Newest title", occurrence: firstOccurrence, recent: recent("Renamed playlist"))
        _ = await storage.publishMetadata(
            owner: owner, sequence: 2, snapshot: newest, currentRevision: revision)
        XCTAssertNil(
            store.artwork(for: try store.load()),
            "A new provider revision must not retain the prior image")
        _ = await storage.publishMetadata(
            owner: owner, sequence: 1, snapshot: first,
            currentRevision: oldRevision)
        XCTAssertEqual(try store.load().title, "Newest title")
        let stale = await storage.publishCurrentArtwork(
            owner: owner, occurrence: firstOccurrence, revision: oldRevision, data: image)
        XCTAssertFalse(stale)
        let current = await storage.publishCurrentArtwork(
            owner: owner, occurrence: firstOccurrence, revision: revision, data: image)
        XCTAssertTrue(current)
        let staleCollection = await storage.publishRecentArtwork(
            owner: owner, collection: recent(tag: "old-art"), data: image)
        XCTAssertFalse(staleCollection)
        let collection = await storage.publishRecentArtwork(
            owner: owner, collection: recent(), data: image)
        XCTAssertTrue(collection)
        let saved = try store.load()
        XCTAssertEqual(saved.title, "Newest title")
        XCTAssertEqual(saved.recentCollection?.title, "Renamed playlist")
        XCTAssertNotNil(store.artwork(for: saved))
        XCTAssertNotNil(store.artwork(for: saved, mode: .recentCollection))
        await storage.retire(owner: owner, generation: 1)
        let cleared = await storage.clear(scope: scope)
        XCTAssertTrue(cleared)
        do {
            try await storage.activate(owner: owner, scope: scope, generation: 1)
            XCTFail("Retired generation reactivated")
        } catch {}
        let late = await storage.publishRecentArtwork(
            owner: owner, collection: recent(), data: image)
        XCTAssertFalse(late)
        XCTAssertEqual(try store.load(), .empty)
    }

    func testCollectionContextRestoresWithoutChangingQueueOccurrenceOrOldSnapshotFormat() throws {
        let player = FoundationPlayer(
            resolve: { _ in throw FoundationLibraryError.unavailable },
            activateSession: {}, deactivateSession: {}, observeSystemEvents: false)
        defer { player.stop() }
        let collection = FoundationItem(
            id: "playlist", title: "Synthetic playlist", subtitle: "Synthetic", kind: .playlist,
            duration: nil)
        let track = FoundationItem(
            id: "track", title: "Synthetic track", subtitle: "Synthetic", kind: .track,
            duration: nil)
        let occurrence = FoundationQueueEntry(item: track)
        var saved = FoundationPlaybackSnapshot(
            entries: [occurrence], selectedEntryID: occurrence.id, shuffleEnabled: false,
            repeatMode: .off)
        saved.collection = FoundationWidgetSnapshot.Collection(collection)
        saved.lastCollection = saved.collection
        player.restoreSession(saved)
        XCTAssertEqual(player.selectedEntryID, occurrence.id)
        XCTAssertEqual(player.playbackCollection?.id, collection.id)
        let widget = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
        XCTAssertEqual(widget.presentation, .track)
        XCTAssertEqual(widget.collection?.id, collection.id)
        player.setQueue([], selectedIndex: 0)
        let idle = FoundationWidgetPlayback.snapshot(scope: scope, player: player)
        XCTAssertEqual(idle.presentation, .collection)
        XCTAssertTrue(
            FoundationWidgetCommand(
                scope: scope, occurrence: nil, collectionID: collection.id, action: .collection,
                mode: .recentCollection, collectionKind: "playlist"
            ).matches(idle))
        let encoded = try JSONEncoder().encode(saved)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "collection")
        old.removeValue(forKey: "lastCollection")
        let legacy = try JSONDecoder().decode(
            FoundationPlaybackSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(legacy.isValid)
        XCTAssertNil(legacy.collection)
        player.restoreSession(legacy)
        XCTAssertEqual(player.selectedEntryID, occurrence.id)
        XCTAssertNil(player.lastPlaybackCollection)
        old["collection"] = 42
        old["lastCollection"] = ["kind": "future-kind", "id": "unknown"]
        let unknownContext = try JSONDecoder().decode(
            FoundationPlaybackSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertTrue(unknownContext.isValid)
        player.restoreSession(unknownContext)
        XCTAssertEqual(player.selectedEntryID, occurrence.id)
        XCTAssertNil(player.playbackCollection)
        XCTAssertNil(player.lastPlaybackCollection)
        player.restoreSession(saved)
        XCTAssertNotNil(player.playbackCollection)
        XCTAssertTrue(player.continueSession(legacy, position: 0, wasPlaying: false))
        XCTAssertNil(player.playbackCollection)
        XCTAssertNil(player.lastPlaybackCollection)

        old["entries"] = []
        old.removeValue(forKey: "selectedEntryID")
        old["collection"] = [
            "id": collection.id, "kind": "playlist", "title": collection.title,
            "subtitle": collection.subtitle,
        ]
        old["lastCollection"] = old["collection"]
        let empty = try JSONDecoder().decode(
            FoundationPlaybackSnapshot.self, from: JSONSerialization.data(withJSONObject: old))
        player.restoreSession(empty)
        XCTAssertNotNil(player.playbackCollection)
        player.enqueue([track], position: .last)
        XCTAssertNil(player.playbackCollection)
    }
}
