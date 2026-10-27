import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationRemoteListeningTests: XCTestCase {
    private static let owner = "00000000000000000000000000000002"
    private static let itemID = "00000000000000000000000000000001"
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)
    private static var session: FoundationSession {
        .init(
            serverURL: URL(string: "https://example.invalid/jellyfin/")!,
            accessToken: "fixture-token", userID: owner, deviceID: "own-device")
    }

    private static func row(
        device: String = "other-device", owner: String = FoundationRemoteListeningTests.owner,
        client: String = "Velacanto Native", name: String = "iPhone",
        paused: Bool = false, type: String = "Audio", active: Bool = true,
        age: TimeInterval = 0, now: Date = FoundationRemoteListeningTests.now
    ) -> [String: Any] {
        [
            "Id": "00000000000000000000000000000004",
            "UserId": owner, "Client": client, "DeviceId": device, "DeviceName": name,
            "IsActive": active,
            "LastPlaybackCheckIn": ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-age)),
            "NowPlayingItem": [
                "Id": Self.itemID, "Type": type, "Name": "Track",
                "Album": "Album", "AlbumId": "00000000000000000000000000000005",
                "AlbumArtist": "Artist", "RunTimeTicks": 1_800_000_000,
                "AlbumPrimaryImageTag": "00000000000000000000000000000006",
            ],
            "PlayState": ["IsPaused": paused, "PositionTicks": 900_000_000],
        ]
    }

    private static func data(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }

    func testStrictOwnerOwnDeviceClientFreshnessAndAudioFilters() throws {
        var additionalUserOnly = Self.row(owner: "00000000000000000000000000000003")
        additionalUserOnly["AdditionalUsers"] = [["UserId": Self.owner]]
        let rows = [
            Self.row(device: "own-device"), Self.row(device: "OWN-DEVICE"),
            Self.row(owner: ""), additionalUserOnly, Self.row(client: "Other App"),
            Self.row(paused: true), Self.row(type: "Movie"), Self.row(active: false),
            Self.row(age: 91), Self.row(age: -6),
            Self.row(device: "allowed", owner: "00000000-0000-0000-0000-000000000002"),
        ]
        let result = try FoundationRemoteListeningActivity.decode(
            Self.data(rows), userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.deviceLabel, "iPhone")
        XCTAssertNotEqual(result.first?.id, "allowed")
    }

    func testMissingFieldsNeverImplyPlaybackOrOwnerAndLabelsNeverInferPersonalPlatform() throws {
        var missingUser = Self.row()
        missingUser.removeValue(forKey: "UserId")
        var missingPaused = Self.row()
        missingPaused["PlayState"] = [:]
        var missingCheckIn = Self.row()
        missingCheckIn.removeValue(forKey: "LastPlaybackCheckIn")
        let result = try FoundationRemoteListeningActivity.decode(
            Self.data([missingUser, missingPaused, missingCheckIn]),
            userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertTrue(result.isEmpty)
        for label in [nil, "Apple", "Tyler’s iPhone", "<script>", "Windows"] as [String?] {
            XCTAssertEqual(FoundationClientDeviceName.activityLabel(label), "another device")
        }
        XCTAssertEqual(FoundationClientDeviceName.activityLabel("Mac"), "Mac")
        XCTAssertEqual(FoundationClientDeviceName.activityLabel("iPad"), "iPad")
    }

    func testDeduplicatesDevicesKeepsFreshestAndCapsThree() throws {
        let result = try FoundationRemoteListeningActivity.decode(
            Self.data([
                Self.row(device: "a", name: "Apple", age: 80),
                Self.row(device: "A", name: "Mac", age: 0),
                Self.row(device: "b", age: 10), Self.row(device: "c", age: 20),
                Self.row(device: "d", age: 30),
            ]), userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.deviceLabel, "Mac")
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
    }

    func testDecodeBudgetsRejectEntireResponseAndInvalidCurrentIdentity() throws {
        for data in [
            Data(repeating: 32, count: 1_048_577),
            try Self.data(Array(repeating: Self.row(), count: 513)),
        ] {
            XCTAssertThrowsError(
                try FoundationRemoteListeningActivity.decode(
                    data, userID: Self.owner, ownDeviceID: "own-device", now: Self.now))
        }
        for user in ["", "00000000000000000000000000000000", "not-user"] {
            XCTAssertThrowsError(
                try FoundationRemoteListeningActivity.decode(
                    Self.data([Self.row()]), userID: user, ownDeviceID: "own-device", now: Self.now)
            )
        }
    }

    func testActualAdapterOnlyReadsSessionsWithOrdinaryIdentityAndBoundedRequest() async throws {
        let recorder = RemoteListeningRequestRecorder()
        let library = FoundationJellyfinLibrary(session: Self.session, deviceName: .mac) {
            request in
            await recorder.append(request)
            return (
                try Self.data([Self.row(now: Date())]), Self.response(request)
            )
        }
        let result = try await library.remoteListeningActivity()
        XCTAssertEqual(result.count, 1)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/jellyfin/Sessions")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query, [URLQueryItem(name: "activeWithinSeconds", value: "90")])
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), Self.header(.mac))
    }

    func testActualActivityReadUsesOrdinaryAdmissionAndCancellationRemovesWaiter() async throws {
        let admission = FoundationNetworkAdmission(limit: 2)
        let held = try await admission.acquire()
        let recorder = RemoteListeningRequestRecorder()
        let library = FoundationJellyfinLibrary(
            session: Self.session,
            load: { request in
                await recorder.append(request)
                return (Data("[]".utf8), Self.response(request))
            }, networkAdmission: admission)
        let task = Task {
            try await FoundationRequestIntent.$isPlayback.withValue(true) {
                try await library.remoteListeningActivity()
            }
        }
        // Match the existing admission tests: wait for the actual queued state,
        // bounded by elapsed time rather than assuming a scheduler yield count.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await admission.pendingCount != 1 {
            guard ContinuousClock.now < deadline else {
                task.cancel()
                _ = try? await task.value
                await admission.release(held)
                XCTFail("Activity read did not enter ordinary admission within the test deadline")
                return
            }
            await Task.yield()
        }
        let pending = await admission.pendingCount
        XCTAssertEqual(pending, 1)
        let requestCount = await recorder.requests.count
        XCTAssertEqual(requestCount, 0)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled read succeeded")
        } catch {}
        let afterCancellation = await admission.pendingCount
        XCTAssertEqual(afterCancellation, 0)
        await admission.release(held)
    }

    func testHeaderDeviceNameDefaultAndExplicitNamesAcrossReadsAndBothDownloadRequests()
        async throws
    {
        let track = FoundationItem(
            id: Self.itemID, title: "Fixture", subtitle: "", kind: .track, duration: nil)
        for name in FoundationClientDeviceName.allCases {
            let recorder = RemoteListeningRequestRecorder()
            let library = FoundationJellyfinLibrary(session: Self.session, deviceName: name) {
                request in
                await recorder.append(request)
                let body: String
                if request.url!.path.contains("/Users/") {
                    body = """
                        {"Id":"\(Self.owner)","Policy":{"IsDisabled":false,"EnableMediaPlayback":true,
                        "AuthenticationProviderId":"fixture-auth","PasswordResetProviderId":"fixture-reset",
                        "EnableContentDownloading":true,"EnableAudioPlaybackTranscoding":true}}
                        """
                } else {
                    body = """
                        {"Id":"\(Self.itemID)","Type":"Audio","CanDownload":true,"RunTimeTicks":1800000000,
                        "MediaSources":[{"Id":"fixture-source","Protocol":"File","Container":"mp3","Size":123,
                        "RunTimeTicks":1800000000,"MediaStreams":[{"Type":"Audio","Codec":"mp3","Index":0}]}]}
                        """
                }
                return (Data(body.utf8), Self.response(request))
            }
            let source = try await library.downloadSource(for: track)
            let proposal = try await library.convertedDownloadProposal(for: track, quality: .aac128)
            XCTAssertEqual(
                source.request.value(forHTTPHeaderField: "Authorization"), Self.header(name))
            XCTAssertEqual(
                proposal.request.value(forHTTPHeaderField: "Authorization"), Self.header(name))
            let requests = await recorder.requests
            XCTAssertTrue(
                requests.allSatisfy {
                    $0.value(forHTTPHeaderField: "Authorization") == Self.header(name)
                })
            XCTAssertEqual(library.scoped(to: Self.itemID).deviceName, name)
            XCTAssertEqual(
                library.scoped(to: Self.itemID).listeningActivityScope,
                library.listeningActivityScope)
            XCTAssertEqual(library.session.deviceID, Self.session.deviceID)
            XCTAssertEqual(library.session.accessToken, Self.session.accessToken)
            XCTAssertEqual(
                library.catalogAccountIdentity,
                FoundationJellyfinLibrary(session: Self.session).catalogAccountIdentity)
        }
        let recorder = RemoteListeningRequestRecorder()
        let legacy = FoundationJellyfinLibrary(session: Self.session) { request in
            await recorder.append(request)
            return (Data("[]".utf8), Self.response(request))
        }
        _ = try await legacy.remoteListeningActivity()
        let headers = await recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(headers, [Self.header(.apple)])
    }

    func testSignInPassesOnlyGenericDeviceMetadataAndPreservesReturnedDeviceIdentity() async throws
    {
        for name in FoundationClientDeviceName.allCases {
            let recorder = RemoteListeningRequestRecorder()
            let session = try await FoundationJellyfinLibrary.signIn(
                serverURL: Self.session.serverURL, username: "fixture", password: "fixture",
                deviceName: name
            ) { request in
                await recorder.append(request)
                return (
                    Data(
                        "{\"AccessToken\":\"fixture-token\",\"User\":{\"Id\":\"\(Self.owner)\"}}"
                            .utf8), Self.response(request)
                )
            }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.httpMethod, "POST")
            let header = requests.first?.value(forHTTPHeaderField: "Authorization") ?? ""
            XCTAssertTrue(header.contains("Device=\"\(name.rawValue)\""))
            XCTAssertTrue(header.contains("DeviceId=\"\(session.deviceID)\""))
            XCTAssertEqual(session.userID, Self.owner)
            XCTAssertEqual(session.accessToken, Self.session.accessToken)
            XCTAssertNotNil(UUID(uuidString: session.deviceID))
        }
    }

    func testDeadlineCancelsCooperativeLoadAndCallerCancellationPropagates() async {
        let started = RemoteListeningSignal()
        do {
            let _: Int = try await FoundationRemoteListeningDeadline.run(timeout: .milliseconds(10))
            {
                await started.signal()
                try await Task.sleep(for: .seconds(60))
                return 1
            }
            XCTFail("Expected deadline failure")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let didStart = await started.value
        XCTAssertTrue(didStart)
        let task = Task {
            try await FoundationRemoteListeningDeadline.run {
                try await Task.sleep(for: .seconds(60))
                return 1
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {}
    }

    @MainActor
    func testRetiredContextNeverPublishesLateResponseOrError() async {
        let gate = RemoteListeningGate()
        let model = FoundationRemoteListeningModel()
        let old = Task {
            await model.refresh {
                await gate.wait()
                return [Self.activity]
            }
        }
        await gate.waitForStart()
        model.cancel()
        await model.refresh { [] }
        await gate.release()
        await old.value
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.unavailable)
        let failingGate = RemoteListeningGate()
        let staleFailure = Task {
            await model.refresh {
                await failingGate.wait()
                throw FoundationLibraryError.unavailable
            }
        }
        await failingGate.waitForStart()
        await model.refresh { [Self.activity] }
        await failingGate.release()
        await staleFailure.value
        XCTAssertEqual(model.activities, [Self.activity])
        XCTAssertFalse(model.unavailable)
        model.cancel()
        let cancelled = Task {
            await model.refresh {
                try await Task.sleep(for: .seconds(60))
                return [Self.activity]
            }
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertTrue(model.activities.isEmpty)
        XCTAssertFalse(model.unavailable)
    }

    @MainActor
    func testForegroundExpiryDoesNotPollAndRetiredExpiryCannotClearFreshActivity() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        await model.expireVisibleActivity(now: { Self.now }, sleep: { _ in })
        XCTAssertTrue(model.activities.isEmpty)
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let oldExpiry = Task {
            await model.expireVisibleActivity(now: { Self.now }) { _ in await gate.wait() }
        }
        await gate.waitForStart()
        model.cancel()
        await model.refresh { [Self.activity] }
        await gate.release()
        await oldExpiry.value
        XCTAssertEqual(model.activities, [Self.activity])
    }

    @MainActor
    func testPreCancelledRefreshPreservesFreshRowsAndExistingExpiryGeneration() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let existingExpiry = Task {
            await model.expireVisibleActivity(now: { Self.now }) { _ in await gate.wait() }
        }
        await gate.waitForStart()
        let loadCalled = RemoteListeningSignal()
        let staleRefresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.refresh {
                await loadCalled.signal()
                return []
            }
        }
        await staleRefresh.value
        XCTAssertEqual(model.activities, [Self.activity])
        XCTAssertFalse(model.unavailable)
        let called = await loadCalled.value
        XCTAssertFalse(called)
        await gate.release()
        await existingExpiry.value
        // The cancelled refresh must not silently advance generation: the valid
        // already-owned expiry still removes this activity when its deadline arrives.
        XCTAssertTrue(model.activities.isEmpty)
    }

    @MainActor
    func testPreCancelledExpiryCannotClearFreshRowsOrStartSleeping() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let sleepCalled = RemoteListeningSignal()
        let staleExpiry = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.expireVisibleActivity(now: { Self.now }) { _ in
                await sleepCalled.signal()
                try Task.checkCancellation()
            }
        }
        await staleExpiry.value
        XCTAssertEqual(model.activities, [Self.activity])
        XCTAssertFalse(model.unavailable)
        let called = await sleepCalled.value
        XCTAssertFalse(called)
    }

    @MainActor
    func testGuidePreferenceIsLocalBooleanAndExplicitHelpRemainsIndependent() {
        let suite = "fixture.remote-listening.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = FoundationHandoffGuidePreference(defaults: defaults)
        XCTAssertFalse(preference.suppressed)
        preference.suppressed = true
        XCTAssertTrue(FoundationHandoffGuidePreference(defaults: defaults).suppressed)
        XCTAssertEqual(
            defaults.dictionaryRepresentation()[FoundationHandoffGuidePreference.key] as? Bool, true
        )
        preference.suppressed = false
        XCTAssertFalse(preference.suppressed)
    }

    func testMapsCanonicalTrackAlbumArtworkAndSnapshotPositionWithoutMetadataRead() throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let result = try FoundationRemoteListeningActivity.decode(
            Self.data([Self.row()]), userID: Self.owner, ownDeviceID: "own-device", now: Self.now,
            catalogSource: source)
        let activity = try XCTUnwrap(result.first)
        XCTAssertEqual(activity.item.title, "Track")
        XCTAssertEqual(activity.item.subtitle, "Artist")
        XCTAssertEqual(activity.item.kind, .track)
        XCTAssertEqual(activity.item.album?.title, "Album")
        XCTAssertEqual(activity.item.catalogSource, source)
        XCTAssertEqual(activity.item.catalogArtworkItem.kind, .album)
        XCTAssertEqual(
            activity.item.catalogArtworkItem.primaryImageTag,
            "00000000000000000000000000000006")
        XCTAssertEqual(activity.item.catalogArtworkItem.catalogSource, source)
        XCTAssertEqual(activity.elapsed, 90)
        XCTAssertEqual(activity.item.duration, 180)
        XCTAssertEqual(activity.progress.fraction, 0.5)
        XCTAssertEqual(activity.progress.label, "1:30 / 3:00")
        XCTAssertEqual(activity.progress.accessibilityValue, "Elapsed 1:30, duration 3:00")
    }

    func testMissingMediaDetailsHaveHonestFallbackAndMissingItemOrSessionCannotMakeCard() throws {
        var missingDetails = Self.row()
        missingDetails["NowPlayingItem"] = ["Id": Self.itemID, "Type": "Audio"]
        missingDetails["PlayState"] = ["IsPaused": false]
        let mapped = try FoundationRemoteListeningActivity.decode(
            Self.data([missingDetails]), userID: Self.owner, ownDeviceID: "own-device",
            now: Self.now)
        XCTAssertEqual(mapped.first?.item.title, "Untitled")
        XCTAssertEqual(mapped.first?.item.subtitle, "Unknown Artist")
        XCTAssertNil(mapped.first?.item.album)
        XCTAssertEqual(mapped.first?.albumTitle, "Unknown Album")
        XCTAssertNil(mapped.first?.elapsed)
        XCTAssertEqual(mapped.first?.progress.fraction, 0)
        var albumWithoutID = Self.row()
        albumWithoutID["NowPlayingItem"] = [
            "Id": Self.itemID, "Type": "Audio", "Album": "Known Album",
        ]
        let albumFallback = try FoundationRemoteListeningActivity.decode(
            Self.data([albumWithoutID]), userID: Self.owner, ownDeviceID: "own-device",
            now: Self.now)
        XCTAssertEqual(albumFallback.first?.albumTitle, "Known Album")
        XCTAssertNil(albumFallback.first?.item.album)
        var missingItem = Self.row()
        missingItem["NowPlayingItem"] = ["Type": "Audio"]
        var missingSession = Self.row()
        missingSession.removeValue(forKey: "Id")
        XCTAssertTrue(
            try FoundationRemoteListeningActivity.decode(
                Self.data([missingItem, missingSession]), userID: Self.owner,
                ownDeviceID: "own-device", now: Self.now
            ).isEmpty)
    }

    func testProgressIsFiniteAndClampedForMissingNegativeOversizedAndNonfiniteTimes() {
        for (elapsed, duration, expected) in [
            (Double?.none, 180.0, 0.0), (-1, 180, 0), (900, 180, 1),
            (90, 0, 0), (Double.infinity, 180, 0), (90, Double.nan, 0),
        ] {
            let progress = FoundationListeningProgress(elapsed: elapsed, duration: duration)
            XCTAssertEqual(progress.fraction, expected)
            XCTAssertTrue(progress.fraction.isFinite)
        }
        let huge = FoundationListeningProgress(
            elapsed: Double(Int64.max) / 10_000_000, duration: 180)
        XCTAssertEqual(huge.fraction, 1)
        XCTAssertFalse(huge.label.isEmpty)
    }

    func testRemoteOnlySelectionIsAbsentWithoutRemoteAndDismissNeverRevealsFallback() {
        // Local queue/playback is intentionally not an input to this presentation policy.
        XCTAssertNil(FoundationContinueListeningSelection.select([], dismissed: []))
        let fresh = Self.activity
        let older = FoundationRemoteListeningActivity(
            id: "older", deviceKey: "older-device", deviceLabel: "iPhone",
            checkedInAt: Self.now.addingTimeInterval(-10), item: fresh.item,
            albumTitle: fresh.albumTitle, elapsed: 10)
        XCTAssertEqual(
            FoundationContinueListeningSelection.select(
                [older, fresh], dismissed: [])?.id, fresh.id)
        XCTAssertNil(
            FoundationContinueListeningSelection.select(
                [older, fresh], dismissed: [fresh.id]))
        // A local Now Playing bar cannot substitute a local card or change this result.
        XCTAssertEqual(
            FoundationContinueListeningInstructionAction.onTap(guideSuppressed: false), .fullGuide)
        XCTAssertEqual(
            FoundationContinueListeningInstructionAction.onTap(guideSuppressed: true),
            .inlineInstructions)
    }

    @MainActor
    func testDismissalIsAccountOwnedAndNewTrackOrSessionCanAppearWithoutPlaybackCommands() throws {
        let memory = FoundationContinueListeningDismissals()
        memory.configure(scope: "account-a")
        let initial = try XCTUnwrap(
            FoundationRemoteListeningActivity.decode(
                Self.data([Self.row()]), userID: Self.owner, ownDeviceID: "own-device",
                now: Self.now
            ).first)
        memory.dismiss(initial.id, scope: "account-a")
        var same = Self.row()
        same["PlayState"] = ["IsPaused": false, "PositionTicks": 910_000_000]
        let refreshed = try FoundationRemoteListeningActivity.decode(
            Self.data([same]), userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertNil(FoundationContinueListeningSelection.select(refreshed, dismissed: memory.keys))
        var nextTrack = Self.row()
        nextTrack["NowPlayingItem"] = ["Id": "00000000000000000000000000000007", "Type": "Audio"]
        let next = try FoundationRemoteListeningActivity.decode(
            Self.data([nextTrack]), userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertNotNil(FoundationContinueListeningSelection.select(next, dismissed: memory.keys))
        var nextSession = Self.row()
        nextSession["Id"] = "00000000000000000000000000000008"
        let session = try FoundationRemoteListeningActivity.decode(
            Self.data([nextSession]), userID: Self.owner, ownDeviceID: "own-device", now: Self.now)
        XCTAssertNotNil(
            FoundationContinueListeningSelection.select(session, dismissed: memory.keys))
        var nextOccurrence = Self.row()
        nextOccurrence["PlaylistItemId"] = "queue-occurrence-2"
        let occurrence = try FoundationRemoteListeningActivity.decode(
            Self.data([nextOccurrence]), userID: Self.owner, ownDeviceID: "own-device",
            now: Self.now)
        XCTAssertNotNil(
            FoundationContinueListeningSelection.select(occurrence, dismissed: memory.keys))
        memory.configure(scope: "account-b")
        XCTAssertTrue(memory.keys.isEmpty)
        memory.dismiss(initial.id, scope: "account-a")
        XCTAssertTrue(memory.keys.isEmpty)
        memory.configure(scope: nil)
        XCTAssertTrue(memory.keys.isEmpty)
    }

    @MainActor
    func testRemotePlaybackEndAndForegroundExpiryRemoveOnlyCardData() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        XCTAssertNotNil(
            FoundationContinueListeningSelection.select(model.activities, dismissed: []))
        await model.expireVisibleActivity(now: { Self.now }, sleep: { _ in })
        XCTAssertNil(FoundationContinueListeningSelection.select(model.activities, dismissed: []))
        await model.refresh { [Self.activity] }
        await model.refresh { [] }
        XCTAssertNil(FoundationContinueListeningSelection.select(model.activities, dismissed: []))
    }

    private static var activity: FoundationRemoteListeningActivity {
        .init(
            id: "fixture", deviceKey: "fixture-device", deviceLabel: "Mac", checkedInAt: now,
            item: FoundationItem(
                id: itemID, title: "Track", subtitle: "Artist", kind: .track,
                duration: 180), albumTitle: "Album", elapsed: 90)
    }
    private static func header(_ name: FoundationClientDeviceName) -> String {
        "MediaBrowser Client=\"Velacanto Native\", Device=\"\(name.rawValue)\", DeviceId=\"own-device\", Version=\"1\", Token=\"fixture-token\""
    }
    private static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private actor RemoteListeningRequestRecorder {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}
private actor RemoteListeningSignal {
    private(set) var value = false
    func signal() { value = true }
}
private actor RemoteListeningGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }
    func waitForStart() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
