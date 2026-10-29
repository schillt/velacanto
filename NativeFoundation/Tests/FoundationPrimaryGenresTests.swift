import Combine
import Foundation
import SwiftUI
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
        failSecond: Bool = false, gate: PrimaryGenreGate? = nil
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
                if offset == "0", let gate { await gate.wait() }
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
            XCTAssertEqual(
                Set(
                    query.filter { $0.name == "fields" }.compactMap(\.value)
                        .flatMap { $0.split(separator: ",").map(String.init) }),
                Set(["Genres", "DateCreated"]))
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

    func testAutomaticPreparationWaitsForOnlineAndPersistsOneSuccessfulAppVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "automatic-primary", root: root)
        let requests = PrimaryGenreRequests()
        let library = try library(recorder: requests, cache: cache)
        let first = FoundationPrimaryGenresModel(library: library, appVersion: "0.6.0(247)")
        await first.prepareAutomaticallyIfNeeded(allowsNetwork: false)
        XCTAssertFalse(first.isBuilding)
        let offlineReads = await requests.requests.count
        XCTAssertEqual(offlineReads, 0)
        async let one: Void = first.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        async let two: Void = first.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        _ = await (one, two)
        await first.buildCompletion?.value
        XCTAssertEqual(first.record?.builtWithAppVersion, "0.6.0(247)")
        let afterFirst = await requests.requests.count
        XCTAssertEqual(afterFirst, 2, "Concurrent app/connectivity boundaries share one census")
        let nextLaunch = FoundationPrimaryGenresModel(library: library, appVersion: "0.6.0(247)")
        await nextLaunch.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        XCTAssertFalse(nextLaunch.isBuilding)
        XCTAssertEqual(nextLaunch.record, first.record)
        let afterRelaunch = await requests.requests.count
        XCTAssertEqual(
            afterRelaunch, afterFirst, "A persisted successful marker suppresses duplicate work")
    }

    func testAppUpdatePublishesPreviousGenresWhileBuildingReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "automatic-update", root: root)
        let firstLibrary = try library(cache: cache)
        let first = FoundationPrimaryGenresModel(library: firstLibrary, appVersion: "0.6.0(246)")
        await first.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await first.buildCompletion?.value
        let previous = try XCTUnwrap(first.record)
        let gate = PrimaryGenreGate()
        let updatedLibrary = try library(cache: cache, gate: gate)
        let updated = FoundationPrimaryGenresModel(
            library: updatedLibrary, appVersion: "0.6.0(247)")
        await updated.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await gate.started()
        XCTAssertTrue(updated.isBuilding)
        XCTAssertEqual(updated.record, previous)
        await gate.release()
        await updated.buildCompletion?.value
        XCTAssertEqual(updated.record?.builtWithAppVersion, "0.6.0(247)")
        XCTAssertNotEqual(updated.record?.snapshot.censusID, previous.snapshot.censusID)
    }

    func testFailedAutomaticBuildDoesNotMarkVersionOrLoopAndManualRebuildCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "automatic-failure", root: root)
        let requests = PrimaryGenreRequests()
        let good = try library(recorder: requests, cache: cache)
        let previous = FoundationPrimaryGenresModel(library: good, appVersion: "0.6.0(246)")
        await previous.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await previous.buildCompletion?.value
        let accepted = try XCTUnwrap(previous.record)
        let failing = try library(recorder: requests, cache: cache, failSecond: true)
        let updated = FoundationPrimaryGenresModel(library: failing, appVersion: "0.6.0(247)")
        await updated.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await updated.buildCompletion?.value
        XCTAssertEqual(updated.record, accepted)
        XCTAssertNotNil(updated.errorMessage)
        let failedReads = await requests.requests.count
        await updated.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await updated.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        let repeatedReads = await requests.requests.count
        XCTAssertEqual(
            repeatedReads, failedReads,
            "Foreground/appearance changes cannot endlessly retry failure")
        updated.bind(good)
        updated.start()
        await updated.buildCompletion?.value
        XCTAssertEqual(updated.record?.builtWithAppVersion, "0.6.0(247)")
    }

    func testOfflineSuspensionRejectsLateAutomaticResultAndResumesAfterOnlineReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "automatic-suspend", root: root)
        let gate = PrimaryGenreGate()
        let held = try library(cache: cache, gate: gate)
        let model = FoundationPrimaryGenresModel(library: held, appVersion: "0.6.0(247)")
        await model.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await gate.started()
        let old = model.buildCompletion
        model.suspendForOffline()
        await model.prepareAutomaticallyIfNeeded(allowsNetwork: false)
        XCTAssertFalse(model.isBuilding)
        await gate.release()
        await old?.value
        XCTAssertNil(model.record)
        let good = try library(cache: cache)
        model.bind(good)
        await model.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await model.buildCompletion?.value
        XCTAssertEqual(model.record?.builtWithAppVersion, "0.6.0(247)")
    }

    func testFailedCacheWriteDoesNotPublishSuccessfulVersionMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "automatic-write-failure", root: root)
        _ = await cache.invalidate()
        let library = try library(cache: cache)
        let model = FoundationPrimaryGenresModel(library: library, appVersion: "0.6.0(247)")
        await model.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await model.buildCompletion?.value
        XCTAssertNotNil(
            model.record, "Complete in-memory data remains useful after a cache write failure")
        XCTAssertNil(model.record?.builtWithAppVersion)
        XCTAssertNotNil(model.errorMessage)
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

    func testCanonicalGenreModesProjectOnlyLoadedScopedSongReferences() throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let foreign = FoundationCatalogSource.local(sourceID: UUID())
        let first = FoundationItem(
            id: Self.id(100), title: "One", subtitle: "", kind: .track, duration: 10,
            album: .init(id: Self.id(10), title: "First Album"),
            artist: .init(id: Self.id(20), title: "First Artist"), catalogSource: source)
        let repeated = FoundationItem(
            id: Self.id(101), title: "Two", subtitle: "", kind: .track, duration: 10,
            album: first.album, artist: first.artist, catalogSource: source)
        let second = FoundationItem(
            id: Self.id(102), title: "Three", subtitle: "", kind: .track, duration: 10,
            album: .init(id: Self.id(11), title: "Second Album"),
            artist: .init(id: Self.id(21), title: "Second Artist"), catalogSource: source)
        let missing = FoundationItem(
            id: Self.id(103), title: "No References", subtitle: "", kind: .track, duration: 10,
            catalogSource: source)
        var foreignSong = second
        foreignSong.catalogSource = foreign
        var foreignReference = second
        foreignReference.album = .init(
            id: Self.id(99), title: "Foreign Album", catalogSource: foreign)
        foreignReference.artist = .init(
            id: Self.id(98), title: "Foreign Artist", catalogSource: foreign)
        let songs = [first, repeated, second, missing, foreignSong, foreignReference]
        let albums = FoundationPrimaryGenreContent.albums.items(in: songs, source: source)
        let artists = FoundationPrimaryGenreContent.artists.items(in: songs, source: source)
        XCTAssertEqual(albums.map(\.id), [Self.id(10), Self.id(11)])
        XCTAssertEqual(artists.map(\.id), [Self.id(20), Self.id(21)])
        XCTAssertTrue(albums.allSatisfy { $0.kind == .album && $0.catalogSource == source })
        XCTAssertTrue(artists.allSatisfy { $0.kind == .artist && $0.catalogSource == source })
        XCTAssertEqual(first.relatedAlbum?.id, albums.first?.id)
        XCTAssertEqual(first.relatedArtist?.id, artists.first?.id)
        XCTAssertEqual(
            FoundationPrimaryGenreContent.tracks.items(in: songs, source: source).map(\.id),
            [first.id, repeated.id, second.id, missing.id, foreignReference.id])
    }

    func testGenreProjectionKeepsRawPaginationAndStopsDuplicateCollectionDemand() async throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let track = FoundationItem(
            id: Self.id(100), title: "One", subtitle: "", kind: .track, duration: 10,
            album: .init(id: Self.id(10), title: "Album"), catalogSource: source)
        let missing = FoundationItem(
            id: Self.id(101), title: "No References", subtitle: "", kind: .track, duration: 10,
            catalogSource: source)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.load(.initial) { _ in .init(items: [track], nextStartIndex: 50) }
        let first = FoundationPrimaryGenreContent.albums.items(in: model.items, source: source)
        let demand = FoundationPrimaryGenreContent.albums.pageDemandIdentity(for: first)
        await model.loadNextPage { offset in
            XCTAssertEqual(offset, 50)
            return .init(items: [track, missing], nextStartIndex: 100)
        }
        XCTAssertEqual(model.nextStartIndex, 100)
        XCTAssertNil(model.errorMessage)
        let second = FoundationPrimaryGenreContent.albums.items(in: model.items, source: source)
        XCTAssertEqual(second, first)
        XCTAssertEqual(FoundationPrimaryGenreContent.albums.pageDemandIdentity(for: second), demand)
        XCTAssertTrue(
            FoundationPrimaryGenreContent.artists.items(in: model.items, source: source).isEmpty)
        XCTAssertNil(FoundationPrimaryGenreContent.tracks.pageDemandIdentity(for: model.items))
    }

    func testNewUserScrollDemandReachesAlbumAfterDuplicateOrMissingReferencePage() async throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let first = FoundationItem(
            id: Self.id(100), title: "One", subtitle: "", kind: .track, duration: 10,
            album: .init(id: Self.id(10), title: "First Album"), catalogSource: source)
        let missing = FoundationItem(
            id: Self.id(101), title: "No References", subtitle: "", kind: .track, duration: 10,
            catalogSource: source)
        let later = FoundationItem(
            id: Self.id(102), title: "Later", subtitle: "", kind: .track, duration: 10,
            album: .init(id: Self.id(11), title: "Later Album"), catalogSource: source)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.load(.initial) { _ in .init(items: [first], nextStartIndex: 50) }
        var demand = FoundationCatalogPageDemand()
        let firstEpoch = demand.epoch
        let initialIdentity = FoundationPrimaryGenreContent.albums.pageDemandIdentity(
            for: FoundationPrimaryGenreContent.albums.items(in: model.items, source: source))
        var offsets: [Int] = []
        await model.loadNextPage { offset in
            offsets.append(offset)
            return .init(items: [first, missing], nextStartIndex: 100)
        }
        XCTAssertEqual(model.nextStartIndex, 100)
        XCTAssertEqual(
            FoundationPrimaryGenreContent.albums.pageDemandIdentity(
                for: FoundationPrimaryGenreContent.albums.items(in: model.items, source: source)),
            initialIdentity)
        XCTAssertEqual(
            demand.epoch, firstEpoch, "A duplicate raw page cannot create another demand")
        for phase: ScrollPhase in [.idle, .tracking, .decelerating, .animating] {
            demand.scrollPhaseChanged(
                to: phase, footerVisible: true, active: true,
                allowsNetwork: true, isLoading: false, hasError: false)
            XCTAssertEqual(demand.epoch, firstEpoch)
        }
        let suppressed: [(footer: Bool, active: Bool, online: Bool, loading: Bool, error: Bool)] = [
            (false, true, true, false, false), (true, false, true, false, false),
            (true, true, false, false, false), (true, true, true, true, false),
            (true, true, true, false, true),
        ]
        for state in suppressed {
            demand.scrollPhaseChanged(
                to: .interacting, footerVisible: state.footer, active: state.active,
                allowsNetwork: state.online, isLoading: state.loading, hasError: state.error)
            XCTAssertEqual(demand.epoch, firstEpoch)
        }
        XCTAssertEqual(offsets, [50], "Suppressed phase changes must not fetch another raw page")
        demand.scrollPhaseChanged(
            to: .interacting, footerVisible: true, active: true,
            allowsNetwork: true, isLoading: false, hasError: false)
        XCTAssertNotEqual(demand.epoch, firstEpoch)
        await model.loadNextPage { offset in
            offsets.append(offset)
            return .init(items: [later], nextStartIndex: nil)
        }
        XCTAssertEqual(offsets, [50, 100])
        XCTAssertEqual(
            FoundationPrimaryGenreContent.albums.items(in: model.items, source: source).map(\.id),
            [Self.id(10), Self.id(11)])
        XCTAssertNil(model.nextStartIndex)
    }

    func testVisibleCanonicalGenrePagingIsBoundedOfflineSafeAndRequiresExplicitFailureRetry()
        async throws
    {
        let recorder = PrimaryGenreRequests()
        let resolver = FoundationJellyfinLibrary(session: Self.session) { request in
            await recorder.append(request)
            let requests = await recorder.requests
            if requests.count == 2 { throw URLError(.timedOut) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            let ids = query.filter { $0.name == "ids" }.compactMap(\.value)
            let items = ids.reversed().map { ["Id": $0, "Name": "Synthetic", "Type": "Audio"] }
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": items, "StartIndex": 0, "TotalRecordCount": ids.count,
            ])
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        let scope = try XCTUnwrap(resolver.primaryGenreIndexScope)
        let ids = (100..<225).map(Self.id)
        let census = UUID()
        let record = FoundationPrimaryGenreRecord(
            snapshot: .init(
                scope: scope, songCount: ids.count, censusID: census, completedAt: Date(),
                songCountsByGenre: [Self.id(1): ids.count], eligibleGenreIDs: [Self.id(1)],
                primaryBySongID: Dictionary(uniqueKeysWithValues: ids.map { ($0, [Self.id(1)]) }),
                orderedSongIDs: ids),
            descriptors: [
                .init(
                    id: Self.id(1), title: "Genre", subtitle: "", kind: .genre,
                    duration: nil, primaryGenreCensusID: census, catalogSource: scope.source)
            ])
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let load: (Int) async throws -> FoundationPage = {
            try await record.songPage(genreID: Self.id(1), startIndex: $0, library: resolver)
        }
        await model.load(.initial, using: load)
        XCTAssertEqual(model.items.count, 50)
        XCTAssertEqual(model.nextStartIndex, 50)
        await model.loadNextPage(ifActive: false, using: load)
        await model.loadNextPage(allowsNetwork: false, using: load)
        let admitted = await recorder.requests
        XCTAssertEqual(admitted.count, 1)
        await model.loadNextPage(using: load)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 50)
        await model.loadNextPage(using: load)
        let afterFailure = await recorder.requests
        XCTAssertEqual(afterFailure.count, 2, "Visible demand must not automatically retry failure")
        await model.load(.more, using: load)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items.count, 100)
        XCTAssertEqual(model.nextStartIndex, 100)
        await model.loadNextPage(using: load)
        XCTAssertEqual(model.items.map(\.id), ids)
        XCTAssertNil(model.nextStartIndex)
        await model.loadNextPage(using: load)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 4)
        let counts = requests.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .filter { $0.name == "ids" }.count
        }
        XCTAssertEqual(counts, [50, 50, 50, 25])
        XCTAssertTrue(requests.allSatisfy { !$0.url!.absoluteString.contains("genreIds") })
    }

    private func orderedGenreRecord(scope: FoundationPrimaryGenreIndex.Scope)
        -> (FoundationPrimaryGenreRecord, [FoundationPrimaryGenreMetadataPage.Song])
    {
        let rows: [FoundationPrimaryGenreMetadataPage.Song] = (0..<125).map { offset in
            let album = (offset * 7) % 65
            let artist = (offset * 11) % 53
            return .init(
                id: Self.id(1000 + offset), genres: [.init(id: Self.id(1), title: "Genre")],
                content: .init(
                    title: String(format: "Title %03d", (offset * 37) % 125),
                    album: .init(
                        id: Self.id(10_000 + album), title: String(format: "Album %03d", 64 - album)
                    ),
                    artist: .init(
                        id: Self.id(20_000 + artist),
                        title: String(format: "Artist %03d", 52 - artist)),
                    duration: offset.isMultiple(of: 10) ? nil : Double(500 - offset),
                    year: offset.isMultiple(of: 9) ? nil : 2000 + offset % 5,
                    dateAdded: offset.isMultiple(of: 8)
                        ? nil : Date(timeIntervalSince1970: 1_600_000_000 + Double(offset))))
        }
        var builder = FoundationPrimaryGenreContentIndex.Builder()
        builder.append(rows, source: scope.source)
        let census = UUID()
        let ids = rows.map(\.id)
        let record = FoundationPrimaryGenreRecord(
            snapshot: .init(
                scope: scope, songCount: ids.count, censusID: census, completedAt: Date(),
                songCountsByGenre: [Self.id(1): ids.count], eligibleGenreIDs: [Self.id(1)],
                primaryBySongID: Dictionary(uniqueKeysWithValues: ids.map { ($0, [Self.id(1)]) }),
                orderedSongIDs: ids),
            descriptors: [
                .init(
                    id: Self.id(1), title: "Genre", subtitle: "", kind: .genre,
                    duration: nil, primaryGenreCensusID: census, catalogSource: scope.source)
            ],
            contentMetadataVersion: FoundationPrimaryGenreContentIndex.version,
            contentIndex: builder.finish(songIDs: Set(ids)))
        return (record, rows)
    }

    func testFullGenreAlphabeticalOrderPrecedesPagingForAllThreeMediaTypes() async throws {
        let requests = PrimaryGenreRequests()
        let resolver = FoundationJellyfinLibrary(session: Self.session) { request in
            await requests.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            let ids = query.filter { $0.name == "ids" }.compactMap(\.value)
            let type = query.first { $0.name == "includeItemTypes" }!.value!
            let entries = ids.reversed().map { id -> [String: Any] in
                let value = Int(id, radix: 16)!
                let title: String
                switch type {
                case "Audio": title = String(format: "Title %03d", ((value - 1000) * 37) % 125)
                case "MusicAlbum": title = String(format: "Album %03d", 64 - (value - 10_000))
                default: title = String(format: "Artist %03d", 52 - (value - 20_000))
                }
                return [
                    "Id": id, "Name": title, "Type": type,
                    "ImageTags": ["Primary": "synthetic"],
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": entries, "StartIndex": 0, "TotalRecordCount": entries.count,
            ])
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        let scope = try XCTUnwrap(resolver.primaryGenreIndexScope)
        let (record, rows) = orderedGenreRecord(scope: scope)
        XCTAssertTrue(record.isValid(for: scope))
        let expectedTracks = rows.sorted { $0.content!.title < $1.content!.title }.map(\.id)
        let expectedAlbums = (0..<65).reversed().map { Self.id(10_000 + $0) }
        let expectedArtists = (0..<53).reversed().map { Self.id(20_000 + $0) }
        XCTAssertNotEqual(Array(expectedTracks.prefix(50)), Array(rows.prefix(50).map(\.id)))
        for (kind, expected) in [
            (FoundationItem.Kind.track, expectedTracks), (.album, expectedAlbums),
            (.artist, expectedArtists),
        ] {
            let source = try XCTUnwrap(record.contentSource(genreID: Self.id(1), kind: kind))
            XCTAssertEqual(source.ids, expected)
            let reverse = try XCTUnwrap(
                record.contentSource(genreID: Self.id(1), kind: kind, descending: true))
            XCTAssertEqual(reverse.ids, Array(expected.reversed()))
            var offset: Int? = 0
            var result: [String] = []
            var titles: [String] = []
            while let current = offset {
                let page = try await source.page(startIndex: current, library: resolver)
                XCTAssertLessThanOrEqual(page.items.count, 50)
                result += page.items.map(\.id)
                titles += page.items.map(\.title)
                XCTAssertTrue(page.items.allSatisfy { $0.catalogSource == scope.source })
                if kind != .track {
                    XCTAssertTrue(page.items.allSatisfy { $0.primaryImageTag == "synthetic" })
                }
                offset = page.nextStartIndex
            }
            XCTAssertEqual(
                result, expected, "Concatenated pages must preserve complete logical order")
            XCTAssertEqual(titles, titles.sorted())
            let finished = try await source.page(startIndex: expected.count, library: resolver)
            XCTAssertTrue(finished.items.isEmpty)
        }
        let captured = await requests.requests
        XCTAssertEqual(
            captured.count, 7, "125 tracks,65 albums,53 artists require3+2+2 bounded reads")
        for request in captured {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertLessThanOrEqual(query.filter { $0.name == "ids" }.count, 50)
            XCTAssertNil(query.first { $0.name == "genreIds" })
            let artist = query.first { $0.name == "includeItemTypes" }?.value == "MusicArtist"
            XCTAssertEqual(query.first { $0.name == "parentId" }?.value, artist ? nil : Self.id(77))
        }
        let source = try XCTUnwrap(record.contentSource(genreID: Self.id(1), kind: .album))
        do {
            _ = try await source.page(startIndex: 0, library: resolver.scoped(to: Self.id(78)))
            XCTFail("Changed library cannot resolve an old logical genre source")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let after = await requests.requests
        XCTAssertEqual(after.count, captured.count)
    }

    func testMissingGenreCollectionMetadataDoesNotSilentlyCompleteAFilteredPage() async throws {
        let requests = PrimaryGenreRequests()
        let resolver = FoundationJellyfinLibrary(session: Self.session) { request in
            await requests.append(request)
            let data = Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8)
            return (
                data,
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }.scoped(to: Self.id(77))
        let scope = try XCTUnwrap(resolver.primaryGenreIndexScope)
        let (record, _) = orderedGenreRecord(scope: scope)
        let source = try XCTUnwrap(record.contentSource(genreID: Self.id(1), kind: .album))
        do {
            _ = try await source.page(startIndex: 0, library: resolver)
            XCTFail("Missing canonical album metadata must not become a successful empty result")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let captured = await requests.requests
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(source.ids.count, 65)
    }

    func testGenreDownloadedFilterAppliesBeforeSortingDeduplicationAndPaging() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).scoped(to: Self.id(77))
                .primaryGenreIndexScope)
        let (record, rows) = orderedGenreRecord(scope: scope)
        let readyRows = rows.enumerated().filter { $0.offset.isMultiple(of: 3) }.map(\.element)
        let ready = Set(readyRows.map(\.id) + [Self.id(999_999)])
        let expectedTracks = readyRows.sorted { $0.content!.title < $1.content!.title }.map(\.id)
        let expectedAlbums = Array(Set(readyRows.compactMap { $0.content?.album?.id })).sorted(
            by: >)
        let expectedArtists = Array(Set(readyRows.compactMap { $0.content?.artist?.id })).sorted(
            by: >)
        for (kind, expected) in [
            (FoundationItem.Kind.track, expectedTracks), (.album, expectedAlbums),
            (.artist, expectedArtists),
        ] {
            let source = try XCTUnwrap(
                record.contentSource(genreID: Self.id(1), kind: kind, readySongIDs: ready))
            XCTAssertEqual(source.ids, expected)
            XCTAssertFalse(source.ids.contains(Self.id(999_999)))
            XCTAssertTrue(
                try XCTUnwrap(
                    record.contentSource(genreID: Self.id(1), kind: kind, readySongIDs: [])
                ).ids.isEmpty)
        }
    }

    func testGenreSortOptionsUseOwnMediaFactsAndUnknownValuesRemainLast() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, rows) = orderedGenreRecord(scope: scope)
        let index = try XCTUnwrap(record.contentIndex)
        XCTAssertEqual(index.supportedSorts(kind: .album, membership: rows.map(\.id)), [.name])
        XCTAssertEqual(index.supportedSorts(kind: .artist, membership: rows.map(\.id)), [.name])
        XCTAssertEqual(
            Set(index.supportedSorts(kind: .track, membership: rows.map(\.id))),
            Set(FoundationPrimaryGenreSort.allCases))
        let duration = try XCTUnwrap(
            record.contentSource(
                genreID: Self.id(1), kind: .track, sort: .duration, descending: true))
        let known = duration.ids.compactMap { index.tracks[$0]?.duration }
        XCTAssertEqual(known, known.sorted(by: >))
        let firstUnknown = try XCTUnwrap(
            duration.ids.firstIndex { index.tracks[$0]?.duration == nil })
        XCTAssertTrue(
            duration.ids[firstUnknown...].allSatisfy { index.tracks[$0]?.duration == nil })
        XCTAssertNil(record.contentSource(genreID: Self.id(1), kind: .album, sort: .year))
        XCTAssertNil(record.contentSource(genreID: Self.id(1), kind: .artist, sort: .dateAdded))
        var builder = FoundationPrimaryGenreContentIndex.Builder()
        builder.append(
            [
                .init(id: "b", genres: [], content: .init(title: "Same")),
                .init(id: "a", genres: [], content: .init(title: "Same")),
            ], source: scope.source)
        let ties = try XCTUnwrap(builder.finish(songIDs: ["a", "b"]))
        XCTAssertEqual(ties.orderedIDs(membership: ["b", "a"], kind: .track), ["a", "b"])
        XCTAssertEqual(
            ties.orderedIDs(membership: ["b", "a"], kind: .track, descending: true), ["a", "b"])
    }

    func testLegacyGenreRecordKeepsEligibilityAndOfflineAlbumsWithoutClaimingPartialSort() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (current, _) = orderedGenreRecord(scope: scope)
        let legacy = FoundationPrimaryGenreRecord(
            snapshot: current.snapshot, descriptors: current.descriptors)
        XCTAssertTrue(legacy.isValid(for: scope))
        XCTAssertEqual(legacy.matchingItems(), current.matchingItems())
        XCTAssertNil(legacy.contentSource(genreID: Self.id(1), kind: .album))
        let unsupported = FoundationPrimaryGenreRecord(
            snapshot: current.snapshot, descriptors: current.descriptors,
            contentMetadataVersion: FoundationPrimaryGenreContentIndex.version + 1,
            contentIndex: current.contentIndex)
        XCTAssertNil(unsupported.contentSource(genreID: Self.id(1), kind: .album))
        XCTAssertNil(unsupported.contentSource(genreID: Self.id(1), kind: .track))
        let downloaded = [
            FoundationItem(
                id: Self.id(1000), title: "Z Track", subtitle: "", kind: .track, duration: 10,
                album: .init(id: "z-album", title: "Z Album")),
            FoundationItem(
                id: Self.id(1001), title: "A Track", subtitle: "", kind: .track, duration: 10,
                album: .init(id: "a-album", title: "A Album")),
        ]
        XCTAssertEqual(
            legacy.offlineContent(genreID: Self.id(1), kind: .album, downloaded: downloaded).map(
                \.id), ["a-album", "z-album"])
        XCTAssertEqual(
            legacy.offlineContent(genreID: Self.id(1), kind: .track, downloaded: downloaded).map(
                \.id), [Self.id(1001), Self.id(1000)])
        let data = try PropertyListEncoder().encode(legacy)
        let restored = try PropertyListDecoder().decode(
            FoundationPrimaryGenreRecord.self, from: data)
        XCTAssertEqual(restored, legacy)
        XCTAssertNil(restored.contentMetadataVersion)
    }

    func testPackedGenreIdentitiesPreserveExactUUIDSpellingAndRejectCorruptFrames() throws {
        let ids = [
            "abcdefab12345678901234567890abcd", "ABCDEFAB12345678901234567890ABCD",
            "aBcDeFaB-1234-5678-9012-34567890aBcD",
        ]
        let table = try FoundationPrimaryGenreIdentityTable(ids)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(table)
        XCTAssertEqual(
            try PropertyListDecoder().decode(FoundationPrimaryGenreIdentityTable.self, from: data),
            table)
        var fields = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        fields["uuidBytes"] = Data([0])
        let corrupt = try PropertyListSerialization.data(
            fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertThrowsError(
            try PropertyListDecoder().decode(
                FoundationPrimaryGenreIdentityTable.self, from: corrupt))
        XCTAssertThrowsError(try FoundationPrimaryGenreIdentityTable([ids[0], ids[0]]))
        let generic = try FoundationPrimaryGenreIdentityTable(["fixture-track", "fixture-album"])
        XCTAssertEqual(
            try PropertyListDecoder().decode(
                FoundationPrimaryGenreIdentityTable.self, from: encoder.encode(generic)), generic)
    }

    func testPackedSnapshotKeepsZeroOneTwoPrimaryMembershipAndReadsLegacyEnvelope() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, _) = orderedGenreRecord(scope: scope)
        struct Legacy: Encodable {
            let snapshot: FoundationPrimaryGenreIndex.Snapshot
            let descriptors: [FoundationItem]
            let builtWithAppVersion: String?
            let contentMetadataVersion: Int?
        }
        let legacy = Legacy(
            snapshot: record.snapshot, descriptors: record.descriptors,
            builtWithAppVersion: "0.6.0(259)", contentMetadataVersion: 1)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let restored = try PropertyListDecoder().decode(
            FoundationPrimaryGenreRecord.self, from: encoder.encode(legacy))
        XCTAssertEqual(restored.snapshot, record.snapshot)
        XCTAssertTrue(restored.isValid(for: scope))
        XCTAssertEqual(restored.contentMetadataVersion, 1)
        let ids = [Self.id(1), Self.id(2), Self.id(3)]
        let a = Self.id(100)
        let b = Self.id(101)
        let snapshot = FoundationPrimaryGenreIndex.Snapshot(
            scope: scope, songCount: 3, censusID: UUID(), completedAt: Date(),
            songCountsByGenre: [a: 2, b: 1], eligibleGenreIDs: [a, b],
            primaryBySongID: [ids[0]: [], ids[1]: [a], ids[2]: [a, b]], orderedSongIDs: ids)
        let packed = try FoundationPrimaryGenrePackedSnapshot(snapshot)
        XCTAssertEqual(try packed.unpack(), snapshot)
        let data = try encoder.encode(packed)
        var fields = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        fields["primaryPairs"] = FoundationPrimaryGenreWords.encode([
            UInt16.max, 0, UInt16.max, UInt16.max, 0, 1,
        ])
        let malformed = try PropertyListSerialization.data(
            fromPropertyList: fields, format: .binary, options: 0)
        XCTAssertThrowsError(
            try PropertyListDecoder().decode(
                FoundationPrimaryGenrePackedSnapshot.self, from: malformed
            ).unpack())
    }

    func testPackedNameRanksKeepEqualNameIDTiesAndNeverPersistSecondSongIdentityTable() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, _) = orderedGenreRecord(scope: scope)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        let fields = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertNil(fields["snapshot"])
        let content = try XCTUnwrap(fields["contentIndex"] as? [String: Any])
        XCTAssertNil(content["tracks"])
        let ranks = try XCTUnwrap(content["ranks"] as? [String: Any])
        XCTAssertNil(ranks["songIDs"])
        XCTAssertEqual(
            Set(ranks.keys),
            [
                "albumIDs", "artistIDs", "trackNames", "albumNames", "artistNames", "trackAlbums",
                "trackArtists",
            ])
        let restored = try PropertyListDecoder().decode(
            FoundationPrimaryGenreRecord.self, from: data)
        for kind in [FoundationItem.Kind.track, .album, .artist] {
            for descending in [false, true] {
                XCTAssertEqual(
                    restored.contentSource(genreID: Self.id(1), kind: kind, descending: descending)?
                        .ids,
                    record.contentSource(genreID: Self.id(1), kind: kind, descending: descending)?
                        .ids)
            }
        }
        var builder = FoundationPrimaryGenreContentIndex.Builder()
        builder.append(
            ["b", "a"].map {
                .init(
                    id: $0, genres: [],
                    content: .init(
                        title: "Same", album: .init(id: "album-\($0)", title: "Same"),
                        artist: .init(id: "artist-\($0)", title: "Same")))
            }, source: scope.source)
        let index = try XCTUnwrap(builder.finish(songIDs: ["a", "b"]))
        for kind in [FoundationItem.Kind.track, .album, .artist] {
            let ordered = index.orderedIDs(membership: ["b", "a"], kind: kind)
            XCTAssertEqual(
                index.orderedIDs(membership: ["b", "a"], kind: kind, descending: true), ordered)
            XCTAssertEqual(ordered, ordered.sorted())
        }
    }

    func testMaximumPackedGenreRecordRetainsEveryNameOrderWithinOriginalEightMiB() async throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let worker = FoundationPrimaryGenreContentWorker()
        let census = FoundationPrimaryGenreIndex()
        let generation = try await census.begin(scope: scope)
        func uuid(_ value: Int) -> String {
            let raw = Array(
                Self.id(value).enumerated().map { offset, character in
                    offset.isMultiple(of: 2) ? String(character) : String(character).uppercased()
                }.joined())
            return [
                String(raw[0..<8]), String(raw[8..<12]), String(raw[12..<16]), String(raw[16..<20]),
                String(raw[20..<32]),
            ].joined(separator: "-")
        }
        func name(_ value: Int) -> String {
            String(format: "%08d", value) + String(repeating: "x", count: 504)
        }
        let genres = (0..<4096).map {
            FoundationItemReference(id: uuid(1_000_000 + $0), title: name($0))
        }
        var songIDs: [String] = []
        var albumIDs: [String] = []
        var artistIDs: [String] = []
        for start in stride(from: 0, to: 50_000, by: 200) {
            let rows: [FoundationPrimaryGenreMetadataPage.Song] = (start..<start + 200).map {
                value in
                let id = uuid(value + 1)
                let album = uuid(100_000 + value)
                let artist = uuid(200_000 + value)
                songIDs.append(id)
                albumIDs.append(album)
                artistIDs.append(artist)
                return .init(
                    id: id, genres: [genres[value % 4096], genres[(value + 1) % 4096]],
                    content: .init(
                        title: name(50_000 - value),
                        album: .init(id: album, title: name(50_000 - value)),
                        artist: .init(id: artist, title: name(50_000 - value)),
                        duration: Double(value), year: 2000 + value % 25,
                        dateAdded: Date(timeIntervalSinceReferenceDate: Double(value))))
            }
            try await worker.append(rows, source: scope.source)
            try await census.append(
                .init(
                    startIndex: start, total: 50_000,
                    songs: rows.map { .init(id: $0.id, genreIDs: $0.genres.map(\.id)) },
                    nextStartIndex: start + 200 < 50_000 ? start + 200 : nil),
                generation: generation)
        }
        let snapshot = try await census.finish(generation: generation)
        let descriptors = genres.map {
            FoundationItem(
                id: $0.id, title: $0.title, subtitle: "", kind: .genre, duration: nil,
                primaryGenreCensusID: snapshot.censusID, catalogSource: scope.source)
        }
        let record = try await worker.finish(snapshot: snapshot, descriptors: descriptors)
        XCTAssertTrue(record.isValid(for: scope))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        XCTAssertLessThanOrEqual(data.count, 8 * 1_024 * 1_024)
        print("Maximum packed primary genre record bytes: \(data.count)")
        let restored = try PropertyListDecoder().decode(
            FoundationPrimaryGenreRecord.self, from: data)
        XCTAssertEqual(restored.snapshot, snapshot)
        XCTAssertEqual(restored, record)
        let index = try XCTUnwrap(restored.contentIndex)
        for (kind, expected) in [
            (FoundationItem.Kind.track, Array(songIDs.reversed())),
            (.album, Array(albumIDs.reversed())), (.artist, Array(artistIDs.reversed())),
        ] {
            let ordered = index.orderedIDs(membership: songIDs, kind: kind)
            XCTAssertEqual(ordered, expected)
            XCTAssertEqual(ordered.count, 50_000)
            XCTAssertEqual(Set(ordered).count, 50_000)
            XCTAssertEqual(Array(ordered.prefix(50)), Array(expected.prefix(50)))
            XCTAssertEqual(Array(ordered.suffix(50)), Array(expected.suffix(50)))
            XCTAssertEqual(
                index.orderedIDs(membership: songIDs, kind: kind, descending: true),
                Array(expected.reversed()))
        }
    }

    func testTightRecordBudgetOmitsOptionalFactsBeforeAnyMandatoryNameOrMembership() async throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, rows) = orderedGenreRecord(scope: scope)
        let content = try XCTUnwrap(record.contentIndex)
        let withoutDates = FoundationPrimaryGenreRecord(
            snapshot: record.snapshot, descriptors: record.descriptors,
            contentMetadataVersion: FoundationPrimaryGenreContentIndex.version,
            contentIndex: content.omitting(.dateAdded))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let target = try encoder.encode(withoutDates).count
        XCTAssertLessThan(target, try encoder.encode(record).count)
        let worker = FoundationPrimaryGenreContentWorker(maximumRecordBytes: target)
        try await worker.append(rows, source: scope.source)
        let fitted = try await worker.finish(
            snapshot: record.snapshot, descriptors: record.descriptors)
        XCTAssertEqual(fitted.snapshot, record.snapshot)
        let fittedContent = try XCTUnwrap(fitted.contentIndex)
        XCTAssertFalse(
            fittedContent.supportedSorts(kind: .track, membership: rows.map(\.id)).contains(
                .dateAdded))
        XCTAssertTrue(
            fittedContent.supportedSorts(kind: .track, membership: rows.map(\.id)).contains(
                .duration))
        XCTAssertTrue(
            fittedContent.supportedSorts(kind: .track, membership: rows.map(\.id)).contains(.year))
        for kind in [FoundationItem.Kind.track, .album, .artist] {
            XCTAssertEqual(
                fitted.contentSource(genreID: Self.id(1), kind: kind)?.ids,
                record.contentSource(genreID: Self.id(1), kind: kind)?.ids)
        }
        XCTAssertLessThanOrEqual(try encoder.encode(fitted).count, target)
    }

    func testCancelledGenreRankWorkerCannotPublishCompletedOrder() async throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, rows) = orderedGenreRecord(scope: scope)
        let worker = FoundationPrimaryGenreContentWorker()
        try await worker.append(rows, source: scope.source)
        let operation = Task {
            try await worker.finish(snapshot: record.snapshot, descriptors: record.descriptors)
        }
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled rank preparation cannot publish")
        } catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testOrderingMetadataBudgetCannotRemoveExistingGenreEligibility() throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, _) = orderedGenreRecord(scope: scope)
        var builder = FoundationPrimaryGenreContentIndex.Builder()
        let rows: [FoundationPrimaryGenreMetadataPage.Song] = (0..<20_000).map {
            .init(
                id: Self.id($0 + 1000), genres: [],
                content: .init(title: String(repeating: "x", count: 512)))
        }
        builder.append(rows, source: scope.source)
        XCTAssertFalse(builder.exceededBudget)
        let ordered = try XCTUnwrap(builder.finish(songIDs: Set(rows.map(\.id))))
        XCTAssertTrue(ordered.tracks.values.allSatisfy { $0.title.isEmpty })
        XCTAssertEqual(
            ordered.orderedIDs(membership: rows.map(\.id), kind: .track).count, rows.count)
        let membershipOnly = FoundationPrimaryGenreRecord(
            snapshot: record.snapshot, descriptors: record.descriptors,
            contentMetadataVersion: FoundationPrimaryGenreContentIndex.version)
        XCTAssertTrue(membershipOnly.isValid(for: scope))
        XCTAssertEqual(membershipOnly.matchingItems(), record.matchingItems())
        XCTAssertEqual(membershipOnly.songIDs(for: Self.id(1)), record.songIDs(for: Self.id(1)))
        XCTAssertNil(membershipOnly.contentSource(genreID: Self.id(1), kind: .track))
    }

    func testOrderingRecordRoundTripAndEightMiBCacheLimitPreservePriorRecord() async throws {
        let scope = try XCTUnwrap(
            FoundationJellyfinLibrary(session: Self.session).primaryGenreIndexScope)
        let (record, _) = orderedGenreRecord(scope: scope)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(record)
        XCTAssertLessThan(data.count, 8 * 1_024 * 1_024)
        XCTAssertEqual(
            try PropertyListDecoder().decode(FoundationPrimaryGenreRecord.self, from: data), record)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "ordered-record-cache", root: root)
        try await cache.writePrimaryGenres(
            record, key: "content-index", permit: FoundationPageWritePermit())
        let ids = (0..<18_000).map { Self.id(50_000 + $0) }
        let tracks = Dictionary(
            uniqueKeysWithValues: ids.map { id in
                (
                    id,
                    FoundationPrimaryGenreContentIndex.Track(
                        title: String(repeating: "x", count: 480) + id, albumID: nil, artistID: nil,
                        duration: nil, year: nil, dateAdded: nil)
                )
            })
        let census = UUID()
        var descriptor = record.descriptors[0]
        descriptor.primaryGenreCensusID = census
        let tooLarge = FoundationPrimaryGenreRecord(
            snapshot: .init(
                scope: scope, songCount: ids.count, censusID: census, completedAt: Date(),
                songCountsByGenre: [Self.id(1): ids.count], eligibleGenreIDs: [Self.id(1)],
                primaryBySongID: Dictionary(uniqueKeysWithValues: ids.map { ($0, [Self.id(1)]) }),
                orderedSongIDs: ids), descriptors: [descriptor],
            contentMetadataVersion: FoundationPrimaryGenreContentIndex.version,
            contentIndex: .init(tracks: tracks, albums: [:], artists: [:]))
        XCTAssertTrue(tooLarge.isValid(for: scope))
        XCTAssertGreaterThan(try encoder.encode(tooLarge).count, 8 * 1_024 * 1_024)
        do {
            try await cache.writePrimaryGenres(
                tooLarge, key: "content-index", permit: FoundationPageWritePermit())
            XCTFail("Ordering metadata cannot widen the existing eight-MiB record cap")
        } catch { XCTAssertEqual(error as? FoundationPrimaryGenreIndex.Failure, .resourceLimit) }
        let retained = try await cache.readPrimaryGenres(key: "content-index", scope: scope)
        XCTAssertEqual(
            retained, record, "An oversized replacement must preserve the prior complete record")
    }

    func testContentSchemaUpgradeRebuildsOnceEvenWhenTheAppVersionMarkerIsCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationCatalogPageCache(scope: "content-schema-upgrade", root: root)
        let recorder = PrimaryGenreRequests()
        let library = try library(recorder: recorder, cache: cache)
        let first = FoundationPrimaryGenresModel(library: library, appVersion: "0.6.0(256)")
        await first.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await first.buildCompletion?.value
        let fresh = try XCTUnwrap(first.record)
        let legacy = FoundationPrimaryGenreRecord(
            snapshot: fresh.snapshot, descriptors: fresh.descriptors,
            builtWithAppVersion: "0.6.0(256)")
        try await cache.writePrimaryGenres(
            legacy, key: library.catalogCacheKey("primary-genres-v2"),
            permit: FoundationPageWritePermit())
        let next = FoundationPrimaryGenresModel(library: library, appVersion: "0.6.0(256)")
        await next.prepareAutomaticallyIfNeeded(allowsNetwork: false)
        XCTAssertEqual(next.record, legacy)
        let before = await recorder.requests.count
        await next.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        await next.buildCompletion?.value
        XCTAssertEqual(
            next.record?.contentMetadataVersion, FoundationPrimaryGenreContentIndex.version)
        XCTAssertNotNil(next.record?.contentIndex)
        let after = await recorder.requests.count
        XCTAssertEqual(after, before + 2)
        await next.prepareAutomaticallyIfNeeded(allowsNetwork: true)
        let final = await recorder.requests.count
        XCTAssertEqual(final, after, "The schema upgrade cannot become a foreground census loop")
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
        for fault in ["duplicate", "policy", "storage"] {
            var malformed = original
            var snapshot = try XCTUnwrap(malformed["packedSnapshot"] as? [String: Any])
            if fault == "duplicate" {
                var identities = try XCTUnwrap(snapshot["songIDs"] as? [String: Any])
                var bytes = try XCTUnwrap(identities["uuidBytes"] as? Data)
                var spelling = try XCTUnwrap(identities["spelling"] as? Data)
                bytes.replaceSubrange(16..<32, with: bytes.prefix(16))
                spelling.replaceSubrange(5..<10, with: spelling.prefix(5))
                identities["uuidBytes"] = bytes
                identities["spelling"] = spelling
                snapshot["songIDs"] = identities
            } else if fault == "policy" {
                var scope = try XCTUnwrap(snapshot["scope"] as? [String: Any])
                scope["policyVersion"] = 1
                snapshot["scope"] = scope
            } else {
                malformed["storageVersion"] = 999
            }
            malformed["packedSnapshot"] = snapshot
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
