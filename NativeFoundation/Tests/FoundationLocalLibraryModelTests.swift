import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationLocalLibraryModelTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRestorePublishesCachedSelectionWithoutScanOrAccount() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, _, _ in
                XCTFail("Restoration must not open or scan the folder")
                throw CancellationError()
            })
        let id = try await source.select(root.appendingPathComponent("music"))
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        XCTAssertEqual(model.catalog?.sourceID, id)
        XCTAssertEqual(model.catalog?.state, .empty)
        XCTAssertNil(model.activity)
        XCTAssertFalse(model.corruptSelection)
    }

    func testCancelledRestorationDoesNotClaimNoSelectionAndSupportsExplicitReload() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) })
        let id = try await source.select(root.appendingPathComponent("music"))
        let model = FoundationLocalLibraryModel(source: source)
        let restoration = model.restore()
        model.cancel()
        await restoration.value
        XCTAssertTrue(model.restorationCancelled)
        XCTAssertNil(model.catalog)
        XCTAssertNil(model.activity)
        await model.restore().value
        XCTAssertFalse(model.restorationCancelled)
        XCTAssertEqual(model.catalog?.sourceID, id)
        XCTAssertNil(model.errorMessage)
    }

    func testUnavailableRefreshRetainsRecordsAndRequiresExplicitAction() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let music = root.appendingPathComponent("music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try Data([7]).write(to: music.appendingPathComponent("fixture.mp3"))
        let source = FoundationLocalSource(
            storage: storage, makeBookmark: { _ in Data([1]) },
            scan: { _, _, _ in throw FoundationLocalFolderAccess.AccessFailure.unavailable })
        let id = try await source.select(music)
        let cached = try await FoundationLocalCatalogIndex(
            storage: storage.appendingPathComponent("catalogs")
        ).refresh(sourceID: id, authorizedRoot: music)
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        XCTAssertEqual(model.catalog?.state, .ready)
        XCTAssertEqual(model.catalog?.records.count, 1)
        await model.refresh().value
        XCTAssertEqual(model.catalog?.state, .unavailable)
        XCTAssertEqual(model.catalog?.records, cached.records)
        XCTAssertEqual(model.catalog?.sourceID, id)
        XCTAssertNil(model.activity)
    }

    func testCorruptCacheStaysDistinctFromEmptyAndCanRefreshToPartial() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let source = FoundationLocalSource(
            storage: storage, makeBookmark: { _ in Data([1]) },
            scan: { _, id, _ in .init(sourceID: id, state: .partial) })
        let id = try await source.select(root.appendingPathComponent("music"))
        let catalogs = storage.appendingPathComponent("catalogs")
        try FileManager.default.createDirectory(at: catalogs, withIntermediateDirectories: true)
        try Data([255]).write(to: catalogs.appendingPathComponent(id.uuidString + ".json"))
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        XCTAssertEqual(model.catalog?.state, .corrupt)
        XCTAssertFalse(model.corruptSelection)
        await model.refresh().value
        XCTAssertEqual(model.catalog?.state, .partial)
        XCTAssertEqual(model.catalog?.sourceID, id)
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

    private func waitForScanTask(
        _ task: Task<Void, Never>, gate: HeldScan, name: String
    ) async -> Bool {
        let finished = XCTestExpectation(description: name)
        let observer = Task {
            await task.value
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            task.cancel()
            await gate.finish()
            observer.cancel()
            XCTFail("\(name) did not finish within 5 seconds")
            return false
        }
        return true
    }

    func testCancelRetainsPublishedCacheAndRejectsSuccessfulLateScan() async throws {
        let root = try fixture()
        var rootSafeToRemove = true
        defer { if rootSafeToRemove { try? FileManager.default.removeItem(at: root) } }
        let gate = HeldScan()
        let source = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, id, _ in
                await gate.run()
                return .init(sourceID: id, state: .partial)
            })
        _ = try await source.select(root.appendingPathComponent("music"))
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        let cached = model.catalog
        let refresh = model.refresh()
        rootSafeToRemove = false
        guard await gate.waitForStart() else {
            model.cancel()
            await gate.finish()
            XCTFail("Local scan did not enter its hold within 5 seconds")
            return
        }
        XCTAssertEqual(model.activity, .refreshing)
        model.cancel()
        await gate.finish()
        guard await waitForScanTask(refresh, gate: gate, name: "local scan refresh") else {
            return
        }
        XCTAssertEqual(model.catalog, cached)
        XCTAssertNil(model.activity)
        XCTAssertNotNil(model.errorMessage)
        rootSafeToRemove = true
    }

    func testForgetDuringScanPreventsLatePublicationAndPreservesMusic() async throws {
        let root = try fixture()
        var rootSafeToRemove = true
        defer { if rootSafeToRemove { try? FileManager.default.removeItem(at: root) } }
        let music = root.appendingPathComponent("music.mp3")
        try Data([9]).write(to: music)
        let gate = HeldScan()
        let source = FoundationLocalSource(
            storage: root.appendingPathComponent("private"), makeBookmark: { _ in Data([1]) },
            scan: { _, id, _ in
                await gate.run()
                return .init(sourceID: id, state: .partial)
            })
        _ = try await source.select(root.appendingPathComponent("music"))
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        let refresh = model.refresh()
        rootSafeToRemove = false
        guard await gate.waitForStart() else {
            model.cancel()
            await gate.finish()
            XCTFail("Local scan did not enter its hold within 5 seconds")
            return
        }
        let forget = model.forget()
        guard await waitForScanTask(forget, gate: gate, name: "local library forget") else {
            return
        }
        await gate.finish()
        guard await waitForScanTask(refresh, gate: gate, name: "local scan refresh") else {
            return
        }
        let selected = try await source.selection()
        XCTAssertNil(selected)
        XCTAssertNil(model.catalog)
        XCTAssertNil(model.activity)
        XCTAssertEqual(try Data(contentsOf: music), Data([9]))
        rootSafeToRemove = true
    }

    func testCorruptAuthorizationCanBeExplicitlyForgottenWithoutSilentReset() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let selection = root.appendingPathComponent("selection.json")
        try Data([255]).write(to: selection)
        let model = FoundationLocalLibraryModel(source: FoundationLocalSource(storage: root))
        await model.restore().value
        XCTAssertTrue(model.corruptSelection)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.path))
        await model.forget().value
        XCTAssertFalse(model.corruptSelection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.path))
    }

    func testFailedForgetRetainsVisibleSelectionAndReportsFailure() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("private")
        let source = FoundationLocalSource(storage: storage, makeBookmark: { _ in Data([1]) })
        _ = try await source.select(root.appendingPathComponent("music"))
        let model = FoundationLocalLibraryModel(source: source)
        await model.restore().value
        let cached = model.catalog
        try FileManager.default.moveItem(at: storage, to: root.appendingPathComponent("retained"))
        try Data([1]).write(to: storage)
        await model.forget().value
        XCTAssertEqual(model.catalog, cached)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.activity)
    }
}
