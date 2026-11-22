import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLocalSourceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testSelectionRestoresIdentityWithoutOpeningFolder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let owner = FoundationLocalSource(storage: storage, makeBookmark: { _ in Data([1, 2]) })
        let id = try await owner.select(root.appendingPathComponent("music"))
        let restored = try await FoundationLocalSource(storage: storage).selection()
        XCTAssertEqual(restored?.sourceID, id)
        XCTAssertEqual(restored?.bookmark, Data([1, 2]))
        let cached = try await owner.cachedCatalog()
        XCTAssertEqual(cached?.state, .empty)
    }

    func testReselectionIsNewSourceAndRemovalNeverTouchesMusic() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("track.mp3")
        try Data([7]).write(to: music)
        let owner = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) })
        let first = try await owner.select(root.appendingPathComponent("selected"))
        let second = try await owner.select(root.appendingPathComponent("selected"))
        XCTAssertNotEqual(first, second)
        try await owner.removeSelection()
        let selected = try await owner.selection()
        XCTAssertNil(selected)
        XCTAssertEqual(try Data(contentsOf: music), Data([7]))
    }

    func testReplacedStorageCannotClaimForgetAndCanBeRetriedAfterRecovery() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let retained = root.appendingPathComponent("retained")
        let music = root.appendingPathComponent("track.mp3")
        try Data([7]).write(to: music)
        let owner = FoundationLocalSource(storage: storage, makeBookmark: { _ in Data([1, 2]) })
        let id = try await owner.select(root.appendingPathComponent("selected"))
        // Populate URL resource caches before the underlying directory changes.
        let initial = try await owner.selection()
        XCTAssertEqual(initial?.sourceID, id)
        let manifest = try Data(contentsOf: storage.appendingPathComponent("selection.json"))
        try FileManager.default.moveItem(at: storage, to: retained)
        try Data([9]).write(to: storage)
        do {
            try await owner.removeSelection()
            XCTFail("Invalid storage must not report successful authorization removal")
        } catch FoundationLocalSource.Failure.invalidStorage {}
        XCTAssertEqual(
            try Data(contentsOf: retained.appendingPathComponent("selection.json")), manifest)
        XCTAssertEqual(try Data(contentsOf: storage), Data([9]))
        XCTAssertEqual(try Data(contentsOf: music), Data([7]))

        try FileManager.default.removeItem(at: storage)
        try FileManager.default.moveItem(at: retained, to: storage)
        let recovered = try await owner.selection()
        XCTAssertEqual(recovered, initial)
        try await owner.removeSelection()
        let removed = try await owner.selection()
        XCTAssertNil(removed)
        XCTAssertEqual(try Data(contentsOf: music), Data([7]))
    }

    func testForgetIsIdempotentForAbsentStoreAndAbsentSelection() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let owner = FoundationLocalSource(storage: storage)
        try await owner.removeSelection()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try await owner.removeSelection()
        let selected = try await owner.selection()
        XCTAssertNil(selected)
    }

    func testDeniedBookmarkHasHonestUnavailableStateAndNoRetry() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, _, _ in throw FoundationLocalFolderAccess.AccessFailure.unavailable })
        let id = try await owner.select(root.appendingPathComponent("music"))
        let result = try await owner.refresh()
        XCTAssertEqual(result?.sourceID, id)
        XCTAssertEqual(result?.state, .unavailable)
        XCTAssertEqual(result?.records, [])
        let selected = try await owner.selection()
        XCTAssertEqual(selected?.sourceID, id)
    }

    func testCorruptSelectionIsNotSilentlyReplacedWithEmpty() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([255]).write(to: root.appendingPathComponent("selection.json"))
        let owner = FoundationLocalSource(storage: root)
        do {
            _ = try await owner.selection()
            XCTFail("Expected corrupt selection")
        } catch FoundationLocalSource.Failure.corruptSelection {}
    }

    func testSelectionRejectsPrivateStoreInsideMusicFolder() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) })
        do {
            _ = try await owner.select(root)
            XCTFail("Expected invalid private storage")
        } catch FoundationLocalSource.Failure.invalidStorage {}
    }

    func testCaseAliasSelectionCannotCreateStorageOrManifestInsideMusic() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("SELECTED")
        guard FileManager.default.fileExists(atPath: alias.path) else {
            throw XCTSkip("Case-sensitive filesystem; symlink alias is tested separately")
        }
        let storage = alias.appendingPathComponent("private")
        let owner = FoundationLocalSource(
            storage: storage,
            makeBookmark: { _ in
                XCTFail("Containment must be rejected before bookmark creation")
                return Data([1])
            })
        do {
            _ = try await owner.select(music)
            XCTFail("Case-equivalent music folder accepted as private storage")
        } catch FoundationLocalSource.Failure.invalidStorage {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.appendingPathComponent("selection.json").path))
    }

    func testSymlinkAncestorSelectionCannotWriteInsideMusic() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: music)
        let storage = alias.appendingPathComponent("private")
        let owner = FoundationLocalSource(
            storage: storage,
            makeBookmark: { _ in
                XCTFail("Containment must be rejected before bookmark creation")
                return Data([1])
            })
        do {
            _ = try await owner.select(music)
            XCTFail("Symlink alias accepted as private storage")
        } catch FoundationLocalSource.Failure.invalidStorage {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.appendingPathComponent("selection.json").path))
    }

    func testSelectionRechecksContainmentAfterBookmarkCreation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("later-alias")
        let storage = alias.appendingPathComponent("private")
        let owner = FoundationLocalSource(
            storage: storage,
            makeBookmark: { _ in
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: music)
                return Data([1])
            })
        do {
            _ = try await owner.select(music)
            XCTFail("Storage alias introduced during bookmark creation was accepted")
        } catch FoundationLocalSource.Failure.invalidStorage {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: storage.appendingPathComponent("selection.json").path))
    }

    private actor HeldScan {
        private var started = false
        private var released = false
        private var finishWaiter: CheckedContinuation<Void, Never>?

        func run() async {
            started = true
            guard !released else { return }
            await withCheckedContinuation { finishWaiter = $0 }
        }

        func waitForStart() async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !started && !Task.isCancelled && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return started && !Task.isCancelled
        }

        func finish() {
            released = true
            finishWaiter?.resume()
            finishWaiter = nil
        }
    }

    func testRetiredSourceCannotPublishLateScan() async throws {
        let root = try fixture()
        var rootSafeToRemove = true
        defer { if rootSafeToRemove { try? FileManager.default.removeItem(at: root) } }
        let gate = HeldScan()
        let owner = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, id, _ in
                await gate.run()
                return .init(sourceID: id, state: .empty)
            })
        _ = try await owner.select(root.appendingPathComponent("music"))
        let pending = Task { try await owner.refresh() }
        rootSafeToRemove = false
        guard await gate.waitForStart() else {
            pending.cancel()
            await gate.finish()
            XCTFail("Local source scan did not enter its hold within 5 seconds")
            return
        }
        do {
            try await owner.removeSelection()
        } catch {
            pending.cancel()
            await gate.finish()
            throw error
        }
        await gate.finish()
        let finished = XCTestExpectation(description: "retired local source scan returned")
        var outcome: Result<FoundationLocalCatalog?, Error>?
        let observer = Task {
            outcome = await pending.result
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            pending.cancel()
            observer.cancel()
            XCTFail("Retired local source scan did not return within 5 seconds")
            return
        }
        rootSafeToRemove = true
        switch outcome {
        case .some(.success):
            XCTFail("Retired source published a result")
        case .some(.failure(let error)):
            guard let sourceError = error as? FoundationLocalSource.Failure,
                case .superseded = sourceError
            else { throw error }
        case nil:
            XCTFail("Retired local source scan returned without an outcome")
        }
        let cached = try await owner.cachedCatalog()
        XCTAssertNil(cached)
    }

    func testCancelledCallerCannotPublishSuccessfulLateScan() async throws {
        let root = try fixture()
        var rootSafeToRemove = true
        defer { if rootSafeToRemove { try? FileManager.default.removeItem(at: root) } }
        let gate = HeldScan()
        let owner = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, id, _ in
                await gate.run()
                return .init(sourceID: id, state: .empty)
            })
        _ = try await owner.select(root.appendingPathComponent("music"))
        let pending = Task { try await owner.refresh() }
        rootSafeToRemove = false
        guard await gate.waitForStart() else {
            pending.cancel()
            await gate.finish()
            XCTFail("Local source scan did not enter its hold within 5 seconds")
            return
        }
        pending.cancel()
        await gate.finish()
        let finished = XCTestExpectation(description: "cancelled local source scan returned")
        var outcome: Result<FoundationLocalCatalog?, Error>?
        let observer = Task {
            outcome = await pending.result
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            pending.cancel()
            observer.cancel()
            XCTFail("Cancelled local source scan did not return within 5 seconds")
            return
        }
        rootSafeToRemove = true
        switch outcome {
        case .some(.success):
            XCTFail("Cancelled caller published a result")
        case .some(.failure(let error)):
            guard error is CancellationError else { throw error }
        case nil:
            XCTFail("Cancelled local source scan returned without an outcome")
        }
    }

}
