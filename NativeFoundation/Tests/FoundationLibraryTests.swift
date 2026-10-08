import Foundation
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import SwiftUI
    import UIKit
#endif

final class FoundationLibraryTests: XCTestCase {

    func testTypedFavoritesQueriesEachKindIndependentlyWithFavoriteFilterAndCursor() async throws {
        for (kind, type) in [
            (FoundationItem.Kind.album, "MusicAlbum"), (.artist, "MusicArtist"), (.track, "Audio"),
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!
                XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, type)
                XCTAssertEqual(query.first { $0.name == "isFavorite" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "50")
                XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
                XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
                let payload =
                    "{\"Items\":[{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"" + type
                    + "\",\"Name\":\"Favorite\",\"UserData\":{\"Key\":\"synthetic-key\",\"IsFavorite\":true}}],\"StartIndex\":50,\"TotalRecordCount\":51}"
                return (Data(payload.utf8), Self.response(request))
            }
            let page = try await library.favorites(kind: kind, startIndex: 50)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.kind, kind)
            XCTAssertEqual(page.items.first?.isFavorite, true)
            XCTAssertNil(page.nextStartIndex)
        }
    }

    @MainActor
    func testSongsActivationLoadsCompleteMembershipBeforeAnyLetterSelection() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let c = FoundationItem(id: "c", title: "Charlie", subtitle: "", kind: .track, duration: nil)
        let f = FoundationItem(id: "f", title: "Foxtrot", subtitle: "", kind: .track, duration: nil)
        var offsets: [Int] = []
        await model.loadCompleteCatalog { offset in
            offsets.append(offset)
            switch offset {
            case 0: return .init(items: [a], nextStartIndex: 50)
            case 50: return .init(items: [c], nextStartIndex: 100)
            default: return .init(items: [f], nextStartIndex: nil)
            }
        }
        XCTAssertEqual(offsets, [0, 50, 100])
        XCTAssertEqual(model.items, [a, c, f])
        XCTAssertNil(model.nextStartIndex)
        for letter in FoundationAlphabetAnchors.titles {
            XCTAssertNotNil(FoundationAlphabetAnchors.index(for: letter, in: model.items))
        }
        XCTAssertEqual(model.items, [a, c, f])
        XCTAssertEqual(offsets, [0, 50, 100])
        await model.loadCompleteCatalog { _ in
            XCTFail("Reactivation retains the complete catalog without a cache refresh")
            return .init(items: [], nextStartIndex: nil)
        }
    }

    @MainActor
    func testSongsActivationCancellationRejectsStalePageAndResumesRemainingMembership() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let f = FoundationItem(id: "f", title: "Foxtrot", subtitle: "", kind: .track, duration: nil)
        await model.loadPending { _ in .init(items: [a], nextStartIndex: 50) }
        let gate = FoundationAlphabetTestGate()
        let old = Task {
            await model.loadCompleteCatalog { offset in
                XCTAssertEqual(offset, 50)
                await gate.suspend()
                return .init(items: [f], nextStartIndex: nil)
            }
        }
        await gate.entered()
        old.cancel()
        await gate.release()
        await old.value
        XCTAssertEqual(model.items, [a])
        XCTAssertEqual(model.nextStartIndex, 50)
        XCTAssertFalse(model.isLoading)
        await model.loadCompleteCatalog { offset in
            XCTAssertEqual(offset, 50)
            return .init(items: [f], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items, [a, f])
        XCTAssertNil(model.nextStartIndex)
    }

    @MainActor
    func testCompleteCatalogStopsOnFailureWithoutAutomaticRetry() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        var requests = 0
        await model.loadCompleteCatalog { offset in
            requests += 1
            if offset == 0 { return .init(items: [a], nextStartIndex: 50) }
            throw FoundationLibraryError.network
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.items, [a])
        XCTAssertNotNil(model.errorMessage)
        await model.loadCompleteCatalog { _ in
            XCTFail("A failed catalog requires explicit retry")
            return .init(items: [], nextStartIndex: nil)
        }
    }

    @MainActor
    func testCachedCatalogFailureRequiresExplicitRetryOnRevisit() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "synthetic-rail-retry", root: directory)
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let f = FoundationItem(id: "f", title: "Foxtrot", subtitle: "", kind: .track, duration: nil)
        // Cover a refresh failure retaining disk data and a later-page failure retaining live data.
        for failRefresh in [true, false] {
            let key = "songs-\(failRefresh)"
            await cache.write(.init(items: [a], nextStartIndex: 50), key: key)
            let model = FoundationBrowseModel(refreshInterval: 0)
            model.configureCatalogPagination()
            model.configureCache(cache, key: key)
            await model.loadCompleteCatalog { offset in
                if !failRefresh, offset == 0 {
                    return .init(items: [a], nextStartIndex: 50)
                }
                throw FoundationLibraryError.network
            }
            XCTAssertEqual(model.items, [a])
            XCTAssertEqual(model.isRetainedSnapshot, failRefresh)
            XCTAssertEqual(model.errorCategory, .network)
            await model.loadCompleteCatalog { _ in
                XCTFail("Revisiting a failed cached catalog must not retry any page")
                return .init(items: [], nextStartIndex: nil)
            }
            XCTAssertEqual(model.items, [a])
            XCTAssertEqual(model.errorCategory, .network)
            model.request(model.retryRequest)
            await model.loadCompleteCatalog { offset in
                offset == 0
                    ? .init(items: [a], nextStartIndex: 50)
                    : .init(items: [f], nextStartIndex: nil)
            }
            XCTAssertEqual(model.items, [a, f])
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.nextStartIndex)
        }
    }

    @MainActor
    func testCompleteCatalogAccountResetRejectsLatePageAndStopsPaging() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let gate = FoundationAlphabetTestGate()
        var requests = 0
        let loading = Task {
            await model.loadCompleteCatalog { _ in
                requests += 1
                await gate.suspend()
                return .init(items: [a], nextStartIndex: 50)
            }
        }
        await gate.entered()
        model.clearRetainedData()
        await gate.release()
        await loading.value
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.nextStartIndex)
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testCompleteCatalogRejectsNonAdvancingCursor() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        var requests = 0
        await model.loadCompleteCatalog { offset in
            requests += 1
            return .init(items: [a], nextStartIndex: offset)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.errorCategory, .invalidResponse)
    }

    func testAlphabetRailOffersNumbersThenAZAndMissingLettersUseFollowingOrFinalAnchor() {
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let g = FoundationItem(id: "g", title: "Golf", subtitle: "", kind: .track, duration: nil)
        XCTAssertEqual(FoundationAlphabetAnchors.titles.count, 27)
        XCTAssertEqual(FoundationAlphabetAnchors.titles.first, "#")
        XCTAssertEqual(FoundationAlphabetAnchors.titles.last, "Z")
        XCTAssertNil(FoundationAlphabetAnchors.index(for: "All", in: [a, g]))
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "#", in: [a, g]), 0)
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "F", in: [a, g]), 1)
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "Z", in: [a, g]), 1)
        XCTAssertNil(FoundationAlphabetAnchors.index(for: "A", in: []))
    }

    func testAlphabetNumberAndSymbolAnchorsAndRailDragGeometry() {
        let number = FoundationItem(
            id: "number", title: "2 Songs", subtitle: "", kind: .track, duration: nil)
        let symbol = FoundationItem(
            id: "symbol", title: "! Song", subtitle: "", kind: .track, duration: nil)
        let alpha = FoundationItem(
            id: "alpha", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        XCTAssertEqual(FoundationAlphabetAnchors.letter(for: number), "#")
        XCTAssertEqual(FoundationAlphabetAnchors.letter(for: symbol), "#")
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "#", in: [number, symbol, alpha]), 0)
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "A", in: [number, symbol, alpha]), 2)
        // Every equal-height hit region maps consistently while dragging down and back up.
        for index in 0..<27 {
            XCTAssertEqual(
                FoundationAlphabetRailGeometry.index(
                    y: Double(index) * 22 + 11, height: 594, count: 27), index)
        }
        XCTAssertEqual(FoundationAlphabetRailGeometry.index(y: -50, height: 594, count: 27), 0)
        XCTAssertEqual(FoundationAlphabetRailGeometry.index(y: 650, height: 594, count: 27), 26)
        XCTAssertNil(FoundationAlphabetRailGeometry.index(y: 0, height: 0, count: 27))
    }

    @MainActor
    func testSongsSortActualTitlesAcrossShuffledPagesAndKeepQueueAligned() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination(sortByTitle: true)
        let z = FoundationItem(
            id: "z", title: "Zulu", subtitle: "", kind: .track, duration: nil, sortName: "001 album"
        )
        let a = FoundationItem(
            id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil,
            sortName: "999 album")
        let number = FoundationItem(
            id: "n", title: "42", subtitle: "", kind: .track, duration: nil, sortName: "z")
        let accented = FoundationItem(
            id: "e", title: "Écho", subtitle: "", kind: .track, duration: nil, sortName: "0")
        var offsets: [Int] = []
        await model.loadCompleteCatalog { offset in
            offsets.append(offset)
            return offset == 0
                ? .init(items: [z, accented], nextStartIndex: 2)
                : .init(items: [a, number], nextStartIndex: nil)
        }
        XCTAssertEqual(offsets, [0, 2])
        XCTAssertEqual(model.items.map(\.id), ["n", "a", "e", "z"])
        XCTAssertEqual(model.items.map(FoundationAlphabetAnchors.letter), ["#", "A", "E", "Z"])
        let anchor = FoundationAlphabetAnchors.index(for: "E", in: model.items)
        XCTAssertEqual(anchor, 2)
        let queue = model.trackQueue(selecting: anchor ?? -1)
        XCTAssertEqual(queue?.items.map(\.id), ["n", "a", "e", "z"])
        XCTAssertEqual(queue?.index, 2)
        XCTAssertEqual(FoundationAlphabetAnchors.sorted([a, z, number, accented]), model.items)
    }

    func testTitleSortTieBreakAndScrubBubbleStayDeterministic() {
        let first = FoundationItem(
            id: "1", title: "Echo", subtitle: "", kind: .track, duration: nil)
        let second = FoundationItem(
            id: "2", title: "ÉCHO", subtitle: "", kind: .track, duration: nil)
        XCTAssertEqual(FoundationAlphabetAnchors.sorted([second, first]).map(\.id), ["1", "2"])
        XCTAssertEqual(
            FoundationAlphabetRailGeometry.bubbleTop(index: 0, height: 594, count: 27), 0)
        XCTAssertEqual(
            FoundationAlphabetRailGeometry.bubbleTop(index: 13, height: 594, count: 27), 270)
        XCTAssertEqual(
            FoundationAlphabetRailGeometry.bubbleTop(index: 26, height: 594, count: 27), 540)
    }

    func testAlphabetAnchorUsesActualTitleAndDecodesOlderCaches() throws {
        let a = FoundationItem(
            id: "a", title: "The Zebra", subtitle: "", kind: .track,
            duration: nil, sortName: "alpha")
        let b = FoundationItem(id: "b", title: "Bravo", subtitle: "", kind: .track, duration: nil)
        XCTAssertEqual(FoundationAlphabetAnchors.letter(for: a), "T")
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "T", in: [b, a]), 1)
        XCTAssertEqual(FoundationAlphabetAnchors.index(for: "B", in: [a, b]), 1)
        let encoded = try JSONEncoder().encode(a)
        XCTAssertEqual(
            try JSONDecoder().decode(FoundationItem.self, from: encoded).sortName, "alpha")
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        older.removeValue(forKey: "sortName")
        let legacy = try JSONSerialization.data(withJSONObject: older)
        XCTAssertNil(try JSONDecoder().decode(FoundationItem.self, from: legacy).sortName)
    }

    func testOrdinarySongsPageRequestsProviderSortNameForFullListAnchors() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertEqual(query.first { $0.name == "fields" }?.value, "SortName")
            XCTAssertNil(query.first { $0.name == "nameStartsWithOrGreater" })
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"The Zebra","SortName":"alpha"}],"StartIndex":0,"TotalRecordCount":1}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.songs(startIndex: 0)
        XCTAssertEqual(page.items.first?.sortName, "alpha")
        XCTAssertEqual(page.items.first?.title, "The Zebra")
    }

    func testFunctionalAlphabetProbeUsesSortNameNotDisplayTitleAndHasNoVersionGate() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let result = await library.alphabetCapability()
        XCTAssertEqual(result, .verified)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertTrue(request.url!.path.hasSuffix("/Items"))
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            XCTAssertEqual(value("limit"), "1")
            XCTAssertEqual(value("fields"), "SortName")
            XCTAssertEqual(value("includeItemTypes"), "Audio")
            XCTAssertEqual(value("sortBy"), "SortName")
            XCTAssertEqual(value("enableImages"), "false")
            XCTAssertNil(value("parentId"))
        }
        let boundary = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "nameStartsWithOrGreater" }?.value
        XCTAssertEqual(boundary, "b")
    }

    func testFunctionalAlphabetProbeRejectsMissingSortNameEmptyCatalogAndIncoherentCount() async {
        let initial =
            #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"The Zebra","SortName":"alpha"}],"StartIndex":0,"TotalRecordCount":2}"#
        let cases = [
            (#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#, initial, 2),
            (initial.replacingOccurrences(of: #","SortName":"alpha""#, with: ""), initial, 2),
            (initial.replacingOccurrences(of: "alpha", with: "zebra"), initial, 2),
            (initial, initial, 2),
            (
                initial,
                #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","SortName":"bravo"}],"StartIndex":0,"TotalRecordCount":2}"#,
                4
            ),
            (
                initial,
                #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":0,"TotalRecordCount":1}"#,
                4
            ),
            (initial, #"{"Items":[],"StartIndex":0,"TotalRecordCount":1}"#, 4),
            (
                initial,
                #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","SortName":"bravo"}],"StartIndex":0,"TotalRecordCount":3}"#,
                4
            ),
        ]
        for (first, filtered, count) in cases {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                let hasBoundary = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.contains { $0.name == "nameStartsWithOrGreater" }
                return (Data((hasBoundary ? filtered : first).utf8), Self.response(request))
            }
            let result = await library.alphabetCapability()
            XCTAssertEqual(result, .unavailable)
            let cached = await library.alphabetCapability()
            XCTAssertEqual(cached, .unavailable)
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, count)
        }
    }

    func testInconclusiveAlphabetProbeRetriesWhenCatalogFills() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if await recorder.requests.count == 1 {
                return (
                    Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                    Self.response(request)
                )
            }
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let empty = await library.alphabetCapability()
        XCTAssertEqual(empty, .unavailable)
        let filled = await library.alphabetCapability()
        XCTAssertEqual(filled, .verified)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testAlphabetWindowsAreBoundedScopedRelativeAndShareOneCapabilityRequest() async throws {
        let recorder = Recorder()
        let scope = "00000000000000000000000000000009"
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if let data = Self.alphabetProbeData(request) {
                return (data, Self.response(request))
            }
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let start = Int(query.first { $0.name == "startIndex" }?.value ?? "") ?? 0
            let json = #"{"Items":[],"TotalRecordCount":START,"StartIndex":START}"#
                .replacingOccurrences(of: "START", with: String(start))
            return (Data(json.utf8), Self.response(request))
        }
        await withTaskGroup(of: FoundationAlphabetCapability.self) { group in
            for _ in 0..<10 {
                group.addTask { await library.scoped(to: scope).alphabetCapability() }
            }
            for await value in group { XCTAssertEqual(value, .verified) }
        }
        for kind in [FoundationItem.Kind.album, .artist, .track, .playlist, .genre] {
            for offset in [0, 50] {
                _ = try await library.scoped(to: scope).alphabetPage(
                    kind: kind, letter: "F", startIndex: offset)
            }
        }
        let requests = await recorder.requests
        XCTAssertEqual(
            requests.filter { Self.alphabetProbeData($0) != nil }.count, 2)
        let pages = requests.filter { Self.alphabetProbeData($0) == nil }
        XCTAssertEqual(pages.count, 10)
        for (index, request) in pages.enumerated() {
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            XCTAssertEqual(value("nameStartsWithOrGreater"), "f")
            XCTAssertNil(value("nameStartsWith"))
            XCTAssertNil(value("nameLessThan"))
            XCTAssertEqual(value("startIndex"), index.isMultiple(of: 2) ? "0" : "50")
            XCTAssertEqual(value("limit"), "50")
            XCTAssertEqual(value("sortBy"), "SortName")
            XCTAssertEqual(value("sortOrder"), "Ascending")
            XCTAssertEqual(value("enableTotalRecordCount"), "true")
            XCTAssertEqual(value("parentId"), index / 2 == 3 ? nil : scope)
            XCTAssertEqual(value("userId"), session.userID)
            let path = request.url!.path
            if index / 2 == 1 {
                XCTAssertTrue(path.hasSuffix("/Artists/AlbumArtists"))
            } else if index / 2 == 4 {
                XCTAssertTrue(path.hasSuffix("/MusicGenres"))
            } else {
                XCTAssertTrue(path.hasSuffix("/Items"))
            }
        }
    }

    func testIgnoredAlphabetBoundaryDoesNotIssueUserCatalogSeek() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Self.alphabetProbeData(request, ignoresBoundary: true)!, Self.response(request))
        }
        for _ in 0..<2 {
            do {
                _ = try await library.alphabetPage(kind: .album, letter: "F", startIndex: 0)
                XCTFail("Unsupported server must not issue a seek")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotNil(Self.alphabetProbeData(requests[0]))
    }

    func testFailedAlphabetProbeCanExplicitlyRetryWithOneCoalescedAccountRequest() async {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let count = await recorder.requests.count
            if count == 1 { throw URLError(.notConnectedToInternet) }
            if count == 2 { await gate.suspend() }
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let failed = await library.alphabetCapability()
        XCTAssertEqual(failed, .unavailable)
        let retry = Task {
            await withTaskGroup(of: FoundationAlphabetCapability.self) { group in
                for _ in 0..<10 {
                    group.addTask { await library.alphabetCapability() }
                }
                for await value in group { XCTAssertEqual(value, .verified) }
            }
        }
        await gate.entered()
        await gate.release()
        await retry.value
        let cached = await library.alphabetCapability()
        XCTAssertEqual(cached, .verified)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { Self.alphabetProbeData($0) != nil })
    }

    func testFailedAlphabetProbeCachesResolvedUnsupportedFilterAfterExplicitRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if await recorder.requests.count == 1 { throw URLError(.timedOut) }
            return (Self.alphabetProbeData(request, ignoresBoundary: true)!, Self.response(request))
        }
        for _ in 0..<3 {
            let value = await library.alphabetCapability()
            XCTAssertEqual(value, .unavailable)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { Self.alphabetProbeData($0) != nil })
    }

    func testAlphabetMemoIsRetiredAtAccountEnd() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if let data = Self.alphabetProbeData(request) {
                return (data, Self.response(request))
            }
            return (Data(), Self.response(request, status: 204))
        }
        let initial = await library.alphabetCapability()
        XCTAssertEqual(initial, .verified)
        try await library.endSession()
        let ended = await library.scoped(to: itemID).alphabetCapability()
        XCTAssertEqual(ended, .unavailable)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testCancellingOneCapabilityWaiterKeepsAccountSingleflightAvailable() async {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if await recorder.requests.count == 1 { await gate.suspend() }
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let first = Task { await library.alphabetCapability() }
        await gate.entered()
        first.cancel()
        let scopeID = itemID
        let second = Task { await library.scoped(to: scopeID).alphabetCapability() }
        await gate.release()
        let result = await second.value
        XCTAssertEqual(result, .verified)
        _ = await first.value
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLogoutWhileCapabilityInflightRejectsLateCompletionAndNewReads() async throws {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if let data = Self.alphabetProbeData(request) {
                if await recorder.requests.count == 1 { await gate.suspend() }
                return (data, Self.response(request))
            }
            return (Data(), Self.response(request, status: 204))
        }
        let pending = Task { await library.alphabetCapability() }
        await gate.entered()
        try await library.endSession()
        await gate.release()
        let late = await pending.value
        XCTAssertEqual(late, .unavailable)
        let retired = await library.alphabetCapability()
        XCTAssertEqual(retired, .unavailable)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testAlphabetItemTypesAndProviderMappingPreserveAllFiveTypedIndexes() async throws {
        let recorder = Recorder()
        let types: [(FoundationItem.Kind, String)] = [
            (.album, "MusicAlbum"), (.artist, "MusicArtist"), (.track, "Audio"),
            (.playlist, "Playlist"), (.genre, "MusicGenre"),
        ]
        for (kind, type) in types {
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                if let data = Self.alphabetProbeData(request) {
                    return (data, Self.response(request))
                }
                let body =
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"TYPE","Name":"Synthetic F"}],"StartIndex":0,"TotalRecordCount":1}"#
                    .replacingOccurrences(of: "TYPE", with: type)
                return (Data(body.utf8), Self.response(request))
            }
            let page = try await library.alphabetPage(kind: kind, letter: "F", startIndex: 0)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.kind, kind)
            XCTAssertNil(page.nextStartIndex)
        }
        let requests = await recorder.requests
        let pages = requests.filter { Self.alphabetProbeData($0) == nil }
        for (index, request) in pages.enumerated() {
            let query =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let itemTypes = query.first { $0.name == "includeItemTypes" }?.value
            if index == 1 {
                XCTAssertNil(itemTypes)
            } else if index == 4 {
                let genreTypes = query.filter { $0.name == "includeItemTypes" }.compactMap(\.value)
                XCTAssertEqual(genreTypes, ["MusicAlbum", "Audio"])
            } else {
                XCTAssertEqual(itemTypes, types[index].1)
            }
        }
    }

    func testAlphabetEmptyTailIsCompleteButEmptyPositiveCountIsRejected() async throws {
        for (offset, total, valid) in [(0, 0, true), (50, 50, true), (0, 2, false)] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                if let data = Self.alphabetProbeData(request) {
                    return (data, Self.response(request))
                }
                let body = "{\"Items\":[],\"StartIndex\":OFFSET,\"TotalRecordCount\":TOTAL}"
                    .replacingOccurrences(of: "OFFSET", with: String(offset))
                    .replacingOccurrences(of: "TOTAL", with: String(total))
                return (Data(body.utf8), Self.response(request))
            }
            do {
                let page = try await library.alphabetPage(
                    kind: .album, letter: "Z", startIndex: offset)
                XCTAssertTrue(valid)
                XCTAssertTrue(page.items.isEmpty)
                XCTAssertNil(page.nextStartIndex)
            } catch {
                XCTAssertFalse(valid)
                XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse)
            }
        }
    }

    @MainActor
    func testAlphabetDuplicateSuppressionPreservesProviderRelativeCursor() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let first = FoundationItem(
            id: "first", title: "", subtitle: "", kind: .album, duration: nil)
        let next = FoundationItem(id: "next", title: "", subtitle: "", kind: .album, duration: nil)
        await model.loadPending { offset in
            XCTAssertEqual(offset, 0)
            return FoundationPage(items: [first, first], nextStartIndex: 2)
        }
        XCTAssertEqual(model.items.map(\.id), ["first"])
        XCTAssertEqual(model.nextStartIndex, 2)
        await model.loadNextPage { offset in
            XCTAssertEqual(offset, 2)
            return FoundationPage(items: [first, next], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["first", "next"])
        XCTAssertNil(model.nextStartIndex)
    }

    func testAlphabetCapabilityIsNotSharedAcrossAccountOwnedAdapters() async {
        let recorder = Recorder()
        let otherSession = FoundationSession(
            serverURL: session.serverURL, accessToken: "second-synthetic-token",
            userID: "00000000000000000000000000000004", deviceID: session.deviceID)
        let first = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let second = FoundationJellyfinLibrary(session: otherSession) { request in
            await recorder.append(request)
            return (Self.alphabetProbeData(request, ignoresBoundary: true)!, Self.response(request))
        }
        let supported = await first.alphabetCapability()
        let unsupported = await second.alphabetCapability()
        XCTAssertEqual(supported, .verified)
        XCTAssertEqual(unsupported, .unavailable)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 4)
    }

    @MainActor
    func testAlphabetScopeAndQueryInvalidationRejectStaleCompletion() async {
        for boundaryChange in ["scope", "query"] {
            let model = FoundationBrowseModel()
            model.configureCatalogPagination()
            let gate = FoundationAlphabetTestGate()
            let old = FoundationItem(
                id: "old", title: "", subtitle: "", kind: .album, duration: nil)
            let current = FoundationItem(
                id: boundaryChange, title: "", subtitle: "", kind: .album, duration: nil)
            let stale = Task {
                await model.loadPending { _ in
                    await gate.suspend()
                    return FoundationPage(items: [old], nextStartIndex: 50)
                }
            }
            await gate.entered()
            // This is the LibraryIndex ownership revocation on either scope or query change.
            model.clearRetainedData()
            stale.cancel()
            await model.loadPending { _ in
                FoundationPage(items: [current], nextStartIndex: nil)
            }
            await gate.release()
            await stale.value
            XCTAssertEqual(model.items.map(\.id), [boundaryChange])
            XCTAssertNil(model.nextStartIndex)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isLoading)
        }
    }

    @MainActor
    func testAlphabetMoreCancelledByKeyedViewOwnerCannotPublishOffscreen() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let first = FoundationItem(
            id: "first", title: "", subtitle: "", kind: .album, duration: nil)
        let offscreen = FoundationItem(
            id: "offscreen", title: "", subtitle: "", kind: .album, duration: nil)
        await model.loadPending { _ in FoundationPage(items: [first], nextStartIndex: 50) }
        let gate = FoundationAlphabetTestGate()
        // Native demand requests pending.more; the view's keyed task owns this await.
        model.request(.more)
        let viewTask = Task {
            await model.loadPending { offset in
                XCTAssertEqual(offset, 50)
                await gate.suspend()
                return FoundationPage(items: [offscreen], nextStartIndex: 100)
            }
        }
        await gate.entered()
        viewTask.cancel()  // SwiftUI cancels its keyed owner on disappear or identity change.
        await gate.release()
        await viewTask.value
        XCTAssertEqual(model.items.map(\.id), ["first"])
        XCTAssertEqual(model.nextStartIndex, 50)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
    }

    func testOfflineAlphabetReconnectNormalizesOtherAndUnsupportedWindowsToAll() {
        XCTAssertNil(FoundationAlphabetSelectionPolicy.onlineSelection("#", capability: .verified))
        XCTAssertNil(
            FoundationAlphabetSelectionPolicy.onlineSelection("#", capability: .unavailable))
        XCTAssertNil(
            FoundationAlphabetSelectionPolicy.onlineSelection("A", capability: .unavailable))
        XCTAssertNil(FoundationAlphabetSelectionPolicy.onlineSelection(nil, capability: .verified))
        XCTAssertEqual(
            FoundationAlphabetSelectionPolicy.onlineSelection("F", capability: .verified), "F")
    }

    func testAccountLifecycleHookRetiresActualAdapterWithoutLogoutTransport() async {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if await recorder.requests.count == 1 { await gate.suspend() }
            return (Self.alphabetProbeData(request)!, Self.response(request))
        }
        let scopeID = itemID
        let pending = Task { await library.scoped(to: scopeID).alphabetCapability() }
        await gate.entered()
        // This exact hook is called by App.open and successful local signOut.
        let retirement = FoundationAlphabetAccountLifecycle.retire(library)
        await retirement?.value
        await gate.release()
        let late = await pending.value
        let ended = await library.alphabetCapability()
        XCTAssertEqual(late, .unavailable)
        XCTAssertEqual(ended, .unavailable)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertNotNil(Self.alphabetProbeData(requests[0]))
    }

    func testLibraryCoverGridGeometryMatchesCompactWideAndAccessibilityViewports() {
        XCTAssertEqual(FoundationLibraryGridLayout.columnCount(width: 375, accessibility: false), 2)
        XCTAssertEqual(
            FoundationLibraryGridLayout.columnCount(width: 1024, accessibility: false), 6)
        XCTAssertEqual(FoundationLibraryGridLayout.columnCount(width: 375, accessibility: true), 1)
        XCTAssertEqual(FoundationLibraryGridLayout.columnCount(width: 1024, accessibility: true), 3)
        XCTAssertEqual(
            FoundationLibraryGridLayout.columnCount(
                width: 375, accessibility: false,
                nativeIndex: true), 2)
        XCTAssertEqual(
            FoundationLibraryGridLayout.placeholderCount(
                width: 375, height: 800,
                accessibility: false, textHeight: 72), 8)
        XCTAssertEqual(
            FoundationLibraryGridLayout.placeholderCount(
                width: 1024, height: 1000,
                accessibility: false, textHeight: 72), 30)
    }

    func testLibraryCoverGridGroupingPreservesEveryCanonicalItemAndPartialFinalRow() {
        let items = Array(0..<5)
        let rows = (0..<FoundationLibraryGridLayout.rowCount(itemCount: items.count, columns: 2))
            .map { row in
                Array(
                    items[
                        FoundationLibraryGridLayout.itemRange(
                            row: row, itemCount: items.count, columns: 2)])
            }
        XCTAssertEqual(rows, [[0, 1], [2, 3], [4]])
        XCTAssertEqual(rows.flatMap { $0 }, items)
        XCTAssertEqual(FoundationLibraryGridLayout.rowCount(itemCount: 0, columns: 2), 0)
        XCTAssertTrue(
            FoundationLibraryGridLayout.itemRange(row: 3, itemCount: 5, columns: 2).isEmpty)
    }

    func testLibraryCoverGridInvalidGeometryRemainsBounded() {
        XCTAssertEqual(
            FoundationLibraryGridLayout.columnCount(width: .nan, accessibility: false), 1)
        XCTAssertEqual(
            FoundationLibraryGridLayout.columnCount(width: .infinity, accessibility: false), 1)
        XCTAssertEqual(
            FoundationLibraryGridLayout.columnCount(
                width: .greatestFiniteMagnitude,
                accessibility: false), 100)
        XCTAssertEqual(
            FoundationLibraryGridLayout.placeholderCount(
                width: 375,
                height: .greatestFiniteMagnitude, accessibility: false, textHeight: 72), 200)
    }

    private let itemID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid/proxy/jellyfin/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "00000000-0000-0000-0000-000000000003")
    }

    @MainActor
    func testFailedPinCleanupPreventsServerAuthentication() async {
        var authenticated = false
        do {
            _ = try await FoundationSignInPolicy.authenticate {
                false
            } signIn: {
                authenticated = true
                return session
            }
            XCTFail("Expected local pin cleanup failure")
        } catch {
            XCTAssertTrue(error is FoundationPinStorageError)
        }
        XCTAssertFalse(authenticated)
    }

    func testRetainedArtworkRequestsEnforceIndependentDownloadNetworkPolicy() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request))
        }
        let album = FoundationItem(
            id: itemID, title: "", subtitle: "", kind: .album, duration: nil,
            primaryImageTag: "synthetic-tag")
        _ = try await library.downloadArtwork(for: album, size: 640, allowsCellular: false)
        _ = try await library.downloadArtwork(for: album, size: 640, allowsCellular: true)
        _ = try await library.artwork(for: album, size: 160)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests[0].allowsCellularAccess)
        XCTAssertFalse(requests[0].allowsExpensiveNetworkAccess)
        XCTAssertFalse(requests[0].allowsConstrainedNetworkAccess)
        XCTAssertTrue(requests[1].allowsCellularAccess)
        XCTAssertTrue(requests[1].allowsExpensiveNetworkAccess)
        XCTAssertFalse(requests[1].allowsConstrainedNetworkAccess)
        // Normal catalog image reads keep their existing independent policy.
        XCTAssertTrue(requests[2].allowsCellularAccess)
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.url?.absoluteString.contains(session.accessToken) ?? true)
        }
    }

    func testSessionEndUsesAuthenticatedFixedPathAndAcceptsNoContent() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request, status: 204))
        }
        try await library.endSession()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Sessions/Logout")
        XCTAssertTrue(request.url?.query?.isEmpty ?? true)
        XCTAssertFalse(request.url?.absoluteString.contains(session.accessToken) ?? true)
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Authorization")?.contains(session.accessToken)
                ?? false)
    }

    func testSessionEndFailureIsUnconfirmedWithoutRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.notConnectedToInternet)
        }
        do {
            try await library.endSession()
            XCTFail("Expected network failure")
        } catch {
            XCTAssertEqual(error as? FoundationLibraryError, .network)
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testSignOutPolicyClearsLocallyWithoutWaitingForServerAndReportsClearFailure() async {
        var order: [String] = []
        let offline = FoundationSignOutPolicy.begin {
            order.append("start")
            return Task { false }
        } clear: {
            order.append("clear")
        } clearPins: {
            order.append("pins")
            return true
        }
        XCTAssertTrue(offline.localCleared)
        XCTAssertTrue(offline.pinsCleared)
        XCTAssertEqual(order, ["start", "clear", "pins"])
        let serverAccepted = await offline.revocation.value
        XCTAssertFalse(serverAccepted)

        order.removeAll()
        let clearFailed = FoundationSignOutPolicy.begin {
            order.append("start")
            return Task { true }
        } clear: {
            order.append("clear")
            throw FoundationLibraryError.credentials
        } clearPins: {
            order.append("pins")
            return false
        }
        XCTAssertFalse(clearFailed.localCleared)
        XCTAssertFalse(clearFailed.pinsCleared)
        XCTAssertEqual(order, ["start", "clear"])

        let pinsFailed = FoundationSignOutPolicy.begin {
            Task { false }
        } clear: {
            // Local sign-out must still complete when pin storage rejects removal.
        } clearPins: {
            false
        }
        XCTAssertTrue(pinsFailed.localCleared)
        XCTAssertFalse(pinsFailed.pinsCleared)
    }

    func testAlbumAndTrackPagesUseOneRequestEachAndExplicitBounds() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(parts.queryItems)
            // Generated array parameters repeat keys, notably track sortBy.
            let startText = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            let start = try XCTUnwrap(Int(startText))
            let kind = try XCTUnwrap(query.first { $0.name == "includeItemTypes" }?.value)
            let body = """
                {"Items":[{"Id":"00000000000000000000000000000001","Name":"Synthetic","Type":"\(kind)","ImageTags":{"Primary":"synthetic-tag"}}],"StartIndex":\(start),"TotalRecordCount":200}
                """
            return (Data(body.utf8), Self.response(request))
        }
        let albums = try await library.albums(startIndex: 0)
        let tracks = try await library.tracks(albumID: itemID, startIndex: 100)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertNil(tracks.items.first?.primaryImageTag)
        XCTAssertEqual(albums.nextStartIndex, 1)
        XCTAssertEqual(tracks.nextStartIndex, 101)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(url.path, "/proxy/jellyfin/Items")
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(parts.queryItems)
            XCTAssertEqual(
                query.filter { $0.name == "limit" }.compactMap(\.value),
                [index == 0 ? "50" : "100"])
            XCTAssertEqual(
                query.filter { $0.name == "startIndex" }.compactMap(\.value),
                [index == 0 ? "0" : "100"])
            XCTAssertEqual(
                query.filter { $0.name == "includeItemTypes" }.compactMap(\.value),
                [index == 0 ? "MusicAlbum" : "Audio"])
            XCTAssertEqual(
                query.filter { $0.name == "sortBy" }.compactMap(\.value),
                index == 0 ? ["SortName"] : ["ParentIndexNumber", "IndexNumber", "SortName"])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testArtistPagesAndSelectedArtistAlbumsUseExplicitSinglePageRequests() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let url = try XCTUnwrap(request.url)
            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            let start = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            let kind = url.path.hasSuffix("AlbumArtists") ? "MusicArtist" : "MusicAlbum"
            return (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000001","Name":"Synthetic","Type":"\(kind)","ImageTags":{"Primary":"synthetic-tag"}}],"StartIndex":\(start),"TotalRecordCount":51}
                    """.utf8), Self.response(request)
            )
        }
        let first = try await library.artists(startIndex: 0)
        XCTAssertEqual(first.items.first?.kind, .artist)
        XCTAssertEqual(first.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(first.nextStartIndex, 1)
        let last = try await library.artists(startIndex: 50)
        XCTAssertNil(last.nextStartIndex)
        let albums = try await library.albums(artistID: itemID, startIndex: 0)
        XCTAssertEqual(albums.items.first?.kind, .album)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(albums.nextStartIndex, 1)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for (index, request) in requests.enumerated() {
            let url = try XCTUnwrap(request.url)
            XCTAssertEqual(
                url.path,
                index < 2 ? "/proxy/jellyfin/Artists/AlbumArtists" : "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ key: String) -> [String] {
                query.filter { $0.name == key }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), ["50"])
            XCTAssertEqual(values("startIndex"), [index == 1 ? "50" : "0"])
            XCTAssertEqual(values("sortBy"), ["SortName"])
            XCTAssertEqual(values("sortOrder"), ["Ascending"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
            XCTAssertEqual(values("enableImages"), ["true"])
            XCTAssertEqual(values("enableImageTypes"), ["Primary"])
            XCTAssertEqual(values("imageTypeLimit"), ["1"])
            XCTAssertEqual(values("enableUserData"), ["true"])
            XCTAssertEqual(values("albumArtistIds"), index < 2 ? [] : [itemID])
            XCTAssertTrue(values("parentId").isEmpty)
            XCTAssertEqual(values("includeItemTypes"), index < 2 ? [] : ["MusicAlbum"])
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testInvalidArtistScopeAndNegativeArtistPageStartNoTransport() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.albums(artistID: "../other", startIndex: 0)
            XCTFail("Expected invalid artist rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await library.artists(startIndex: -1)
            XCTFail("Expected invalid page rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testArtistPageFailureDoesNotRetryAndLaterAlbumReadSucceeds() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if request.url?.path.hasSuffix("AlbumArtists") == true { throw URLError(.timedOut) }
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }
        do {
            _ = try await library.artists(startIndex: 0)
            XCTFail("Expected artist failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let page = try await library.albums(artistID: itemID, startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextStartIndex)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testAlbumAndArtistArtworkUseOneTaggedBoundedAuthenticatedImageRequestEach() async throws {
        for kind in [FoundationItem.Kind.album, .artist, .playlist] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                return (Data([1, 2, 3]), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil,
                primaryImageTag: "synthetic-tag")
            let data = try await library.artwork(for: item)
            XCTAssertEqual(data, Data([1, 2, 3]))
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Primary")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            for expected in [
                URLQueryItem(name: "maxWidth", value: "160"),
                URLQueryItem(name: "maxHeight", value: "160"),
                URLQueryItem(name: "tag", value: "synthetic-tag"),
            ] {
                XCTAssertTrue(query.contains(expected))
            }
            XCTAssertFalse(query.contains { $0.name.lowercased() == "apikey" })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testArtistAndAlbumReferencesWithoutImageTagsMakeOneBoundedImageRequestEach() async throws {
        for kind in [FoundationItem.Kind.artist, .album] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                return (Data([1, 2, 3]), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
            let data = try await library.artwork(for: item, size: 640)
            XCTAssertEqual(data, Data([1, 2, 3]))
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Primary")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertFalse(query.contains { $0.name == "tag" })
            XCTAssertTrue(query.contains(URLQueryItem(name: "maxWidth", value: "640")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "maxHeight", value: "640")))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testUntaggedPlaylistsAndTracksMakeNoImageRequest() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        for kind in [FoundationItem.Kind.playlist, .track] {
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil,
                primaryImageTag: kind == .track ? "synthetic-tag" : nil)
            let data = try await library.artwork(for: item)
            XCTAssertNil(data)
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testImageFailureDoesNotRetryOrPreventLaterCatalogRead() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if request.url?.path.contains("Images") == true { throw URLError(.timedOut) }
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .album, duration: nil,
            primaryImageTag: "synthetic-tag")
        do {
            _ = try await library.artwork(for: item)
            XCTFail("Expected image failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let page = try await library.albums(startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 2)
    }

    func testPlaybackURLUsesNoTransportAndPreservesBasePath() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.unsupportedURL)
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        let url = try await library.playbackURL(for: item)
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(url.path, "/proxy/jellyfin/Audio/\(itemID)/universal")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains(URLQueryItem(name: "ApiKey", value: "synthetic-token")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "audioCodec", value: "aac")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "transcodingProtocol", value: "hls")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "transcodingContainer", value: "ts")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableRedirection", value: "false")))
        XCTAssertEqual(
            query.filter { $0.name == "container" }.compactMap(\.value),
            [
                "mp3", "aac", "mp4|aac|alac", "m4a|aac|alac", "flac",
                "wav|pcm_s16le|pcm_s24le", "aiff|pcm_s16be|pcm_s24be",
            ])
        XCTAssertFalse(query.contains { $0.name == "static" || $0.name == "allowAudioStreamCopy" })
    }

    func testSignInIsOnePostWithGeneratedBodyAndFractionalDates() async throws {
        let recorder = Recorder()
        let result = try await FoundationJellyfinLibrary.signIn(
            serverURL: session.serverURL,
            username: "synthetic", password: "synthetic"
        ) { request in
            await recorder.append(request)
            let body = """
                {"AccessToken":"synthetic-token","User":{"Id":"00000000000000000000000000000002","LastLoginDate":"2026-01-01T00:00:00.1234567Z"}}
                """
            return (Data(body.utf8), Self.response(request))
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url!.path, "/proxy/jellyfin/Users/AuthenticateByName")
        let body =
            try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: String]
        XCTAssertEqual(body["Username"], "synthetic")
        XCTAssertEqual(body["Pw"], "synthetic")
        XCTAssertEqual(result.accessToken, "synthetic-token")
    }

    func testFailureIsCategorizedAndNeverRetried() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.albums(startIndex: 0)
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 1)
    }

    func testUnauthorizedAndRedirectResponsesAreFiniteErrors() async {
        for (status, expected) in [
            (401, FoundationLibraryError.authentication), (302, .secureConnection),
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (Data(), Self.response(request, status: status))
            }
            do {
                _ = try await library.albums(startIndex: 0)
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, expected) }
        }
    }

    func testCancelledCallerStartsNoRequest() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data(), Self.response(request))
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await library.albums(startIndex: 0)
                XCTFail("Expected cancellation")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .cancelled) }
        }
        await task.value
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    func testInvalidServerAndInjectedPathAreRejectedWithoutTransport() async throws {
        for text in [
            "http://example.invalid", "https://user:pass@example.invalid",
            "https://example.invalid/?token=x",
        ] {
            XCTAssertThrowsError(
                try FoundationJellyfinLibrary.validatedServerURL(URL(string: text)!))
        }
        let library = FoundationJellyfinLibrary(session: session) { _ in
            XCTFail("Invalid IDs must not start requests")
            throw URLError(.unsupportedURL)
        }
        do {
            _ = try await library.tracks(albumID: "../other", startIndex: 0)
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testEmptyPageHasNoContinuation() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (
                Data("{\"Items\":[],\"StartIndex\":0,\"TotalRecordCount\":0}".utf8),
                Self.response(request)
            )
        }
        let page = try await library.albums(startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextStartIndex)
    }

    func testSongsPlaylistsAndFavoritesEachUseOneBoundedScopedPage() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            let types = query.filter { $0.name == "includeItemTypes" }.compactMap(\.value)
            let entries = types.enumerated().map { index, type in
                "{\"Id\":\"0000000000000000000000000000000\(index + 1)\",\"Type\":\"\(type)\",\"ImageTags\":{\"Primary\":\"synthetic-tag\"}}"
            }.joined(separator: ",")
            return (
                Data("{\"Items\":[\(entries)],\"StartIndex\":50,\"TotalRecordCount\":200}".utf8),
                Self.response(request)
            )
        }
        let songs = try await library.songs(startIndex: 50)
        let playlists = try await library.playlists(startIndex: 50)
        let favorites = try await library.favorites(startIndex: 50)
        XCTAssertEqual(songs.items.map(\.kind), [.track])
        XCTAssertNil(songs.items.first?.primaryImageTag)
        XCTAssertEqual(playlists.items.map(\.kind), [.playlist])
        XCTAssertEqual(playlists.items.first?.primaryImageTag, "synthetic-tag")
        XCTAssertEqual(favorites.items.map(\.kind), [.track, .album, .artist, .playlist])
        XCTAssertEqual(favorites.nextStartIndex, 54)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ name: String) -> [String] {
                query.filter { $0.name == name }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), [index == 0 ? "100" : "50"])
            XCTAssertEqual(values("startIndex"), ["50"])
            XCTAssertEqual(values("recursive"), ["true"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("isFavorite"), index == 2 ? ["true"] : [])
            XCTAssertEqual(values("sortBy"), ["SortName"])
            XCTAssertEqual(values("enableImages"), ["true"])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
        }
    }

    func testPlaylistItemsPreserveServerOrderAndDuplicatesWithOneExplicitPage() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio"},{"Id":"00000000000000000000000000000001","Type":"Audio"},{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":100,"TotalRecordCount":200}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.playlistTracks(playlistID: itemID, startIndex: 100)
        XCTAssertEqual(
            page.items.map(\.id),
            ["00000000000000000000000000000002", itemID, "00000000000000000000000000000002"])
        XCTAssertEqual(page.nextStartIndex, 103)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Playlists/\(itemID)/Items")
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: session.userID)))
        XCTAssertTrue(query.contains(URLQueryItem(name: "startIndex", value: "100")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "100")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableImages", value: "true")))
        XCTAssertFalse(query.contains { $0.name == "sortBy" })
    }

    func testInvalidPlaylistIDStartsNoRequestAndFavoritesFailureDoesNotRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.playlistTracks(playlistID: "../other", startIndex: 0)
            XCTFail("Expected invalid playlist rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0)
        do {
            _ = try await library.favorites(startIndex: 0)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let after = await recorder.requests.count
        XCTAssertEqual(after, 1)
    }

    func testMixedFavoritesRejectUnsupportedServerTypes() async {
        let library = FoundationJellyfinLibrary(session: session) { request in
            (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Movie"}],"StartIndex":0,"TotalRecordCount":1}"#
                        .utf8), Self.response(request)
            )
        }
        do {
            _ = try await library.favorites(startIndex: 0)
            XCTFail("Expected unsupported type rejection")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
    }

    func testFavoriteMutationUsesOneExplicitPostOrDeleteAndChecksServerResult() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let favorite = request.httpMethod == "POST"
            return (
                Data("{\"Key\":\"synthetic-key\",\"IsFavorite\":\(favorite)}".utf8),
                Self.response(request)
            )
        }
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        try await library.setFavorite(for: item, isFavorite: true)
        try await library.setFavorite(for: item, isFavorite: false)
        let requests = await recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "DELETE"])
        for request in requests {
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/UserFavoriteItems/\(itemID)")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(query.contains(URLQueryItem(name: "userId", value: session.userID)))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testFavoriteMutationFailureIsNotRetriedOrReportedAsSuccess() async {
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .album, duration: nil)
        for timeout in [true, false] {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                if timeout { throw URLError(.timedOut) }
                return (
                    Data(#"{"Key":"synthetic-key","IsFavorite":false}"#.utf8),
                    Self.response(request)
                )
            }
            do {
                try await library.setFavorite(for: item, isFavorite: true)
                XCTFail("Expected failure")
            } catch {
                XCTAssertEqual(
                    error as? FoundationLibraryError, timeout ? .network : .invalidResponse)
            }
            let count = await recorder.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testCatalogHydratesOptionalFavoriteWithoutExtraRequests() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","UserData":{"Key":"synthetic-key","IsFavorite":true}},{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":0,"TotalRecordCount":2}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.songs(startIndex: 0)
        XCTAssertEqual(page.items.map(\.isFavorite), [true, nil])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let query = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "enableUserData", value: "true")))
    }

    func testMostPlayedAlbumsGroupsOneBoundedTrackSampleWithoutPaging() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            for (name, value) in [
                ("limit", "100"), ("startIndex", "0"), ("includeItemTypes", "Audio"),
                ("sortBy", "PlayCount"), ("sortOrder", "Descending"), ("isPlayed", "true"),
            ] {
                XCTAssertTrue(query.contains(URLQueryItem(name: name, value: value)))
            }
            var items: [[String: Any]] = (1...14).map { index in
                [
                    "Id": String(format: "%032d", index), "Type": "Audio",
                    "AlbumId": String(format: "%032d", index + 100), "Album": "Synthetic \(index)",
                    "UserData": ["Key": "synthetic", "PlayCount": 20 - index],
                ]
            }
            // Two occurrences from the same album combine, without duplicate cards.
            items.append([
                "Id": String(format: "%032d", 30), "Type": "Audio",
                "AlbumId": String(format: "%032d", 102), "Album": "Synthetic 2",
                "UserData": ["Key": "synthetic", "PlayCount": 18],
            ])
            items.append([
                "Id": String(format: "%032d", 31), "Type": "Audio",
                "UserData": ["Key": "synthetic", "PlayCount": 100],
            ])
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": items, "StartIndex": 0, "TotalRecordCount": 1000,
            ])
            return (data, Self.response(request))
        }
        let page = try await library.mostPlayedAlbums()
        XCTAssertEqual(page.items.count, 12)
        XCTAssertEqual(page.items.first?.title, "Synthetic 2")
        XCTAssertEqual(page.items.first?.playCount, 36)
        XCTAssertTrue(page.items.allSatisfy { $0.kind == .album })
        XCTAssertEqual(Set(page.items.map(\.id)).count, 12)
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testRecentAlbumsAndTracksUseOneDateDescendingPageEachAndServerCursor() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            let type = try XCTUnwrap(query.first { $0.name == "includeItemTypes" }?.value)
            let start = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            return (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000001","Type":"\(type)","ImageTags":{"Primary":"synthetic"},"GenreItems":[{"Id":"00000000000000000000000000000009","Name":"Synthetic Genre"}],"UserData":{"Key":"synthetic","IsFavorite":true}}],"StartIndex":\(start),"TotalRecordCount":25}
                    """.utf8), Self.response(request)
            )
        }
        let albums = try await library.recentAlbums(startIndex: 0)
        let tracks = try await library.recentTracks(startIndex: 24)
        XCTAssertEqual(albums.items.first?.kind, .album)
        XCTAssertEqual(albums.items.first?.primaryImageTag, "synthetic")
        XCTAssertEqual(albums.nextStartIndex, 1)
        XCTAssertEqual(albums.items.first?.genres.first?.title, "Synthetic Genre")
        XCTAssertEqual(tracks.items.first?.kind, .track)
        XCTAssertNil(tracks.items.first?.primaryImageTag)
        XCTAssertNil(tracks.nextStartIndex)
        XCTAssertEqual(tracks.items.first?.isFavorite, true)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            func values(_ name: String) -> [String] {
                query.filter { $0.name == name }.compactMap(\.value)
            }
            XCTAssertEqual(values("limit"), ["24"])
            XCTAssertEqual(values("startIndex"), [index == 0 ? "0" : "24"])
            XCTAssertEqual(values("includeItemTypes"), [index == 0 ? "MusicAlbum" : "Audio"])
            XCTAssertEqual(values("fields"), index == 0 ? ["Genres"] : [])
            XCTAssertEqual(values("sortBy"), ["DateCreated"])
            XCTAssertEqual(values("sortOrder"), ["Descending"])
            XCTAssertEqual(values("recursive"), ["true"])
            XCTAssertEqual(values("userId"), [session.userID])
            XCTAssertEqual(values("enableTotalRecordCount"), ["true"])
            XCTAssertEqual(values("enableUserData"), ["true"])
        }
    }

    func testRecentInvalidOffsetsMakeNoRequestsAndFailureDoesNotRetry() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            throw URLError(.timedOut)
        }
        do {
            _ = try await library.recentAlbums(startIndex: -1)
            XCTFail("Expected invalid offset")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        do {
            _ = try await library.recentTracks(startIndex: -1)
            XCTFail("Expected invalid offset")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0)
        do {
            _ = try await library.recentAlbums(startIndex: 0)
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .network) }
        let after = await recorder.requests.count
        XCTAssertEqual(after, 1)
    }

    func testScopedPlaylistAndGenreSearchUsesFullServerPages() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let components = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
            let query = try XCTUnwrap(components.queryItems)
            let start = try XCTUnwrap(query.first { $0.name == "startIndex" }?.value)
            let type = request.url!.path.hasSuffix("MusicGenres") ? "MusicGenre" : "Playlist"
            return (
                Data(
                    """
                    {"Items":[{"Id":"00000000000000000000000000000001","Name":"Beyond first page","Type":"\(type)","ImageTags":{"Primary":"synthetic"}}],"StartIndex":\(start),"TotalRecordCount":101}
                    """.utf8), Self.response(request)
            )
        }
        for kind in [FoundationItem.Kind.playlist, .genre] {
            let page = try await library.search(
                query: "  Beyond  ", kind: kind, startIndex: 50, limit: 25)
            XCTAssertEqual(page.items.first?.kind, kind)
            XCTAssertEqual(page.items.first?.primaryImageTag, "synthetic")
            XCTAssertEqual(page.nextStartIndex, 51)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            XCTAssertEqual(
                request.url?.path,
                index == 0 ? "/proxy/jellyfin/Items" : "/proxy/jellyfin/MusicGenres")
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            for (name, value) in [
                ("searchTerm", "Beyond"), ("startIndex", "50"), ("limit", "25"),
                ("sortBy", "SortName"), ("enableTotalRecordCount", "true"),
            ] {
                XCTAssertTrue(query.contains(URLQueryItem(name: name, value: value)))
            }
            if index == 0 {
                XCTAssertTrue(
                    query.contains(URLQueryItem(name: "includeItemTypes", value: "Playlist")))
            }
        }
        let empty = try await library.search(query: "  ", kind: .genre, startIndex: 0, limit: 25)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.nextStartIndex)
        let finalCount = await recorder.requests.count
        XCTAssertEqual(finalCount, 2)
    }

    /// SortName deliberately differs from display title to cover article-aware provider sorting.
    private static func alphabetProbeData(_ request: URLRequest, ignoresBoundary: Bool = false)
        -> Data?
    {
        let query =
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.contains(where: { $0.name == "limit" && $0.value == "1" }),
            query.contains(where: { $0.name == "fields" && $0.value == "SortName" })
        else { return nil }
        let filtered = !ignoresBoundary && query.contains { $0.name == "nameStartsWithOrGreater" }
        let body =
            filtered
            ? #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","Name":"The Apple","SortName":"bravo"}],"StartIndex":0,"TotalRecordCount":1}"#
            : #"{"Items":[{"Id":"00000000000000000000000000000001","Type":"Audio","Name":"The Zebra","SortName":"alpha"}],"StartIndex":0,"TotalRecordCount":2}"#
        return Data(body.utf8)
    }

    private static func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private actor Recorder {
    var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

@MainActor
final class FoundationBrowsePaginationTests: XCTestCase {
    private func item(_ id: String, kind: FoundationItem.Kind = .album) -> FoundationItem {
        FoundationItem(id: id, title: id, subtitle: "", kind: kind, duration: nil)
    }

    func testCatalogDedupKeepsRawCursorAndOrderingWhileDetailsKeepOccurrences() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.loadPending { _ in
            .init(items: [self.item("a"), self.item("a")], nextStartIndex: 2)
        }
        var offsets: [Int] = []
        await model.loadNextPage { offset in
            offsets.append(offset)
            return .init(
                items: [self.item("a"), self.item("b"), self.item("a", kind: .artist)],
                nextStartIndex: nil)
        }
        await model.loadNextPage { _ in
            XCTFail("End must stop requests")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(offsets, [2])
        XCTAssertEqual(
            model.items.map { $0.kind.rawValue + ":" + $0.id }, ["album:a", "album:b", "artist:a"])
        let details = FoundationBrowseModel()
        await details.loadPending { _ in
            .init(items: [self.item("same", kind: .track)], nextStartIndex: 1)
        }
        await details.loadNextPage { _ in
            .init(items: [self.item("same", kind: .track)], nextStartIndex: nil)
        }
        XCTAssertEqual(details.items.count, 2)
    }

    func testDemandGatesAndMalformedCursorRequireExplicitRetry() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.loadPending { _ in .init(items: [self.item("a")], nextStartIndex: 1) }
        var calls = 0
        let loader: (Int) async throws -> FoundationPage = { offset in
            calls += 1
            return .init(items: [self.item("b")], nextStartIndex: offset)
        }
        await model.loadNextPage(ifActive: false, using: loader)
        await model.loadNextPage(allowsNetwork: false, using: loader)
        XCTAssertEqual(calls, 0)
        await model.loadNextPage(using: loader)
        XCTAssertEqual(model.errorCategory, .invalidResponse)
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.nextStartIndex, 1)
        await model.loadNextPage(using: loader)
        XCTAssertEqual(calls, 1)
        model.request(model.retryRequest)
        await model.loadPending { offset in
            XCTAssertEqual(offset, 1)
            return .init(items: [self.item("b")], nextStartIndex: nil)
        }
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
        XCTAssertNil(model.errorMessage)
    }

    func testCatalogCacheRetainsRawPrefixAndResumesCorrectOffsetAfterRelaunch() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "synthetic-account/server", root: directory)
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        model.configureCache(cache, key: "library.albums")
        await model.loadPending { _ in
            .init(items: (0..<100).map { self.item(String($0 / 2)) }, nextStartIndex: 100)
        }
        await model.loadNextPage { _ in
            .init(items: (100..<200).map { self.item(String($0 / 2)) }, nextStartIndex: 200)
        }
        await model.loadNextPage { _ in
            .init(items: [self.item("last")], nextStartIndex: nil)
        }
        let restored = FoundationBrowseModel()
        restored.configureCatalogPagination()
        restored.configureCache(cache, key: "library.albums")
        await restored.loadPending(allowsNetwork: false) { _ in
            XCTFail("Offline cache restore must not read server")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(restored.items.count, 100)
        XCTAssertEqual(restored.nextStartIndex, 200)
        await restored.loadNextPage { offset in
            XCTAssertEqual(offset, 200)
            return .init(items: [self.item("last")], nextStartIndex: nil)
        }
        XCTAssertEqual(restored.items.last?.id, "last")
        XCTAssertNil(restored.nextStartIndex)
    }

    func testEmptyNonterminalCatalogPageRetainsRowsWithoutAutomaticRetry() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.loadPending { _ in .init(items: [self.item("a")], nextStartIndex: 1) }
        await model.loadNextPage { _ in .init(items: [], nextStartIndex: 2) }
        XCTAssertEqual(model.errorCategory, .invalidResponse)
        XCTAssertEqual(model.items.map(\.id), ["a"])
        await model.loadNextPage { _ in
            XCTFail("Invalid page must require explicit retry")
            return .init(items: [], nextStartIndex: nil)
        }
    }

    func testConcurrentDemandAndCancelledResponseCannotDuplicateOrPublish() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        await model.loadPending { _ in .init(items: [self.item("a")], nextStartIndex: 1) }
        var continuation: CheckedContinuation<FoundationPage, Never>?
        var calls = 0
        let task = Task {
            await model.loadNextPage { _ in
                calls += 1
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        await model.loadNextPage { _ in
            calls += 1
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(calls, 1)
        task.cancel()
        continuation?.resume(returning: .init(items: [item("stale")], nextStartIndex: nil))
        await task.value
        XCTAssertEqual(model.items.map(\.id), ["a"])
        XCTAssertEqual(model.nextStartIndex, 1)
        XCTAssertFalse(model.isLoading)
        await model.loadNextPage { _ in .init(items: [self.item("b")], nextStartIndex: nil) }
        XCTAssertEqual(model.items.map(\.id), ["a", "b"])
    }
}

/// Controlled synthetic transport suspension; no clock-dependent race or real network.
private actor FoundationAlphabetTestGate {
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            blocked = continuation
            observer?.resume()
            observer = nil
        }
    }

    func entered() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}

