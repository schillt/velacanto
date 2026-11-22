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

    func testSearchSeedKeepsCursorAndReconcilesOnlyDeclaredSupplementalOverlap() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let direct = track("direct")
        let supplemental = track("supplemental")
        try await composition.seedSearch(
            remote, page: .init(items: [direct, supplemental], nextStartIndex: 50),
            supplementalIDs: [supplemental.id])
        var updated = supplemental
        updated.title = "Updated from provider"
        let updatedItem = updated
        let next = track("next")
        try await composition.load(remote) { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(page: .init(items: [updatedItem, next], nextStartIndex: 100))
        }
        let snapshots = await composition.snapshots()
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.items.map(\.id), ["direct", "supplemental", "next"])
        XCTAssertEqual(snapshot.items[1].title, "Updated from provider")
        XCTAssertEqual(snapshot.nextStartIndex, 100)
        do {
            try await composition.load(remote) { _ in
                .init(page: .init(items: [updatedItem], nextStartIndex: nil))
            }
            XCTFail("A second provider occurrence must be rejected")
        } catch FoundationCatalogComposition.Failure.invalidPage {
            // A supplemental overlap is consumed only once.
        }
    }

    func testSearchSeedRejectsForeignAndUndeclaredSupplementalIdentity() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        do {
            try await composition.seedSearch(
                remote, page: .init(items: [track("one")], nextStartIndex: nil),
                supplementalIDs: ["missing"])
            XCTFail("Seed supplemental identities must belong to the page")
        } catch FoundationCatalogComposition.Failure.invalidPage {}
        let foreign = track("foreign", source: try server("b"))
        do {
            try await composition.seedSearch(
                remote, page: .init(items: [foreign], nextStartIndex: nil), supplementalIDs: [])
            XCTFail("Seed must not cross account scope")
        } catch FoundationCatalogComposition.Failure.invalidSource {}
        try await composition.seedSearch(
            remote, page: .init(items: [track("one")], nextStartIndex: nil), supplementalIDs: [])
        do {
            try await composition.seedSearch(
                remote, page: .init(items: [track("two")], nextStartIndex: nil), supplementalIDs: []
            )
            XCTFail("A seed may only be admitted once")
        } catch FoundationCatalogComposition.Failure.unavailable {}
    }

    func testSearchSeedDoesNotPermitDuplicateRowsWithinProviderPage() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let supplemental = track("supplemental")
        try await composition.seedSearch(
            remote, page: .init(items: [supplemental], nextStartIndex: 50),
            supplementalIDs: [supplemental.id])
        do {
            try await composition.load(remote) { _ in
                .init(page: .init(items: [supplemental, supplemental], nextStartIndex: nil))
            }
            XCTFail("Duplicate rows in a provider page must remain invalid")
        } catch FoundationCatalogComposition.Failure.invalidPage {}
        let snapshots = await composition.snapshots()
        XCTAssertEqual(snapshots.first?.items.map(\.id), [supplemental.id])
        XCTAssertEqual(snapshots.first?.nextStartIndex, 50)
        XCTAssertEqual(snapshots.first?.state, .failed)
    }

    func testSearchFallbackContinuationOwnsItsCursorAndRetainsProviderRows() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let original = FoundationItem(
            id: "direct", title: "Garden", subtitle: "", kind: .track, duration: nil)
        try await composition.seedSearch(
            remote, page: .init(items: [original], nextStartIndex: 50), supplementalIDs: [],
            fallbackCursor: .init(term: "gar", nextStartIndex: 100))
        try await composition.load(remote) { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(page: .init(items: [], nextStartIndex: nil))
        }
        let beforeSnapshots = await composition.snapshots()
        let before = try XCTUnwrap(beforeSnapshots.first)
        XCTAssertNil(before.nextStartIndex)
        XCTAssertEqual(before.fallbackCursor?.nextStartIndex, 100)
        XCTAssertTrue(before.hasMore)
        try await composition.loadSearchFallback(remote, query: "Gardenx") { cursor in
            XCTAssertEqual(cursor, 100)
            let fuzzy = FoundationItem(
                id: "fuzzy", title: "Garden", subtitle: "", kind: .track, duration: nil)
            let unrelated = FoundationItem(
                id: "other", title: "Unrelated", subtitle: "", kind: .track, duration: nil)
            return .init(page: .init(items: [original, fuzzy, unrelated], nextStartIndex: nil))
        }
        let afterSnapshots = await composition.snapshots()
        let after = try XCTUnwrap(afterSnapshots.first)
        XCTAssertEqual(after.items.map(\.id), ["direct", "fuzzy"])
        XCTAssertFalse(after.hasMore)
        XCTAssertEqual(after.freshKeys.map(\.itemID), ["fuzzy"])
    }

    func testEmptySearchSeedCanContinueFallbackToFirstMatch() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        try await composition.seedSearch(
            remote, page: .init(items: [], nextStartIndex: nil), supplementalIDs: [],
            fallbackCursor: .init(term: "gar", nextStartIndex: 50))
        let initialSnapshots = await composition.snapshots()
        let initial = try XCTUnwrap(initialSnapshots.first)
        XCTAssertTrue(initial.items.isEmpty)
        XCTAssertTrue(initial.hasMore)
        try await composition.loadSearchFallback(remote, query: "Gardenx") { cursor in
            XCTAssertEqual(cursor, 50)
            let item = FoundationItem(
                id: "first", title: "Garden", subtitle: "", kind: .track, duration: nil)
            return .init(page: .init(items: [item], nextStartIndex: nil))
        }
        let finishedSnapshots = await composition.snapshots()
        let finished = try XCTUnwrap(finishedSnapshots.first)
        XCTAssertEqual(finished.items.map(\.id), ["first"])
        XCTAssertFalse(finished.hasMore)
    }

    func testFallbackFailureKeepsCursorForExplicitRetry() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        try await composition.seedSearch(
            remote, page: .init(items: [], nextStartIndex: nil), supplementalIDs: [],
            fallbackCursor: .init(term: "gar", nextStartIndex: 50))
        do {
            try await composition.loadSearchFallback(remote, query: "Gardenx") { _ in
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Expected provider failure")
        } catch is URLError {}
        let failedSnapshots = await composition.snapshots()
        let failed = try XCTUnwrap(failedSnapshots.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.fallbackCursor?.nextStartIndex, 50)
        try await composition.loadSearchFallback(remote, query: "Gardenx") { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(page: .init(items: [], nextStartIndex: nil))
        }
        let recoveredSnapshots = await composition.snapshots()
        let recovered = try XCTUnwrap(recoveredSnapshots.first)
        XCTAssertFalse(recovered.hasMore)
    }

    func testRetiredFallbackCannotPublishLatePage() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        try await composition.seedSearch(
            remote, page: .init(items: [], nextStartIndex: nil), supplementalIDs: [],
            fallbackCursor: .init(term: "gar", nextStartIndex: 50))
        let entered = expectation(description: "fallback page held")
        let gate = HeldPage(entered: entered)
        let pending = Task {
            do {
                try await composition.loadSearchFallback(remote, query: "Gardenx") { _ in
                    await gate.hold()
                    let item = FoundationItem(
                        id: "late", title: "Garden", subtitle: "", kind: .track, duration: nil)
                    return .init(page: .init(items: [item], nextStartIndex: nil))
                }
                await gate.record(.success(()))
            } catch {
                await gate.record(.failure(error))
            }
        }
        do {
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            guard entry == .completed, !Task.isCancelled else {
                XCTFail("Timed out or cancelled waiting for fallback entry")
                await cleanUpHeldPage(
                    task: pending, gate: gate, composition: composition, source: remote)
                return
            }
            try await composition.reset(remote)
            await gate.finish()
            guard
                await requireHeldPageCompletion(
                    gate, context: "retired fallback page completion", stopOnCancellation: true)
            else {
                await cleanUpHeldPage(
                    task: pending, gate: gate, composition: composition, source: remote)
                return
            }
            let outcome = await gate.outcome
            do {
                try XCTUnwrap(outcome).get()
                XCTFail("Retired fallback published")
            } catch FoundationCatalogComposition.Failure.stale {}
            let snapshots = await composition.snapshots()
            XCTAssertEqual(snapshots.first?.state, .idle)
            XCTAssertTrue(snapshots.first?.items.isEmpty == true)
        } catch {
            await cleanUpHeldPage(
                task: pending, gate: gate, composition: composition, source: remote)
            throw error
        }
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

    /// Owns held fake pages and records the actual load outcome after it returns.
    private actor HeldPage {
        private let entered: XCTestExpectation
        private var held: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var announced = false
        private(set) var outcome: Result<Void, Error>?
        var isHeld: Bool { !held.isEmpty }

        init(entered: XCTestExpectation) { self.entered = entered }

        func hold(announce: Bool = true) async {
            guard !released else { return }
            await withCheckedContinuation { continuation in
                held.append(continuation)
                if announce, !announced {
                    announced = true
                    entered.fulfill()
                }
            }
        }

        func finish() {
            released = true
            let pending = held
            held.removeAll()
            for continuation in pending { continuation.resume() }
        }

        func record(_ result: Result<Void, Error>) { outcome = result }
    }

    private func requireHeldPageCompletion(
        _ gate: HeldPage, context: String, stopOnCancellation: Bool = false
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await gate.outcome == nil {
            if stopOnCancellation, Task.isCancelled {
                XCTFail("Cancelled waiting for \(context)")
                return false
            }
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for \(context)")
                return false
            }
            await Task.yield()
        }
        if stopOnCancellation, Task.isCancelled {
            XCTFail("Cancelled waiting for \(context)")
            return false
        }
        return true
    }

    private func cleanUpHeldPage(
        task: Task<Void, Never>, gate: HeldPage,
        composition: FoundationCatalogComposition, source: FoundationCatalogSource
    ) async {
        task.cancel()
        try? await composition.reset(source)
        await gate.finish()
        _ = await requireHeldPageCompletion(gate, context: "held catalog page cleanup")
        let stillHeld = await gate.isHeld
        XCTAssertFalse(stillHeld, "Page cleanup must release every held entrant")
    }

    func testHeldServerDoesNotDelayLocalPublicationAndSourceOrderStaysStable() async throws {
        let remote = try server()
        let id = UUID()
        let local = FoundationCatalogSource.local(sourceID: id)
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: local)
        let entered = expectation(description: "composition remote page held")
        let gate = HeldPage(entered: entered)
        let remoteItem = track()
        let remoteTask = Task {
            do {
                try await composition.load(remote) { _ in
                    await gate.hold()
                    return .init(page: .init(items: [remoteItem], nextStartIndex: nil))
                }
                await gate.record(.success(()))
            } catch {
                await gate.record(.failure(error))
            }
        }
        do {
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            guard entry == .completed, !Task.isCancelled else {
                XCTFail("Timed out or cancelled waiting for composition page entry")
                await cleanUpHeldPage(
                    task: remoteTask, gate: gate, composition: composition, source: remote)
                return
            }
            let page = try FoundationCatalogComposition.localPage(
                localCatalog(id), startIndex: 0, limit: 20)
            try await composition.load(local) { _ in page }
            let partial = await composition.snapshots()
            XCTAssertEqual(partial.map(\.source), [remote, local])
            XCTAssertEqual(partial.map(\.state), [.loading, .ready])
            XCTAssertEqual(partial[1].items.count, 1)
            await gate.finish()
            guard
                await requireHeldPageCompletion(
                    gate, context: "composition remote page completion", stopOnCancellation: true)
            else {
                await cleanUpHeldPage(
                    task: remoteTask, gate: gate, composition: composition, source: remote)
                return
            }
            let outcome = await gate.outcome
            try XCTUnwrap(outcome).get()
            let stillHeld = await gate.isHeld
            XCTAssertFalse(stillHeld, "Completed composition must not retain a held page")
            let finished = await composition.snapshots()
            XCTAssertEqual(finished.map(\.state), [.ready, .ready])
        } catch {
            await cleanUpHeldPage(
                task: remoteTask, gate: gate, composition: composition, source: remote)
            throw error
        }
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
        let entered = expectation(description: "retired composition page held")
        let gate = HeldPage(entered: entered)
        let item = track()
        let pending = Task {
            do {
                try await composition.load(remote) { _ in
                    await gate.hold()
                    return .init(page: .init(items: [item], nextStartIndex: nil))
                }
                await gate.record(.success(()))
            } catch {
                await gate.record(.failure(error))
            }
        }
        do {
            let entry = await XCTWaiter.fulfillment(of: [entered], timeout: 5)
            guard entry == .completed, !Task.isCancelled else {
                XCTFail("Timed out or cancelled waiting for retired composition page entry")
                await cleanUpHeldPage(
                    task: pending, gate: gate, composition: composition, source: remote)
                return
            }
            try await composition.reset(remote)
            await gate.finish()
            guard
                await requireHeldPageCompletion(
                    gate, context: "retired composition page completion", stopOnCancellation: true)
            else {
                await cleanUpHeldPage(
                    task: pending, gate: gate, composition: composition, source: remote)
                return
            }
            let outcome = await gate.outcome
            do {
                try XCTUnwrap(outcome).get()
                XCTFail("Retired request published")
            } catch FoundationCatalogComposition.Failure.stale {}
            let stillHeld = await gate.isHeld
            XCTAssertFalse(stillHeld, "Retired composition must not retain a held page")
            let states = await composition.snapshots()
            XCTAssertEqual(states.map(\.state), [.idle, .idle])
            XCTAssertTrue(states.allSatisfy { $0.items.isEmpty })
        } catch {
            await cleanUpHeldPage(
                task: pending, gate: gate, composition: composition, source: remote)
            throw error
        }
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
    func testSeedOverflowIsExplicitAndCannotConsumeEitherProviderCursor() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let items = (0..<401).map { track("seed-\($0)") }
        try await composition.seedSearch(
            remote, page: .init(items: items, nextStartIndex: 50),
            supplementalIDs: Set(items.map(\.id)),
            fallbackCursor: .init(term: "gar", nextStartIndex: 100))
        let snapshots1 = await composition.snapshots()
        let initial = try XCTUnwrap(snapshots1.first)
        XCTAssertEqual(initial.items.count, 200)
        XCTAssertEqual(initial.seedOverflowCount, 201)
        do {
            try await composition.load(remote) { _ in
                XCTFail("Cannot skip retained rows")
                return .init(page: .init(items: [], nextStartIndex: nil))
            }
            XCTFail("Provider load bypassed overflow")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        for expected in [400, 401] {
            try await composition.loadSeedOverflow(remote)
            let snapshots2 = await composition.snapshots()
            let snapshot = try XCTUnwrap(snapshots2.first)
            XCTAssertEqual(snapshot.items.count, expected)
            XCTAssertEqual(snapshot.nextStartIndex, 50)
            XCTAssertEqual(snapshot.fallbackCursor?.nextStartIndex, 100)
            XCTAssertTrue(snapshot.freshKeys.isEmpty, "Retained rows are not a fresh provider read")
        }
        let snapshots3 = await composition.snapshots()
        let ready = try XCTUnwrap(snapshots3.first)
        XCTAssertEqual(ready.items.map(\.id), items.map(\.id))
        XCTAssertEqual(ready.seedOverflowCount, 0)
        XCTAssertTrue(ready.hasMore)
        try await composition.load(remote) { cursor in
            XCTAssertEqual(cursor, 50)
            return .init(page: .init(items: [], nextStartIndex: nil))
        }
        try await composition.loadSearchFallback(remote, query: "Garden") { cursor in
            XCTAssertEqual(cursor, 100)
            return .init(page: .init(items: [], nextStartIndex: nil))
        }
        let snapshots4 = await composition.snapshots()
        let finished = try XCTUnwrap(snapshots4.first)
        XCTAssertFalse(finished.hasMore)
    }

    func testSeedOverflowCancellationAndRetirementLeaveNoUnscopedRows() async throws {
        let remote = try server()
        let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
        let items = (0..<201).map { track("seed-\($0)") }
        try await composition.seedSearch(
            remote, page: .init(items: items, nextStartIndex: nil), supplementalIDs: [])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await composition.loadSeedOverflow(remote)
                XCTFail("Cancelled retained demand committed")
            } catch is CancellationError {} catch {
                XCTFail("Unexpected cancellation outcome: \(error)")
            }
        }
        await cancelled.value
        let snapshots5 = await composition.snapshots()
        let unchanged = try XCTUnwrap(snapshots5.first)
        XCTAssertEqual(unchanged.items.count, 200)
        XCTAssertEqual(unchanged.seedOverflowCount, 1)
        try await composition.reset(remote)
        do {
            try await composition.loadSeedOverflow(remote)
            XCTFail("Reset revived old overflow")
        } catch FoundationCatalogComposition.Failure.unavailable {}
        let snapshots6 = await composition.snapshots()
        let reset = try XCTUnwrap(snapshots6.first)
        XCTAssertTrue(reset.items.isEmpty)
        XCTAssertEqual(reset.seedOverflowCount, 0)
        await composition.retire(remote)
        do {
            try await composition.loadSeedOverflow(remote)
            XCTFail("Retired source revived overflow")
        } catch FoundationCatalogComposition.Failure.unavailable {}
    }

    func testSeedOverflowValidatesEntireMembershipBeforeAdmittingPrefix() async throws {
        let remote = try server()
        let items = (0..<201).map { track("seed-\($0)") }
        for invalid in [
            items + [items[0]], items + [track("foreign", source: try server("b"))],
            (0...FoundationCatalogComposition.itemLimit).map { track("row-\($0)") },
        ] {
            let composition = try FoundationCatalogComposition(jellyfin: remote, local: nil)
            do {
                try await composition.seedSearch(
                    remote, page: .init(items: invalid, nextStartIndex: nil), supplementalIDs: [])
                XCTFail("Invalid overflow admitted")
            } catch FoundationCatalogComposition.Failure.invalidPage {
            } catch FoundationCatalogComposition.Failure.invalidSource {}
            let snapshots7 = await composition.snapshots()
            let snapshot = try XCTUnwrap(snapshots7.first)
            XCTAssertEqual(snapshot.state, .idle)
            XCTAssertTrue(snapshot.items.isEmpty)
            XCTAssertEqual(snapshot.seedOverflowCount, 0)
        }
    }

}
