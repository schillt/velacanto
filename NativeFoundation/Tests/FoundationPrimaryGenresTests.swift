import Combine
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPrimaryGenresTests: XCTestCase {
    private func waitForDownloads(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "Verified download membership did not settle")
    }

    private func seededDownloads(
        root: URL, scope: String, track: FoundationItem
    ) async throws {
        let downloads = FoundationDownloads(
            scope: scope, library: PrimaryGenreDownloadLibrary(), root: root,
            transfer: { _, destination, _, progress in
                try Data("synthetic audio".utf8).write(to: destination)
                progress(15, 15)
            }, monitorConnectivity: false)
        downloads.updateConnectivity(isAllowed: true)
        downloads.download(track)
        try await waitForDownloads { downloads.isReady(track) }
        downloads.invalidate()
    }

    func testVerifiedInventoryAndReadyChangesDriveBoundOfflineGenresWithoutProgressRescans()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = FoundationItem(
            id: Self.id(100), title: "Synthetic", subtitle: "", kind: .track, duration: 1)
        try await seededDownloads(root: root, scope: "primary-ready", track: track)
        let inventory = PrimaryGenreGate()
        let transfer = PrimaryGenreGate()
        let downloads = FoundationDownloads(
            scope: "primary-ready", library: PrimaryGenreDownloadLibrary(), root: root,
            transfer: { _, destination, _, progress in
                progress(1, 15)
                await transfer.wait()
                try Data("synthetic audio".utf8).write(to: destination)
                progress(15, 15)
            }, monitorConnectivity: false,
            verifyInventoryFiles: { files, directory in
                if !files.isEmpty { await inventory.wait() }
                return try await FoundationDownloadStorage.verifiedFiles(
                    files, directory: directory)
            })
        defer { downloads.invalidate() }
        let library = try library()
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        model.bindDownloads(downloads)
        await inventory.started()
        XCTAssertTrue(downloads.isLoading)
        XCTAssertTrue(model.items(localOnly: true).isEmpty)
        XCTAssertEqual(downloads.verifiedReadyRevision, 0)
        await inventory.release()
        try await waitForDownloads { model.readySongIDs == [track.id] }
        XCTAssertEqual(model.items(localOnly: true).map(\.id), [Self.id(1), Self.id(2)])
        XCTAssertEqual(downloads.catalogRevision, 0, "Inventory is not a collection metadata edit")
        let readyRevision = downloads.verifiedReadyRevision
        XCTAssertEqual(readyRevision, 1)

        model.cancel()
        model.bind(library.scoped(to: Self.id(78)))
        XCTAssertEqual(model.readySongIDs, [track.id], "Library changes retain account ready IDs")
        model.bind(library)
        model.start()
        await model.buildCompletion?.value
        downloads.removeTrack(track)
        try await waitForDownloads { model.readySongIDs.isEmpty }
        XCTAssertTrue(model.items(localOnly: true).isEmpty)
        XCTAssertEqual(downloads.verifiedReadyRevision, readyRevision + 1)

        let next = FoundationItem(
            id: Self.id(101), title: "Synthetic next", subtitle: "", kind: .track, duration: 1)
        let beforeProgress = downloads.verifiedReadyRevision
        var readinessEvents = 0
        let observation = downloads.$verifiedReadyRevision.dropFirst().sink { _ in
            readinessEvents += 1
        }
        defer { observation.cancel() }
        downloads.updateConnectivity(isAllowed: true)
        downloads.download(next)
        await transfer.started()
        try await waitForDownloads { downloads.owners.first?.activeTrackProgress != nil }
        XCTAssertEqual(downloads.verifiedReadyRevision, beforeProgress)
        XCTAssertEqual(readinessEvents, 0, "Transfer progress must not trigger a membership scan")
        XCTAssertTrue(model.readySongIDs.isEmpty)
        await transfer.release()
        try await waitForDownloads { model.readySongIDs == [next.id] }
        XCTAssertEqual(readinessEvents, 1)
        XCTAssertEqual(model.items(localOnly: true).map(\.id), [Self.id(1), Self.id(2)])
    }

    func testHeldInventoryCannotPublishThroughReplacedRetiredOrCrossAccountBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = FoundationItem(
            id: Self.id(100), title: "Synthetic", subtitle: "", kind: .track, duration: 1)
        for mode in 0..<3 {
            let scope = "primary-binding-\(mode)"
            try await seededDownloads(root: root, scope: scope, track: track)
            let inventory = PrimaryGenreGate()
            let old = FoundationDownloads(
                scope: scope, library: PrimaryGenreDownloadLibrary(), root: root,
                monitorConnectivity: false,
                verifyInventoryFiles: { files, directory in
                    if !files.isEmpty { await inventory.wait() }
                    return try await FoundationDownloadStorage.verifiedFiles(
                        files, directory: directory)
                })
            let replacement = FoundationDownloads(
                scope: scope + "-empty", library: PrimaryGenreDownloadLibrary(), root: root,
                monitorConnectivity: false)
            let model = FoundationPrimaryGenresModel(library: try library())
            model.bindDownloads(old)
            await inventory.started()
            switch mode {
            case 0: model.bindDownloads(replacement)
            case 1: model.retire()
            default:
                model.bind(
                    FoundationJellyfinLibrary(
                        session: .init(
                            serverURL: Self.session.serverURL, accessToken: "synthetic-token",
                            userID: Self.id(98), deviceID: "synthetic-device")))
            }
            await inventory.release()
            try await waitForDownloads { !old.isLoading }
            // Join a fresh MainActor turn after the old producer's publication task.
            await Task.yield()
            XCTAssertTrue(old.isReady(track))
            XCTAssertTrue(model.readySongIDs.isEmpty, "Departed binding resurrected downloaded IDs")
            old.invalidate()
            replacement.invalidate()
        }
    }

    private static func id(_ number: Int) -> String { String(format: "%032x", number) }
    private static let session = FoundationSession(
        serverURL: URL(string: "https://example.invalid/base/")!, accessToken: "synthetic-token",
        userID: id(99), deviceID: "synthetic-device")

    func testRecentGenresUseOnlyLoadedSongPrimaryMembershipAndTrustedArtwork() async throws {
        let library = try library()
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(
            model.completedRecord(libraryScope: library.primaryGenreIndexScope))
        var first = FoundationItem(
            id: Self.id(102), title: "Recent song", subtitle: "", kind: .track, duration: 1,
            album: .init(id: "trusted-album", title: "Loaded album"),
            genres: [.init(id: Self.id(3), title: "Raw rare tag")])
        first.catalogSource = record.snapshot.scope.source
        let second = FoundationItem(
            id: Self.id(101), title: "Standalone", subtitle: "", kind: .track, duration: 1)
        var foreign = second
        foreign.catalogSource = .local(sourceID: UUID())
        let unknown = FoundationItem(
            id: "not-in-census", title: "Unknown", subtitle: "", kind: .track, duration: 1,
            genres: [.init(id: Self.id(3), title: "Raw rare tag")])
        let rawAlbum = FoundationItem(
            id: Self.id(100), title: "Album is not a song", subtitle: "", kind: .album,
            duration: nil, genres: [.init(id: Self.id(3), title: "Raw rare tag")])
        let entries = record.recentGenres(songs: [foreign, unknown, rawAlbum, first, second])
        XCTAssertEqual(entries.map(\.genre.id), [Self.id(1), Self.id(2)])
        XCTAssertEqual(entries.map(\.artwork.id), ["trusted-album", second.id])
        XCTAssertTrue(
            entries.allSatisfy { $0.genre.primaryGenreCensusID == record.snapshot.censusID })
        XCTAssertEqual(first.genres.map(\.id), [Self.id(3)], "Raw provider tags remain intact")
        XCTAssertEqual(
            record.recentGenres(songs: [first, second], readySongIDs: [first.id]).map(\.genre.id),
            [Self.id(1)], "Offline New must not reclassify tags using local popularity")
        XCTAssertEqual(record.recentGenres(songs: [first, second], limit: 1).count, 1)
        XCTAssertTrue(record.recentGenres(songs: [unknown, rawAlbum]).isEmpty)
        XCTAssertNil(
            model.completedRecord(
                libraryScope: library.scoped(to: Self.id(78)).primaryGenreIndexScope))
    }

    func testHistoricalGenrePinResolvesCurrentScopedDescriptorAndRetainsWhitelistHistory()
        async throws
    {
        let library = try library()
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let original = try XCTUnwrap(model.items(localOnly: false).first)
        var storage: [String: Data] = [:]
        let make = {
            FoundationLibraryActions(
                sourceScope: "primary-pins", read: { storage[$0] }, write: { storage[$0] = $1 },
                mutateFavorite: { _, _ in XCTFail("Pin resolution must not mutate the provider") })
        }
        make().togglePin(original)
        let saved = try XCTUnwrap(make().pins.first)
        XCTAssertNil(saved.catalogSource)
        XCTAssertNil(saved.primaryGenreCensusID, "Stored pins must keep their existing whitelist")
        let history = storage
        XCTAssertEqual(
            model.resolvePinnedGenre(saved, libraryScope: library.primaryGenreIndexScope), original)
        let rare = FoundationItem(
            id: Self.id(3), title: "Raw rare tag", subtitle: "", kind: .genre, duration: nil)
        XCTAssertNil(model.resolvePinnedGenre(rare, libraryScope: library.primaryGenreIndexScope))
        var foreign = saved
        foreign.catalogSource = .local(sourceID: UUID())
        XCTAssertNil(
            model.resolvePinnedGenre(foreign, libraryScope: library.primaryGenreIndexScope))
        XCTAssertNil(
            model.resolvePinnedGenre(
                saved, libraryScope: library.scoped(to: Self.id(78)).primaryGenreIndexScope))
        model.start()
        await model.buildCompletion?.value
        let refreshed = try XCTUnwrap(
            model.resolvePinnedGenre(saved, libraryScope: library.primaryGenreIndexScope))
        XCTAssertNotEqual(refreshed.primaryGenreCensusID, original.primaryGenreCensusID)
        XCTAssertNil(
            model.canonicalRecord(for: original, libraryScope: library.primaryGenreIndexScope))
        model.retire()
        XCTAssertNil(model.resolvePinnedGenre(saved, libraryScope: library.primaryGenreIndexScope))
        XCTAssertEqual(storage, history)
        XCTAssertEqual(make().pins, [saved], "Unavailable genres keep their historical saved pins")
    }

    func testHomeProminenceCapKeepsSixGenreEligibilityAndUsesScopedCensusCountsOffline()
        async throws
    {
        let sets = [[6], [1], [5], [2], [4], [3], [6], [5]]
        let body = try Self.body(start: 0, sets: sets, total: sets.count)
        let library = FoundationJellyfinLibrary(session: Self.session) { request in
            (
                body,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(
            model.completedRecord(libraryScope: library.primaryGenreIndexScope))
        XCTAssertEqual(record.snapshot.eligibleGenreIDs.count, 6)
        XCTAssertEqual(record.prominentGenres().map(\.id), [5, 6, 1, 2, 3].map(Self.id))
        XCTAssertEqual(
            record.matchingItems().count, 6, "The Home cap must not change Library or Search")
        XCTAssertEqual(
            record.prominentGenres(eligibleIDs: Set([2, 4, 6].map(Self.id))).map(\.id),
            [6, 2, 4].map(Self.id),
            "Offline presentation uses server census counts, not local recounts")
        XCTAssertEqual(record.snapshot.primaryBySongID[Self.id(100)], [Self.id(6)])
        XCTAssertEqual(record.prominentGenres(limit: 0).count, 0)
    }

    private static func body(start: Int, sets: [[Int]], total: Int) throws -> Data {
        let items: [[String: Any]] = sets.enumerated().map { offset, genres in
            [
                "Id": id(100 + start + offset), "Type": "Audio",
                "Genres": genres.map { "Genre \($0)" },
                "GenreItems": genres.map { ["Id": id($0), "Name": "Genre \($0)"] },
            ]
        }
        return try JSONSerialization.data(withJSONObject: [
            "Items": items, "StartIndex": start, "TotalRecordCount": total,
        ])
    }

    private func library(
        recorder: PrimaryGenreRequests = PrimaryGenreRequests(),
        cache: FoundationCatalogPageCache? = nil,
        failSecond: Bool = false
    ) throws -> FoundationJellyfinLibrary {
        let first = try Self.body(start: 0, sets: [[1, 2, 3], [1, 2]], total: 4)
        let second = try Self.body(start: 2, sets: [[1], []], total: 4)
        return FoundationJellyfinLibrary(
            session: Self.session,
            load: { request in
                await recorder.append(request)
                let query =
                    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems
                    ?? []
                let searching = query.contains { $0.name == "searchTerm" }
                let offset = query.first { $0.name == "startIndex" }?.value ?? "0"
                if failSecond, offset == "2" { throw URLError(.timedOut) }
                let data =
                    searching
                    ? Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8)
                    : offset == "0" ? first : second
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200,
                        httpVersion: nil, headerFields: nil)!
                )
            }, catalogPageCache: cache
        ).scoped(to: Self.id(77))
    }

    func testExplicitProductionBuildReadsOnlyScopedSongMetadataAndPublishesPerSongUnion()
        async throws
    {
        let recorder = PrimaryGenreRequests()
        let library = try library(recorder: recorder)
        let model = FoundationPrimaryGenresModel(library: library)
        await model.configure(library)
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0, "Cold configuration must not scan the catalog")
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        XCTAssertEqual(record.snapshot.songCount, 4)
        XCTAssertEqual(record.snapshot.eligibleGenreIDs, [Self.id(1), Self.id(2)])
        XCTAssertEqual(model.items(localOnly: false).map(\.id), [Self.id(1), Self.id(2)])
        XCTAssertNil(model.errorMessage)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.url?.path, "/base/Items")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            XCTAssertEqual(value("parentId"), Self.id(77))
            XCTAssertEqual(value("userId"), Self.session.userID)
            XCTAssertEqual(value("includeItemTypes"), "Audio")
            XCTAssertEqual(value("fields"), "Genres")
            XCTAssertEqual(value("enableImages"), "false")
            XCTAssertEqual(value("enableUserData"), "false")
            XCTAssertEqual(value("limit"), "200")
            XCTAssertEqual(
                query.filter { $0.name == "sortBy" }.compactMap(\.value), ["SortName", "Name"])
        }
        model.updateDownloads([
            .init(id: Self.id(100), title: "", subtitle: "", kind: .track, duration: nil),
            .init(id: "unindexed", title: "", subtitle: "", kind: .track, duration: nil),
        ])
        XCTAssertEqual(model.items(localOnly: true).map(\.id), [Self.id(1), Self.id(2)])
        XCTAssertNotNil(model.offlineErrorMessage)
        XCTAssertEqual(
            model.primaryGenreTitles(
                for:
                    .init(id: Self.id(100), title: "", subtitle: "", kind: .track, duration: nil)),
            ["Genre 1", "Genre 2"])
        XCTAssertTrue(model.page(query: "Genre 3", localOnly: false).items.isEmpty)
    }

    func testOmittedGenreFieldsFailWhileExplicitEmptyArraysAreValid() async throws {
        let data = Data(
            "{\"Items\":[{\"Id\":\"\(Self.id(100))\",\"Type\":\"Audio\"}],\"StartIndex\":0,\"TotalRecordCount\":1}"
                .utf8)
        let library = FoundationJellyfinLibrary(session: Self.session) { request in
            (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await library.primaryGenreMetadataPage(startIndex: 0)
            XCTFail("Missing fields were interpreted as untagged")
        } catch { XCTAssertEqual(error as? FoundationPrimaryGenreIndex.Failure, .unknownMetadata) }
    }

    func testCompletedCacheRestoresWithoutNetworkAndFailedRefreshKeepsPreviousResult() async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-fixture", root: root)
        let recorder = PrimaryGenreRequests()
        let good = try library(recorder: recorder, cache: cache)
        let model = FoundationPrimaryGenresModel(library: good)
        model.start()
        await model.buildCompletion?.value
        let accepted = try XCTUnwrap(model.record)
        let savedReads = await recorder.requests.count
        let failing = try library(recorder: recorder, cache: cache, failSecond: true)
        let restored = FoundationPrimaryGenresModel(library: failing)
        await restored.configure(failing)
        let restoredReads = await recorder.requests.count
        XCTAssertEqual(restoredReads, savedReads)
        XCTAssertEqual(restored.record, accepted)
        restored.start()
        await restored.buildCompletion?.value
        XCTAssertEqual(restored.record, accepted)
        XCTAssertNotNil(restored.errorMessage)
    }

    func testScopeChangeAndCancellationRejectLateProductionResponse() async throws {
        let gate = PrimaryGenreGate()
        let data = try Self.body(start: 0, sets: [[1]], total: 1)
        let library = FoundationJellyfinLibrary(session: Self.session) { request in
            await gate.wait()
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        let pending = model.buildCompletion
        await gate.started()
        model.bind(library.scoped(to: Self.id(77)))
        await gate.release()
        await pending?.value
        XCTAssertNil(model.record)
        XCTAssertFalse(model.isBuilding)
        XCTAssertTrue(model.items(localOnly: false).isEmpty)
    }

    func testTypedGenreResolverUsesCanonicalMapWithoutRemoteGenreQuery() async throws {
        let recorder = PrimaryGenreRequests()
        let library = try library(recorder: recorder)
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        let resolver = FoundationSearchResolver(
            library: library,
            genreSearch: { query, _, limit in
                record.page(query: query, limit: limit)
            })
        let result = try await resolver.resolve(query: "Genre 1")
        XCTAssertEqual(
            result.direct.first { $0.kind == .genre }?.page.items.map(\.id), [Self.id(1)])
        let requests = await recorder.requests
        XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("MusicGenres") == true })
    }

    func testPrimaryCachePreservesPriorRecordOnRejectedWriteAndRetiresWithAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-cache", root: root)
        let library = try library()
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        try await cache.writePrimaryGenres(record, key: "primary-v1", permit: .init())
        let invalid = FoundationPrimaryGenreRecord(snapshot: record.snapshot, descriptors: [])
        do {
            try await cache.writePrimaryGenres(invalid, key: "primary-v1", permit: .init())
            XCTFail("Invalid codec payload replaced a valid record")
        } catch {}
        let retained = try await cache.readPrimaryGenres(
            key: "primary-v1", scope: record.snapshot.scope)
        XCTAssertEqual(retained, record)
        let revoked = FoundationPageWritePermit()
        revoked.revoke()
        do {
            try await cache.writePrimaryGenres(record, key: "primary-v1", permit: revoked)
            XCTFail("Revoked writer published")
        } catch {}
        let removed = await cache.invalidate()
        XCTAssertTrue(removed)
        do {
            try await cache.writePrimaryGenres(record, key: "primary-v1", permit: .init())
            XCTFail("Retired writer recreated account cache")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(cache.scope).path))
    }
    func testCorruptCacheIsReportedAndPrimaryTrimmingPreservesOrdinaryPages() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-corrupt", root: root)
        let model = FoundationPrimaryGenresModel(library: try library())
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        await cache.write(.init(items: [], nextStartIndex: nil), key: "ordinary")
        for key in ["one", "two", "three"] {
            try await cache.writePrimaryGenres(record, key: key, permit: .init())
        }
        let directory = root.appendingPathComponent(cache.scope)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(urls.filter { $0.pathExtension == "primarygenres" }.count, 2)
        XCTAssertEqual(urls.filter { $0.pathExtension == "page" }.count, 1)
        XCTAssertFalse(urls.contains { $0.pathExtension == "primarytmp" })
        let expectedBytes = try urls.reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        let measuredBytes = await cache.storageBytes()
        XCTAssertEqual(measuredBytes, expectedBytes)
        let corrupted = directory.appendingPathComponent(
            FoundationArtworkCache.digest("three") + ".primarygenres")
        try Data([0, 1, 2]).write(to: corrupted)
        do {
            _ = try await cache.readPrimaryGenres(key: "three", scope: record.snapshot.scope)
            XCTFail("Corruption was treated as an empty successful index")
        } catch {}
    }

    func testCacheSaveFailureKeepsCompleteRuntimeResultAndReportsFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-save-failure", root: root)
        let library = try library(cache: cache)
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        XCTAssertNotNil(model.record)
        XCTAssertEqual(
            model.errorMessage, "Primary genres are ready, but this index could not be saved.")
        XCTAssertFalse(model.items(localOnly: false).isEmpty)
    }

    func testMetadataPageBudgetRejectsRequest1001BeforeTransport() async throws {
        let recorder = PrimaryGenreRequests()
        let library = FoundationJellyfinLibrary(session: Self.session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            let offset = Int(query.first { $0.name == "startIndex" }!.value!)!
            let id = String(format: "%032x", offset + 100)
            let data = Data(
                "{\"Items\":[{\"Id\":\"\(id)\",\"Type\":\"Audio\",\"Genres\":[\"Genre\"],\"GenreItems\":[{\"Id\":\"00000000000000000000000000000001\",\"Name\":\"Genre\"}]}],\"StartIndex\":\(offset),\"TotalRecordCount\":1001}"
                    .utf8)
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1000)
        XCTAssertNil(model.record)
        XCTAssertTrue(model.errorMessage?.contains("indexing limits") == true)
    }

    func testCrashStagingIsAccountedRecoveredAndUnknownPathsArePreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-staging", root: root)
        let model = FoundationPrimaryGenresModel(library: try library())
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        try await cache.writePrimaryGenres(record, key: "primary", permit: .init())
        let measuredBaseline = await cache.storageBytes()
        let baseline = try XCTUnwrap(measuredBaseline)
        let directory = root.appendingPathComponent(cache.scope)
        let staging = directory.appendingPathComponent(UUID().uuidString + ".primarytmp")
        try Data(repeating: 1, count: 1024).write(to: staging)
        let withStaging = await cache.storageBytes()
        XCTAssertEqual(withStaging, baseline + 1024)
        let restored = try await cache.readPrimaryGenres(
            key: "primary", scope: record.snapshot.scope)
        XCTAssertEqual(restored, record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        let unknown = directory.appendingPathComponent("unknown.primarytmp")
        try Data([1]).write(to: unknown)
        do {
            _ = try await cache.readPrimaryGenres(key: "primary", scope: record.snapshot.scope)
            XCTFail("Unknown staging name was silently accepted or removed")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        try FileManager.default.removeItem(at: unknown)
        let afterRecovery = try await cache.readPrimaryGenres(
            key: "primary", scope: record.snapshot.scope)
        XCTAssertEqual(afterRecovery, record)
    }

    func testCanonicalGenreRoutesRejectStaleMarkerCrossScopeAndRefreshSameGenre() async throws {
        let library = try library()
        let model = FoundationPrimaryGenresModel(library: library)
        model.start()
        await model.buildCompletion?.value
        let original = try XCTUnwrap(model.record?.descriptors.first)
        XCTAssertNotNil(
            model.canonicalRecord(for: original, libraryScope: library.primaryGenreIndexScope))
        var relabeled = original
        relabeled.title = "Unrecognized descriptor"
        XCTAssertNil(
            model.canonicalRecord(for: relabeled, libraryScope: library.primaryGenreIndexScope))
        var foreign = original
        foreign.catalogSource = .local(sourceID: UUID())
        XCTAssertNil(
            model.canonicalRecord(for: foreign, libraryScope: library.primaryGenreIndexScope))
        XCTAssertNil(
            model.canonicalRecord(
                for: original,
                libraryScope: library.scoped(to: Self.id(78)).primaryGenreIndexScope))
        model.start()
        await model.buildCompletion?.value
        let updated = try XCTUnwrap(model.record?.descriptors.first { $0.id == original.id })
        XCTAssertNotEqual(updated.primaryGenreCensusID, original.primaryGenreCensusID)
        XCTAssertNil(
            model.canonicalRecord(for: original, libraryScope: library.primaryGenreIndexScope))
        XCTAssertNotNil(
            model.canonicalRecord(for: updated, libraryScope: library.primaryGenreIndexScope))
        let encoded = try JSONEncoder().encode(updated)
        XCTAssertEqual(try JSONDecoder().decode(FoundationItem.self, from: encoded), updated)
        let legacy = FoundationItem(
            id: "legacy", title: "", subtitle: "", kind: .genre, duration: nil)
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNil(
            try JSONDecoder().decode(FoundationItem.self, from: legacyData).primaryGenreCensusID)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        XCTAssertNil(object["primaryGenreCensusID"])
    }

    func testCanonicalDestinationUsesOrderedSongMembershipOnlineAndColdDownloadedProjection()
        async throws
    {
        let model = FoundationPrimaryGenresModel(library: try library())
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        let membership = record.songIDs(for: Self.id(1))
        XCTAssertEqual(membership, [Self.id(100), Self.id(101), Self.id(102)])
        let recorder = PrimaryGenreRequests()
        let resolver = FoundationJellyfinLibrary(session: Self.session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            let ids = query.filter { $0.name == "ids" }.compactMap(\.value)
            let items: [[String: Any]] = ids.reversed().map {
                ["Id": $0, "Name": "Song " + String($0.suffix(2)), "Type": "Audio"]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": items, "StartIndex": 0, "TotalRecordCount": ids.count,
            ])
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        let page = try await record.songPage(genreID: Self.id(1), startIndex: 0, library: resolver)
        XCTAssertEqual(
            page.items.map(\.id), membership,
            "Provider response order must not replace census order")
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!
            .queryItems!
        XCTAssertEqual(query.filter { $0.name == "ids" }.compactMap(\.value), membership)
        XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Audio")
        XCTAssertNil(query.first { $0.name == "genreIds" })
        XCTAssertEqual(query.first { $0.name == "parentId" }?.value, Self.id(77))
        var foreign = FoundationItem(
            id: Self.id(101), title: "", subtitle: "", kind: .track, duration: nil)
        foreign.catalogSource = .local(sourceID: UUID())
        let downloaded = [
            FoundationItem(id: Self.id(102), title: "", subtitle: "", kind: .track, duration: nil),
            FoundationItem(id: Self.id(100), title: "", subtitle: "", kind: .track, duration: nil),
            foreign,
        ]
        XCTAssertEqual(
            record.readySongs(membershipIDs: membership, from: downloaded).map(\.id),
            [Self.id(100), Self.id(102)],
            "Cold downloads need no album genre tags or previous remote page")
        do {
            _ = try await record.songPage(
                genreID: Self.id(1), startIndex: 0,
                library: resolver.scoped(to: Self.id(78)))
            XCTFail("Canonical destination crossed selected-library scope")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let stale = FoundationJellyfinLibrary(session: Self.session) { request in
            (
                Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        do {
            _ = try await record.songPage(genreID: Self.id(1), startIndex: 0, library: stale)
            XCTFail("Missing canonical IDs were presented as a successful empty genre")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
    }

    func testAccountOwnerSharesOneBuildAndFreshSnapshotAcrossTwoWindowsAndRetiresBoth() async throws
    {
        let recorder = PrimaryGenreRequests()
        let library = try library(recorder: recorder)
        let owner = FoundationAppModel(prepareCaches: { true }, restoreAccount: { _ in })
        owner.configurePrimaryGenres(library)
        let shared = try XCTUnwrap(owner.primaryGenres)
        let player = FoundationPlayer(library: library)
        let first = FoundationLibraryView(
            library: library, player: player, primaryGenres: shared, signOut: {})
        let second = FoundationLibraryView(
            library: library, player: player, primaryGenres: shared, signOut: {})
        XCTAssertTrue(first.primaryGenres === second.primaryGenres)
        first.primaryGenres.start()
        second.primaryGenres.start()
        await shared.buildCompletion?.value
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2, "Two windows must share the same two-page build")
        XCTAssertNotNil(second.primaryGenres.record)
        XCTAssertEqual(first.primaryGenres.record, second.primaryGenres.record)
        owner.configurePrimaryGenres(library.scoped(to: Self.id(78)))
        XCTAssertTrue(owner.primaryGenres === shared)
        XCTAssertNil(first.primaryGenres.record)
        XCTAssertNil(second.primaryGenres.record)
        let gate = PrimaryGenreGate()
        let incoming = try Self.body(start: 0, sets: [[1]], total: 1)
        let held = FoundationJellyfinLibrary(session: Self.session) { request in
            await gate.wait()
            return (
                incoming,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(78))
        owner.configurePrimaryGenres(held)
        shared.start()
        let pending = shared.buildCompletion
        await gate.started()
        owner.retirePrimaryGenres()
        await gate.release()
        await pending?.value
        XCTAssertNil(owner.primaryGenres)
        XCTAssertFalse(shared.isSupported)
        XCTAssertNil(first.primaryGenres.record)
        XCTAssertNil(second.primaryGenres.record)
    }

    func testPrimaryCacheRejectsUnknownSchemaAndDuplicateOrderedMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-schema", root: root)
        let model = FoundationPrimaryGenresModel(library: try library())
        model.start()
        await model.buildCompletion?.value
        let record = try XCTUnwrap(model.record)
        try await cache.writePrimaryGenres(record, key: "primary", permit: .init())
        let good = try PropertyListEncoder().encode(record)
        let original = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: good, options: [], format: nil) as? [String: Any])
        let file = root.appendingPathComponent(cache.scope).appendingPathComponent(
            FoundationArtworkCache.digest("primary") + ".primarygenres")
        for duplicateOrder in [false, true] {
            var malformed = original
            var snapshot = try XCTUnwrap(malformed["snapshot"] as? [String: Any])
            if duplicateOrder {
                var ids = record.snapshot.orderedSongIDs
                ids[1] = ids[0]
                snapshot["orderedSongIDs"] = ids
            } else {
                var scope = try XCTUnwrap(snapshot["scope"] as? [String: Any])
                scope["policyVersion"] = 1
                snapshot["scope"] = scope
            }
            malformed["snapshot"] = snapshot
            let data = try PropertyListSerialization.data(
                fromPropertyList: malformed, format: .binary, options: 0)
            try data.write(to: file, options: .atomic)
            do {
                _ = try await cache.readPrimaryGenres(key: "primary", scope: record.snapshot.scope)
                XCTFail("Unsupported or inconsistent ordered index was accepted")
            } catch {}
        }
    }

    func testPrimaryTrimFailurePreservesPriorSameScopeRecordAndUnknownFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "primary-trim-failure", root: root)
        let model = FoundationPrimaryGenresModel(library: try library())
        model.start()
        await model.buildCompletion?.value
        let prior = try XCTUnwrap(model.record)
        try await cache.writePrimaryGenres(prior, key: "primary", permit: .init())
        model.start()
        await model.buildCompletion?.value
        let replacement = try XCTUnwrap(model.record)
        XCTAssertNotEqual(prior.snapshot.censusID, replacement.snapshot.censusID)
        let unknown = root.appendingPathComponent(cache.scope).appendingPathComponent(
            "unknown.primarygenres")
        try Data([1]).write(to: unknown)
        do {
            try await cache.writePrimaryGenres(replacement, key: "primary", permit: .init())
            XCTFail("Unknown cache path was silently trimmed")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
        let retained = try await cache.readPrimaryGenres(
            key: "primary", scope: prior.snapshot.scope)
        XCTAssertEqual(retained, prior)
    }

}

private struct PrimaryGenreDownloadLibrary: FoundationLibrary {
    func albums(startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
        .init(items: [], nextStartIndex: nil)
    }
    func playbackURL(for item: FoundationItem) async throws -> URL {
        URL(string: "https://example.invalid/synthetic")!
    }
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        .init(
            request: URLRequest(url: URL(string: "https://example.invalid/synthetic")!),
            fileExtension: "mp3", expectedBytes: nil)
    }
}

private actor PrimaryGenreRequests {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

private actor PrimaryGenreGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var didStart = false
    func wait() async {
        didStart = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func started() async {
        if didStart { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
