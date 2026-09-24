import AVFoundation
import ImageIO
import NowPlaying
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCurrentArtworkTests: XCTestCase {
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

    private func imageData(width: Int = 2, height: Int = 2) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testHeroAndSystemShareResultAcrossMetadataAndSameAlbumSelection() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
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
        await probe.waitForCount(1)
        XCTAssertNil(owner.result(for: item))
        XCTAssertNil((bridge.content as? MusicContent)?.artwork)
        await probe.complete(0, with: data)
        await owner.loadTask?.value
        await bridge.updateTask?.value
        let result = try XCTUnwrap(owner.result(for: item))
        XCTAssertEqual((bridge.content as? MusicContent)?.artwork?.id, result.id.uuidString)
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

    func testChangedIdentityCancelsAndRejectsLateResultAndStaleCallback() async throws {
        let data = try imageData()
        let probe = ArtworkProbe()
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
        await probe.waitForCount(1)
        let oldTask = owner.loadTask
        player.next()
        await owner.updateTask?.value
        XCTAssertTrue(oldTask?.isCancelled == true)
        await probe.waitForCount(2)
        await probe.complete(1, with: data)
        await owner.loadTask?.value
        let accepted = try XCTUnwrap(owner.result(for: second))
        await probe.complete(0, with: data)
        await oldTask?.value
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
        let player = player()
        let old = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        let item = track("album", tag: nil)
        player.setQueue([item], selectedIndex: 0)
        await old.updateTask?.value
        await probe.waitForCount(1)
        let oldTask = old.loadTask
        old.invalidate()
        let current = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            current.invalidate()
            player.stop()
        }
        await probe.waitForCount(2)
        await probe.complete(0, with: data)
        await oldTask?.value
        XCTAssertNil(old.result)
        await probe.complete(1, with: data)
        await current.loadTask?.value
        let result = try XCTUnwrap(current.result(for: item))
        current.invalidate()
        XCTAssertNil(current.data(for: result.id))
        XCTAssertNil(current.artwork(for: item))
        let count = await probe.count
        XCTAssertEqual(count, 2)
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
        let owner = FoundationCurrentArtwork(player: player) { await probe.load($0) }
        defer {
            owner.invalidate()
            player.stop()
        }
        let item = track("album")
        player.setQueue([item, item], selectedIndex: 0)
        await owner.updateTask?.value
        await probe.waitForCount(1)
        await probe.complete(0, with: Data("invalid".utf8))
        await owner.loadTask?.value
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
}

private actor ArtworkProbe {
    private(set) var count = 0
    private var pending: [Int: CheckedContinuation<Data?, Never>] = [:]
    private var waiter: (Int, CheckedContinuation<Void, Never>)?

    func missingResult(shouldFail: Bool) throws -> Data? {
        count += 1
        if shouldFail { throw URLError(.timedOut) }
        return nil
    }

    func load(_ item: FoundationItem) async -> Data? {
        let request = count
        count += 1
        return await withCheckedContinuation { continuation in
            pending[request] = continuation
            if let (target, continuation) = waiter, count >= target {
                waiter = nil
                continuation.resume()
            }
        }
    }

    func waitForCount(_ target: Int) async {
        guard count < target else { return }
        await withCheckedContinuation { waiter = (target, $0) }
    }

    func complete(_ request: Int, with data: Data?) {
        pending.removeValue(forKey: request)?.resume(returning: data)
    }
}
