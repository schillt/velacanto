import Foundation
import ImageIO
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

    private func waitUntilAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let settled = await condition()
        XCTAssertTrue(settled, "Download work did not settle before the deadline")
    }

    private func artworkData() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 1024, height: 512, bitsPerComponent: 8, bytesPerRow: 1024 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 512))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func artworkTrack(_ id: String, tag: String = "first") -> FoundationItem {
        var track = item(id)
        track.album = .init(id: "album", title: "Synthetic album", primaryImageTag: tag)
        return track
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

    func testAccountCleanupWaitsForAllPlaybackLeasesBeforeReportingSuccess() async throws {
        let track = item("track")
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let first = try await manager.playbackResource(for: track)
        let second = try await manager.playbackResource(for: track)
        var result: Bool?
        let cleanup = Task { result = await manager.clearAccount(waitForPlayback: true) }
        // The account is retired immediately, while native items still own both files leases.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        await first.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        await second.release()
        await cleanup.value
        XCTAssertEqual(result, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
        XCTAssertTrue(manager.owners.isEmpty)
        XCTAssertEqual(manager.storageBytes, 0)
    }

    func testCancelledAccountCleanupWaitDoesNotHangOrDeleteLeasedAudio() async throws {
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
        let cleanup = Task { await manager.clearAccount(waitForPlayback: true) }
        for _ in 0..<20 { await Task.yield() }
        cleanup.cancel()
        let cleared = await cleanup.value
        XCTAssertFalse(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resource.url.path))
        await resource.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
    }

    func testCancellationRacingFinalLeaseReleaseStillRemovesAccountFiles() async throws {
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
        let cleanup = Task { await manager.clearAccount(waitForPlayback: true) }
        for _ in 0..<20 { await Task.yield() }
        cleanup.cancel()
        // Deliberately release before joining cleanup, unlike the retained-lease cancellation case.
        await resource.release()
        _ = await cleanup.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: account.path))
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

    func testProjectionsAndFootprintsDeduplicateSharedOccurrences() async throws {
        var first = item("first")
        first.album = FoundationItemReference(
            id: "album", title: "Synthetic album", primaryImageTag: nil)
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [first, first, second]),
            root: try root(), transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        XCTAssertEqual(manager.downloadedSongs.map(\.id), ["first", "second"])
        XCTAssertEqual(manager.browseTracks(for: playlist).map(\.id), ["first", "first", "second"])
        XCTAssertEqual(manager.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(manager.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(manager.availability(for: playlist), .ready)
        XCTAssertEqual(
            manager.availability(for: item("album", kind: .album)), .partial(ready: 1, total: 1))
        let bytes = Int64(Data("synthetic audio".utf8).count)
        XCTAssertEqual(manager.itemBytes(playlist), 2 * bytes)
        XCTAssertEqual(manager.itemBytes(first), bytes)
        XCTAssertEqual(
            manager.reclaimableBytes(ownerIDs: ["playlist:playlist"], trackIDs: []), bytes)
        XCTAssertEqual(
            manager.reclaimableBytes(ownerIDs: ["playlist:playlist", "track:first"], trackIDs: []),
            2 * bytes)
        let lease = try await manager.playbackResource(for: first)
        XCTAssertEqual(manager.reclaimableBytes(ownerIDs: [], trackIDs: ["first"]), 0)
        await lease.release()
        XCTAssertEqual(manager.reclaimableBytes(ownerIDs: [], trackIDs: ["first"]), bytes)
        _ = await manager.clearAccount()
    }

    func testTrackExclusionPreservesSnapshotsAcrossRefreshAndRelaunchUntilDownloadAgain()
        async throws
    {
        let first = item("first")
        let second = item("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first, second])
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil {
            manager.owners.count == 2 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let lease = try await manager.playbackResource(for: first)
        manager.removeTrack(first)
        XCTAssertEqual(manager.owners.count, 1)
        XCTAssertEqual(manager.owners.first?.tracks.map(\.id), ["first", "first", "second"])
        XCTAssertFalse(manager.isReady(first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lease.url.path))
        let fallback = try await manager.playbackResource(for: first)
        XCTAssertFalse(fallback.url.isFileURL)
        await fallback.release()
        XCTAssertEqual(manager.availability(for: playlist), .partial(ready: 1, total: 3))
        XCTAssertEqual(manager.owners.first?.status, "Partially On Device")
        await library.setTracks([second, first, first])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.map(\.id) == ["second", "first", "first"]
        }
        XCTAssertFalse(manager.isReady(first))
        await lease.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.url.path))
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        restored.updateConnectivity(isAllowed: true)
        restored.reconcilePlaylists()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(restored.isReady(first))
        XCTAssertEqual(restored.browseTracks(for: playlist).map(\.id), ["second"])
        restored.downloadAgain(first)
        try await waitUntil { restored.isReady(first) }
        XCTAssertEqual(restored.availability(for: playlist), .ready)
        XCTAssertEqual(
            restored.browseTracks(for: playlist).map(\.id), ["second", "first", "first"])
        _ = await restored.clearAccount()
    }

    func testAllExcludedSavedCollectionsRemainReachableAfterRelaunchAndRedownload() async throws {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let album = item("album", kind: .album)
        let library = DownloadsLibrary(tracks: [track, track])
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(playlist)
        original.download(album)
        try await waitUntil {
            original.owners.count == 2 && original.owners.allSatisfy { $0.state == .ready }
        }
        original.removeTrack(track)
        XCTAssertTrue(original.downloadedSongs.isEmpty)
        XCTAssertEqual(original.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(original.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(original.availability(for: playlist), .unavailable)
        XCTAssertEqual(original.availability(for: album), .unavailable)
        original.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        XCTAssertTrue(restored.downloadedSongs.isEmpty)
        XCTAssertEqual(restored.downloadedPlaylists.map(\.id), ["playlist"])
        XCTAssertEqual(restored.downloadedAlbums.map(\.id), ["album"])
        XCTAssertEqual(restored.owners.first?.tracks.map(\.id), ["track", "track"])
        XCTAssertTrue(restored.browseTracks(for: playlist).isEmpty)
        XCTAssertEqual(restored.availability(for: playlist), .unavailable)
        restored.updateConnectivity(isAllowed: true)
        restored.downloadAgain(playlist)
        try await waitUntil { restored.isReady(track) }
        XCTAssertEqual(restored.browseTracks(for: playlist).map(\.id), ["track", "track"])
        XCTAssertEqual(restored.availability(for: playlist), .ready)
        XCTAssertEqual(restored.availability(for: album), .ready)
        XCTAssertEqual(restored.downloadedSongs.map(\.id), ["track"])
        _ = await restored.clearAccount()
    }

    func testVersionOneManifestMigratesWithoutChangingRetainedMediaOrOccurrences() async throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        let track = item("track")
        let fileURL = account.appendingPathComponent("fixture.mp3")
        let data = Data("synthetic audio".utf8)
        try data.write(to: fileURL)
        var manifest = FoundationDownloadManifest()
        manifest.version = 1
        manifest.owners = [
            .init(
                id: "playlist:playlist",
                item: FoundationStoredDownloadItem(item("playlist", kind: .playlist)),
                tracks: [FoundationStoredDownloadItem(track), FoundationStoredDownloadItem(track)],
                paused: false, expanded: true)
        ]
        manifest.files = [
            track.id: .init(
                name: "fixture.mp3", bytes: Int64(data.count),
                digest: try FoundationDownloadStorage.digest(fileURL))
        ]
        try FoundationDownloadStorage.save(manifest, directory: account)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: []), root: directory,
            transfer: transfer, monitorConnectivity: false)
        try await waitUntil { !manager.isLoading }
        XCTAssertTrue(manager.isReady(track))
        XCTAssertEqual(manager.readyTracks(ownerID: "playlist:playlist").count, 2)
        XCTAssertEqual(try Data(contentsOf: fileURL), data)
        let migrated = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertTrue(migrated.excludedTrackIDs?.isEmpty ?? true)
        _ = await manager.clearAccount()
    }

    func testFailedRemovalAndRedownloadManifestWritesRollBackIntentAndReadiness() async throws {
        let directory = try root()
        let track = item("track")
        let playlist = item("playlist", kind: .playlist)
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: directory,
            transfer: transfer, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        try await waitUntil { manager.owners.first?.state == .ready }
        manager.updateConnectivity(isAllowed: false)
        let target = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
            .appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        manager.removeSelected(ownerIDs: ["playlist:playlist"], trackIDs: ["track"])
        XCTAssertTrue(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.tracks.count, 2)
        XCTAssertNotNil(manager.errorMessage)
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        manager.removeTrack(track)
        XCTAssertFalse(manager.isReady(track))
        let excluded = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        manager.downloadAgain(track)
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.count, 1)
        try FileManager.default.removeItem(at: target)
        try excluded.write(to: target)
        manager.updateConnectivity(isAllowed: true)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(manager.isReady(track))
        _ = await manager.clearAccount()
    }

    func testTrackRemovalRejectsLateTransferDespitePreservedSnapshot() async throws {
        let gate = DownloadGate()
        let track = item("track")
        let manager = FoundationDownloads(
            scope: "fixture", library: DownloadsLibrary(tracks: [track, track]), root: try root(),
            transfer: { _, destination, _, _ in
                await gate.wait()
                try Data("late result".utf8).write(to: destination)
            }, monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntilAsync { await gate.started }
        manager.removeTrack(track)
        await gate.resume()
        try await waitUntil { manager.owners.first?.state == .ready }
        XCTAssertFalse(manager.isReady(track))
        XCTAssertEqual(manager.owners.first?.tracks.count, 2)
        XCTAssertTrue(manager.downloadedSongs.isEmpty)
        _ = await manager.clearAccount()
    }

    func testArtworkSharesBoundedRenditionPersistsOfflineAndDeletesAfterFinalReference()
        async throws
    {
        let first = artworkTrack("first")
        let second = artworkTrack("second")
        let playlist = item("playlist", kind: .playlist)
        let library = DownloadsLibrary(tracks: [first, first, second])
        await library.setArtwork(try artworkData())
        let directory = try root()
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(playlist)
        manager.download(first)
        try await waitUntil {
            manager.artworkBytes > 0 && manager.owners.allSatisfy { $0.state == .ready }
        }
        let retained = await manager.retainedArtwork(for: first)
        let data = try XCTUnwrap(retained)
        let decoded = try XCTUnwrap(FoundationCurrentArtwork.decode(data))
        XCTAssertEqual(decoded.image.width, 640)
        XCTAssertEqual(decoded.image.height, 320)
        XCTAssertLessThanOrEqual(data.count, FoundationCurrentArtwork.maximumBytes)
        let secondArtwork = await manager.retainedArtwork(for: second)
        XCTAssertEqual(secondArtwork, data)
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies, [false])
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let manifest = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(manifest.artwork?.count, 1)
        let record = try XCTUnwrap(manifest.artwork?.values.first)
        let artURL = try XCTUnwrap(
            FoundationDownloadStorage.fileURL(record.file, directory: account))
        XCTAssertTrue(
            try artURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true)
        XCTAssertEqual(
            manager.itemBytes(first), Int64(Data("synthetic audio".utf8).count + data.count))
        manager.invalidate()
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        try await waitUntil { !restored.isLoading }
        let restoredData = await restored.retainedArtwork(for: first)
        XCTAssertEqual(restoredData, data)
        let policiesAfterRelaunch = await library.artworkPolicies
        XCTAssertEqual(policiesAfterRelaunch, [false])
        restored.removeTrack(first)
        XCTAssertEqual(restored.artworkBytes, Int64(data.count))
        restored.removeTrack(second)
        XCTAssertEqual(restored.artworkBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artURL.path))
        let removedData = await restored.retainedArtwork(for: first)
        XCTAssertNil(removedData)
        _ = await restored.clearAccount()
    }

    func testRestoredReadyAudioSchedulesMissingArtworkAfterInitialInventoryCompletes() async throws
    {
        let directory = try root()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        let original = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        original.updateConnectivity(isAllowed: true)
        original.download(track)
        try await waitUntil { original.isReady(track) }
        await original.artworkTask?.value
        XCTAssertEqual(original.artworkBytes, 0)
        let originalPolicies = await library.artworkPolicies
        XCTAssertEqual(originalPolicies, [false])
        original.invalidate()
        await library.setArtwork(try artworkData())
        let restored = FoundationDownloads(
            scope: "fixture", library: library, root: directory,
            transfer: { _, _, _, _ in
                XCTFail("Restored complete audio must not be downloaded again")
                throw FoundationLibraryError.unavailable
            }, monitorConnectivity: false)
        XCTAssertTrue(restored.isLoading)
        restored.updateConnectivity(isAllowed: true)
        try await waitUntil { !restored.isLoading && restored.artworkBytes > 0 }
        await restored.artworkTask?.value
        XCTAssertTrue(restored.isReady(track))
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies, [false, false])
        let retained = await restored.retainedArtwork(for: track)
        XCTAssertNotNil(retained)
        _ = await restored.clearAccount()
    }

    func testManifestPublicationRejectsInvalidTargetAndLeavesNoStagingFiles() throws {
        let directory = try root()
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        try FoundationDownloadStorage.prepare(account)
        var initial = FoundationDownloadManifest()
        try FoundationDownloadStorage.save(initial, directory: account)
        let target = account.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: target)
        initial.allowsCellular = true
        try FoundationDownloadStorage.save(initial, directory: account)
        XCTAssertTrue(try FoundationDownloadStorage.load(directory: account).allowsCellular)
        XCTAssertTrue(
            try target.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let sentinel = target.appendingPathComponent("sentinel")
        try original.write(to: sentinel)
        XCTAssertThrowsError(try FoundationDownloadStorage.save(initial, directory: account))
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: account.path), ["manifest.json"])
    }

    func testFailedArtworkTagRefreshRetainsPreviousImageWithoutBlockingAudio() async throws {
        let first = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [first])
        await library.setArtwork(try artworkData())
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.artworkBytes > 0 }
        let oldImage = await manager.retainedArtwork(for: first)
        let changed = artworkTrack("track", tag: "second")
        await library.setArtworkFailure(true)
        await library.setTracks([changed])
        manager.reconcilePlaylists()
        try await waitUntil {
            manager.owners.first?.tracks.first?.album?.primaryImageTag == "second"
        }
        try await waitUntilAsync { await library.artworkPolicies.count >= 2 }
        await manager.artworkTask?.value
        XCTAssertTrue(manager.isReady(changed))
        let fallback = await manager.retainedArtwork(for: changed)
        XCTAssertEqual(fallback, oldImage)
        manager.reconcilePlaylists()
        for _ in 0..<30 { await Task.yield() }
        let policies = await library.artworkPolicies
        XCTAssertEqual(policies.count, 2)
        _ = await manager.clearAccount()
    }

    func testFailedArtworkPublicationKeepsPreviousFileAndRemovesStagedReplacement() async throws {
        let directory = try root()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        await library.setArtwork(try artworkData())
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: directory, transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(item("playlist", kind: .playlist))
        try await waitUntil { manager.artworkBytes > 0 }
        await manager.artworkTask?.value
        let oldData = await manager.retainedArtwork(for: track)
        let revision = manager.artworkRevision
        let account = FoundationDownloadStorage.directory(scope: "fixture", root: directory)
        let oldManifest = try FoundationDownloadStorage.load(directory: account)
        let originalFiles = Set(try FileManager.default.contentsOfDirectory(atPath: account.path))
        let gate = DownloadGate()
        await library.setArtworkGate(gate)
        let changed = artworkTrack("track", tag: "second")
        await library.setTracks([changed])
        manager.reconcilePlaylists()
        try await waitUntilAsync { await gate.started }
        let task = manager.artworkTask
        let target = account.appendingPathComponent("manifest.json")
        let saved = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        await gate.resume()
        await task?.value
        XCTAssertEqual(manager.artworkRevision, revision)
        let retained = await manager.retainedArtwork(for: changed)
        XCTAssertEqual(retained, oldData)
        XCTAssertTrue(manager.isReady(changed))
        try FileManager.default.removeItem(at: target)
        try saved.write(to: target)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: account.path)), originalFiles)
        let restored = try FoundationDownloadStorage.load(directory: account)
        XCTAssertEqual(
            restored.artwork?.values.first?.file.name, oldManifest.artwork?.values.first?.file.name)
        _ = await manager.clearAccount()
    }

    func testRemovedArtworkReferenceRejectsLateOptionalResponse() async throws {
        let gate = DownloadGate()
        let track = artworkTrack("track")
        let library = DownloadsLibrary(tracks: [track])
        await library.setArtwork(try artworkData())
        await library.setArtworkGate(gate)
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntilAsync { await gate.started }
        XCTAssertTrue(manager.isReady(track))
        manager.removeTrack(track)
        await gate.resume()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(manager.artworkBytes, 0)
        let data = await manager.retainedArtwork(for: track)
        XCTAssertNil(data)
        _ = await manager.clearAccount()
    }

    func testLocalOnlyResolverRevalidatesMissingFileWithoutStartingRemoteRequest() async throws {
        let track = item("track")
        let library = DownloadsLibrary(tracks: [track])
        let manager = FoundationDownloads(
            scope: "fixture", library: library, root: try root(), transfer: transfer,
            monitorConnectivity: false)
        manager.updateConnectivity(isAllowed: true)
        manager.download(track)
        try await waitUntil { manager.isReady(track) }
        let local = try await manager.playbackResource(for: track, allowsRemoteFallback: false)
        XCTAssertTrue(local.url.isFileURL)
        await local.release()
        manager.updateConnectivity(isAllowed: false)
        try FileManager.default.removeItem(at: local.url)
        XCTAssertTrue(
            manager.isReady(track), "The cached projection is revalidated by the resolver")
        do {
            _ = try await manager.playbackResource(for: track, allowsRemoteFallback: false)
            XCTFail("A missing local file must fail in local-only mode")
        } catch {
            XCTAssertTrue(error is FoundationLibraryError)
        }
        XCTAssertFalse(manager.isReady(track))
        let requests = await library.playbackRequests
        XCTAssertEqual(requests, 0)
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
    private var artwork: Data?
    private var artworkFails = false
    private var artworkGate: DownloadGate?
    private(set) var artworkPolicies: [Bool] = []
    private(set) var playbackRequests = 0
    func setArtwork(_ data: Data?) { artwork = data }
    func setArtworkFailure(_ value: Bool) { artworkFails = value }
    func setArtworkGate(_ gate: DownloadGate) { artworkGate = gate }
    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    {
        guard item.kind == .album else { return nil }
        artworkPolicies.append(allowsCellular)
        if let gate = artworkGate {
            artworkGate = nil
            await gate.wait()
        }
        if artworkFails { throw FoundationLibraryError.unavailable }
        return artwork
    }
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
        playbackRequests += 1
        return URL(string: "https://example.invalid/stream")!
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
