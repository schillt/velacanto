import AVFoundation
import ImageIO
import NowPlaying
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCurrentArtworkTests: XCTestCase {
    private func requireArtworkTask<Success: Sendable, Failure: Error>(
        _ task: Task<Success, Failure>?, probe: ArtworkProbe, name: String,
        cleanup: @MainActor () -> Void
    ) async -> Bool {
        guard let task else { return true }
        let finished = XCTestExpectation(description: name)
        let observer = Task {
            _ = await task.result
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            task.cancel()
            cleanup()
            await probe.retire()
            observer.cancel()
            XCTFail("\(name) did not finish within 5 seconds")
            return false
        }
        return true
    }

    private func track(_ album: String, tag: String? = "version") -> FoundationItem {
        FoundationItem(
            id: "track", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album, title: "", primaryImageTag: tag))
    }

    private func player() -> FoundationPlayer {
        FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) },
            activateSession: {}, deactivateSession: {}, startPlayback: { _ in })
    }

    private func imageData(width: Int = 64, height: Int = 64) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Three synthetic lossless WebP frames: red canvas, blue partial with
    /// background disposal, then green partial. Created solely for this test.
    func testHeroAndSystemShareResultAcrossMetadataAndSameAlbumSelection() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let owner = FoundationCurrentArtwork(player: player) { item in await probe.load(item) }
        let bridge = FoundationNowPlaying(player: player, artwork: owner)
        defer {
            bridge.invalidate()
            owner.invalidate()
            player.stop()
        }
        let item = track("album")
        player.setQueue([item, item], selectedIndex: 0)
        await owner.updateTask?.value
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        XCTAssertNil(owner.result(for: item))
        await bridge.updateTask?.value
        let pendingArtworkID = try XCTUnwrap((bridge.content as? MusicContent)?.artwork?.id)
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    bridge.invalidate()
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        await bridge.updateTask?.value
        let result = try XCTUnwrap(owner.result(for: item))
        XCTAssertEqual((bridge.content as? MusicContent)?.artwork?.id, result.id.uuidString)
        XCTAssertEqual(pendingArtworkID, result.id.uuidString)
        XCTAssertEqual(owner.data(for: result.id), data)
        for _ in 0..<5 {
            _ = owner.artwork(for: item)
            _ = owner.result(for: item)
            _ = bridge.commands
        }
        player.pause()
        await bridge.updateTask?.value
        player.next()
        await owner.updateTask?.value
        await bridge.updateTask?.value
        XCTAssertEqual(owner.result(for: item)?.id, result.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        XCTAssertTrue(player.wantsPlayback)
    }

    func testExplicitRefreshRetainsArtworkIdentityAndBytesOnOptionalFailure() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let item = track("album")
        player.setQueue([item], selectedIndex: 0)
        let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            owner.invalidate()
            player.stop()
        }
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        let first = try XCTUnwrap(owner.result(for: item))
        owner.refreshRetainedArtwork()
        guard await probe.waitForCount(2) else {
            XCTFail("Artwork request 2 did not enter within 5 seconds")
            return
        }
        XCTAssertEqual(owner.result(for: item)?.id, first.id)
        let provider = try XCTUnwrap(owner.provider(for: item))
        let retainedProvider = Task { _ = try await provider(CGSize(width: 640, height: 640)) }
        guard
            await requireArtworkTask(
                retainedProvider, probe: probe, name: "retained provider",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        try await retainedProvider.value
        await probe.complete(1, with: nil)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        XCTAssertEqual(owner.result(for: item)?.data, data)
        XCTAssertEqual(owner.result(for: item)?.id, first.id)
        XCTAssertTrue(player.wantsPlayback)
    }

    func testCachedPreviewAppearsWhileUpgradeRunsAndSurvivesFailure() async throws {
        let data = try imageData(width: 160, height: 80)
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let item = track("album")
        player.setQueue([item], selectedIndex: 0)
        let owner = FoundationCurrentArtwork(
            player: player, cachedLoad: { _ in data }, load: { await probe.load($0) })
        defer {
            owner.invalidate()
            player.stop()
        }
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let preview = try XCTUnwrap(owner.result(for: item))
        XCTAssertEqual(preview.image.width, 160)
        await probe.complete(0, with: nil)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        XCTAssertEqual(owner.result(for: item)?.id, preview.id)
        player.setQueue([track("album", tag: nil)], selectedIndex: 0)
        await owner.updateTask?.value
        XCTAssertEqual(owner.result?.id, preview.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }

    func testPreviewUpgradePublishesNewDisplayRevisionWithStableSystemIdentity() async throws {
        let previewData = try imageData(width: 160, height: 80)
        let heroData = try imageData(width: 640, height: 320)
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let item = track("album")
        player.setQueue([item], selectedIndex: 0)
        let owner = FoundationCurrentArtwork(
            player: player, cachedLoad: { _ in previewData }, load: { await probe.load($0) })
        defer {
            owner.invalidate()
            player.stop()
        }
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let preview = try XCTUnwrap(owner.result(for: item))
        let systemID = try XCTUnwrap(owner.artwork(for: item)?.id)
        await probe.complete(0, with: heroData)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        let hero = try XCTUnwrap(owner.result(for: item))
        XCTAssertEqual(hero.image.width, 640)
        XCTAssertEqual(hero.id, preview.id)
        XCTAssertNotEqual(hero.revision, preview.revision)
        XCTAssertEqual(owner.artwork(for: item)?.id, systemID)
        XCTAssertEqual(owner.data(for: preview.id), heroData)
        XCTAssertTrue(player.wantsPlayback)
    }

    func testDelayedSystemProvidersShareLoadAndConsumerCancellationDoesNotCancelOwner() async throws
    {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let item = track("album")
        let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            owner.invalidate()
            player.stop()
        }
        player.setQueue([item], selectedIndex: 0)
        await owner.updateTask?.value
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let provider = try XCTUnwrap(owner.provider(for: item))
        let started = XCTestExpectation(description: "Both system providers await artwork")
        started.expectedFulfillmentCount = 2
        let first = Task { () throws -> Void in
            started.fulfill()
            _ = try await provider(CGSize(width: 40, height: 40))
        }
        let second = Task { () throws -> Void in
            started.fulfill()
            _ = try await provider(CGSize(width: 1_024, height: 1_024))
        }
        let ready = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        guard ready == .completed else {
            first.cancel()
            second.cancel()
            owner.invalidate()
            player.stop()
            await probe.retire()
            XCTFail("System providers did not start within 2 seconds")
            return
        }
        first.cancel()
        XCTAssertFalse(owner.loadTask?.isCancelled == true)
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                second, probe: probe, name: "second provider",
                cleanup: {
                    first.cancel()
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        try await second.value
        guard
            await requireArtworkTask(
                first, probe: probe, name: "cancelled provider",
                cleanup: {
                    second.cancel()
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        do {
            try await first.value
            XCTFail("Cancelled provider published artwork")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation outcome") }
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let retainedProvider = Task { _ = try await provider(CGSize(width: 640, height: 640)) }
        guard
            await requireArtworkTask(
                retainedProvider, probe: probe, name: "retained provider",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        try await retainedProvider.value
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 1)
    }

    func testPendingSystemProviderDoesNotRetainInvalidatedOwner() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let item = track("album")
        var owner: FoundationCurrentArtwork? = FoundationCurrentArtwork(player: player) {
            await probe.load($0)
        }
        player.setQueue([item], selectedIndex: 0)
        await owner?.updateTask?.value
        guard await probe.waitForCount(1) else {
            owner?.invalidate()
            player.stop()
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let provider = try XCTUnwrap(owner?.provider(for: item))
        let started = XCTestExpectation(description: "Provider starts before account teardown")
        let request = Task { () throws -> Void in
            started.fulfill()
            _ = try await provider(CGSize(width: 640, height: 640))
        }
        let ready = await XCTWaiter.fulfillment(of: [started], timeout: 2)
        guard ready == .completed else {
            request.cancel()
            owner?.invalidate()
            player.stop()
            await probe.retire()
            XCTFail("System provider did not start within 2 seconds")
            return
        }
        weak let released = owner
        owner?.invalidate()
        owner = nil
        XCTAssertNil(released)
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                request, probe: probe, name: "released provider",
                cleanup: {
                    player.stop()
                })
        else { return }
        do {
            try await request.value
            XCTFail("Released account published artwork")
        } catch {}
        player.stop()
    }

    func testPendingSystemProviderRejectsDiscardedSelectionAndAccount() async throws {
        let data = try imageData()
        for invalidateAccount in [false, true] {
            let probe = ArtworkProbe()
            addTeardownBlock { await probe.retire() }
            let player = player()
            let item = track("album")
            let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
            player.setQueue([item], selectedIndex: 0)
            await owner.updateTask?.value
            guard await probe.waitForCount(1) else {
                owner.invalidate()
                player.stop()
                XCTFail("Artwork request 1 did not enter within 5 seconds")
                return
            }
            let provider = try XCTUnwrap(owner.provider(for: item))
            let started = XCTestExpectation(description: "System provider awaits current load")
            let request = Task { () throws -> Void in
                started.fulfill()
                _ = try await provider(CGSize(width: 640, height: 640))
            }
            let ready = await XCTWaiter.fulfillment(of: [started], timeout: 2)
            guard ready == .completed else {
                request.cancel()
                owner.invalidate()
                player.stop()
                await probe.retire()
                XCTFail("System provider did not start within 2 seconds")
                return
            }
            if invalidateAccount {
                owner.invalidate()
            } else {
                player.setQueue(
                    [
                        FoundationItem(
                            id: "no-art", title: "", subtitle: "", kind: .track, duration: nil)
                    ], selectedIndex: 0)
                await owner.updateTask?.value
            }
            await probe.complete(0, with: data)
            guard
                await requireArtworkTask(
                    request, probe: probe, name: "discarded provider",
                    cleanup: {
                        owner.invalidate()
                        player.stop()
                    })
            else { return }
            do {
                try await request.value
                XCTFail("Discarded provider published artwork")
            } catch {}
            XCTAssertNil(owner.result)
            owner.invalidate()
            player.stop()
        }
    }

    func testChangedIdentityCancelsAndRejectsLateResultAndStaleCallback() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            owner.invalidate()
            player.stop()
        }
        let first = track("album")
        let second = track("album", tag: "changed")
        player.setQueue([first, second], selectedIndex: 0)
        await owner.updateTask?.value
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let oldTask = owner.loadTask
        player.next()
        await owner.updateTask?.value
        XCTAssertTrue(oldTask?.isCancelled == true)
        guard await probe.waitForCount(2) else {
            XCTFail("Artwork request 2 did not enter within 5 seconds")
            return
        }
        await probe.complete(1, with: data)
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        let accepted = try XCTUnwrap(owner.result(for: second))
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                oldTask, probe: probe, name: "oldTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        XCTAssertEqual(owner.result(for: second)?.id, accepted.id)
        XCTAssertNil(owner.result(for: first))
        player.previous()
        // Even before the coalesced owner update, a retained system callback is obsolete.
        XCTAssertNil(owner.data(for: accepted.id))
        owner.invalidate()
    }

    func testAccountInvalidationRejectsLateWorkAndRetainedSystemResult() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let player = player()
        let old = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        let item = track("album", tag: nil)
        player.setQueue([item], selectedIndex: 0)
        await old.updateTask?.value
        guard await probe.waitForCount(1) else {
            old.invalidate()
            player.stop()
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        let oldTask = old.loadTask
        old.invalidate()
        let current = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            current.invalidate()
            player.stop()
        }
        guard await probe.waitForCount(2) else {
            XCTFail("Artwork request 2 did not enter within 5 seconds")
            return
        }
        await probe.complete(0, with: data)
        guard
            await requireArtworkTask(
                oldTask, probe: probe, name: "oldTask",
                cleanup: {
                    old.invalidate()
                    current.invalidate()
                    player.stop()
                })
        else { return }
        XCTAssertNil(old.result)
        await probe.complete(1, with: data)
        guard
            await requireArtworkTask(
                current.loadTask, probe: probe, name: "current.loadTask",
                cleanup: {
                    old.invalidate()
                    current.invalidate()
                    player.stop()
                })
        else { return }
        let result = try XCTUnwrap(current.result(for: item))
        current.invalidate()
        XCTAssertNil(current.data(for: result.id))
        XCTAssertNil(current.artwork(for: item))
        let count = await probe.count
        XCTAssertEqual(count, 2)
    }

    func testMissingCurrentArtworkRecoversOnlyAtExplicitRetryBoundary() async throws {
        let player = player()
        let item = track("album")
        player.setQueue([item], selectedIndex: 0)
        let probe = ArtworkProbe()
        let data = try imageData()
        let owner = FoundationCurrentArtwork(player: player) { _ in
            let count = await probe.count
            if count == 0 { return try await probe.missingResult(shouldFail: true) }
            XCTAssertTrue(FoundationRequestIntent.isPlayback)
            return data
        }
        defer {
            owner.invalidate()
            player.stop()
        }
        await owner.loadTask?.value
        XCTAssertNil(owner.result)
        owner.retryMissingArtwork()
        await owner.loadTask?.value
        XCTAssertNotNil(owner.result(for: item))
        XCTAssertTrue(player.wantsPlayback)
    }

    func testOptionalProviderFailureAndMissingResultDoNotRetrySameIdentity() async {
        let player = player()
        let item = track("album")
        player.setQueue([item, item], selectedIndex: 0)
        defer { player.stop() }
        for shouldFail in [false, true] {
            let probe = ArtworkProbe()
            let owner = FoundationCurrentArtwork(player: player) { _ in
                try await probe.missingResult(shouldFail: shouldFail)
            }
            await owner.loadTask?.value
            XCTAssertNil(owner.result)
            player.setQueue([item, item], selectedIndex: 0)
            await owner.updateTask?.value
            XCTAssertNil(owner.result)
            XCTAssertTrue(player.wantsPlayback)
            let count = await probe.count
            XCTAssertEqual(count, 1)
            owner.invalidate()
        }
    }

    func testOptionalMalformedOversizedAndAbsentArtworkNeverChangesPlayback() async throws {
        XCTAssertNil(FoundationCurrentArtwork.decode(Data()))
        XCTAssertNil(FoundationCurrentArtwork.decode(Data("malformed".utf8)))
        XCTAssertNil(
            FoundationCurrentArtwork.decode(Data(count: FoundationCurrentArtwork.maximumBytes + 1)))
        XCTAssertNil(FoundationCurrentArtwork.decode(try imageData(width: 2_049, height: 1)))
        let bounded = try XCTUnwrap(
            FoundationCurrentArtwork.decode(try imageData(width: 1_024, height: 1_024)))
        XCTAssertLessThanOrEqual(bounded.image.width, 640)
        XCTAssertLessThanOrEqual(bounded.image.height, 640)
        let player = player()
        let probe = ArtworkProbe()
        addTeardownBlock { await probe.retire() }
        let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            owner.invalidate()
            player.stop()
        }
        let item = track("album")
        player.setQueue([item, item], selectedIndex: 0)
        await owner.updateTask?.value
        guard await probe.waitForCount(1) else {
            XCTFail("Artwork request 1 did not enter within 5 seconds")
            return
        }
        await probe.complete(0, with: Data("invalid".utf8))
        guard
            await requireArtworkTask(
                owner.loadTask, probe: probe, name: "owner.loadTask",
                cleanup: {
                    owner.invalidate()
                    player.stop()
                })
        else { return }
        XCTAssertNil(owner.result)
        XCTAssertTrue(player.wantsPlayback)
        player.next()
        await owner.updateTask?.value
        let count = await probe.count
        XCTAssertEqual(count, 1)
        player.setQueue(
            [FoundationItem(id: "no-album", title: "", subtitle: "", kind: .track, duration: nil)],
            selectedIndex: 0)
        await owner.updateTask?.value
        XCTAssertNil(owner.result)
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 1)
    }

    func testCatalogDecodeBoundsRetainedPixelsAndRejectsInvalidLimits() throws {
        let data = try imageData(width: 1_024, height: 512)
        let thumbnail = try XCTUnwrap(FoundationCurrentArtwork.decode(data, maximumPixels: 160))
        XCTAssertEqual(thumbnail.image.width, 160)
        XCTAssertEqual(thumbnail.image.height, 80)
        XCTAssertLessThanOrEqual(
            thumbnail.image.bytesPerRow * thumbnail.image.height, 160 * 160 * 4)
        let hero = try XCTUnwrap(FoundationCurrentArtwork.decode(data, maximumPixels: 640))
        XCTAssertEqual(hero.image.width, 640)
        XCTAssertEqual(hero.image.height, 320)
        XCTAssertLessThanOrEqual(hero.image.bytesPerRow * hero.image.height, 640 * 640 * 4)
        XCTAssertNil(FoundationCurrentArtwork.decode(data, maximumPixels: 0))
        XCTAssertNil(FoundationCurrentArtwork.decode(data, maximumPixels: 2049))
        XCTAssertNil(
            FoundationCurrentArtwork.decode(Data("offline failure".utf8), maximumPixels: 160))
    }
}

