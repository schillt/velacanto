import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLocalCatalogTests: XCTestCase {
    private struct Fixture {
        let temporary: URL
        let root: URL
        let store: URL

        init() throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)
            root = temporary.appendingPathComponent("selected")
            store = temporary.appendingPathComponent("private-index")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: temporary) }
    }

    func testRefreshPersistsRestoresAndNeverChangesMusicBytes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        let bytes = Data([0, 7, 13, 255])
        let file = root.appendingPathComponent("Song.mp3")
        try bytes.write(to: file)
        let source = UUID()
        let index = FoundationLocalCatalogIndex(storage: store)
        let first = try await index.refresh(sourceID: source, authorizedRoot: root)
        XCTAssertEqual(first.state, .ready)
        XCTAssertEqual(first.records.count, 1)
        XCTAssertEqual(first.records.first?.title, "Song")
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let restored = await FoundationLocalCatalogIndex(storage: store).restore(sourceID: source)
        XCTAssertEqual(restored, first)
        let next = try await index.refresh(sourceID: source, authorizedRoot: root)
        XCTAssertEqual(next, first)
    }

    func testRenameKeepsOpaqueOccurrenceAndMissingFileRemainsExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        let original = root.appendingPathComponent("First.flac")
        try Data([1]).write(to: original)
        let source = UUID()
        let index = FoundationLocalCatalogIndex(storage: store)
        let first = try await index.refresh(sourceID: source, authorizedRoot: root)
        let renamed = root.appendingPathComponent("Renamed.flac")
        try FileManager.default.moveItem(at: original, to: renamed)
        let moved = try await index.refresh(sourceID: source, authorizedRoot: root)
        XCTAssertEqual(moved.records.first?.id, first.records.first?.id)
        XCTAssertEqual(moved.records.first?.relativePath, "Renamed.flac")
        try FileManager.default.removeItem(at: renamed)
        let missing = try await index.refresh(sourceID: source, authorizedRoot: root)
        XCTAssertEqual(missing.state, .empty)
        XCTAssertEqual(missing.records.first?.missing, true)
    }

    func testSameFolderSourcesRemainIsolated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        try Data([1]).write(to: root.appendingPathComponent("Song.wav"))
        let index = FoundationLocalCatalogIndex(storage: store)
        let first = try await index.refresh(sourceID: UUID(), authorizedRoot: root)
        let second = try await index.refresh(sourceID: UUID(), authorizedRoot: root)
        XCTAssertNotEqual(first.records.first?.id, second.records.first?.id)
        let restored = await index.restore(sourceID: first.sourceID)
        XCTAssertEqual(restored, first)
    }

    func testMissingRootDoesNotDestroyLastKnownCatalog() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        try Data([1]).write(to: root.appendingPathComponent("Song.aac"))
        let index = FoundationLocalCatalogIndex(storage: store)
        let source = UUID()
        let initial = try await index.refresh(sourceID: source, authorizedRoot: root)
        try FileManager.default.removeItem(at: root)
        let unavailable = try await index.refresh(sourceID: source, authorizedRoot: root)
        XCTAssertEqual(unavailable.state, .unavailable)
        XCTAssertEqual(unavailable.records, initial.records)
        let restored = await index.restore(sourceID: source)
        XCTAssertEqual(restored, initial)
    }

    func testPartialEnumerationCannotFalselyMarkPreviousTracksMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        for name in ["One.mp3", "Two.mp3", "Three.mp3"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        let index = FoundationLocalCatalogIndex(storage: store)
        let source = UUID()
        _ = try await index.refresh(sourceID: source, authorizedRoot: root)
        let partial = try await index.refresh(
            sourceID: source, authorizedRoot: root, inspectionLimit: 1)
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.records.count, 3)
        XCTAssertTrue(partial.records.allSatisfy { !$0.missing })
    }

    func testSymlinksOutsideSelectionAreExcludedAndOtherFilesIgnored() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let store = fixture.store
        let outside = fixture.temporary.appendingPathComponent("Outside.mp3")
        try Data([2]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked.mp3"), withDestinationURL: outside)
        try Data([3]).write(to: root.appendingPathComponent("Text.txt"))
        let index = FoundationLocalCatalogIndex(storage: store)
        let result = try await index.refresh(sourceID: UUID(), authorizedRoot: root)
        XCTAssertEqual(result.state, .empty)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outside), Data([2]))
    }

    func testCorruptOrForeignIndexDoesNotPublishRecordsOrDeleteEvidence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store
        let source = UUID()
        let index = FoundationLocalCatalogIndex(storage: store)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let file = store.appendingPathComponent(source.uuidString).appendingPathExtension("json")
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: file)
        let result = await index.restore(sourceID: source)
        XCTAssertEqual(result.state, .corrupt)
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        let foreign = FoundationLocalCatalog(sourceID: UUID(), state: .empty)
        try JSONEncoder().encode(foreign).write(to: file)
        let mismatched = await index.restore(sourceID: source)
        XCTAssertEqual(mismatched.state, .corrupt)
    }

    func testIndexRejectsTraversalAndCannotWriteInsideSelectedMusicFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        for path in ["../outside.mp3", "/absolute.mp3", "a/../b.mp3", "a//b.mp3", "a/./b.mp3"] {
            XCTAssertFalse(FoundationLocalCatalog.safeRelativePath(path))
        }
        let index = FoundationLocalCatalogIndex(storage: root.appendingPathComponent("index"))
        do {
            _ = try await index.refresh(sourceID: UUID(), authorizedRoot: root)
            XCTFail("Index persistence must remain outside the read-only music source")
        } catch FoundationLocalCatalogIndex.Failure.invalidRoot {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("index").path))
    }
    func testStorageSymlinkAncestorCannotWriteIntoSelectedMusicFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.temporary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let index = FoundationLocalCatalogIndex(
            storage: alias.appendingPathComponent("private-index"))
        do {
            _ = try await index.refresh(sourceID: UUID(), authorizedRoot: fixture.root)
            XCTFail("A symlink ancestor must not redirect index writes into selected music")
        } catch FoundationLocalCatalogIndex.Failure.invalidRoot {}
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("private-index").path))
    }

    func testCaseAliasStorageCannotWriteIntoSelectedMusicFolderWhenEquivalent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.root.deletingLastPathComponent().appendingPathComponent("SELECTED")
        let manager = FileManager.default
        guard manager.fileExists(atPath: alias.path) else {
            throw XCTSkip(
                "This filesystem distinguishes case; symlink alias has a separate regression")
        }
        let index = FoundationLocalCatalogIndex(
            storage: alias.appendingPathComponent("private-index"))
        do {
            _ = try await index.refresh(sourceID: UUID(), authorizedRoot: fixture.root)
            XCTFail("An equivalent case alias must not redirect index writes into music")
        } catch FoundationLocalCatalogIndex.Failure.invalidRoot {}
        XCTAssertFalse(
            manager.fileExists(atPath: fixture.root.appendingPathComponent("private-index").path))
    }

    func testRecordCapacityPreservesEveryPriorOccurrenceAndAvailability() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = UUID()
        let records = (0..<FoundationLocalCatalogIndex.recordLimit).map { number in
            FoundationLocalCatalog.Record(
                id: source.uuidString + ":" + String(format: "%064x", number),
                relativePath: "Old\(number).mp3", title: "Old\(number)", byteCount: 1,
                modified: Date(timeIntervalSince1970: 1), missing: false)
        }
        let prior = FoundationLocalCatalog(sourceID: source, state: .ready, records: records)
        XCTAssertTrue(prior.isValid)
        try FileManager.default.createDirectory(
            at: fixture.store, withIntermediateDirectories: true)
        let file = fixture.store.appendingPathComponent(source.uuidString).appendingPathExtension(
            "json")
        try JSONEncoder().encode(prior).write(to: file)
        try Data([1]).write(to: fixture.root.appendingPathComponent("New.mp3"))
        let index = FoundationLocalCatalogIndex(storage: fixture.store)
        let limited = try await index.refresh(sourceID: source, authorizedRoot: fixture.root)
        XCTAssertEqual(limited.state, .partial)
        XCTAssertEqual(limited.records, records)
        let restored = await index.restore(sourceID: source)
        XCTAssertEqual(restored, limited)
    }

    func testAncestryCheckTerminatesForSeparateTemporaryStorageAndFilesystemRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // temporaryDirectory appendingPathComponent retains the Foundation URL
        // form whose deletingLastPathComponent can ascend beyond "/" to "/..".
        XCTAssertTrue(
            FoundationLocalCatalogIndex.storageIsOutsideRoot(fixture.store, root: fixture.root))
        XCTAssertTrue(
            FoundationLocalCatalogIndex.storageIsOutsideRoot(
                URL(fileURLWithPath: "/", isDirectory: true), root: fixture.root))
        XCTAssertFalse(
            FoundationLocalCatalogIndex.storageIsOutsideRoot(
                fixture.root.appendingPathComponent("index"), root: fixture.root))
        XCTAssertFalse(
            FoundationLocalCatalogIndex.storageIsOutsideRoot(
                fixture.store, root: URL(fileURLWithPath: "/", isDirectory: true)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.path))
    }

    func testNestedMissingStorageThroughAliasIsRejectedBeforeCreatingAnyDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.temporary.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let storage = alias.appendingPathComponent("first/second/index", isDirectory: true)
        let index = FoundationLocalCatalogIndex(storage: storage)
        do {
            _ = try await index.refresh(sourceID: UUID(), authorizedRoot: fixture.root)
            XCTFail("Every missing suffix must be attached to the resolved existing ancestor")
        } catch FoundationLocalCatalogIndex.Failure.invalidRoot {}
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.root.appendingPathComponent("first").path))
    }

    func testDanglingStorageAncestorFailsClosedWithoutCreatingItsTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.temporary.appendingPathComponent("missing-target")
        let alias = fixture.temporary.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let index = FoundationLocalCatalogIndex(storage: alias.appendingPathComponent("index"))
        do {
            _ = try await index.refresh(sourceID: UUID(), authorizedRoot: fixture.root)
            XCTFail("A dangling ancestor is not a safe missing-directory path")
        } catch FoundationLocalCatalogIndex.Failure.invalidRoot {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(
            try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    }

}
