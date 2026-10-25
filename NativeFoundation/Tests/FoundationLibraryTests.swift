import Foundation
import JellyfinAPI
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import SwiftUI
    import UIKit
#endif

final class FoundationLibraryTests: XCTestCase {
    func testCatalogAdapterAdmissionProtectsPlayReadsAndNeverGatesAudioURL() async throws {
        let admission = FoundationNetworkAdmission(limit: 2)
        let heldBrowse = try await admission.acquire()
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(
            session: session,
            load: { request in
                await recorder.append(request)
                return (
                    Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8),
                    Self.response(request)
                )
            }, networkAdmission: admission)
        let browsing = Task { try await library.songs(startIndex: 0) }
        try await waitForPending(admission, count: 1)
        let track = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        let audio = try await library.playbackURL(for: track)
        XCTAssertTrue(audio.path.hasSuffix("/universal"))
        let before = await recorder.requests.count
        XCTAssertEqual(before, 0)
        let protected = try await FoundationRequestIntent.$isPlayback.withValue(true) {
            try await library.songs(startIndex: 0)
        }
        XCTAssertTrue(protected.items.isEmpty)
        let afterProtected = await recorder.requests.count
        XCTAssertEqual(afterProtected, 1)
        await admission.release(heldBrowse)
        _ = try await browsing.value
        let finalCount = await recorder.requests.count
        XCTAssertEqual(finalCount, 2)
    }

    func testPlaybackAdmissionReservesCapacityWithoutRankingBrowsing() async throws {
        let admission = FoundationNetworkAdmission(limit: 3)
        let first = try await admission.acquire()
        let second = try await admission.acquire()
        let queued = Task { try await admission.acquire() }
        try await waitForPending(admission, count: 1)
        let protected = try await FoundationRequestIntent.$isPlayback.withValue(true) {
            try await admission.acquire()
        }
        let peak = await admission.activeCount
        XCTAssertEqual(peak, 3)
        await admission.release(first)
        let third = try await queued.value
        await admission.release(second)
        await admission.release(third)
        await admission.release(protected)
        let remaining = await admission.activeCount
        XCTAssertEqual(remaining, 0)
    }

    func testPlaybackProtectionLimitsBrowsingButAllowsProgressAndRejectsStaleState() async throws {
        let admission = FoundationNetworkAdmission(limit: 4)
        await admission.updatePlaybackProtection(true, revision: 2)
        let first = try await admission.acquire()
        let queued = Task { try await admission.acquire() }
        try await waitForPending(admission, count: 1)
        await admission.updatePlaybackProtection(false, revision: 1)
        let pending = await admission.pendingCount
        XCTAssertEqual(pending, 1)
        await admission.release(first)
        let next = try await queued.value
        let another = Task { try await admission.acquire() }
        try await waitForPending(admission, count: 1)
        await admission.updatePlaybackProtection(false, revision: 3)
        let resumed = try await another.value
        await admission.release(next)
        await admission.release(resumed)
    }

    func testAdmissionCancellationAndAccountRetirementReleaseWaiters() async throws {
        let admission = FoundationNetworkAdmission(limit: 2)
        let first = try await admission.acquire()
        let cancelled = Task { try await admission.acquire() }
        try await waitForPending(admission, count: 1)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Cancelled admission succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let retired = Task { try await admission.acquire() }
        try await waitForPending(admission, count: 1)
        await admission.retire()
        do {
            _ = try await retired.value
            XCTFail("Retired admission succeeded")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        await admission.release(first)
        let active = await admission.activeCount
        let pending = await admission.pendingCount
        XCTAssertEqual(active, 0)
        XCTAssertEqual(pending, 0)
        do {
            _ = try await admission.acquire()
            XCTFail("Retired owner admitted new work")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func waitForPending(_ admission: FoundationNetworkAdmission, count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await admission.pendingCount != count {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
    }

    func testArtistMetadataPublishesWhileSuggestedSongsTransportIsSuspended() async throws {
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            if request.url?.path.hasSuffix("/Items") == true {
                await gate.suspend()
                return (
                    Data(#"{"Items":[],"TotalRecordCount":0,"StartIndex":0}"#.utf8),
                    Self.response(request)
                )
            }
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Artist","Overview":"Ready before songs"}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let songs = Task { try await library.suggestedSongs(artistID: artist.id) }
        await gate.entered()
        let overview = try await library.overview(for: artist)
        let cached = await library.cachedArtistDetails(for: artist)
        XCTAssertEqual(overview, "Ready before songs")
        XCTAssertEqual(cached?.overview, overview)
        await gate.release()
        let result = try await songs.value
        XCTAssertTrue(result.items.isEmpty)
    }

    func testArtistCachePeekNeverWaitsForPendingTransport() async throws {
        let memo = FoundationArtistDetailMemo()
        let gate = FoundationAlphabetTestGate()
        let artist = FoundationItem(
            id: "artist", title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let request = Task {
            try await memo.value(key: "artist", revision: "current") {
                await gate.suspend()
                return .init(item: artist, overview: "About")
            }
        }
        await gate.entered()
        let pending = await memo.cachedValue(key: "artist", revision: "current")
        XCTAssertNil(pending, "A cache miss returns while the network is still suspended")
        await gate.release()
        _ = try await request.value
        let ready = await memo.cachedValue(key: "artist", revision: "current")
        XCTAssertEqual(ready?.overview, "About")
        let changed = await memo.cachedValue(key: "artist", revision: "changed")
        XCTAssertNil(changed, "Refreshed branding must not hydrate stale metadata")
        await memo.invalidate(key: "artist")
        let invalidated = await memo.cachedValue(key: "artist", revision: "current")
        XCTAssertNil(invalidated)
    }

    func testArtistCachedDetailsAreProviderNeutralAndAccountLifetimeBounded() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Artist","Overview":"About"}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let missing = await library.cachedArtistDetails(for: artist)
        XCTAssertNil(missing)
        var requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty, "A cache-only read does not start transport")
        _ = try await library.overview(for: artist)
        let cached = await library.cachedArtistDetails(for: artist)
        XCTAssertEqual(cached?.item.id, artist.id)
        XCTAssertEqual(cached?.overview, "About")
        requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        await library.retireAlphabetCapability()
        let retired = await library.cachedArtistDetails(for: artist)
        XCTAssertNil(retired, "Retired accounts cannot rehydrate their old metadata")
    }

    func testArtistDetailsAndOverviewShareOneReadAndExplicitInvalidationRefreshes() async throws {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if await recorder.requests.count == 1 { await gate.suspend() }
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Synthetic Artist","Overview":" About the artist ","ImageTags":{"Logo":"logo-revision"}}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        async let details = library.itemDetails(for: artist)
        async let overview = library.overview(for: artist)
        await gate.entered()
        await gate.release()
        let (item, text) = try await (details, overview)
        XCTAssertEqual(item?.logoImageTag, "logo-revision")
        XCTAssertEqual(text, "About the artist")
        _ = try await library.itemDetails(for: artist)
        var requests = await recorder.requests
        XCTAssertEqual(
            requests.count, 1, "All metadata consumers share the successful artist snapshot")
        await library.invalidateItemDetails(for: artist)
        _ = try await library.overview(for: artist)
        requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testRefreshedArtistImageTagsBypassRetainedMetadata() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let body =
                "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"MusicArtist\",\"Name\":\"Artist\"}"
            return (Data(body.utf8), Self.response(request))
        }
        var artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        _ = try await library.itemDetails(for: artist)
        artist.logoImageTag = "changed-tag"
        _ = try await library.itemDetails(for: artist)
        _ = try await library.overview(for: artist)
        let requests = await recorder.requests
        XCTAssertEqual(
            requests.count, 2, "Fresh image metadata must not be masked by the prior snapshot")
    }

    func testArtistDetailFailureIsNotCachedAndAccountRetirementRejectsReads() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let count = await recorder.requests.count
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Artist","Overview":"Recovered"}"#
                        .utf8),
                Self.response(request, status: count == 1 ? 503 : 200)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        do {
            _ = try await library.overview(for: artist)
            XCTFail("Failed metadata must remain an error")
        } catch {}
        let recovered = try await library.overview(for: artist)
        XCTAssertEqual(recovered, "Recovered")
        await library.retireAlphabetCapability()
        do {
            _ = try await library.itemDetails(for: artist)
            XCTFail("Retired account must not serve retained metadata")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testArtistDetailSnapshotsRemainAccountLocal() async throws {
        let recorder = Recorder()
        let load: FoundationJellyfinLibrary.Load = { request in
            await recorder.append(request)
            return (
                Data(
                    #"{"Id":"00000000000000000000000000000001","Type":"MusicArtist","Name":"Artist","Overview":"About"}"#
                        .utf8),
                Self.response(request)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let first = FoundationJellyfinLibrary(session: session, load: load)
        let second = FoundationJellyfinLibrary(session: session, load: load)
        _ = try await first.overview(for: artist)
        _ = try await second.overview(for: artist)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2, "Separate account lifetimes never share metadata")
    }

    func testCancelledArtistReadDoesNotPublishOverItsReplacement() async throws {
        let memo = FoundationArtistDetailMemo()
        let gate = FoundationAlphabetTestGate()
        let old = FoundationItem(
            id: "artist", title: "Old", subtitle: "", kind: .artist, duration: nil)
        let replacement = FoundationItem(
            id: "artist", title: "Current", subtitle: "", kind: .artist, duration: nil)
        let first = Task {
            try await memo.value(key: "artist") {
                await gate.suspend()
                return .init(item: old, overview: "Old")
            }
        }
        await gate.entered()
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("The cancelled consumer must finish without waiting for transport")
        } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await memo.value(key: "artist") {
            .init(item: replacement, overview: "Current")
        }
        XCTAssertEqual(current.item.title, "Current")
        await gate.release()
        let retained = try await memo.value(key: "artist") {
            XCTFail("Successful replacement should be retained")
            return .init(item: old, overview: nil)
        }
        XCTAssertEqual(retained.item.title, "Current")
    }

    func testArtistFavoriteMutationInvalidatesRetainedMetadata() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let count = await recorder.requests.count
            let body =
                request.httpMethod == "POST"
                ? #"{"Key":"synthetic","IsFavorite":true}"#
                : "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"MusicArtist\",\"Name\":\"Artist\",\"UserData\":{\"Key\":\"synthetic\",\"IsFavorite\":\(count > 1)}}"
            return (Data(body.utf8), Self.response(request))
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let initial = try await library.itemDetails(for: artist)
        XCTAssertEqual(initial?.isFavorite, false)
        try await library.setFavorite(for: artist, isFavorite: true)
        let updated = try await library.itemDetails(for: artist)
        XCTAssertEqual(updated?.isFavorite, true)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testArtistFavoriteMutationLetsVisibleMetadataFinishWithoutCachingStaleRead() async throws {
        let recorder = Recorder()
        let gate = FoundationAlphabetTestGate()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let count = await recorder.requests.count
            if request.httpMethod == "POST" {
                return (
                    Data(#"{"Key":"synthetic","IsFavorite":true}"#.utf8), Self.response(request)
                )
            }
            if count == 1 { await gate.suspend() }
            let body =
                "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"MusicArtist\",\"Name\":\"Artist\",\"Overview\":\"About\",\"UserData\":{\"Key\":\"synthetic\",\"IsFavorite\":\(count > 1)}}"
            return (Data(body.utf8), Self.response(request))
        }
        let artist = FoundationItem(
            id: itemID, title: "Artist", subtitle: "", kind: .artist, duration: nil)
        let visibleRead = Task { try await library.itemDetails(for: artist) }
        await gate.entered()
        try await library.setFavorite(for: artist, isFavorite: true)
        let fresh = try await library.itemDetails(for: artist)
        XCTAssertEqual(fresh?.isFavorite, true)
        await gate.release()
        let visible = try await visibleRead.value
        XCTAssertEqual(
            visible?.isFavorite, false,
            "Existing consumers finish; favorite sequencing rejects their stale favorite observation"
        )
        let retained = try await library.itemDetails(for: artist)
        XCTAssertEqual(
            retained?.isFavorite, true, "Old completion must not replace the post-mutation snapshot"
        )
        let overview = try await library.overview(for: artist)
        XCTAssertEqual(overview, "About")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
    }

    @MainActor
    func testNewTracksScopeResetRestoresDateAddedFeedWithoutLegacyOrOtherLibrarySongs() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "synthetic-new-tracks", root: directory)
        let library = FoundationJellyfinLibrary(
            session: session,
            load: { _ in
                XCTFail("Offline scope restoration must not contact the server")
                throw FoundationLibraryError.network
            }, catalogPageCache: cache)
        let model = FoundationBrowseModel()
        let legacy = FoundationItem(
            id: "legacy", title: "Legacy", subtitle: "", kind: .track, duration: nil)
        for scope in ["first", "second", "first"] {
            let scoped = library.scoped(to: scope)
            let current = FoundationItem(
                id: scope, title: "Date Added song", subtitle: "", kind: .track, duration: nil)
            await cache.write(
                .init(items: [legacy], nextStartIndex: nil),
                key: scoped.catalogCacheKey("recent-tracks"))
            await cache.write(
                .init(items: [current], nextStartIndex: nil),
                key: scoped.catalogCacheKey("date-added-ascending-v1"))
            FoundationLibraryView.configureRecentTracksCache(model, library: scoped)
            XCTAssertTrue(model.items.isEmpty, "Changing library must discard the previous feed")
            await model.loadPending(allowsNetwork: false) { _ in
                XCTFail("Offline scope restoration must not load tracks")
                return .init(items: [], nextStartIndex: nil)
            }
            XCTAssertEqual(model.items, [current])
            XCTAssertTrue(model.loaded)
            XCTAssertNil(model.nextStartIndex)
        }
    }

    func testRecentMusicSuggestionsRejectsUnavailableScopeWithoutNetworkRead() async {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data("[]".utf8), Self.response(request))
        }.scoped(to: "unavailable-library", available: false)
        do {
            _ = try await library.recentMusicSuggestions()
            XCTFail("Unavailable selected library must not become an account-wide feed")
        } catch {
            XCTAssertEqual(FoundationLibraryError.category(error), .unavailable)
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testRecentMusicSuggestionsPreservesServerGroupsAndSelectedLibrary() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (
                Data(
                    #"[{"Id":"00000000000000000000000000000001","Type":"MusicAlbum","Name":"Recent Album"},{"Id":"00000000000000000000000000000002","Type":"Audio","Name":"Recent Single"}]"#
                        .utf8), Self.response(request)
            )
        }.scoped(to: "selected-library")
        let page = try await library.recentMusicSuggestions()
        XCTAssertEqual(page.items.map(\.kind), [.album, .track])
        XCTAssertEqual(page.items.map(\.title), ["Recent Album", "Recent Single"])
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/proxy/jellyfin/Items/Latest")
        let query = try XCTUnwrap(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "parentId" }?.value, "selected-library")
        XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Audio")
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "24")
        XCTAssertFalse(
            query.contains { ["groupItems", "isPlayed", "sortBy", "startIndex"].contains($0.name) })
    }

    func testRecentMusicSuggestionsRejectsUnsupportedKindsAndPreservesAuthenticationError()
        async throws
    {
        for status in [200, 401] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                (
                    Data(#"[{"Id":"00000000000000000000000000000001","Type":"MusicArtist"}]"#.utf8),
                    Self.response(request, status: status)
                )
            }
            do {
                _ = try await library.recentMusicSuggestions()
                XCTFail("Unsupported response must not become a successful empty feed")
            } catch {
                XCTAssertEqual(
                    FoundationLibraryError.category(error),
                    status == 401 ? .authentication : .invalidResponse)
            }
        }
    }

    @MainActor
    func testVisibleRefreshTakesOverAbandonedInitialLoadWithoutManualRefresh() async {
        let model = FoundationBrowseModel()
        let abandonedGate = FoundationAlphabetTestGate()
        let replacement = FoundationItem(
            id: "visible-replacement", title: "Replacement", subtitle: "Synthetic", kind: .track,
            duration: 1)
        var activeRequests = 0
        var maximumActiveRequests = 0
        var replacementReads = 0
        let abandoned = Task {
            await model.loadPending { _ in
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                defer { activeRequests -= 1 }
                await abandonedGate.suspend()
                return .init(items: [], nextStartIndex: nil)
            }
        }
        await abandonedGate.entered()
        let visible = Task {
            await model.refreshVisible(allowsNetwork: true) { _ in
                replacementReads += 1
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                defer { activeRequests -= 1 }
                return .init(items: [replacement], nextStartIndex: nil)
            }
        }
        await waitForInitialDemands(1, in: model)
        abandoned.cancel()
        XCTAssertEqual(replacementReads, 0, "Wait for the abandoned transport to unwind")
        await abandonedGate.release()
        await abandoned.value
        await visible.value
        XCTAssertEqual(replacementReads, 1)
        XCTAssertEqual(maximumActiveRequests, 1)
        XCTAssertEqual(model.items.map(\.id), [replacement.id])
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
    }

    @MainActor
    func testCollectionInitialDemandTakesOverCancelledOwnerAfterTransportUnwinds() async {
        let model = FoundationBrowseModel()
        let firstGate = FoundationAlphabetTestGate()
        let secondGate = FoundationAlphabetTestGate()
        let track = FoundationItem(
            id: "replacement", title: "Replacement", subtitle: "Synthetic", kind: .track,
            duration: 1)
        var activeRequests = 0
        var maximumActiveRequests = 0
        var replacementReads = 0
        let first = Task {
            await model.loadPending(waitForInitialLoad: true) { _ in
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                defer { activeRequests -= 1 }
                await firstGate.suspend()
                return .init(items: [], nextStartIndex: nil)
            }
        }
        await firstGate.entered()
        let second = Task {
            await model.loadPending(waitForInitialLoad: true) { _ in
                replacementReads += 1
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                defer { activeRequests -= 1 }
                await secondGate.suspend()
                return .init(items: [track], nextStartIndex: nil)
            }
        }
        await waitForInitialDemands(1, in: model)
        first.cancel()
        // The first synthetic transport ignores cancellation until explicitly released.
        let third = Task {
            await model.loadPending(waitForInitialLoad: true) { _ in
                replacementReads += 1
                activeRequests += 1
                maximumActiveRequests = max(maximumActiveRequests, activeRequests)
                defer { activeRequests -= 1 }
                await secondGate.suspend()
                return .init(items: [track], nextStartIndex: nil)
            }
        }
        await waitForInitialDemands(2, in: model)
        XCTAssertEqual(replacementReads, 0)
        await firstGate.release()
        await first.value
        await secondGate.entered()
        XCTAssertEqual(replacementReads, 1)
        await secondGate.release()
        await second.value
        await third.value
        XCTAssertEqual(maximumActiveRequests, 1)
        XCTAssertEqual(replacementReads, 1)
        XCTAssertEqual(model.items.map(\.id), ["replacement"])
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
    }

    @MainActor
    func testCollectionInitialDemandDoesNotRetrySuccessfulOrFailedOwner() async {
        for fails in [false, true] {
            let model = FoundationBrowseModel()
            let gate = FoundationAlphabetTestGate()
            let track = FoundationItem(
                id: "original", title: "Original", subtitle: "Synthetic", kind: .track, duration: 1)
            let first = Task {
                await model.loadPending(waitForInitialLoad: true) { _ in
                    await gate.suspend()
                    if fails { throw FoundationLibraryError.invalidResponse }
                    return .init(items: [track], nextStartIndex: nil)
                }
            }
            await gate.entered()
            let second = Task {
                await model.loadPending(waitForInitialLoad: true) { _ in
                    XCTFail("Completed owner must satisfy initial demand without another request")
                    return .init(items: [], nextStartIndex: nil)
                }
            }
            await waitForInitialDemands(1, in: model)
            await gate.release()
            await first.value
            await second.value
            XCTAssertEqual(model.loaded, !fails)
            XCTAssertEqual(model.errorMessage != nil, fails)
            XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
        }
    }

    @MainActor
    func testCancelledCollectionWaiterReturnsWithoutWaitingForNoncooperativeTransport() async {
        let model = FoundationBrowseModel()
        let gate = FoundationAlphabetTestGate()
        let first = Task {
            await model.loadPending(waitForInitialLoad: true) { _ in
                await gate.suspend()
                return .init(items: [], nextStartIndex: nil)
            }
        }
        await gate.entered()
        let second = Task {
            await model.loadPending(waitForInitialLoad: true) { _ in
                XCTFail("Cancelled destination must not take over")
                return .init(items: [], nextStartIndex: nil)
            }
        }
        await waitForInitialDemands(1, in: model)
        second.cancel()
        await second.value
        XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
        XCTAssertTrue(model.isLoading)
        first.cancel()
        await gate.release()
        await first.value
        XCTAssertFalse(model.loaded)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testCollectionDemandInvalidationCannotResurrectRetiredModel() async {
        for invalidation in ["clear", "snapshot", "request"] {
            let model = FoundationBrowseModel()
            let gate = FoundationAlphabetTestGate()
            let first = Task {
                await model.loadPending(waitForInitialLoad: true) { _ in
                    await gate.suspend()
                    return .init(items: [], nextStartIndex: nil)
                }
            }
            await gate.entered()
            let second = Task {
                await model.loadPending(waitForInitialLoad: true) { _ in
                    XCTFail("Invalidated demand must not start another request")
                    return .init(items: [], nextStartIndex: nil)
                }
            }
            await waitForInitialDemands(1, in: model)
            switch invalidation {
            case "clear": model.clearRetainedData()
            case "snapshot":
                model.installSnapshot([
                    FoundationItem(
                        id: "snapshot", title: "Snapshot", subtitle: "Synthetic", kind: .track,
                        duration: 1)
                ])
            default: model.request(.refresh)
            }
            await second.value
            first.cancel()
            await gate.release()
            await first.value
            XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
            XCTAssertEqual(model.loaded, invalidation == "snapshot")
            XCTAssertNil(model.errorMessage)
        }
    }

    @MainActor
    func testCollectionInitialHandoffPreservesExplicitRefreshAndRetry() async {
        for initialFailure in [false, true] {
            let model = FoundationBrowseModel()
            let original = FoundationItem(
                id: "original", title: "Original", subtitle: "Synthetic", kind: .track, duration: 1)
            let replacement = FoundationItem(
                id: "replacement", title: "Replacement", subtitle: "Synthetic", kind: .track,
                duration: 1)
            await model.loadPending { _ in
                if initialFailure { throw FoundationLibraryError.invalidResponse }
                return .init(items: [original], nextStartIndex: nil)
            }
            XCTAssertEqual(model.loaded, !initialFailure)
            XCTAssertEqual(model.errorMessage != nil, initialFailure)

            // Hold an older refresh across the explicit replacement request. The opt-in
            // handoff must not change existing refresh/retry supersession behavior.
            let gate = FoundationAlphabetTestGate()
            let stale = Task {
                await model.load(.refresh) { _ in
                    await gate.suspend()
                    return .init(items: [original], nextStartIndex: nil)
                }
            }
            await gate.entered()
            model.request(.refresh)
            var replacementReads = 0
            let current = Task {
                await model.loadPending(waitForInitialLoad: true) { offset in
                    XCTAssertEqual(offset, 0)
                    replacementReads += 1
                    return .init(items: [replacement], nextStartIndex: nil)
                }
            }
            for _ in 0..<10_000 {
                if replacementReads != 0 { break }
                await Task.yield()
            }
            XCTAssertEqual(replacementReads, 1, "Explicit refresh must not wait for retired work")
            await gate.release()
            await stale.value
            await current.value
            XCTAssertEqual(model.items.map(\.id), ["replacement"])
            XCTAssertTrue(model.loaded)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.pendingInitialLoadDemandCount, 0)
        }
    }

    @MainActor
    private func waitForInitialDemands(_ count: Int, in model: FoundationBrowseModel) async {
        // Bounded cooperative scheduling, not a timing-dependent sleep or real transport.
        for _ in 0..<10_000 {
            if model.pendingInitialLoadDemandCount == count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) registered initial demand(s)")
    }

    func testHomeFavoriteCollectionsPreviewBoundsAndSeparatesLibraryScopes() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            let type = query.first { $0.name == "includeItemTypes" }?.value
            XCTAssertTrue(type == "MusicAlbum" || type == "Playlist")
            XCTAssertEqual(query.first { $0.name == "limit" }?.value, "5")
            XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "0")
            XCTAssertEqual(query.first { $0.name == "isFavorite" }?.value, "true")
            XCTAssertEqual(
                query.first { $0.name == "parentId" }?.value,
                type == "MusicAlbum" ? "selected-library" : nil)
            let entries = (1...5).map { index in
                "{\"Id\":\"0000000000000000000000000000000\(index)\",\"Type\":\"\(type!)\",\"UserData\":{\"Key\":\"synthetic\",\"IsFavorite\":true}}"
            }.joined(separator: ",")
            return (
                Data("{\"Items\":[\(entries)],\"StartIndex\":0,\"TotalRecordCount\":30}".utf8),
                Self.response(request)
            )
        }.scoped(to: "selected-library")
        let preview = try await library.favoriteCollectionsPreview()
        XCTAssertEqual(
            preview.items.prefix(5).map(\.kind), [.album, .playlist, .album, .playlist, .album])
        XCTAssertEqual(preview.items.count, 10)
        XCTAssertNil(
            preview.nextStartIndex, "Preview has no paging route; its heading opens full Favorites")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testHomeFavoritePreviewKeepsAccountPlaylistsWhenSelectedCatalogUnavailable() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertNil(query.first { $0.name == "parentId" })
            XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Playlist")
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }.scoped(to: "unavailable-library", available: false)
        _ = try await library.favoriteCollectionsPreview()
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testHomeFavoritePreviewPreservesExplicitFalseForReconciliationWithoutInventingMetadata() {
        let rejected = FoundationItem(
            id: "rejected", title: "Rejected", subtitle: "", kind: .album,
            duration: nil, isFavorite: false)
        let unknown = FoundationItem(
            id: "unknown", title: "Unknown", subtitle: "", kind: .album,
            duration: nil)
        let playlist = FoundationItem(
            id: "playlist", title: "Playlist", subtitle: "", kind: .playlist,
            duration: nil, isFavorite: true)
        let preview = foundationFavoriteCollectionsPreview(
            albums: .init(items: [rejected, unknown], nextStartIndex: 2),
            playlists: .init(items: [playlist], nextStartIndex: nil))
        XCTAssertEqual(preview.items.map(\.id), ["unknown", "playlist", "rejected"])
        XCTAssertEqual(preview.items.last?.isFavorite, false)
        XCTAssertNil(preview.items.first?.isFavorite)
    }

    func testPlaybackReportsUseOfficialEndpointsAndBoundedPayloadWithoutURLCredentials()
        async throws
    {
        let occurrence = UUID()
        for (kind, suffix) in [
            (FoundationPlaybackReport.Kind.start, "/Sessions/Playing"),
            (.progress, "/Sessions/Playing/Progress"), (.stop, "/Sessions/Playing/Stopped"),
        ] {
            let id = itemID
            let library = FoundationJellyfinLibrary(session: session) { request in
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertTrue(request.url!.path.hasSuffix(suffix))
                XCTAssertTrue(request.url!.query?.isEmpty != false)
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody))
                        as? [String: Any])
                XCTAssertEqual(body["ItemId"] as? String, id)
                XCTAssertEqual(body["PlaySessionId"] as? String, occurrence.uuidString)
                XCTAssertEqual(body["PositionTicks"] as? Int, 12_500_000)
                XCTAssertNil(body["MediaSourceId"])
                if kind != .stop { XCTAssertEqual(body["IsPaused"] as? Bool, true) }
                return (Data(), Self.response(request, status: 204))
            }
            try await library.reportPlayback(
                .init(
                    kind: kind, occurrenceID: occurrence, itemID: itemID,
                    position: 1.25, paused: true))
        }
    }

    func testPlaybackReportsRejectInvalidIDsAndNonfinitePositionsBeforeNetwork() async {
        let library = FoundationJellyfinLibrary(session: session) { _ in
            XCTFail("Invalid playback metadata must not reach transport")
            throw URLError(.badURL)
        }
        for (id, position) in [
            ("../item", 1.0), (itemID, Double.nan), (itemID, Double.infinity), (itemID, -1.0),
        ] {
            do {
                try await library.reportPlayback(
                    .init(
                        kind: .start, occurrenceID: UUID(), itemID: id, position: position,
                        paused: false))
                XCTFail("Expected validation failure")
            } catch {}
        }
    }

    func testTypedFavoritesQueriesEachKindIndependentlyWithFavoriteFilterAndCursor() async throws {
        let userID = session.userID
        for (kind, type) in [
            (FoundationItem.Kind.album, "MusicAlbum"), (.artist, "MusicArtist"), (.track, "Audio"),
            (.playlist, "Playlist"),
        ] {
            let library = FoundationJellyfinLibrary(session: session) { request in
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!
                XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, type)
                XCTAssertEqual(
                    query.first { $0.name == "parentId" }?.value,
                    kind == .playlist ? nil : "selected-library")
                XCTAssertEqual(query.first { $0.name == "userId" }?.value, userID)
                XCTAssertEqual(query.first { $0.name == "isFavorite" }?.value, "true")
                XCTAssertEqual(query.first { $0.name == "startIndex" }?.value, "50")
                XCTAssertEqual(query.first { $0.name == "limit" }?.value, "50")
                XCTAssertEqual(query.first { $0.name == "enableUserData" }?.value, "true")
                let payload =
                    "{\"Items\":[{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"" + type
                    + "\",\"Name\":\"Favorite\",\"UserData\":{\"Key\":\"synthetic-key\",\"IsFavorite\":true}}],\"StartIndex\":50,\"TotalRecordCount\":51}"
                return (Data(payload.utf8), Self.response(request))
            }
            let page = try await library.scoped(to: "selected-library")
                .favorites(kind: kind, startIndex: 50)
            XCTAssertEqual(page.items.count, 1)
            XCTAssertEqual(page.items.first?.kind, kind)
            XCTAssertEqual(page.items.first?.isFavorite, true)
            XCTAssertNil(page.nextStartIndex)
        }
    }

    func testFavoritePlaylistsRemainAvailableWithoutSelectedCatalog() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertNil(query.first { $0.name == "parentId" })
            XCTAssertEqual(query.first { $0.name == "includeItemTypes" }?.value, "Playlist")
            XCTAssertEqual(query.first { $0.name == "isFavorite" }?.value, "true")
            return (
                Data(#"{"Items":[],"StartIndex":0,"TotalRecordCount":0}"#.utf8),
                Self.response(request)
            )
        }.scoped(to: "unavailable-library", available: false)
        let page = try await library.favorites(kind: .playlist, startIndex: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertNil(page.nextStartIndex)
        for kind in [FoundationItem.Kind.track, .album, .artist, .genre] {
            do {
                _ = try await library.favorites(kind: kind, startIndex: 0)
                XCTFail("Unavailable or unsupported category must not query another source")
            } catch {
                XCTAssertEqual(error as? FoundationLibraryError, .unavailable)
            }
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor
    func testSongsActivationLoadsOnePageThenScrollDemandLoadsMoreWithoutAButton() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination(sortByTitle: true)
        var offsets: [Int] = []
        let loader: (Int) async throws -> FoundationPage = { offset in
            offsets.append(offset)
            return .init(
                items: [
                    .init(
                        id: "\(offset)", title: "Song \(offset)",
                        subtitle: "", kind: .track, duration: nil)
                ], nextStartIndex: offset + 1)
        }
        await model.loadCatalogPage(using: loader)
        XCTAssertEqual(offsets, [0])
        await model.loadCatalogPage(using: loader)
        XCTAssertEqual(offsets, [0], "Revisiting must not drain the catalog")
        await model.loadNextPage(using: loader)
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(model.items.count, 2)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testAdvancingPagesStopAtLifetimeSafetyLimitAndRetryCannotResetIt() async {
        let model = FoundationBrowseModel(catalogLimits: .init(maximumPages: 3))
        model.configureCatalogPagination()
        var requests = 0
        let loader: (Int) async throws -> FoundationPage = { offset in
            requests += 1
            return .init(
                items: [
                    .init(
                        id: "\(offset)", title: "Song", subtitle: "",
                        kind: .track, duration: nil)
                ], nextStartIndex: offset + 1)
        }
        await model.drainDemandedPagesForTesting(using: loader)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(model.items.count, 3)
        XCTAssertEqual(model.nextStartIndex, 3)
        XCTAssertEqual(model.errorCategory, .invalidResponse)
        model.request(.more)
        await model.loadPending(using: loader)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(model.items.count, 3)
    }

    @MainActor
    func testDuplicatePagesConsumeRawItemBudgetBeforeDeduplication() async {
        let model = FoundationBrowseModel(catalogLimits: .init(maximumItems: 400))
        model.configureCatalogPagination()
        let item = FoundationItem(
            id: "same", title: "Song", subtitle: "",
            kind: .track, duration: nil)
        var requests = 0
        await model.drainDemandedPagesForTesting { offset in
            requests += 1
            return .init(items: Array(repeating: item, count: 200), nextStartIndex: offset + 200)
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.items, [item])
        XCTAssertEqual(model.nextStartIndex, 400)
        XCTAssertEqual(model.errorCategory, .invalidResponse)
    }

    @MainActor
    func testMetadataBudgetRejectsOversizedPageBeforePublishingAndRefreshRetainsRowsOnError() async
    {
        let model = FoundationBrowseModel(catalogLimits: .init(maximumBytes: 2_048))
        model.configureCatalogPagination()
        let earlier = FoundationItem(
            id: "earlier", title: "Earlier", subtitle: "",
            kind: .track, duration: nil)
        let huge = FoundationItem(
            id: "huge", title: String(repeating: "x", count: 2_048),
            subtitle: "", kind: .track, duration: nil)
        await model.drainDemandedPagesForTesting { offset in
            offset == 0
                ? .init(items: [earlier], nextStartIndex: 50)
                : .init(items: [huge], nextStartIndex: 100)
        }
        XCTAssertEqual(model.items, [earlier])
        XCTAssertEqual(model.nextStartIndex, 50)
        XCTAssertEqual(model.errorCategory, .invalidResponse)
        model.request(.refresh)
        await model.loadCatalogPage { _ in throw FoundationLibraryError.network }
        XCTAssertEqual(model.items, [earlier])
        model.request(.refresh)
        await model.loadCatalogPage { _ in .init(items: [earlier], nextStartIndex: nil) }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.nextStartIndex)
        model.clearRetainedData()
        await model.loadCatalogPage { _ in .init(items: [earlier], nextStartIndex: 50) }
        XCTAssertNil(model.errorMessage)
    }

    func testMetadataCostIncludesEmptyNestedReferences() {
        var item = FoundationItem(id: "", title: "", subtitle: "", kind: .track, duration: nil)
        item.genres = Array(repeating: .init(id: "", title: ""), count: 100)
        XCTAssertNil(
            FoundationCatalogBudget(maximumBytes: 2_048).cost(
                of: .init(items: [item], nextStartIndex: nil)))
    }

    @MainActor
    func testDemandedSongsPagesRetainMembershipForLetterSelection() async {
        let model = FoundationBrowseModel()
        model.configureCatalogPagination()
        let a = FoundationItem(id: "a", title: "Alpha", subtitle: "", kind: .track, duration: nil)
        let c = FoundationItem(id: "c", title: "Charlie", subtitle: "", kind: .track, duration: nil)
        let f = FoundationItem(id: "f", title: "Foxtrot", subtitle: "", kind: .track, duration: nil)
        var offsets: [Int] = []
        await model.drainDemandedPagesForTesting { offset in
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
        await model.drainDemandedPagesForTesting { _ in
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
            await model.drainDemandedPagesForTesting { offset in
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
        await model.drainDemandedPagesForTesting { offset in
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
        await model.drainDemandedPagesForTesting { offset in
            requests += 1
            if offset == 0 { return .init(items: [a], nextStartIndex: 50) }
            throw FoundationLibraryError.network
        }
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.items, [a])
        XCTAssertNotNil(model.errorMessage)
        await model.drainDemandedPagesForTesting { _ in
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
            await model.drainDemandedPagesForTesting { offset in
                if !failRefresh, offset == 0 {
                    return .init(items: [a], nextStartIndex: 50)
                }
                throw FoundationLibraryError.network
            }
            XCTAssertEqual(model.items, [a])
            XCTAssertEqual(model.isRetainedSnapshot, failRefresh)
            XCTAssertEqual(model.errorCategory, .network)
            await model.drainDemandedPagesForTesting { _ in
                XCTFail("Revisiting a failed cached catalog must not retry any page")
                return .init(items: [], nextStartIndex: nil)
            }
            XCTAssertEqual(model.items, [a])
            XCTAssertEqual(model.errorCategory, .network)
            model.request(model.retryRequest)
            await model.drainDemandedPagesForTesting { offset in
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
            await model.drainDemandedPagesForTesting { _ in
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
        await model.drainDemandedPagesForTesting { offset in
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
        await model.drainDemandedPagesForTesting { offset in
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

    func testSongLetterSeekFetchesUnloadedTitleRangeAndKeepsAbsoluteCursor() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
            XCTAssertEqual(value("sortBy"), "Name")
            XCTAssertNil(value("nameStartsWithOrGreater"))
            let offset = Int(value("startIndex")!)!
            let limit = Int(value("limit")!)!
            let entries = (offset..<min(200, offset + limit)).map { index in
                let title = index < 100 ? "Alpha" : index < 180 ? "Mike" : "Zulu"
                return
                    "{\"Id\":\"\(String(format: "%032x", index + 1))\",\"Type\":\"Audio\",\"Name\":\"\(title) \(String(format: "%03d", index))\",\"SortName\":\"01-01 metadata\"}"
            }.joined(separator: ",")
            return (
                Data(
                    "{\"Items\":[\(entries)],\"StartIndex\":\(offset),\"TotalRecordCount\":200}"
                        .utf8), Self.response(request)
            )
        }
        let first = try await library.alphabetPage(kind: .track, letter: "M", startIndex: 0)
        XCTAssertEqual(first.items.first?.title, "Mike 100")
        XCTAssertEqual(first.items.count, 50)
        XCTAssertEqual(first.nextStartIndex, 150)
        let initialRequests = await recorder.requests
        XCTAssertLessThanOrEqual(initialRequests.count, 13)
        let second = try await library.alphabetPage(kind: .track, letter: "M", startIndex: 150)
        XCTAssertEqual(second.items.first?.title, "Mike 150")
        XCTAssertEqual(second.items.last?.title, "Zulu 199")
        XCTAssertNil(second.nextStartIndex)
        let allRequests = await recorder.requests
        XCTAssertEqual(allRequests.count, initialRequests.count + 1)
    }

    func testOrdinarySongsPageUsesTitleOrderingInsteadOfDiscMetadata() async throws {
        let library = FoundationJellyfinLibrary(session: session) { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertEqual(query.first { $0.name == "fields" }?.value, "SortName")
            XCTAssertEqual(query.first { $0.name == "sortBy" }?.value, "Name")
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
        for kind in [FoundationItem.Kind.album, .artist, .playlist, .genre] {
            for offset in [0, 50] {
                _ = try await library.scoped(to: scope).alphabetPage(
                    kind: kind, letter: "F", startIndex: offset)
            }
        }
        let requests = await recorder.requests
        XCTAssertEqual(
            requests.filter { Self.alphabetProbeData($0) != nil }.count, 2)
        let pages = requests.filter { Self.alphabetProbeData($0) == nil }
        XCTAssertEqual(pages.count, 8)
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
            XCTAssertEqual(value("parentId"), index / 2 == 2 ? nil : scope)
            XCTAssertEqual(value("userId"), session.userID)
            let path = request.url!.path
            if index / 2 == 1 {
                XCTAssertTrue(path.hasSuffix("/Artists/AlbumArtists"))
            } else if index / 2 == 3 {
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

    func testSortNameAlphabetMappingPreservesNonSongIndexes() async throws {
        let recorder = Recorder()
        let types: [(FoundationItem.Kind, String)] = [
            (.album, "MusicAlbum"), (.artist, "MusicArtist"),
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
            } else if index == 3 {
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

    func testHighResolutionRequestsRespect2048CapAndTransparentLogo() async throws {
        let recorder = Recorder()
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            return (Data([1, 2, 3]), Self.response(request))
        }
        var artist = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .artist, duration: nil,
            primaryImageTag: "portrait")
        artist.logoImageTag = "logo"
        artist.backdropImageTag = "backdrop"
        for role in [FoundationItem.ArtworkRole.primary, .logo, .backdrop] {
            let projection = try XCTUnwrap(artist.artworkItem(for: role))
            _ = try await library.artwork(for: projection, size: 8192)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        for (index, expectedPixels) in [2048, 2048, 2048].enumerated() {
            let request = requests[index]
            let query = try XCTUnwrap(
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertTrue(
                query.contains(URLQueryItem(name: "maxWidth", value: String(expectedPixels))))
            XCTAssertTrue(
                query.contains(URLQueryItem(name: "maxHeight", value: String(expectedPixels))))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testArtistDetailMapsBrandingRolesAndRequestsTransparentLogo() async throws {
        let recorder = Recorder()
        let syntheticID = itemID
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            if request.url?.path.contains("Images") == true {
                return (Data([1, 2, 3]), Self.response(request))
            }
            return (
                Data(
                    "{\"Id\":\"\(syntheticID)\",\"Type\":\"MusicArtist\",\"Name\":\"Synthetic Artist\",\"ImageTags\":{\"Primary\":\"portrait-v1\",\"Logo\":\"logo-v1\"},\"BackdropImageTags\":[\"backdrop-v1\"]}"
                        .utf8),
                Self.response(request)
            )
        }
        let artist = FoundationItem(
            id: itemID, title: "Synthetic Artist", subtitle: "", kind: .artist, duration: nil)
        let resolved = try await library.itemDetails(for: artist)
        let detail = try XCTUnwrap(resolved)
        XCTAssertEqual(detail.logoImageTag, "logo-v1")
        XCTAssertEqual(detail.backdropImageTag, "backdrop-v1")
        for role in [FoundationItem.ArtworkRole.logo, .backdrop] {
            let projected = try XCTUnwrap(detail.artworkItem(for: role))
            _ = try await library.artwork(for: projected, size: 640)
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3)
        let logoRequest = requests[1]
        let backdropRequest = requests[2]
        XCTAssertEqual(logoRequest.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Logo")
        XCTAssertEqual(backdropRequest.url?.path, "/proxy/jellyfin/Items/\(itemID)/Images/Backdrop")
        XCTAssertEqual(logoRequest.value(forHTTPHeaderField: "Accept"), "image/png")
        let query = try XCTUnwrap(
            URLComponents(url: logoRequest.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "format", value: "Png")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "tag", value: "logo-v1")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "maxWidth", value: "640")))
        XCTAssertNotNil(logoRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse(query.contains { $0.name.lowercased() == "apikey" })
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

    #if DEBUG
        func testHLSComparisonNegotiatesAndRetiresOnlyItsServerSession() async throws {
            let recorder = Recorder()
            let itemID = self.itemID
            let deviceID = session.deviceID
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                if request.httpMethod == "DELETE" { return (Data(), Self.response(request)) }
                let body = """
                    {"PlaySessionId":"server-session-a","MediaSources":[{"Id":"source-a",
                    "SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                    "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=server-session-a&DeviceId=\(deviceID)&AudioBitrate=192000"}]}
                    """
                return (Data(body.utf8), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
            let cleanupLoad: FoundationJellyfinLibrary.Load = { request in
                await recorder.append(request)
                return (Data(), Self.response(request))
            }
            let resource = try await FoundationJellyfinLibrary.$hlsCleanupLoad.withValue(
                cleanupLoad
            ) {
                try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(false) {
                    try await library.playbackResource(for: item)
                }
            }
            XCTAssertEqual(resource.source.delivery, .hlsAAC)
            XCTAssertEqual(resource.source.serverSessionID, "server-session-a")
            XCTAssertEqual(resource.source.mediaSourceID, "source-a")
            XCTAssertEqual(resource.url.path, "/proxy/jellyfin/audio/\(itemID)/master.m3u8")
            let query = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertTrue(query.contains(.init(name: "AudioBitrate", value: "192000")))
            XCTAssertTrue(query.contains(.init(name: "ApiKey", value: "synthetic-token")))
            await resource.release()
            await resource.release()
            for _ in 0..<100 {
                if await recorder.requests.count >= 2 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 2)
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody))
                    as? [String: Any])
            XCTAssertEqual(body["EnableDirectPlay"] as? Bool, false)
            XCTAssertEqual(body["EnableDirectStream"] as? Bool, false)
            XCTAssertEqual(body["AllowAudioStreamCopy"] as? Bool, false)
            XCTAssertEqual(body["AutoOpenLiveStream"] as? Bool, false)
            let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
            XCTAssertEqual(profile["MusicStreamingTranscodingBitrate"] as? Int, 320_000)
            let transcode = try XCTUnwrap(
                (profile["TranscodingProfiles"] as? [[String: Any]])?.first)
            XCTAssertEqual(transcode["Protocol"] as? String, "hls")
            XCTAssertEqual(transcode["AudioCodec"] as? String, "aac")
            XCTAssertEqual(requests[1].httpMethod, "DELETE")
            XCTAssertEqual(requests[1].url?.path, "/proxy/jellyfin/Videos/ActiveEncodings")
            let cleanup = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!
                .queryItems!
            XCTAssertTrue(cleanup.contains(.init(name: "playSessionId", value: "server-session-a")))
            XCTAssertTrue(cleanup.contains(.init(name: "deviceId", value: session.deviceID)))
        }

        func testMP3CopyMasterPreservesLimitsAndRefusesIncompatibleSource() throws {
            let raw =
                "/audio/\(itemID)/master.m3u8?AudioCodec=mp3&SegmentContainer=ts&AudioBitrate=320000&PlaySessionId=session-a&RequireAvc=false"
            let audio = MediaStream(
                bitDepth: 16, bitRate: 256_000, channels: 2, codec: "mp3", index: 0,
                sampleRate: 44_100, type: .audio)
            let result = try FoundationJellyfinLibrary.hlsMP3CopyMaster(raw, audio: audio)
            XCTAssertEqual(result.queryItems?.first { $0.name == "AudioCodec" }?.value, "copy")
            XCTAssertEqual(
                result.string,
                raw.replacingOccurrences(of: "AudioCodec=mp3", with: "AudioCodec=copy"))
            for suffix in [
                "&AudioSampleRate=44100&AudioChannels=2&MaxAudioChannels=2&MaxAudioBitDepth=16",
                "&AllowAudioStreamCopy=true&EnableAutoStreamCopy=true&AudioStreamIndex=0",
                "&EnableAudioVbrEncoding=false&TranscodingMaxAudioChannels=2",
                "&EnableAudioVbrEncoding=true&TranscodingMaxAudioChannels=6",
            ] {
                let preserved = try FoundationJellyfinLibrary.hlsMP3CopyMaster(
                    raw + suffix, audio: audio)
                XCTAssertEqual(
                    preserved.string,
                    (raw + suffix).replacingOccurrences(
                        of: "AudioCodec=mp3", with: "AudioCodec=copy"))
            }
            for invalid in [
                raw.replacingOccurrences(of: "320000", with: "128000"),
                raw.replacingOccurrences(of: "AudioCodec=mp3", with: "AudioCodec=aac"),
                raw.replacingOccurrences(of: "SegmentContainer=ts", with: "SegmentContainer=mp4"),
                raw + "&AudioBitrate=320000", raw + "&AudioCodec=copy",
                raw + "&AllowAudioStreamCopy=false", raw + "&EnableAutoStreamCopy=false",
                raw + "&AudioSampleRate=48000", raw + "&AudioChannels=1",
                raw + "&MaxAudioChannels=1", raw + "&MaxAudioBitDepth=8",
                raw + "&AudioStreamIndex=1", raw + "&AudioUnknownLimit=1",
                raw + "&AudioBitDepth=invalid", raw + "&MaxStreamingBitrate=128000",
                raw + "&EnableAudioVbrEncoding=invalid", raw + "&EnableAudioVbrEncoding=",
                raw + "&EnableAudioVbrEncoding=true&enableaudiovbrencoding=false",
                raw + "&TranscodingMaxAudioChannels=1",
                raw + "&TranscodingMaxAudioChannels=invalid",
                raw + "&TranscodingMaxAudioChannels=2&transcodingmaxaudiochannels=2",
            ] {
                XCTAssertThrowsError(
                    try FoundationJellyfinLibrary.hlsMP3CopyMaster(invalid, audio: audio))
            }
            var unknown = audio
            unknown.bitRate = nil
            XCTAssertThrowsError(
                try FoundationJellyfinLibrary.hlsMP3CopyMaster(raw, audio: unknown))
            unknown = audio
            unknown.sampleRate = nil
            XCTAssertThrowsError(
                try FoundationJellyfinLibrary.hlsMP3CopyMaster(
                    raw + "&AudioSampleRate=44100", audio: unknown))
        }

        func testMP3CopyPlaylistRejectsEncodingAndUnsafeVariants() throws {
            let identity =
                "MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(session.deviceID)"
            let valid = "main.m3u8?\(identity)&AudioCodec=copy&SegmentContainer=ts"
            func resolve(_ child: String, suffix: String = "") throws -> URL {
                try FoundationJellyfinLibrary.hlsMP3CopyURL(
                    Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=320000\n\(child)\n\(suffix)".utf8),
                    itemID: itemID, sourceID: "source-a", serverSession: "session-a",
                    base: session.serverURL, token: session.accessToken, deviceID: session.deviceID)
            }
            let url = try resolve(valid)
            XCTAssertEqual(url.path, "/proxy/jellyfin/audio/\(itemID)/main.m3u8")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.filter { $0.name == "ApiKey" }.count, 1)
            for invalid in [
                valid.replacingOccurrences(of: "AudioCodec=copy", with: "AudioCodec=mp3"),
                valid.replacingOccurrences(of: "SegmentContainer=ts", with: "SegmentContainer=mp4"),
                valid + "&AudioCodec=copy", valid + "&PlaySessionId=another-session",
                "https://other.invalid/" + valid, "../" + valid,
                valid.replacingOccurrences(of: "main.m3u8", with: "%6dain.m3u8"),
            ] { XCTAssertThrowsError(try resolve(invalid)) }
            XCTAssertThrowsError(
                try resolve(valid, suffix: "#EXT-X-STREAM-INF:BANDWIDTH=1\n\(valid)"))
            XCTAssertThrowsError(
                try resolve(valid, suffix: "#EXT-X-MEDIA:TYPE=AUDIO,URI=\"other.m3u8\""))
        }

        func testOriginalPreferredHLSSelectsCopyOrAACBeforeNegotiation() async throws {
            for (codec, bitrate, depth, expectedCopy) in [
                ("mp3", 256_000, 16, true), ("aac", 256_000, 16, true),
                ("flac", 9_216_000, 24, true), ("alac", 4_608_000, 24, true),
                ("opus", 192_000, 16, false), ("pcm_s24le", 4_608_000, 24, false),
                ("flac", 50_000_001, 24, false), ("flac", 0, 24, false),
                ("flac", 4_608_000, 32, false),
            ] {
                let recorder = Recorder()
                let itemID = self.itemID
                let deviceID = session.deviceID
                let container = expectedCopy && codec != "mp3" ? "mp4" : "ts"
                let outputCodec = expectedCopy ? codec : "aac"
                let limit = expectedCopy ? 50_000_000 : 320_000
                let profileJSON = codec == "aac" ? ",\"Profile\":\"LC\"" : ""
                let audio = """
                    {"Type":"Audio","Codec":"\(codec)"\(profileJSON),"Index":0,"BitDepth":\(depth),
                    "BitRate":\(bitrate),"SampleRate":44100,"Channels":2}
                    """
                let library = FoundationJellyfinLibrary(session: session) { request in
                    await recorder.append(request)
                    if request.url?.path.hasSuffix("/Items/\(itemID)") == true {
                        return (
                            Data(
                                """
                                {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                                "Protocol":"File","MediaStreams":[\(audio)]}]}
                                """.utf8), Self.response(request)
                        )
                    }
                    if request.httpMethod == "GET" {
                        return (
                            Data(
                                """
                                #EXTM3U
                                #EXT-X-STREAM-INF:BANDWIDTH=\(limit)
                                main.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=copy&SegmentContainer=\(container)&AudioBitrate=\(limit)&AudioStreamIndex=0
                                """.utf8), Self.response(request)
                        )
                    }
                    return (
                        Data(
                            """
                            {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                            "MediaStreams":[\(audio)],"SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                            "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=\(outputCodec)&SegmentContainer=\(container)&AudioBitrate=\(limit)&EnableAudioVbrEncoding=false&TranscodingMaxAudioChannels=2&AudioStreamIndex=0"}]}
                            """.utf8), Self.response(request)
                    )
                }
                let cleanup: FoundationJellyfinLibrary.Load = { request in
                    await recorder.append(request)
                    return (Data(), Self.response(request))
                }
                let item = FoundationItem(
                    id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                let resource = try await FoundationJellyfinLibrary.$hlsCleanupLoad
                    .withValue(cleanup) {
                        try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(
                            true
                        ) {
                            try await library.playbackResource(for: item)
                        }
                    }
                XCTAssertEqual(resource.source.delivery, expectedCopy ? .hlsCopy : .hlsAAC)
                XCTAssertTrue(
                    resource.url.path.hasSuffix(expectedCopy ? "/main.m3u8" : "/master.m3u8"))
                await resource.release()
                for _ in 0..<100 {
                    if await recorder.requests.contains(where: { $0.httpMethod == "DELETE" }) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let requests = await recorder.requests
                XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 1)
                XCTAssertEqual(
                    requests.filter { $0.httpMethod == "GET" }.count, expectedCopy ? 2 : 1)
                if expectedCopy {
                    let master = try XCTUnwrap(
                        requests.first {
                            $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/master.m3u8") == true
                        })
                    let query = try XCTUnwrap(
                        URLComponents(
                            url: try XCTUnwrap(master.url), resolvingAgainstBaseURL: false)?
                            .queryItems)
                    for (name, value) in [
                        ("AudioCodec", "copy"), ("SegmentContainer", container),
                        ("AudioBitrate", String(limit)), ("EnableAudioVbrEncoding", "false"),
                        ("TranscodingMaxAudioChannels", "2"),
                    ] {
                        XCTAssertEqual(query.filter { $0.name == name }.map(\.value), [value])
                    }
                }
                let posted = try XCTUnwrap(requests.first { $0.httpMethod == "POST" })
                let body = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: XCTUnwrap(posted.httpBody)) as? [String: Any])
                XCTAssertEqual(body["AllowAudioStreamCopy"] as? Bool, expectedCopy)
                XCTAssertEqual(body["MediaSourceId"] as? String, "source-a")
                XCTAssertEqual(body["AudioStreamIndex"] as? Int, 0)
                let profile = try XCTUnwrap(body["DeviceProfile"] as? [String: Any])
                XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, limit)
                let transcode = try XCTUnwrap(
                    (profile["TranscodingProfiles"] as? [[String: Any]])?.first)
                XCTAssertEqual(transcode["AudioCodec"] as? String, outputCodec)
                XCTAssertEqual(transcode["Container"] as? String, container)
            }
        }

        func testMP3CopyPreflightBypassesAdmissionAndCleansUpFailureOrCancellation() async throws {
            for cancel in [false, true] {
                let recorder = Recorder()
                let gate = FoundationAlphabetTestGate()
                let admission = FoundationNetworkAdmission(limit: 2)
                let held = try await admission.acquire()
                let itemID = self.itemID
                let deviceID = session.deviceID
                let library = FoundationJellyfinLibrary(
                    session: session,
                    load: { request in
                        await recorder.append(request)
                        if request.url?.path.hasSuffix("/Items/\(itemID)") == true {
                            return (
                                Data(
                                    """
                                    {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                                    "Protocol":"File","MediaStreams":[{"Type":"Audio","Codec":"mp3",
                                    "Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}]}]}
                                    """.utf8), Self.response(request)
                            )
                        }
                        if request.httpMethod == "GET" {
                            await gate.suspend()
                            if !cancel { throw URLError(.timedOut) }
                            return (
                                Data(
                                    "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=320000\nmain.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=copy&SegmentContainer=ts&AudioBitrate=320000\n"
                                        .utf8), Self.response(request)
                            )
                        }
                        let body = """
                            {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                            "MediaStreams":[{"Type":"Audio","Codec":"mp3","Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}],
                            "SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                            "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=mp3&SegmentContainer=ts&AudioBitrate=320000&EnableAudioVbrEncoding=false&TranscodingMaxAudioChannels=2&RequireAvc=false"}]}
                            """
                        return (Data(body.utf8), Self.response(request))
                    }, networkAdmission: admission)
                let cleanup: FoundationJellyfinLibrary.Load = { request in
                    await recorder.append(request)
                    return (Data(), Self.response(request))
                }
                let item = FoundationItem(
                    id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                let preparation = Task {
                    try await FoundationJellyfinLibrary.$hlsCleanupLoad.withValue(cleanup) {
                        try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(
                            true
                        ) {
                            try await library.playbackResource(for: item)
                        }
                    }
                }
                // The held ordinary slot must not block the master preflight.
                // Poll finitely so an admission regression fails rather than hanging the suite.
                for _ in 0..<100 {
                    if await recorder.requests.contains(where: {
                        $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/master.m3u8") == true
                    }) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let entered = await recorder.requests.contains(where: {
                    $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/master.m3u8") == true
                })
                XCTAssertTrue(entered)
                if entered { await gate.entered() }
                await admission.release(held)
                if cancel { preparation.cancel() }
                await gate.release()
                do {
                    let resource = try await preparation.value
                    await resource.release()
                    XCTFail("Failed or cancelled preparation must not publish a resource")
                } catch {
                    XCTAssertEqual(
                        FoundationLibraryError.category(error), cancel ? .cancelled : .network)
                }
                for _ in 0..<100 {
                    if await recorder.requests.contains(where: { $0.httpMethod == "DELETE" }) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let requests = await recorder.requests
                XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 1)
            }
        }

        func testOriginalPreferredAACRequiresKnownProfileAndLosslessMetadata() {
            var audio = MediaStream(
                bitDepth: 24, bitRate: 2_304_000, channels: 2, codec: "aac", index: 0,
                sampleRate: 48_000, type: .audio)
            for profile in [nil, "xHE-AAC", "unknown"] {
                audio.profile = profile
                XCTAssertNil(FoundationJellyfinLibrary.hlsCopyCodec(audio))
            }
            for profile in ["LC", "HE-AAC", "HE-AACv2"] {
                audio.profile = profile
                XCTAssertEqual(FoundationJellyfinLibrary.hlsCopyCodec(audio), "aac")
            }
            audio.codec = "flac"
            audio.bitDepth = nil
            XCTAssertNil(FoundationJellyfinLibrary.hlsCopyCodec(audio))
            audio.bitDepth = 24
            audio.bitRate = nil
            XCTAssertNil(FoundationJellyfinLibrary.hlsCopyCodec(audio))
        }

        func testHLSCopyChildCannotLowerNegotiatedBitrateBelowSource() throws {
            let audio = MediaStream(
                bitDepth: 24, bitRate: 9_216_000, channels: 2, codec: "flac", index: 0,
                sampleRate: 192_000, type: .audio)
            let identity =
                "MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(session.deviceID)"
            for limit in [320_000, 50_000_000] {
                let data = Data(
                    """
                    #EXTM3U
                    #EXT-X-STREAM-INF:BANDWIDTH=\(limit)
                    main.m3u8?\(identity)&AudioCodec=copy&SegmentContainer=mp4&AudioBitrate=\(limit)
                    """.utf8)
                if limit < 9_216_000 {
                    XCTAssertThrowsError(
                        try FoundationJellyfinLibrary.hlsCopyURL(
                            data, container: "mp4", audio: audio, codec: "flac", itemID: itemID,
                            sourceID: "source-a", serverSession: "session-a",
                            base: session.serverURL,
                            token: session.accessToken, deviceID: session.deviceID))
                } else {
                    XCTAssertNoThrow(
                        try FoundationJellyfinLibrary.hlsCopyURL(
                            data, container: "mp4", audio: audio, codec: "flac", itemID: itemID,
                            sourceID: "source-a", serverSession: "session-a",
                            base: session.serverURL,
                            token: session.accessToken, deviceID: session.deviceID))
                }
            }
        }

        func testOriginalPreferredMetadataCancellationDoesNotNegotiate() async throws {
            for quality in FoundationStreamingQuality.allCases {
                let recorder = Recorder()
                let gate = FoundationAlphabetTestGate()
                let itemID = self.itemID
                let library = FoundationJellyfinLibrary(
                    session: session, streamingQuality: { quality },
                    load: { request in
                        await recorder.append(request)
                        await gate.suspend()
                        return (
                            Data(
                                """
                                {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                                "Protocol":"File","MediaStreams":[{"Type":"Audio","Codec":"mp3",
                                "Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}]}]}
                                """.utf8), Self.response(request)
                        )
                    })
                let item = FoundationItem(
                    id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                let preparation = Task {
                    try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(true) {
                        try await library.playbackResource(for: item)
                    }
                }
                await gate.entered()
                preparation.cancel()
                await gate.release()
                do {
                    let resource = try await preparation.value
                    await resource.release()
                    XCTFail("Cancelled metadata cannot negotiate or publish")
                } catch { XCTAssertEqual(FoundationLibraryError.category(error), .cancelled) }
                let requests = await recorder.requests
                XCTAssertEqual(requests.count, 1)
                XCTAssertEqual(requests.first?.httpMethod, "GET")
            }
        }

        func testOriginalPreferredRejectsNegotiatedSourceDriftAndCleansSession() async throws {
            for quality in FoundationStreamingQuality.allCases {
                for drift in ["identity", "codec", "bitrate", "index"] {
                    let recorder = Recorder()
                    let itemID = self.itemID
                    let deviceID = session.deviceID
                    let library = FoundationJellyfinLibrary(
                        session: session, streamingQuality: { quality },
                        load: { request in
                            await recorder.append(request)
                            if request.httpMethod == "GET" {
                                return (
                                    Data(
                                        """
                                        {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                                        "Protocol":"File","MediaStreams":[{"Type":"Audio","Codec":"mp3",
                                        "Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}]}]}
                                        """.utf8), Self.response(request)
                                )
                            }
                            let identity = drift == "identity" ? "source-b" : "source-a"
                            let codec = drift == "codec" ? "aac" : "mp3"
                            let bitrate = drift == "bitrate" ? 128_000 : 256_000
                            let index = drift == "index" ? 1 : 0
                            return (
                                Data(
                                    """
                                    {"PlaySessionId":"session-a","MediaSources":[{"Id":"\(identity)",
                                    "MediaStreams":[{"Type":"Audio","Codec":"\(codec)","Index":\(index),"BitRate":\(bitrate),"SampleRate":44100,"Channels":2}],
                                    "SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                                    "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=\(identity)&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=mp3&SegmentContainer=ts&AudioBitrate=320000"}]}
                                    """.utf8), Self.response(request)
                            )
                        })
                    let cleanup: FoundationJellyfinLibrary.Load = { request in
                        await recorder.append(request)
                        return (Data(), Self.response(request))
                    }
                    let item = FoundationItem(
                        id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                    do {
                        _ = try await FoundationJellyfinLibrary.$hlsCleanupLoad.withValue(
                            cleanup
                        ) {
                            try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(
                                true
                            ) {
                                try await library.playbackResource(for: item)
                            }
                        }
                        XCTFail("Changed negotiated source must not publish")
                    } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
                    for _ in 0..<100 {
                        if await recorder.requests.contains(where: { $0.httpMethod == "DELETE" }) {
                            break
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let requests = await recorder.requests
                    XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
                    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
                    XCTAssertEqual(requests.filter { $0.httpMethod == "DELETE" }.count, 1)
                }
            }
        }

        func testFixedAACRejectsContradictoryServerURLAndCleansOnlyItsSession() async throws {
            for flag in ["AllowAudioStreamCopy", "EnableAutoStreamCopy", "Static"] {
                let recorder = Recorder()
                let itemID = itemID
                let deviceID = session.deviceID
                let audio = """
                    {"Type":"Audio","Codec":"mp3","Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}
                    """
                let library = FoundationJellyfinLibrary(
                    session: session, streamingQuality: { .aac128 },
                    load: { request in
                        await recorder.append(request)
                        if request.httpMethod == "GET" {
                            return (
                                Data(
                                    """
                                    {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                                    "Protocol":"File","MediaStreams":[\(audio)]}]}
                                    """.utf8), Self.response(request)
                            )
                        }
                        return (
                            Data(
                                """
                                {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                                "MediaStreams":[\(audio)],"SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                                "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=aac&SegmentContainer=ts&AudioBitrate=128000&AudioStreamIndex=0&\(flag)=true"}]}
                                """.utf8), Self.response(request)
                        )
                    })
                let cleanup: FoundationJellyfinLibrary.Load = { request in
                    await recorder.append(request)
                    return (Data(), Self.response(request))
                }
                let item = FoundationItem(
                    id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                do {
                    let resource = try await FoundationJellyfinLibrary.$hlsCleanupLoad.withValue(
                        cleanup
                    ) {
                        try await library.playbackResource(for: item)
                    }
                    await resource.release()
                    XCTFail("Contradictory fixed policy must never publish a resource")
                } catch {
                    XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse)
                }
                for _ in 0..<100 {
                    if await recorder.requests.contains(where: { $0.httpMethod == "DELETE" }) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let requests = await recorder.requests
                XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "DELETE"])
                let cleanupRequest = try XCTUnwrap(requests.last)
                XCTAssertEqual(cleanupRequest.url?.path, "/proxy/jellyfin/Videos/ActiveEncodings")
                let query = try XCTUnwrap(
                    URLComponents(
                        url: try XCTUnwrap(cleanupRequest.url), resolvingAgainstBaseURL: false)?
                        .queryItems)
                XCTAssertEqual(
                    query.filter { $0.name.lowercased() == "playsessionid" }.map(\.value),
                    ["session-a"])
                XCTAssertEqual(
                    query.filter { $0.name.lowercased() == "deviceid" }.map(\.value), [deviceID])
                XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/universal") == true })
            }
        }

        func testHLSComparisonAcceptsEquivalentGUIDRouteSpellings() throws {
            let compact = "00112233445566778899aabbccddeeff"
            let guid = "00112233-4455-6677-8899-AABBCCDDEEFF"
            for (requested, returned) in [(compact, guid), (guid, compact)] {
                let url = try FoundationJellyfinLibrary.hlsURL(
                    "/audio/\(returned)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(session.deviceID)",
                    itemID: requested, sourceID: "source-a", serverSession: "session-a",
                    base: session.serverURL, token: session.accessToken, deviceID: session.deviceID)
                XCTAssertEqual(url.path, "/proxy/jellyfin/audio/\(returned)/master.m3u8")
            }
        }

        func testHLSComparisonRejectsUnsafeOrMismatchedNegotiatedURL() throws {
            let route = "/audio/\(itemID)/master.m3u8"
            let identities =
                "?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(session.deviceID)"
            for raw in [
                "https://other.invalid" + route + identities,
                "//other.invalid" + route + identities,
                "/audio/../master.m3u8" + identities,
                "/audio/00000000-0000-0000-0000-000000000002/master.m3u8" + identities,
                "/audio/00000000--0000-0000-0000-000000000001/master.m3u8" + identities,
                "/audio/%30" + itemID.dropFirst() + "/master.m3u8" + identities,
                "/audio//" + itemID + "/master.m3u8" + identities,
                "audio/" + itemID + "/master.m3u8" + identities,
                route + identities + "&PlaySessionId=session-b",
                route + "?MediaSourceId=source-b&PlaySessionId=session-a",
                route + "?MediaSourceId=source-a",
                route + identities + "&DeviceId=another-device",
                route + identities + "#fragment",
            ] {
                XCTAssertThrowsError(
                    try FoundationJellyfinLibrary.hlsURL(
                        raw, itemID: itemID, sourceID: "source-a", serverSession: "session-a",
                        base: session.serverURL, token: session.accessToken,
                        deviceID: session.deviceID))
            }
        }

        func testHLSComparisonDoesNotSilentlyFallbackWhenDenied() async throws {
            let recorder = Recorder()
            let library = FoundationJellyfinLibrary(session: session) { request in
                await recorder.append(request)
                return (Data(#"{"MediaSources":[]}"#.utf8), Self.response(request))
            }
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
            do {
                _ = try await FoundationJellyfinLibrary.$hlsOriginalPreferred.withValue(false) {
                    try await library.playbackResource(for: item)
                }
                XCTFail("Expected unavailable")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
            let count = await recorder.requests.count
            XCTAssertEqual(count, 1)
        }

    #endif

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
            XCTAssertEqual(values("sortBy"), [index == 0 ? "Name" : "SortName"])
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
                    #"{"Items":[{"Id":"00000000000000000000000000000002","Type":"Audio","PlaylistItemId":"membership-1"},{"Id":"00000000000000000000000000000001","Type":"Audio"},{"Id":"00000000000000000000000000000002","Type":"Audio"}],"StartIndex":100,"TotalRecordCount":200}"#
                        .utf8), Self.response(request)
            )
        }
        let page = try await library.playlistTracks(playlistID: itemID, startIndex: 100)
        XCTAssertEqual(
            page.items.map(\.id),
            ["00000000000000000000000000000002", itemID, "00000000000000000000000000000002"])
        XCTAssertEqual(page.items.first?.playlistEntryID, "membership-1")
        XCTAssertNil(page.items.last?.playlistEntryID)
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

    func testSuggestedSongsUsesOneBoundedArtistSampleIncludingUnplayedTracks() async throws {
        let recorder = Recorder()
        let libraryID = String(repeating: "9", count: 32)
        let library = FoundationJellyfinLibrary(session: session) { request in
            await recorder.append(request)
            let data = try JSONSerialization.data(withJSONObject: [
                "Items": (1...16).map { index in
                    [
                        "Id": String(format: "%032d", index), "Type": "Audio",
                        "Name": "Synthetic Song \(index)",
                        "AlbumId": String(format: "%032d", 100 + index / 3),
                        "Album": "Synthetic Album",
                        "UserData": ["Key": "synthetic", "PlayCount": 0],
                    ] as [String: Any]
                },
                "StartIndex": 0, "TotalRecordCount": 1000,
            ])
            return (data, Self.response(request))
        }.scoped(to: libraryID)
        let page = try await library.suggestedSongs(artistID: itemID)
        XCTAssertEqual(page.items.count, 12)
        XCTAssertTrue(page.items.allSatisfy { $0.playCount == 0 })
        XCTAssertNil(page.nextStartIndex)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let query = try XCTUnwrap(
            URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems)
        for (name, value) in [
            ("limit", "32"), ("startIndex", "0"), ("includeItemTypes", "Audio"),
            ("sortBy", "Random"), ("parentId", libraryID), ("albumArtistIds", itemID),
            ("enableUserData", "true"),
        ] {
            XCTAssertTrue(query.contains(URLQueryItem(name: name, value: value)), name)
        }
        XCTAssertFalse(query.contains { $0.name == "isPlayed" || $0.name == "isFavorite" })
    }

    func testSuggestedSongSelectionSpreadsAlbumsThenFillsSmallCatalogs() {
        func song(_ index: Int, album: String) -> FoundationItem {
            FoundationItem(
                id: "song-\(index)", title: "Song \(index)", subtitle: "", kind: .track,
                duration: nil, album: .init(id: album, title: album))
        }
        let sample = (0..<16).map { song($0, album: $0 < 10 ? "first" : "second") }
        let result = FoundationArtistSongSuggestions.select(from: sample)
        XCTAssertEqual(result.count, 12)
        XCTAssertEqual(
            result.prefix(4).map { $0.album!.id }, ["first", "first", "second", "second"])
        let singleAlbum = (0..<8).map { song($0, album: "only") }
        XCTAssertEqual(FoundationArtistSongSuggestions.select(from: singleAlbum), singleAlbum)
        XCTAssertTrue(FoundationArtistSongSuggestions.select(from: []).isEmpty)
    }

    func testSuggestedSongFavoritesHaveAModestStablePreferenceAndIgnoreRepeatIdentities() {
        var sample = (0..<40).map { index in
            FoundationItem(
                id: "song-\(index)", title: "Song \(index)", subtitle: "", kind: .track,
                duration: nil, album: .init(id: "album-\(index)", title: "Album"))
        }
        sample[3].isFavorite = true
        sample[31].isFavorite = true
        sample[32].isFavorite = true
        sample.insert(sample[0], at: 5)
        let result = FoundationArtistSongSuggestions.select(from: sample)
        XCTAssertEqual(Array(result.prefix(4).map(\.id)), ["song-0", "song-1", "song-3", "song-2"])
        XCTAssertEqual(Set(result.map(\.id)).count, 12)
        XCTAssertFalse(result.contains { $0.id == "song-32" })
        XCTAssertEqual(FoundationArtistSongSuggestions.select(from: sample), result)
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

    func testNewTracksUsesDateAddedAscendingWhileAlbumsStayDescendingAndBothKeepServerCursor()
        async throws
    {
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
            XCTAssertEqual(
                values("sortBy"), index == 0 ? ["DateCreated"] : ["DateCreated", "SortName"])
            XCTAssertEqual(values("sortOrder"), [index == 0 ? "Descending" : "Ascending"])
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

    @MainActor
    func testArtistSnapshotFreshnessSkipsRefetchButExplicitRefreshAndDefaultStillRead() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Date()
        let cache = FoundationCatalogPageCache(
            scope: "synthetic-freshness", root: directory, now: { saved })
        await cache.write(.init(items: [item("cached")], nextStartIndex: nil), key: "artist")
        let fresh = FoundationBrowseModel(
            refreshInterval: 1800, now: { saved.addingTimeInterval(60) }, usesCachedFreshness: true)
        fresh.configureCache(cache, key: "artist")
        await fresh.loadPending { _ in
            XCTFail("Fresh artist snapshot should not refetch")
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(fresh.items.map(\.id), ["cached"])
        XCTAssertTrue(fresh.hasFreshCachedContent)
        fresh.request(.refresh)
        var reads = 0
        await fresh.loadPending { _ in
            reads += 1
            return .init(items: [self.item("updated")], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(fresh.items.map(\.id), ["updated"])
        let stale = FoundationBrowseModel(
            refreshInterval: 1800, now: { saved.addingTimeInterval(1801) },
            usesCachedFreshness: true)
        stale.configureCache(cache, key: "artist")
        await stale.loadPending { _ in
            reads += 1
            return .init(items: [self.item("fresh")], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 2)
        let general = FoundationBrowseModel()
        general.configureCache(cache, key: "artist")
        await general.loadPending { _ in
            reads += 1
            return .init(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(reads, 3, "General/Favorites revalidation must retain its existing behavior")
        _ = await cache.invalidate()
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

        func testAccessibilityScrollCreatesDemandAndRailLandingClearsIt() throws {
            let initial = view([section("A", count: 30)])
            let coordinator = initial.makeCoordinator()
            let table = initial.makeTable(coordinator: coordinator)
            initial.updateTable(table, coordinator: coordinator)
            XCTAssertFalse(coordinator.hasScrollDemand)
            let accessible = try XCTUnwrap(table as? FoundationDemandTableView)
            _ = accessible.accessibilityScroll(.down)
            XCTAssertTrue(coordinator.hasScrollDemand)
            var jump = initial
            jump.anchorRowID = "A-29"
            jump.anchorRevision = 1
            jump.updateTable(table, coordinator: coordinator)
            XCTAssertFalse(coordinator.hasScrollDemand)
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

// Model tests explicitly supply each scroll demand; production activation never owns this loop.
extension FoundationBrowseModel {
    func drainDemandedPagesForTesting(using loader: (Int) async throws -> FoundationPage) async {
        await loadCatalogPage(using: loader)
        for _ in 0..<2_001 {
            guard !Task.isCancelled, errorMessage == nil, let offset = nextStartIndex else {
                return
            }
            await loadNextPage(using: loader)
            guard nextStartIndex != offset else { return }
        }
    }
}
