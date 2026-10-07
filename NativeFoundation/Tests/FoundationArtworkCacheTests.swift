import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

final class FoundationArtworkCacheTests: XCTestCase {
    private func item(
        _ id: String = "album", tag: String? = "v1", kind: FoundationItem.Kind = .album
    )
        -> FoundationItem
    {
        FoundationItem(
            id: id, title: "", subtitle: "", kind: kind, duration: nil, primaryImageTag: tag)
    }

    private func image() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 2560,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
    }

    func testHomeAlbumAndLibraryTrackReuseOneDecodedResult() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic-account", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        let home = try await cache.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        let library = try await cache.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(home?.id, library?.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(home?.image.width, 160)
    }

    func testOmittedTagsReuseKnownRevisionIncludingColdOfflineLaunch() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let original = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: "album", title: "", primaryImageTag: nil))
        let omitted = try await cache.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(original?.id, omitted?.id)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let local = try await restored.result(
            for: track, pixels: 640, allowsNetwork: false, load: probe.load)
        XCTAssertEqual(local?.image.width, 160)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let newer = try await restored.result(
            for: item(tag: "v2"), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNotEqual(newer?.id, local?.id)
        let latest = try await restored.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(newer?.id, latest?.id)
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 2)
        _ = await restored.invalidate(removeDisk: true)
    }

    func testMissingTagUpgradeUsesKnownRevisionOnProviderRequest() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        _ = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let upgraded = try await cache.result(
            for: item(tag: nil), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.image.width, 640)
        let requestedTags = await probe.requestedTags
        XCTAssertEqual(requestedTags, ["v1", "v1"])
        let explicit = try await cache.result(
            for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.id, explicit?.id)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testLocalPreviewRemainsUsableDuringCancelledHeroUpgrade() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        let tile = try await cache.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        let held = ArtworkCacheProbe(data: try image(), held: true)
        let upgrade = Task {
            try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: held.load)
        }
        try await held.waitForCount(1)
        let preview = try await cache.cachedResult(for: album, pixels: 640)
        XCTAssertEqual(preview?.id, tile?.id)
        XCTAssertEqual(preview?.image.width, 160)
        upgrade.cancel()
        await held.release()
        _ = try? await upgrade.value
        let retained = try await cache.cachedResult(for: album, pixels: 640)
        XCTAssertNotNil(retained)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testArtistPlaylistAndGenreIdentityAndChangedRevision() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        for kind in [FoundationItem.Kind.artist, .playlist, .genre, .album] {
            for _ in 0..<2 {
                _ = try await cache.result(
                    for: item("same", kind: kind), pixels: 160, allowsNetwork: true,
                    load: probe.load)
            }
        }
        _ = try await cache.result(
            for: item("same", tag: "v2"), pixels: 160, allowsNetwork: true, load: probe.load)
        let count = await probe.count
        XCTAssertEqual(count, 5, "Album representative and genre Primary must not alias")
    }

    func testHeroServesTileButTileRequiresHeroUpgrade() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        _ = try await cache.result(for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let hero = try await cache.result(
            for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(hero?.image.width, 640)
        let tile = try await cache.result(
            for: item("second"), pixels: 640, allowsNetwork: true, load: probe.load)
        let smaller = try await cache.result(
            for: item("second"), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(tile?.id, smaller?.id)
        let count = await probe.count
        XCTAssertEqual(count, 3)
    }

    func testColdLaunchOfflineDiskReuseAccountIsolationAndRemoval() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ArtworkCacheProbe(data: try image())
        let cache = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        _ = try await cache.result(for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        let local = try await restored.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNotNil(local)
        let other = FoundationArtworkCache(scope: "server-b/account-a", root: root)
        let foreign = try await other.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(foreign)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let cleared = await restored.invalidate(removeDisk: true)
        XCTAssertTrue(cleared)
        let third = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        let removed = try await third.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(removed)
    }

    func testMemoryAndDiskEvictionStayBoundedAndDoNotTouchRetainedDownloads() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retained = root.appendingPathComponent("download-owned")
        try Data("retained".utf8).write(to: retained)
        let data = try image()
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root,
            limits: .init(memoryBytes: 60_000, diskBytes: data.count + 1000))
        let probe = ArtworkCacheProbe(data: data)
        for id in ["one", "two", "three"] {
            _ = try await cache.result(
                for: item(id), pixels: 160, allowsNetwork: true, load: probe.load)
        }
        let usage = await cache.usage()
        XCTAssertLessThanOrEqual(usage.memory, 60_000)
        XCTAssertLessThanOrEqual(usage.disk, data.count + 1000)
        _ = await cache.invalidate(removeDisk: true)
        XCTAssertEqual(try Data(contentsOf: retained), Data("retained".utf8))
    }

    func testConcurrentRequestsCoalesceAndOneCancellationKeepsOtherConsumer() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        let album = item()
        let first = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        try await probe.waitForCount(1)
        let second = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        // Actor round trip after registering the second task.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cache.consumerCount() < 2 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        first.cancel()
        await probe.release()
        _ = try await second.value
        do {
            _ = try await first.value
            XCTFail("Cancelled consumer returned artwork")
        } catch is CancellationError {}
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }

    func testFetchConcurrencyAndQueuedCancellationAreBounded() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root, limits: .init(concurrentLoads: 2))
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        var tasks: [Task<FoundationCurrentArtwork.Result?, Error>] = []
        for index in 0..<6 {
            let album = item("album\(index)")
            tasks.append(
                Task {
                    try await cache.result(
                        for: album, pixels: 160, allowsNetwork: true, load: probe.load)
                })
        }
        try await probe.waitForCount(2)
        for task in tasks { task.cancel() }
        await probe.release()
        for task in tasks { _ = try? await task.value }
        _ = await cache.invalidate(removeDisk: false)
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 2)
        let usage = await cache.usage()
        XCTAssertEqual(usage.active, 0)
        XCTAssertEqual(usage.pending, 0)
    }

    func testInvalidationRejectsLateBytesAndNoDiskResurrection() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        let album = item()
        let task = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        try await probe.waitForCount(1)
        let retire = Task { await cache.invalidate(removeDisk: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cache.consumerCount() != 0 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        await probe.release()
        let cleared = await retire.value
        XCTAssertTrue(cleared)
        do {
            _ = try await task.value
            XCTFail("Retired account returned late artwork")
        } catch is CancellationError {}
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let result = try await restored.result(
            for: album, pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(result)
    }

    func testMalformedImageIsNotRetainedAndOfflineDoesNotFetch() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: Data("invalid".utf8))
        let invalid = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNil(invalid)
        let offline = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(offline)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let usage = await cache.usage()
        XCTAssertEqual(usage.memory, 0)
        let directory = root.appendingPathComponent(
            FoundationArtworkCache.digest("synthetic"), isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertTrue(files.allSatisfy { $0.lastPathComponent == "revisions.plist" })
        let metadataBytes = try files.reduce(0) { total, file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            return total + (values.fileSize ?? 0)
        }
        XCTAssertEqual(usage.disk, metadataBytes)
        XCTAssertLessThanOrEqual(metadataBytes, 65_536)
        let cold = FoundationArtworkCache(scope: "synthetic", root: root)
        let restored = try await cold.result(
            for: item(tag: nil), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(restored)
        let restoredCount = await probe.count
        XCTAssertEqual(restoredCount, 1)
    }
    func testUntaggedExpiryAndBoundedFailureSuppression() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtworkCacheClock()
        let cache = FoundationArtworkCache(scope: "synthetic", root: root, now: clock.read)
        let probe = ArtworkCacheProbe(data: try image())
        let untagged = item(tag: nil, kind: .artist)
        _ = try await cache.result(
            for: untagged, pixels: 160, allowsNetwork: true, load: probe.load)
        clock.advance(86_401)
        _ = try await cache.result(
            for: untagged, pixels: 160, allowsNetwork: true, load: probe.load)
        let count = await probe.count
        XCTAssertEqual(count, 2)
        let invalid = ArtworkCacheProbe(data: Data("invalid".utf8))
        let missing = item("missing")
        for _ in 0..<5 {
            _ = try await cache.result(
                for: missing, pixels: 160, allowsNetwork: true, load: invalid.load)
        }
        let suppressed = await invalid.count
        XCTAssertEqual(suppressed, 1)
        clock.advance(61)
        _ = try await cache.result(
            for: missing, pixels: 160, allowsNetwork: true, load: invalid.load)
        let retried = await invalid.count
        XCTAssertEqual(retried, 2)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testStartupCleanupPreservesLiveAccountAndRemovesRetiredScopes() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ArtworkCacheProbe(data: try image())
        let retired = FoundationArtworkCache(scope: "old-account", root: root)
        _ = try await retired.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        _ = await retired.invalidate(removeDisk: false)
        let live = FoundationArtworkCache(scope: "live-account", root: root)
        _ = try await live.result(for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let cleared = await FoundationArtworkCache.clearStoredArtwork(root: root)
        XCTAssertTrue(cleared)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(retired.scope).path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(live.scope).path))
        _ = await live.invalidate(removeDisk: true)
    }

    func testProductionAdapterCoalescesAlbumAndTrackImageRequests() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let library = FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "user", deviceID: "device"),
            load: { request in
                let data = try await probe.load(
                    FoundationItem(id: "", title: "", subtitle: "", kind: .album, duration: nil),
                    160)!
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "image/jpeg"])!
                )
            }, artworkCache: cache)
        let album = item("11111111111111111111111111111111")
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        async let home = library.artworkResult(for: album, size: 160, allowsNetwork: true)
        async let row = library.artworkResult(for: track, size: 160, allowsNetwork: true)
        let results = try await (home, row)
        XCTAssertEqual(results.0?.id, results.1?.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        _ = await cache.invalidate(removeDisk: true)
    }

    @MainActor
    func testCurrentOwnerReadsColdOfflineCacheWithoutChangingQueueOrPlaybackIntent() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        _ = try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activateSession: {},
            deactivateSession: {}, startPlayback: { _ in })
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        player.setQueue([track, track], selectedIndex: 0)
        let selection = player.selectedEntryID
        let entries = player.queue.map(\.id)
        let state = player.state
        let current = FoundationCurrentArtwork(player: player) { item in
            try await restored.result(
                for: item, pixels: 640, allowsNetwork: false, load: probe.load)?.data
        }
        await current.loadTask?.value
        XCTAssertNotNil(current.result(for: track))
        XCTAssertEqual(player.selectedEntryID, selection)
        XCTAssertEqual(player.queue.map(\.id), entries)
        XCTAssertEqual(player.state, state)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        current.invalidate()
        player.stop()
        _ = await restored.invalidate(removeDisk: true)
    }

    func testMalformedPersistentRecordRecoversWithOneFreshImageRead() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        _ = try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let directory = root.appendingPathComponent(cache.scope)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "art" })
        try Data("corrupt".utf8).write(to: file)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let result = try await restored.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNotNil(result)
        let count = await probe.count
        XCTAssertEqual(count, 2)
        _ = await restored.invalidate(removeDisk: true)
    }

    @MainActor
    func testOfflineCurrentMissRecoversOnExplicitConnectivityRefresh() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let availability = ArtworkCacheAvailability()
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activateSession: {},
            deactivateSession: {}, startPlayback: { _ in })
        let album = item()
        player.setQueue(
            [
                FoundationItem(
                    id: "song", title: "", subtitle: "", kind: .track, duration: nil,
                    album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
            ], selectedIndex: 0)
        let current = FoundationCurrentArtwork(player: player) { item in
            try await cache.result(
                for: item, pixels: 640, allowsNetwork: availability.read(), load: probe.load)?.data
        }
        await current.loadTask?.value
        XCTAssertNil(current.result)
        let before = await probe.count
        XCTAssertEqual(before, 0)
        availability.connect()
        current.refreshRetainedArtwork()
        await current.loadTask?.value
        XCTAssertNotNil(current.result)
        let after = await probe.count
        XCTAssertEqual(after, 1)
        current.invalidate()
        player.stop()
        _ = await cache.invalidate(removeDisk: true)
    }

    func testDiskLRURetainsRecentlyReadIdentity() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try image()
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root,
            // Include bounded revision metadata while retaining room for exactly two images.
            limits: .init(memoryBytes: 0, diskBytes: (data.count + 256) * 2 + 1_024))
        let probe = ArtworkCacheProbe(data: data)
        for id in ["one", "two"] {
            _ = try await cache.result(
                for: item(id), pixels: 160, allowsNetwork: true, load: probe.load)
        }
        let directory = root.appendingPathComponent(cache.scope)
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        }
        _ = try await cache.result(
            for: item("one"), pixels: 160, allowsNetwork: true, load: probe.load)
        _ = try await cache.result(
            for: item("three"), pixels: 160, allowsNetwork: true, load: probe.load)
        let one = FoundationArtworkCache.key(item("one"), pixels: 160)
        let two = FoundationArtworkCache.key(item("two"), pixels: 160)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(one.identity)-160.art").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(two.identity)-160.art").path))
        _ = await cache.invalidate(removeDisk: true)
    }

    #if DEBUG
        func testCoalescedWorkerPreservesInitiatingTraceContext() async throws {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = FoundationArtworkCache(scope: "synthetic", root: root)
            let data = try image()
            let expected = FoundationTrace.Context(origin: .home, page: .artwork)
            _ = try await FoundationTrace.$context.withValue(expected) {
                try await cache.result(for: item(), pixels: 160, allowsNetwork: true) { _, _ in
                    XCTAssertEqual(FoundationTrace.context?.owner, expected.owner)
                    return data
                }
            }
            _ = await cache.invalidate(removeDisk: true)
        }
    #endif

}

private actor ArtworkCacheProbe {
    let data: Data
    var held: Bool
    var count = 0
    var requestedTags: [String?] = []
    var active = 0
    var peak = 0
    var waiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data, held: Bool = false) {
        self.data = data
        self.held = held
    }

    func load(_ item: FoundationItem, _ pixels: Int) async throws -> Data? {
        count += 1
        requestedTags.append(item.primaryImageTag)
        active += 1
        peak = max(peak, active)
        if held { await withCheckedContinuation { waiters.append($0) } }
        active -= 1
        return data
    }

    func release() {
        held = false
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while count < expected {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
    }
}

private final class ArtworkCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func advance(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(seconds)
    }
}

private final class ArtworkCacheAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }
    func connect() {
        lock.lock()
        defer { lock.unlock() }
        connected = true
    }
}
