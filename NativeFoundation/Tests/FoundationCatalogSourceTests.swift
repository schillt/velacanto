import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCatalogSourceTests: XCTestCase {
    private func server(_ digit: String = "a") throws -> FoundationCatalogSource {
        try .jellyfin(scope: String(repeating: digit, count: 64))
    }

    private func track(_ id: String = "opaque", source: FoundationCatalogSource? = nil)
        -> FoundationItem
    {
        FoundationItem(
            id: id, title: "Synthetic", subtitle: "", kind: .track, duration: nil,
            catalogSource: source)
    }

    private func localCatalog(
        _ id: UUID, count: Int = 1, state: FoundationLocalCatalog.State = .ready
    )
        -> FoundationLocalCatalog
    {
        .init(
            sourceID: id, state: state,
            records: (0..<count).map {
                .init(
                    id: id.uuidString + ":" + String(format: "%064x", $0),
                    relativePath: "private-subfolder/Synthetic\($0).mp3", title: "Synthetic \($0)",
                    byteCount: 1, modified: Date(timeIntervalSince1970: 0), missing: false)
            })
    }

    func testLegacyItemAndReferenceDecodeWithoutSourceAndKeepRawID() throws {
        let itemData = try JSONEncoder().encode(track())
        let decoded = try JSONDecoder().decode(FoundationItem.self, from: itemData)
        XCTAssertNil(decoded.catalogSource)
        XCTAssertEqual(decoded.id, "opaque")
        let referenceData = Data(#"{"id":"opaque","title":"Synthetic"}"#.utf8)
        let reference = try JSONDecoder().decode(FoundationItemReference.self, from: referenceData)
        XCTAssertNil(reference.catalogSource)
        XCTAssertThrowsError(try decoded.catalogKey())
        XCTAssertEqual(try decoded.catalogKey(legacyJellyfinSource: server()).itemID, "opaque")
        XCTAssertThrowsError(try decoded.catalogKey(legacyJellyfinSource: .local(sourceID: UUID())))
    }

    func testUnknownMalformedSourcesCannotDecodeAsLegacy() throws {
        for source in [
            #"{"kind":"future","identity":"opaque"}"#,
            #"{"kind":"jellyfin","identity":"https://invalid.example"}"#,
            #"{"kind":"local","identity":"not-a-uuid"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(FoundationCatalogSource.self, from: Data(source.utf8)))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(track())) as? [String: Any])
            object["catalogSource"] = try JSONSerialization.jsonObject(with: Data(source.utf8))
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    FoundationItem.self, from: JSONSerialization.data(withJSONObject: object)))
        }
    }

    func testTypedKeysSeparateSourceAndKindWithRawIDsUnchanged() throws {
        let first = try track("opaque:delimiter\0x", source: server()).catalogKey()
        let otherSource = try track("opaque:delimiter\0x", source: server("b")).catalogKey()
        var album = track("opaque:delimiter\0x", source: try server())
        album = FoundationItem(
            id: album.id, title: album.title, subtitle: "", kind: .album,
            duration: nil, catalogSource: album.catalogSource)
        XCTAssertEqual(Set([first, otherSource, try album.catalogKey()]).count, 3)
        XCTAssertEqual(first.itemID, "opaque:delimiter\0x")
    }

    func testLocalIdentityRejectsPathAndWrongSourceDigest() throws {
        let source = FoundationCatalogSource.local(sourceID: UUID())
        XCTAssertThrowsError(try track("/private/music/song.mp3", source: source).catalogKey())
        let other = localCatalog(UUID()).records[0].id
        XCTAssertThrowsError(try track(other, source: source).catalogKey())
        XCTAssertEqual(source.capabilities(for: .track), [.catalogPresence])
    }

    func testSourceRoundTripContainsNoFolderOrBookmark() throws {
        let id = UUID()
        let source = FoundationCatalogSource.local(sourceID: id)
        let data = try JSONEncoder().encode(source)
        XCTAssertEqual(try JSONDecoder().decode(FoundationCatalogSource.self, from: data), source)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["kind", "identity"])
        XCTAssertEqual(fields["identity"], id.uuidString)
    }

    func testRelatedRoutesPropagateSourceAndRejectExplicitCrossSourceReference() throws {
        let source = try server()
        var item = track(source: source)
        item.album = .init(id: "album", title: "Album")
        item.artist = .init(id: "artist", title: "Artist", catalogSource: source)
        XCTAssertEqual(item.relatedAlbum?.catalogSource, source)
        XCTAssertEqual(item.relatedArtist?.catalogSource, source)
        XCTAssertEqual(item.artworkItem(for: .primary)?.catalogSource, source)
        XCTAssertEqual(item.catalogArtworkItem.catalogSource, source)
        item.album = .init(id: "foreign", title: "Foreign", catalogSource: try server("b"))
        XCTAssertNil(item.relatedAlbum)
        XCTAssertEqual(item.catalogArtworkItem, item)
        let legacy = track()
        XCTAssertNil(legacy.catalogArtworkItem.catalogSource)
    }

    private actor HeldPage {
        private var entered = false
        private var enteredWaiter: CheckedContinuation<Void, Never>?
        private var finishWaiter: CheckedContinuation<Void, Never>?
        func hold() async {
            await withCheckedContinuation { continuation in
                finishWaiter = continuation
                entered = true
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { enteredWaiter = $0 }
        }
        func finish() {
            finishWaiter?.resume()
            finishWaiter = nil
        }
    }

    func testHeldServerDoesNotDelayLocalPublicationAndSourceOrderStaysStable() async throws {
        let remote = try server()
        let id = UUID()
        let local = FoundationCatalogSource.local(sourceID: id)
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: local)
        let gate = HeldPage()
        let remoteItem = track()
        let remoteTask = Task {
            try await composition.load(remote) { _ in
                await gate.hold()
                return .init(page: .init(items: [remoteItem], nextStartIndex: nil))
            }
        }
        await gate.waitUntilEntered()
        let page = try FoundationCatalogComposition.localPage(
            localCatalog(id), startIndex: 0, limit: 20)
        try await composition.load(local) { _ in page }
        let partial = await composition.snapshots()
        XCTAssertEqual(partial.map(\.source), [remote, local])
        XCTAssertEqual(partial.map(\.state), [.loading, .ready])
        XCTAssertEqual(partial[1].items.count, 1)
        await gate.finish()
        try await remoteTask.value
        let finished = await composition.snapshots()
        XCTAssertEqual(finished.map(\.state), [.ready, .ready])
    }

    func testLocalCannotEnterServerRouteOrClaimPlaybackAndForeignSourceFails() async throws {
        let id = UUID()
        let local = FoundationCatalogSource.local(sourceID: id)
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: local)
        let item = try XCTUnwrap(
            FoundationCatalogComposition.localPage(localCatalog(id), startIndex: 0, limit: 1).page
                .items.first)
        let localRoute = try await composition.route(for: item, requiring: .catalogPresence)
        XCTAssertEqual(localRoute, .local(try item.catalogKey()))
        do {
            _ = try await composition.route(for: item, requiring: .playback)
            XCTFail("Local Play must remain absent without resource lease routing")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        do {
            _ = try await composition.route(for: track(source: server("b")), requiring: .favorites)
            XCTFail("Foreign server source must never fall back to the current account")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        let legacy = track()
        let routed = try await composition.route(for: legacy, requiring: .playback)
        XCTAssertEqual(routed, .jellyfin(try legacy.catalogKey(legacyJellyfinSource: remote)))
        do {
            try await composition.load(remote) { _ in
                .init(page: .init(items: [item], nextStartIndex: nil))
            }
            XCTFail("Local page dispatched as server results")
        } catch FoundationCatalogComposition.Failure.invalidSource {}
    }

    func testPaginationIsBoundedAndRejectsDuplicateIdentityWithoutLosingPriorPage() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let first = track("one")
        try await composition.load(remote) { cursor in
            XCTAssertEqual(cursor, 0)
            return .init(page: .init(items: [first], nextStartIndex: 1))
        }
        do {
            try await composition.load(remote) { cursor in
                XCTAssertEqual(cursor, 1)
                return .init(page: .init(items: [first], nextStartIndex: 1))
            }
            XCTFail("Nonadvancing cursor accepted")
        } catch FoundationCatalogComposition.Failure.invalidPage {}
        do {
            try await composition.load(remote) { _ in
                .init(page: .init(items: [first], nextStartIndex: nil))
            }
            XCTFail("Duplicate identity accepted")
        } catch FoundationCatalogComposition.Failure.invalidPage {}
        let snapshots = await composition.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.items.map(\.id), ["one"])
        XCTAssertEqual(snapshot.nextStartIndex, 1)
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertThrowsError(
            try FoundationCatalogComposition.localPage(
                localCatalog(UUID()), startIndex: 0, limit: 201))
    }

    func testRetiredSourceCannotPublishLateResultAndDoesNotResetOtherSource() async throws {
        let remote = try server()
        let local = FoundationCatalogSource.local(sourceID: UUID())
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: local)
        let gate = HeldPage()
        let item = track()
        let pending = Task {
            try await composition.load(remote) { _ in
                await gate.hold()
                return .init(page: .init(items: [item], nextStartIndex: nil))
            }
        }
        await gate.waitUntilEntered()
        try await composition.reset(remote)
        await gate.finish()
        do {
            try await pending.value
            XCTFail("Retired request published")
        } catch FoundationCatalogComposition.Failure.stale {}
        let states = await composition.snapshots()
        XCTAssertEqual(states.map(\.state), [.idle, .idle])
        XCTAssertTrue(states.allSatisfy { $0.items.isEmpty })
    }

    func testUnavailableLocalKeepsHonestStateAndNeverExportsPaths() async throws {
        let id = UUID()
        let catalog = localCatalog(id, state: .unavailable)
        let page = try FoundationCatalogComposition.localPage(catalog, startIndex: 0, limit: 1)
        XCTAssertEqual(page.state, .unavailable)
        XCTAssertEqual(page.page.items.first?.catalogSource, .local(sourceID: id))
        let data = try JSONEncoder().encode(page.page)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-subfolder"))
        let composition = try FoundationCatalogComposition(
            jellyfin: server(), local: .local(sourceID: id))
        try await composition.load(.local(sourceID: id)) { _ in page }
        let snapshots = await composition.snapshots()
        XCTAssertEqual(snapshots.map(\.state), [.idle, .unavailable])
        XCTAssertEqual(snapshots[1].items.count, 1)
    }
}