#if os(iOS)
    @MainActor
    final class FoundationAlphabetTableLayoutTests: XCTestCase {
        private func section(_ letter: String, count: Int) -> FoundationAlphabetSection {
            .init(
                id: letter, title: letter, availability: .loaded,
                rows: (0..<count).map { index in
                    let id = letter + "-" + String(index)
                    return .init(
                        id: id,
                        item: FoundationItem(
                            id: id, title: id, subtitle: "", kind: .track, duration: nil))
                })
        }

        private func view(_ sections: [FoundationAlphabetSection])
            -> FoundationLibraryAlphabetIndex<Text>
        {
            FoundationLibraryAlphabetIndex(
                contextID: "synthetic-layout", sections: sections,
                onDemandNextPage: {}, onRefresh: {}, row: { Text($0.item.title) })
        }

        func testDistantRailLandingSurvivesHostedLayoutAndSortedPageReload() async throws {
            let initial = view([
                section("A", count: 30), section("M", count: 30), section("Z", count: 30),
            ])
            let coordinator = initial.makeCoordinator()
            let table = initial.makeTable(coordinator: coordinator)
            let controller = UIViewController()
            guard
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }
                ).first
            else {
                throw XCTSkip("A connected host scene is required for native table layout")
            }
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
            window.rootViewController = controller
            table.frame = window.bounds
            controller.view.addSubview(table)
            window.isHidden = false
            defer { window.isHidden = true }
            initial.updateTable(table, coordinator: coordinator)
            XCTAssertEqual(table.estimatedRowHeight, 0)
            XCTAssertEqual(table.estimatedSectionHeaderHeight, 0)
            XCTAssertEqual(table.selfSizingInvalidation, .disabled)

            var jump = initial
            jump.anchorRowID = "M-0"
            jump.anchorRevision = 1
            jump.updateTable(table, coordinator: coordinator)
            // Let the real deferred rail callback run, then force subsequent hosted layout.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            table.layoutIfNeeded()
            let landed = try XCTUnwrap(coordinator.visibleAnchor(in: table))
            XCTAssertEqual(landed.rowID, "M-0")
            let landedOffset = table.contentOffset.y
            table.setNeedsLayout()
            table.layoutIfNeeded()
            XCTAssertEqual(table.contentOffset.y, landedOffset, accuracy: 0.5)

            var appended = view([
                section("A", count: 30), section("B", count: 25),
                section("M", count: 30), section("Z", count: 30),
            ])
            appended.anchorRowID = "M-0"
            appended.anchorRevision = 1
            appended.updateTable(table, coordinator: coordinator)
            table.setNeedsLayout()
            table.layoutIfNeeded()
            let retained = try XCTUnwrap(coordinator.visibleAnchor(in: table))
            XCTAssertEqual(retained.rowID, landed.rowID)
            XCTAssertEqual(retained.offsetFromTop, landed.offsetFromTop, accuracy: 0.5)
            XCTAssertGreaterThan(table.contentOffset.y, landedOffset)
        }
    }
#endif
