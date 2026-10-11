import XCTest

@testable import VelacantoFoundation

final class FoundationDisposableCachePolicyTests: XCTestCase {
    func testVersionChangeClearsOnlyDisposableCachesAndSameVersionRetainsThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = FoundationDisposableCachePolicy()
        let first = await policy.prepare(version: "117-schema2", cachesRoot: root)
        XCTAssertTrue(first)
        for name in ["VelacantoArtwork", "VelacantoCatalogPages", "DownloadedMusic"] {
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Data("retained".utf8).write(to: directory.appendingPathComponent("fixture"))
        }
        let same = await policy.prepare(version: "117-schema2", cachesRoot: root)
        XCTAssertTrue(same)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("VelacantoArtwork/fixture").path))
        let updated = await policy.prepare(version: "118-schema2", cachesRoot: root)
        XCTAssertTrue(updated)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("VelacantoArtwork").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("VelacantoCatalogPages").path))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("DownloadedMusic/fixture")),
            Data("retained".utf8))
    }

    func testDisposableSymlinkDoesNotRemoveItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("DownloadedMusic")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("artwork"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("VelacantoArtwork"), withDestinationURL: target)
        let prepared = await FoundationDisposableCachePolicy().prepare(
            version: "new", cachesRoot: root)
        XCTAssertTrue(prepared)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("artwork")), Data([1]))
    }

    func testMarkerSymlinkRejectsPreparationWithoutDeletingCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("VelacantoDisposableCacheGeneration"),
            withDestinationURL: target)
        let prepared = await FoundationDisposableCachePolicy().prepare(
            version: "new", cachesRoot: root)
        XCTAssertFalse(prepared)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: target.appendingPathComponent("generation").path)
        )
    }
}
