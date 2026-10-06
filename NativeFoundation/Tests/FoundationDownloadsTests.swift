import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationDownloadsTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func item(_ id: String, kind: FoundationItem.Kind = .track) -> FoundationItem {
        FoundationItem(id: id, title: "Synthetic", subtitle: "Fixture", kind: kind, duration: 1)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Download state did not settle before the deadline")
    }

    private var transfer: FoundationDownloads.Transfer {
        { _, destination, _, progress in
            try Data("synthetic audio".utf8).write(to: destination)
            progress(15, 15)
        }
    }

    func testSharedRetentionDuplicatesAndPlaybackLeaseDelayDeletion() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        let playlistID = try XCTUnwrap(manager.owners.first?.id)
        XCTAssertEqual(manager.readyTracks(ownerID: playlistID).map(\.id), ["track", "track"])
        manager.download(track)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let resource = try await manager.playbackResource(for: track)
        manager.remove(ownerID: playlistID)
        XCTAssertTrue(manager.isReady(track))
        manager.remove(ownerID: "track:track")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        XCTAssertFalse(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testCellularDefaultCancellationAndExplicitRetry() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isConnected: true, usesWiFi: false)
        manager.download(track)
        XCTAssertEqual(manager.owners.first?.state, .waitingForWiFi)
        manager.cancel(ownerID: "track:track")
        manager.setAllowsCellular(true)
        XCTAssertEqual(manager.owners.first?.state, .cancelled)
        XCTAssertFalse(manager.isReady(track))
        manager.retry(ownerID: "track:track")
        try await waitUntil { manager.owners.first?.state == .ready }
        _ = await manager.clearAccount()
    }

    func testFailedPlaylistRefreshPreservesSnapshotAndSharedFile() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        await library.setFailure(true)
        manager.reconcilePlaylists()
        try await waitUntil { manager.errorMessage != nil }
        XCTAssertEqual(manager.owners.first?.tracks.map(\.id), ["track", "track"])
        XCTAssertTrue(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testRelaunchRejectsSameLengthCorruptionAndRemovesStaging() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        await resource.release()
        manager.invalidate()
        let bytes = try Data(contentsOf: resource.url).count
        try Data(repeating: 0, count: bytes).write(to: resource.url)
        let staging = resource.url.deletingLastPathComponent().appendingPathComponent(
            "stage-interrupted")
        try Data("partial".utf8).write(to: staging)
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertFalse(restored.isReady(track))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(restored.owners.first?.state, .waitingForWiFi)
        _ = await restored.clearAccount()
    }

    func testOfflineRelaunchRetainsReadyOccurrencesWithoutAnotherTransfer() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track, track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.invalidate()
        await library.setFailure(true)

        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory,
            transfer: { _, _, _, _ in
                XCTFail("Offline restoration must not start another transfer")
                throw FoundationLibraryError.unavailable
            }, monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertEqual(restored.owners.first?.state, .ready)
        XCTAssertEqual(
            restored.readyTracks(ownerID: "playlist:playlist").map(\.id), ["track", "track"])
        XCTAssertFalse(restored.allowsCellular)
        let resource = try await restored.playbackResource(for: track)
        XCTAssertTrue(resource.url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: resource.url), Data("synthetic audio".utf8))
        await resource.release()
        let cleared = await restored.clearAccount()
        XCTAssertTrue(cleared)
    }

    func testStoredFilesRetainProtectionAfterManifestReplacement() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        let manifest = account.appendingPathComponent("manifest.json")
        for cellular in [true, false] {
            // Each settings save atomically replaces the manifest, so verify the resulting inode.
            manager.setAllowsCellular(cellular)
            XCTAssertEqual(
                try FoundationDownloadStorage.load(directory: account).allowsCellular, cellular)
            for url in [account, manifest, resource.url] {
                XCTAssertEqual(
                    try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
                        .isExcludedFromBackup,
                    true)
                #if os(macOS)
                    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                    XCTAssertEqual(
                        (attributes[.posixPermissions] as? NSNumber)?.intValue,
                        url == account ? 0o700 : 0o600)
                #endif
            }
        }
        await resource.release()
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
    }

    #if os(iOS)
        func testPhysicalIOSStorageProtection() async throws {
            #if targetEnvironment(simulator)
                throw XCTSkip(
                    "Simulator does not expose iOS Data Protection; requires a signed device run")
            #else
                let track = item("track")
                let directory = try root()
                let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
                let manager = FoundationDownloads(
                    scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
                    transfer: transfer, monitorConnectivity: false)
                manager.updateConnectivity(isAllowed: true)
                manager.download(track)
                try await waitUntil { manager.isReady(track) }
                let resource = try await manager.playbackResource(for: track)
                for cellular in [true, false] {
                    manager.setAllowsCellular(cellular)
                    for url in [
                        account, account.appendingPathComponent("manifest.json"), resource.url,
                    ] {
                        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                        XCTAssertEqual(
                            attributes[.protectionKey] as? FileProtectionType,
                            .completeUntilFirstUserAuthentication)
                    }
                }
                await resource.release()
                let cleared = await manager.clearAccount()
                XCTAssertTrue(cleared)
            #endif
        }
    #endif

    func testAccountCleanupDoesNotRemoveAnotherScopesReadyFile() async throws {
        let track = item("track")
        let directory = try root()
        let library = DownloadsLibrary(tracks: [track])
        let first = FoundationDownloads(
            scope: "first-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        let second = FoundationDownloads(
            scope: "second-account", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        first.updateConnectivity(isAllowed: true)
        first.download(track)
        try await waitUntil { first.isReady(track) }
        XCTAssertFalse(second.isReady(track))
        second.updateConnectivity(isAllowed: true)
        second.download(track)
        try await waitUntil { second.isReady(track) }
        let resource = try await second.playbackResource(for: track)
        let cleared = await first.clearAccount()
        XCTAssertTrue(cleared)
        XCTAssertTrue(second.isReady(track))
        XCTAssertEqual(try Data(contentsOf: resource.url), Data("synthetic audio".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: FoundationDownloadStorage.directory(
                    scope: "first-account", root: directory
                ).path))
        await resource.release()
        let secondCleared = await second.clearAccount()
        XCTAssertTrue(secondCleared)
    }

    func testStorageFailureStaysUnavailableAndCanBeExplicitlyRetried() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: { _, destination, _, _ in
                try Data("partial".utf8).write(to: destination)
                throw CocoaError(.fileWriteOutOfSpace)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .failed }
        XCTAssertFalse(manager.isReady(track))
        XCTAssertNotNil(manager.errorMessage)
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
    }

    func testLateTransferAfterAccountInvalidationCannotPublish() async throws {
        let track = item("track")
        let gate = DownloadGate()
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: { _, destination, _, _ in
                await gate.wait()
                try Data("late result".utf8).write(to: destination)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .downloading }
        // Ensure the transfer reached its suspension seam, then invalidate its account.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.started), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await gate.started else {
            XCTFail("Transfer did not start")
            return
        }
        manager.invalidate()
        await gate.resume()
        let cleared = await manager.clearAccount()
        XCTAssertTrue(cleared)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.count, 0)
    }

    func testPlaylistReconciliationAddsAndReordersWithoutDroppingExplicitRetention() async throws {
        let first = item("first")
        let second = item("second")
        let library = DownloadsLibrary(tracks: [first, first])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        await library.setTracks([second, second])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.map(\.id) == ["second", "second"]
                && manager.isReady(second)
        }
        XCTAssertTrue(manager.isReady(first))
        XCTAssertEqual(
            manager.readyTracks(ownerID: "playlist:playlist").map(\.id), ["second", "second"])
        _ = await manager.clearAccount()
    }

    func testUnreadableManifestOffersExplicitLiveRecovery() async throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        try Data("broken JSON".utf8).write(to: account.appendingPathComponent("manifest.json"))
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        XCTAssertNotNil(manager.errorMessage)
        let removed = await manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertNil(manager.errorMessage)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        _ = await manager.clearAccount()
    }

    func testRemoveAllPreservesInstalledFileUntilLeaseRelease() async throws {
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: try root(),
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let resource = try await manager.playbackResource(for: track)
        let removed = await manager.removeAll()
        XCTAssertTrue(removed)
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.url.path))
        _ = await manager.clearAccount()
    }

    func testManifestContainsNoTransientRequestSecretsAndScopesAreOpaque() async throws {
        let track = item("track")
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "https://account.invalid/private", library: DownloadsLibrary(tracks: [track]),
            root: directory, transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.owners.first?.state == .ready }
        let folders = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        let folder = try XCTUnwrap(folders.first)
        XCTAssertEqual(folder.lastPathComponent.count, 64)
        let text = try String(
            contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("fixture-secret"))
        XCTAssertFalse(text.contains("example.invalid"))
        XCTAssertFalse(text.contains("account.invalid"))
        _ = await manager.clearAccount()
    }
}

private actor DownloadsLibrary: FoundationLibrary {
    private var tracks: [FoundationItem]
    private var fails = false
    init(tracks: [FoundationItem]) { self.tracks = tracks }
    func setFailure(_ value: Bool) { fails = value }
    func setTracks(_ value: [FoundationItem]) { tracks = value }
    func albums(startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        .init(items: tracks, nextStartIndex: nil)
    }
    func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
        if fails { throw FoundationLibraryError.unavailable }
        return .init(
            entries: tracks.enumerated().map {
                FoundationPlaylistEntry(
                    id: "\($0.offset)", mutationID: "\($0.offset)", item: $0.element)
            }, nextStartIndex: nil)
    }
    func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
        if fails { throw FoundationLibraryError.unavailable }
        return .init(name: "Synthetic playlist", canEdit: true, canDelete: true)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        URL(string: "https://example.invalid/stream")!
    }
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        var request = URLRequest(url: URL(string: "https://example.invalid/original")!)
        request.setValue("fixture-secret", forHTTPHeaderField: "Authorization")
        return FoundationDownloadSource(request: request, fileExtension: "mp3", expectedBytes: nil)
    }
}

private actor DownloadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started = true
        }
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