private actor ArtworkProbe {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var retired = false
    private var waiters: [(Int, XCTestExpectation)] = []

    func missingResult(shouldFail: Bool) throws -> Data? {
        count += 1
        if shouldFail { throw URLError(.timedOut) }
        return nil
    }

    func load(_ item: FoundationItem) async -> Data? {
        guard !retired else { return nil }
        let request = count
        count += 1
        return await withCheckedContinuation { continuation in
            pending[request] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for (_, event) in ready { event.fulfill() }
        }
    }

    func waitForCount(_ target: Int) async -> Bool {
        guard count < target else { return true }
        let event = XCTestExpectation(description: "artwork request entered")
        waiters.append((target, event))
        let result = await XCTWaiter.fulfillment(of: [event], timeout: 5)
        guard result == .completed && !Task.isCancelled else {
            retired = true
            waiters.removeAll { $0.1 === event }
            let held = Array(pending.values)
            pending.removeAll()
            for continuation in held { continuation.resume(returning: nil) }
            return false
        }
        return true
    }

    func retire() {
        retired = true
        let held = Array(pending.values)
        pending.removeAll()
        for continuation in held { continuation.resume(returning: nil) }
    }

    func complete(_ request: Int, with data: Data?) {
        pending.removeValue(forKey: request)?.resume(returning: data)
    }
}
