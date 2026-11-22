import AVFoundation
import Combine
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

    func testStrictOwnerOwnDeviceFreshnessAndAudioFilters() throws {
        var additionalUserOnly = Self.row(owner: "00000000000000000000000000000003")
        additionalUserOnly["AdditionalUsers"] = [["UserId": Self.owner]]
        let rows = [
            Self.row(device: "own-device"), Self.row(device: "OWN-DEVICE"),
            Self.row(owner: ""), additionalUserOnly,
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
    func testSubscriptionPublishesChangedSnapshotsAndRejectsRetiredCallbacks() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let updated = FoundationRemoteListeningActivity(
            id: Self.activity.id, deviceKey: Self.activity.deviceKey, deviceLabel: "Mac",
            checkedInAt: Self.now, item: Self.activity.item, albumTitle: "Album", elapsed: 110)
        let task = Task {
            await model.observe { receive in
                await receive([updated])
                await gate.wait()
                await receive([])
            }
        }
        await gate.waitForStart()
        XCTAssertEqual(model.activities, [updated])
        model.suspend()
        await gate.release()
        await task.value
        XCTAssertEqual(
            model.activities, [updated], "An old subscription cannot clear a newer context")
    }

    @MainActor
    func testSubscriptionCancellationEndsLifetimeWithoutClearingSnapshot() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let started = RemoteListeningGate()
        let closed = RemoteListeningSignal()
        let task = Task {
            await model.observe { receive in
                await started.wait()
                do { try await Task.sleep(for: .seconds(60)) } catch {}
                await closed.signal()
                await receive([])
            }
        }
        await started.waitForStart()
        task.cancel()
        await started.release()
        await task.value
        let didClose = await closed.value
        XCTAssertTrue(didClose)
        XCTAssertEqual(model.activities, [Self.activity])
        XCTAssertFalse(model.unavailable)
    }

    @MainActor
    func testSubscriptionReconnectsOnceWithReconciliationAndCancellationStopsIt() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let probe = RemoteListeningSubscriptionProbe()
        let updated = FoundationRemoteListeningActivity(
            id: Self.activity.id, deviceKey: Self.activity.deviceKey, deviceLabel: "Mac",
            checkedInAt: Self.now, item: Self.activity.item, albumTitle: "Album", elapsed: 110)
        let task = Task {
            await model.observe(
                reconcile: {
                    await probe.reconcile()
                    return [Self.activity]
                },
                sleep: { interval in await probe.record(interval) },
                using: { receive in
                    let attempt = await probe.begin()
                    if attempt == 1 { throw URLError(.networkConnectionLost) }
                    await receive([updated])
                    await gate.wait()
                    throw CancellationError()
                })
        }
        await gate.waitForStart()
        XCTAssertEqual(model.activities, [updated])
        task.cancel()
        await gate.release()
        await task.value
        let count = await probe.count
        let reconciles = await probe.reconciles
        let intervals = await probe.intervals
        XCTAssertEqual(count, 2)
        XCTAssertEqual(reconciles, 1)
        XCTAssertEqual(intervals, [.seconds(1)])
        XCTAssertEqual(model.activities, [updated])
        XCTAssertFalse(model.unavailable)
    }

    @MainActor
    func testSubscriptionReconnectIsBoundedAndNeverRetriesAuthInvalidDataOrCancellation() async {
        let errors: [any Error] = [
            URLError(.networkConnectionLost), FoundationLibraryError.authentication,
            FoundationLibraryError.invalidResponse, CancellationError(),
        ]
        for error in errors {
            let model = FoundationRemoteListeningModel()
            let probe = RemoteListeningSubscriptionProbe()
            await model.observe(
                sleep: { interval in await probe.record(interval) },
                using: { _ in
                    _ = await probe.begin()
                    throw error
                })
            let count = await probe.count
            let intervals = await probe.intervals
            if error is URLError {
                XCTAssertEqual(count, 3)
                XCTAssertEqual(intervals, [.seconds(1), .seconds(2)])
            } else {
                XCTAssertEqual(count, 1)
                XCTAssertTrue(intervals.isEmpty)
            }
        }
    }

    @MainActor
    func testSubscriptionFailureRetainsSnapshotUntilExpiry() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        await model.observe { _ in throw FoundationLibraryError.unavailable }
        XCTAssertTrue(model.unavailable)
        XCTAssertEqual(model.activities, [Self.activity])
        model.removeExpiredActivities(now: Self.now.addingTimeInterval(90))
        XCTAssertTrue(model.activities.isEmpty)
    }

    func testSessionSubscriptionRequestPreservesBaseIdentityAndNeverUsesTokenQuery() throws {
        let request = try FoundationJellyfinLibrary.remoteListeningSocketRequest(
            session: Self.session, deviceName: .iPhone)
        XCTAssertEqual(request.url?.scheme, "wss")
        XCTAssertEqual(request.url?.path, "/jellyfin/socket")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems, [URLQueryItem(name: "deviceId", value: "own-device")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), Self.header(.iPhone))
        XCTAssertFalse(request.url!.absoluteString.contains("fixture-token"))
    }

    func testSessionSubscriptionDecodesRawSnapshotsWithoutTreatingMalformedDataAsEmpty() throws {
        let source = try FoundationCatalogSource.jellyfin(scope: String(repeating: "a", count: 64))
        let data = try JSONSerialization.data(withJSONObject: [
            "MessageType": "Sessions", "Data": [Self.row()],
        ])
        let update = try FoundationJellyfinLibrary.remoteListeningSocketUpdate(
            data, session: Self.session, catalogSource: source, now: Self.now)
        guard case .sessions(let activities) = update else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.item.id, Self.itemID)
        let empty = try JSONSerialization.data(withJSONObject: [
            "MessageType": "Sessions", "Data": [],
        ])
        XCTAssertEqual(
            try FoundationJellyfinLibrary.remoteListeningSocketUpdate(
                empty, session: Self.session, catalogSource: source, now: Self.now), .sessions([]))
        for value: [String: Any] in [
            ["MessageType": "Sessions"], ["MessageType": "Sessions", "Data": "invalid"],
        ] {
            XCTAssertThrowsError(
                try FoundationJellyfinLibrary.remoteListeningSocketUpdate(
                    JSONSerialization.data(withJSONObject: value), session: Self.session,
                    catalogSource: source, now: Self.now))
        }
        XCTAssertThrowsError(
            try FoundationJellyfinLibrary.remoteListeningSocketUpdate(
                Data(repeating: 0, count: 1_048_577), session: Self.session,
                catalogSource: source, now: Self.now))
        for (type, expected): (String, FoundationJellyfinLibrary.RemoteListeningSocketUpdate) in [
            ("ForceKeepAlive", .keepAlive), ("Play", .ignored), ("KeepAlive", .ignored),
        ] {
            let data = try JSONSerialization.data(withJSONObject: ["MessageType": type])
            XCTAssertEqual(
                try FoundationJellyfinLibrary.remoteListeningSocketUpdate(
                    data, session: Self.session, catalogSource: source, now: Self.now), expected)
        }
    }

    @MainActor
    func testRepeatedServerSnapshotDoesNotPublishOrResetProgressAnchor() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let revision = model.snapshotRevision
        var publications = 0
        let token = model.objectWillChange.sink { publications += 1 }
        let repeated = FoundationRemoteListeningActivity(
            id: Self.activity.id, deviceKey: Self.activity.deviceKey, deviceLabel: "Mac",
            checkedInAt: Self.now, item: Self.activity.item, albumTitle: "Album", elapsed: 90,
            observedAt: Self.now.addingTimeInterval(10))
        await model.refresh { [repeated] }
        XCTAssertEqual(publications, 0)
        XCTAssertEqual(model.snapshotRevision, revision)
        XCTAssertEqual(model.activities.first?.observedAt, Self.now)
        let updated = FoundationRemoteListeningActivity(
            id: Self.activity.id, deviceKey: Self.activity.deviceKey, deviceLabel: "Mac",
            checkedInAt: Self.now.addingTimeInterval(10), item: Self.activity.item,
            albumTitle: "Album", elapsed: 100, observedAt: Self.now.addingTimeInterval(10))
        await model.refresh { [updated] }
        XCTAssertGreaterThan(publications, 0)
        XCTAssertNotEqual(model.snapshotRevision, revision)
        XCTAssertEqual(model.activities, [updated])
        token.cancel()
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
    func testRefreshRetainsCardUntilAuthoritativeTrackAndProgressReplaceIt() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let updated = FoundationRemoteListeningActivity(
            id: Self.activity.id, deviceKey: Self.activity.deviceKey, deviceLabel: "Mac",
            checkedInAt: Self.now, item: Self.activity.item, albumTitle: "Album", elapsed: 110)
        let refresh = Task {
            await model.refresh {
                await gate.wait()
                return [updated]
            }
        }
        await gate.waitForStart()
        XCTAssertEqual(model.activities, [Self.activity], "Refreshing must not remove the card")
        await gate.release()
        await refresh.value
        XCTAssertEqual(model.activities, [updated])
        XCTAssertEqual(model.activities.first?.id, Self.activity.id)
        XCTAssertEqual(model.activities.first?.progress.label, "1:50 / 3:00")
        await model.refresh { [] }
        XCTAssertTrue(model.activities.isEmpty, "An authoritative end must still remove the card")
    }

    @MainActor
    func testSceneSuspensionRetainsFreshCardAndRejectsRetiredResponse() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let gate = RemoteListeningGate()
        let refresh = Task {
            await model.refresh {
                await gate.wait()
                return []
            }
        }
        await gate.waitForStart()
        model.suspend()
        XCTAssertEqual(model.activities, [Self.activity])
        await gate.release()
        await refresh.value
        XCTAssertEqual(model.activities, [Self.activity])
        await model.refresh { throw FoundationLibraryError.unavailable }
        XCTAssertTrue(model.unavailable)
        XCTAssertEqual(model.activities, [Self.activity], "Transient failure is not a remote stop")
        model.removeExpiredActivities(now: Self.now.addingTimeInterval(89))
        XCTAssertEqual(model.activities, [Self.activity])
        model.removeExpiredActivities(now: Self.now.addingTimeInterval(90))
        XCTAssertTrue(
            model.activities.isEmpty, "A retained card cannot outlive its freshness bound")
    }

    @MainActor
    func testRefreshDoesNotRetireAcceptedSnapshotsIndependentExpiry() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        let expiryGate = RemoteListeningGate()
        let expiry = Task {
            await model.expireVisibleActivity(now: { Self.now }) { _ in await expiryGate.wait() }
        }
        await expiryGate.waitForStart()
        let refreshGate = RemoteListeningGate()
        let refresh = Task {
            await model.refresh {
                await refreshGate.wait()
                throw FoundationLibraryError.unavailable
            }
        }
        await refreshGate.waitForStart()
        XCTAssertEqual(model.activities, [Self.activity])
        await expiryGate.release()
        await expiry.value
        XCTAssertTrue(model.activities.isEmpty, "A stalled refresh must not extend freshness")
        await refreshGate.release()
        await refresh.value
        XCTAssertTrue(model.activities.isEmpty)
    }

    @MainActor
    func testCancelledExpiryPreservesCardAndExplicitResetStillClearsIt() async {
        let model = FoundationRemoteListeningModel()
        await model.refresh { [Self.activity] }
        await model.expireVisibleActivity(
            now: { Self.now }, sleep: { _ in throw CancellationError() })
        XCTAssertEqual(model.activities, [Self.activity])
        model.cancel()
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
private actor RemoteListeningSubscriptionProbe {
    private(set) var count = 0
    private(set) var reconciles = 0
    private(set) var intervals: [Duration] = []
    func begin() -> Int {
        count += 1
        return count
    }
    func reconcile() { reconciles += 1 }
    func record(_ interval: Duration) { intervals.append(interval) }
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

/// Real Web-producer-shaped snapshots; no live server, token or media request.
private enum CrossClientFixtures {
    static let owner = "00000000000000000000000000000002"
    static let sourceSession = "00000000000000000000000000000004"
    static let first = "00000000000000000000000000000001"
    static let current = "00000000000000000000000000000003"
    static var session: FoundationSession {
        .init(
            serverURL: URL(string: "https://example.invalid/jellyfin/")!,
            accessToken: "fixture-token", userID: owner, deviceID: "own-device")
    }
    static func guidD(_ value: String) -> String {
        let widths = [8, 4, 4, 4, 12]
        var tail = value[...]
        return widths.map { width in
            let part = String(tail.prefix(width))
            tail = tail.dropFirst(width)
            return part
        }.joined(separator: "-").uppercased()
    }
    static func media(_ id: String) -> [String: Any] {
        [
            "Id": id, "Name": "Synthetic", "Type": "Audio", "RunTimeTicks": 80_000_000,
            "Album": "Synthetic Album", "AlbumArtist": "Synthetic Artist",
        ]
    }
    static func row(
        position: Int64 = 10_000_000, changed: Bool = false,
        fullItems: Bool = true, control: Bool = true
    ) -> [String: Any] {
        var queue = [
            ["Id": first, "PlaylistItemId": "playlistItem0"],
            ["Id": current, "PlaylistItemId": "playlistItem1"],
            ["Id": first, "PlaylistItemId": "playlistItem2"],
        ]
        if changed { queue.reverse() }
        var row: [String: Any] = [
            "Id": sourceSession, "UserId": owner,
            "Client": "Jellyfin Web", "DeviceId": "browser-device", "DeviceName": "Private name",
            "IsActive": true, "SupportsRemoteControl": control,
            "LastPlaybackCheckIn": ISO8601DateFormatter().string(from: Date()),
            "PlaylistItemId": "playlistItem1", "NowPlayingItem": media(current),
            "NowPlayingQueue": queue,
            "PlayState": [
                "PositionTicks": position, "IsPaused": false,
                "RepeatMode": "RepeatAll", "PlaybackOrder": "Default", "ShuffleMode": "Shuffle",
            ],
        ]
        if fullItems { row["NowPlayingQueueFullItems"] = [media(current), media(first)] }
        return row
    }
    static func data(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }
    static func source() throws -> FoundationCatalogSource {
        try .jellyfin(scope: FoundationJellyfinLibrary(session: session).catalogAccountIdentity)
    }
    static func offer(
        _ row: [String: Any], selection: FoundationRemoteContinuationSelection = .fullQueue
    ) throws -> FoundationRemoteContinuationOffer {
        try .decode(
            data([row]), sessionID: sourceSession, userID: owner, ownDeviceID: session.deviceID,
            scope: FoundationJellyfinLibrary(session: session).listeningActivityScope,
            catalogSource: source(), now: Date(), selection: selection)
    }
    static func activity(_ row: [String: Any]) throws -> FoundationRemoteListeningActivity {
        try XCTUnwrap(
            FoundationRemoteListeningActivity.decode(
                data([row]), userID: owner,
                ownDeviceID: session.deviceID, now: Date(), catalogSource: source()
            ).first)
    }
    static func response(_ request: URLRequest, code: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
    }
}

final class FoundationRemoteContinuationTests: XCTestCase {
    #if DEBUG
        func testRemoteContinuationDiagnosticSeparatesPostRefreshGuards() {
            let fields = FoundationRemoteContinuationDiagnostic.fields(
                .postRefresh, outcome: .observed, selection: .fullQueue,
                postRefresh: .init(
                    afterRefreshPresent: true, receiverPlaying: true, networkAllowed: true,
                    supportsControl: false, selectionCanControl: true))
            XCTAssertEqual(
                fields,
                "remote-continuation stage=postRefresh outcome=observed command=Stop"
                    + " afterRefreshPresent=1 receiverPlaying=1 networkAllowed=1"
                    + " supportsControl=0 selectionCanControl=1")
        }

        func testRemoteContinuationDiagnosticRejectsPrivateErrorFields() {
            let secret = "private-token-host-track"
            let underlying = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
                NSLocalizedDescriptionKey: secret,
                NSURLErrorFailingURLErrorKey: URL(string: "https://example.invalid/" + secret)!,
                NSUnderlyingErrorKey: NSError(domain: secret, code: 999, userInfo: [:]),
            ])
            let error = NSError(domain: secret, code: 123, userInfo: [
                NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: underlying,
            ])
            let fields = FoundationRemoteContinuationDiagnostic.fields(
                .withheld, outcome: .failed, selection: .fullQueue, failedAt: .command, error: error)
            XCTAssertEqual(
                fields,
                "remote-continuation stage=withheld outcome=failed command=Stop failedAt=command error=other:0 underlying=url:-1001")
            XCTAssertFalse(fields.contains(secret))
            XCTAssertFalse(fields.contains("https"))
            XCTAssertFalse(fields.contains("999"))
        }
    #endif

    func testAutomaticContinuationPreservesCompleteReportedQueueAndDuplicateOccurrences() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row(), selection: .automatic)
        XCTAssertEqual(offer.selection, .fullQueue)
        XCTAssertEqual(
            offer.queue.map(\.itemID),
            [
                CrossClientFixtures.first, CrossClientFixtures.current, CrossClientFixtures.first,
            ])
        XCTAssertEqual(Set(offer.queue.map(\.sourceID)).count, 3)
        XCTAssertEqual(offer.repeatMode, .all)
    }

    func testAutomaticContinuationUsesOnlyVerifiedCurrentSongForUnusableQueues() throws {
        var missing = CrossClientFixtures.row()
        missing.removeValue(forKey: "NowPlayingQueue")
        var stale = CrossClientFixtures.row()
        stale["NowPlayingQueue"] = [["Id": CrossClientFixtures.first, "PlaylistItemId": "old"]]
        var malformed = CrossClientFixtures.row()
        malformed["NowPlayingQueue"] = [["Id": CrossClientFixtures.first]]
        var duplicate = CrossClientFixtures.row()
        duplicate["NowPlayingQueue"] = [
            ["Id": CrossClientFixtures.current, "PlaylistItemId": "playlistItem1"],
            ["Id": CrossClientFixtures.first, "PlaylistItemId": "playlistItem1"],
        ]
        var noOccurrence = missing
        noOccurrence.removeValue(forKey: "PlaylistItemId")
        var noRepeat = CrossClientFixtures.row()
        var state = try XCTUnwrap(noRepeat["PlayState"] as? [String: Any])
        state.removeValue(forKey: "RepeatMode")
        noRepeat["PlayState"] = state
        for row in [missing, stale, malformed, duplicate, noOccurrence, noRepeat] {
            let offer = try CrossClientFixtures.offer(row, selection: .automatic)
            XCTAssertEqual(offer.selection, .currentSong)
            XCTAssertEqual(offer.queue.map(\.itemID), [CrossClientFixtures.current])
            XCTAssertEqual(offer.repeatMode, .off)
            XCTAssertEqual(offer.activityID, try CrossClientFixtures.activity(row).id)
        }
    }

    func testAutomaticContinuationNeverFallsBackFromInvalidCurrentSource() throws {
        for key in [
            "UserId", "DeviceId", "NowPlayingItem", "LastPlaybackCheckIn", "PlaylistItemId",
        ] {
            var row = CrossClientFixtures.row()
            switch key {
            case "UserId": row[key] = CrossClientFixtures.first
            case "DeviceId": row[key] = CrossClientFixtures.session.deviceID
            case "NowPlayingItem": row[key] = ["Id": "invalid", "Type": "Audio"]
            case "LastPlaybackCheckIn":
                row[key] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -120))
            default: row[key] = "invalid\noccurrence"
            }
            XCTAssertThrowsError(try CrossClientFixtures.offer(row, selection: .automatic), key)
        }
    }

    func testAutomaticAdapterAuthorizesConcreteQueueOrCurrentSongWithoutChangingPolicy()
        async throws
    {
        for songOnly in [false, true] {
            let transport = CrossClientTransport(songOnly: songOnly)
            let library = FoundationJellyfinLibrary(
                session: CrossClientFixtures.session, load: { try await transport.load($0) })
            let offer = try await library.prepareRemotePlayback(
                CrossClientFixtures.activity(CrossClientFixtures.row()))
            XCTAssertEqual(offer.selection, songOnly ? .currentSong : .fullQueue)
            let authorized = try await library.authorizeRemoteContinuation(offer)
            XCTAssertEqual(authorized.selection, offer.selection)
            XCTAssertEqual(authorized.fingerprint, offer.fingerprint)
            XCTAssertEqual(authorized.queue.count, songOnly ? 1 : 3)
            let requests = await transport.requests
            XCTAssertTrue(requests.allSatisfy { $0.httpMethod != "POST" })
        }
    }

    func testAutomaticAdapterPropagatesNetworkAuthorizationAndCancellationFailures() async throws {
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        let networkRequests = RemoteListeningRequestRecorder()
        let network = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session,
            load: { request in
                await networkRequests.append(request)
                throw URLError(.notConnectedToInternet)
            })
        do {
            _ = try await network.prepareRemotePlayback(activity)
            XCTFail("Network failure must not produce a song offer")
        } catch {}
        let networkCount = await networkRequests.requests.count
        XCTAssertEqual(networkCount, 1)
        let deniedRequests = RemoteListeningRequestRecorder()
        let denied = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session,
            load: { request in
                await deniedRequests.append(request)
                return (Data(), CrossClientFixtures.response(request, code: 401))
            })
        do {
            _ = try await denied.prepareRemotePlayback(activity)
            XCTFail("Authorization failure must not produce a song offer")
        } catch {}
        let deniedCount = await deniedRequests.requests.count
        XCTAssertEqual(deniedCount, 1)
        let cancelledRequests = RemoteListeningRequestRecorder()
        let cancelled = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session,
            load: { request in
                await cancelledRequests.append(request)
                throw CancellationError()
            })
        do {
            _ = try await cancelled.prepareRemotePlayback(activity)
            XCTFail("Cancellation must not produce a song offer")
        } catch {}
        let cancelledCount = await cancelledRequests.requests.count
        XCTAssertEqual(cancelledCount, 1)
    }

    func testExplicitSongSelectionNeverInfersMissingQueueOrCopiesSourceModes() throws {
        let queues: [[[String: String]]?] = [
            nil, [], [["Id": CrossClientFixtures.first, "PlaylistItemId": "stale"]],
        ]
        for reportedQueue in queues {
            var row = CrossClientFixtures.row()
            row["NowPlayingQueue"] = reportedQueue
            row.removeValue(forKey: "NowPlayingQueueFullItems")
            let song = try CrossClientFixtures.offer(row, selection: .currentSong)
            XCTAssertEqual(song.queue.map(\.itemID), [CrossClientFixtures.current])
            XCTAssertEqual(song.reportedOccurrence, "playlistItem1")
            XCTAssertEqual(song.repeatMode, .off)
            XCTAssertEqual(song.selection, .currentSong)
            XCTAssertEqual(song.activityID, try CrossClientFixtures.activity(row).id)
            let payload = try song.payload(scope: String(repeating: "a", count: 64), id: UUID())
            XCTAssertEqual(payload.session?.entries.count, 1)
            XCTAssertEqual(payload.session?.shuffle, false)
            XCTAssertThrowsError(try CrossClientFixtures.offer(row))
        }
        let full = try CrossClientFixtures.offer(CrossClientFixtures.row())
        let song = try CrossClientFixtures.offer(CrossClientFixtures.row(), selection: .currentSong)
        XCTAssertThrowsError(try song.matching(full))
        XCTAssertThrowsError(try full.matching(song))
    }

    func testSongWithoutReportedOccurrenceStartsButCannotAutomaticallyPauseSource() throws {
        var row = CrossClientFixtures.row()
        row.removeValue(forKey: "PlaylistItemId")
        row.removeValue(forKey: "NowPlayingQueue")
        let song = try CrossClientFixtures.offer(row, selection: .currentSong)
        XCTAssertEqual(song.queue.count, 1)
        XCTAssertFalse(song.canPauseCurrentSong)
        XCTAssertEqual(song.activityID, try CrossClientFixtures.activity(row).id)
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
    }

    func testSongMatchingRejectsSourceIdentityOccurrenceAndMediaChanges() throws {
        var row = CrossClientFixtures.row()
        var state = try XCTUnwrap(row["PlayState"] as? [String: Any])
        state["MediaSourceId"] = "source-version-one"
        row["PlayState"] = state
        let expected = try CrossClientFixtures.offer(row, selection: .currentSong)
        for key in ["DeviceId", "Client", "PlaylistItemId"] {
            var changed = row
            changed[key] = "different"
            XCTAssertThrowsError(try CrossClientFixtures.offer(changed, selection: .currentSong).matching(expected))
        }
        var changed = row
        state["MediaSourceId"] = "source-version-two"
        changed["PlayState"] = state
        XCTAssertThrowsError(try CrossClientFixtures.offer(changed, selection: .currentSong).matching(expected))
        changed = row
        changed["UserId"] = CrossClientFixtures.first
        XCTAssertThrowsError(try CrossClientFixtures.offer(changed, selection: .currentSong))
        changed = row
        changed["LastPlaybackCheckIn"] = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -120))
        XCTAssertThrowsError(try CrossClientFixtures.offer(changed, selection: .currentSong))
    }

    func testSongAdapterHydratesOnlyCurrentItemAndDispatchesPauseNotStop() async throws {
        let transport = CrossClientTransport(confirmsStop: true, songOnly: true)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await transport.load($0) })
        let offer = try await library.prepareRemoteCurrentSong(
            CrossClientFixtures.activity(CrossClientFixtures.row()))
        let authorized = try await library.authorizeRemoteContinuation(offer)
        let fresh = try await library.refreshRemoteContinuation(authorized)
        XCTAssertEqual(fresh.selection, .currentSong)
        XCTAssertEqual(fresh.queue.count, 1)
        try await library.stopRemoteContinuation(fresh)
        let confirmed = try await library.confirmRemoteContinuationStopped(fresh)
        XCTAssertTrue(confirmed)
        let requests = await transport.requests
        let metadata = requests.filter { $0.url?.path.hasSuffix("/Items") == true }
        XCTAssertEqual(metadata.count, 2)
        for request in metadata {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.filter { $0.name == "ids" }.compactMap(\.value), [CrossClientFixtures.current])
            XCTAssertEqual(query.first(where: { $0.name == "userId" })?.value, CrossClientFixtures.owner)
        }
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.map { $0.url?.lastPathComponent }, ["Pause"])
    }

    func testOpaqueRemoteDeviceByteBoundariesApplyToDiscoveryAndQueuePreparation() throws {
        for device in [
            String(repeating: "a", count: 128), String(repeating: "b", count: 129),
            String(repeating: "c", count: 512), String(repeating: "d", count: 2048),
            String(repeating: "é", count: 1024),
        ] {
            var row = CrossClientFixtures.row()
            row["DeviceId"] = device
            XCTAssertEqual(try CrossClientFixtures.activity(row).remoteDeviceID, device)
            XCTAssertEqual(try CrossClientFixtures.offer(row).deviceID, device)
        }
        for device in [
            "", String(repeating: "a", count: 2049), String(repeating: "é", count: 1025),
            "leading\ncontrol", "trailing-control\u{7F}", "embedded\0control",
        ] {
            var row = CrossClientFixtures.row()
            row["DeviceId"] = device
            let discovered = try FoundationRemoteListeningActivity.decode(
                CrossClientFixtures.data([row]), userID: CrossClientFixtures.owner,
                ownDeviceID: "own-device", now: Date())
            XCTAssertTrue(discovered.isEmpty)
            XCTAssertThrowsError(try CrossClientFixtures.offer(row))
        }
        var missing = CrossClientFixtures.row()
        missing.removeValue(forKey: "DeviceId")
        XCTAssertTrue(
            try FoundationRemoteListeningActivity.decode(
                CrossClientFixtures.data([missing]), userID: CrossClientFixtures.owner,
                ownDeviceID: "own-device", now: Date()
            ).isEmpty)
        XCTAssertThrowsError(try CrossClientFixtures.offer(missing))
        // This policy is for remote opaque device IDs, not our native current identity.
        XCTAssertThrowsError(
            try FoundationRemoteListeningActivity.decode(
                CrossClientFixtures.data([CrossClientFixtures.row()]),
                userID: CrossClientFixtures.owner, ownDeviceID: String(repeating: "x", count: 129),
                now: Date()))
    }

    func testLongOpaqueDeviceKeepsExactMatchingAndExistingOccurrenceLimits() throws {
        var row = CrossClientFixtures.row()
        let device = "AbC/" + String(repeating: "d", count: 200) + "+1"
        row["DeviceId"] = device
        let original = try CrossClientFixtures.offer(row)
        XCTAssertEqual(original.deviceID, device)
        XCTAssertEqual(try CrossClientFixtures.offer(row).matching(original).deviceID, device)
        row["DeviceId"] = device.lowercased()
        XCTAssertThrowsError(try CrossClientFixtures.offer(row).matching(original))
        row["DeviceId"] = device + "different"
        XCTAssertThrowsError(try CrossClientFixtures.offer(row).matching(original))
        row["DeviceId"] = device
        row.removeValue(forKey: "NowPlayingItem")
        XCTAssertTrue(
            try FoundationRemoteContinuationOffer.stopped(
                CrossClientFixtures.data([row]), expected: original,
                userID: CrossClientFixtures.owner))
        row["DeviceId"] = device.lowercased()
        XCTAssertFalse(
            try FoundationRemoteContinuationOffer.stopped(
                CrossClientFixtures.data([row]), expected: original,
                userID: CrossClientFixtures.owner))
        row = CrossClientFixtures.row()
        row["DeviceId"] = device
        row["PlaylistItemId"] = String(repeating: "p", count: 129)
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
    }

    func testWebGeneratedLongDeviceUsesExistingRequestAndStopBoundaries() async throws {
        // Matches official Web generation with a wholly synthetic user-agent and timestamp.
        let userAgent =
            "SyntheticBrowser/1.0 (SyntheticPlatform) " + String(repeating: "x", count: 90)
        let device = Data((userAgent + "|1700000000000").utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "1")
        XCTAssertGreaterThan(device.utf8.count, 128)
        var row = CrossClientFixtures.row()
        row["DeviceId"] = device
        let recorder = CrossClientTransport(customSource: try CrossClientFixtures.data([row]))
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        let activities = try await library.remoteListeningActivity()
        let activity = try XCTUnwrap(activities.first)
        XCTAssertEqual(activity.remoteDeviceID, device)
        let offer = try await library.prepareRemoteContinuation(activity)
        XCTAssertEqual(offer.deviceID, device)
        let refreshed = try await library.refreshRemoteContinuation(offer)
        XCTAssertEqual(refreshed.deviceID, device)
        XCTAssertEqual(refreshed.queue, offer.queue)
        try await library.stopRemoteContinuation(refreshed)
        let confirmed = try await library.confirmRemoteContinuationStopped(refreshed)
        XCTAssertFalse(confirmed, "A command response alone never proves the source stopped")
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "GET", "GET", "POST", "GET"])
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/Items") == true }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/Playing/Stop") == true }.count, 1)
        for request in requests {
            XCTAssertFalse(request.url!.absoluteString.contains(device))
            XCTAssertFalse(
                (request.value(forHTTPHeaderField: "Authorization") ?? "").contains(device))
            XCTAssertNil(request.httpBody)
        }
        XCTAssertEqual(
            offer.entries.map(\.item.id),
            [CrossClientFixtures.first, CrossClientFixtures.current, CrossClientFixtures.first])
        XCTAssertEqual(Set(offer.entries.map(\.id)).count, 3)
    }

    func testChangedOpaqueDeviceFailsBeforeMetadataOrStopRequests() async throws {
        var original = CrossClientFixtures.row()
        let device = "CaseSensitive" + String(repeating: "x", count: 200)
        original["DeviceId"] = device
        var fresh = original
        fresh["DeviceId"] = device.lowercased()
        let recorder = CrossClientTransport(customSource: try CrossClientFixtures.data([fresh]))
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        do {
            _ = try await library.prepareRemoteContinuation(CrossClientFixtures.activity(original))
            XCTFail("Changed device must not retarget the browser card")
        } catch { XCTAssertEqual(error as? FoundationHandoffError, .changed) }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.path, "/jellyfin/Sessions")
    }

    func testDiscoveryIncludesBrowserAndUnknownClientsWithoutNativeInstructions() throws {
        for client in ["Jellyfin Web", "Another client"] {
            var row = CrossClientFixtures.row()
            row["Client"] = client
            let activity = try CrossClientFixtures.activity(row)
            XCTAssertFalse(activity.usesNativeHandoff)
            XCTAssertEqual(activity.deviceLabel, client)
            XCTAssertNotEqual(activity.deviceLabel, "Private name")
            XCTAssertEqual(activity.sessionID, CrossClientFixtures.sourceSession)
        }
        var native = CrossClientFixtures.row()
        native["Client"] = "Velacanto Native"
        XCTAssertTrue(try CrossClientFixtures.activity(native).usesNativeHandoff)
    }
    func testFullReportedQueuePreservesOrderDuplicateOccurrencesAndSelectedItem() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row())
        XCTAssertEqual(
            offer.entries.map(\.item.id),
            [CrossClientFixtures.first, CrossClientFixtures.current, CrossClientFixtures.first])
        XCTAssertEqual(Set(offer.entries.map(\.id)).count, 3)
        XCTAssertEqual(offer.entries[1].id, offer.selected)
        XCTAssertEqual(offer.repeatMode, .all)
        XCTAssertTrue(offer.missingItemIDs.isEmpty)
        XCTAssertTrue(
            offer.entries.allSatisfy {
                $0.item.catalogSource == (try? CrossClientFixtures.source())
            })
    }
    func testLegacyShuffleNeverReshufflesOrClaimsOriginalBackingQueue() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row())
        let payload = try offer.payload(scope: String(repeating: "a", count: 64), id: UUID())
        XCTAssertFalse(try XCTUnwrap(payload.session).shuffle)
        XCTAssertEqual(payload.session?.entries.map(\.itemID), offer.entries.map(\.item.id))
    }
    func testCatalogGUIDVariantsAreCanonicalButPlaylistOccurrencesStayOpaque() throws {
        XCTAssertEqual(
            FoundationRemoteListeningActivity.catalogID("AABBCCDD-EEFF-1122-3344-5566778899AA"),
            "aabbccddeeff112233445566778899aa")
        XCTAssertNil(FoundationRemoteListeningActivity.catalogID("playlistItem0"))
        let original = try CrossClientFixtures.offer(CrossClientFixtures.row())
        var row = CrossClientFixtures.row()
        row["NowPlayingItem"] = CrossClientFixtures.media(
            CrossClientFixtures.guidD(CrossClientFixtures.current))
        row["NowPlayingQueue"] = [
            [
                "Id": CrossClientFixtures.guidD(CrossClientFixtures.first),
                "PlaylistItemId": "playlistItem0",
            ],
            [
                "Id": CrossClientFixtures.guidD(CrossClientFixtures.current),
                "PlaylistItemId": "playlistItem1",
            ],
            ["Id": CrossClientFixtures.first, "PlaylistItemId": "playlistItem2"],
        ]
        row["NowPlayingQueueFullItems"] = [
            CrossClientFixtures.media(CrossClientFixtures.guidD(CrossClientFixtures.current)),
            CrossClientFixtures.media(CrossClientFixtures.guidD(CrossClientFixtures.first)),
        ]
        let variant = try CrossClientFixtures.offer(row)
        XCTAssertEqual(try variant.matching(original).fingerprint, original.fingerprint)
        XCTAssertEqual(variant.sourceOccurrence, "playlistItem1")
        XCTAssertEqual(variant.entries.map(\.item.id), original.entries.map(\.item.id))
    }
    func testAuthorizationAcceptsDifferentValidMediaGUIDRepresentations() async throws {
        let transport = CrossClientTransport(metadataVariants: true)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await transport.load($0) })
        let offer = try await library.prepareRemoteContinuation(
            CrossClientFixtures.activity(CrossClientFixtures.row()))
        XCTAssertEqual(
            offer.entries.map(\.item.id),
            [CrossClientFixtures.first, CrossClientFixtures.current, CrossClientFixtures.first])
    }

    func testDiscoveryEligibleReportStillNeedsCurrentOccurrenceAndRepeatForTransfer() throws {
        var missingOccurrence = CrossClientFixtures.row()
        missingOccurrence.removeValue(forKey: "PlaylistItemId")
        var missingRepeat = CrossClientFixtures.row()
        var state = try XCTUnwrap(missingRepeat["PlayState"] as? [String: Any])
        state.removeValue(forKey: "RepeatMode")
        missingRepeat["PlayState"] = state
        for row in [missingOccurrence, missingRepeat] {
            XCTAssertEqual(
                try CrossClientFixtures.activity(row).item.id, CrossClientFixtures.current)
            XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
                XCTAssertEqual(error as? FoundationHandoffError, .unavailable)
            }
        }
    }

    func testDuplicateFullItemMetadataRejectsRatherThanCollapsingReportedOccurrences() throws {
        var row = CrossClientFixtures.row()
        row["NowPlayingQueueFullItems"] = [
            CrossClientFixtures.media(CrossClientFixtures.current),
            CrossClientFixtures.media(CrossClientFixtures.first),
            CrossClientFixtures.media(CrossClientFixtures.first),
        ]
        XCTAssertEqual(try CrossClientFixtures.activity(row).item.id, CrossClientFixtures.current)
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .invalid)
        }
    }

    func testAuthorizationRejectsWrongPageCountsAndSameCountWrongIDsWithoutControl() async throws {
        let validRows = [
            CrossClientFixtures.media(CrossClientFixtures.first),
            CrossClientFixtures.media(CrossClientFixtures.current),
        ]
        let responses: [[String: Any]] = [
            ["Items": validRows, "StartIndex": 1, "TotalRecordCount": 2],
            ["Items": validRows, "StartIndex": 0, "TotalRecordCount": 3],
            ["Items": validRows, "TotalRecordCount": 2],
            ["Items": [validRows[0], validRows[0]], "StartIndex": 0, "TotalRecordCount": 2],
            [
                "Items": [
                    validRows[0], CrossClientFixtures.media(String(repeating: "9", count: 32)),
                ],
                "StartIndex": 0, "TotalRecordCount": 2,
            ],
        ]
        let sourceData = try CrossClientFixtures.data([CrossClientFixtures.row()])
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        for response in responses {
            let metadataData = try JSONSerialization.data(withJSONObject: response)
            let recorder = RemoteListeningRequestRecorder()
            let library = FoundationJellyfinLibrary(
                session: CrossClientFixtures.session,
                load: { request in
                    await recorder.append(request)
                    let data =
                        request.url?.path.hasSuffix("/Items") == true ? metadataData : sourceData
                    return (data, CrossClientFixtures.response(request))
                })
            do {
                _ = try await library.prepareRemoteContinuation(activity)
                XCTFail(
                    "Invalid authorization response must not prepare a partial or retargeted queue")
            } catch {
                XCTAssertEqual(error as? FoundationHandoffError, .unavailable)
            }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }

    func testMissingQueueNeverBecomesOneTrackTransfer() throws {
        var row = CrossClientFixtures.row()
        row.removeValue(forKey: "NowPlayingQueue")
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .queueUnavailable)
        }
        row["NowPlayingQueue"] = []
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .queueUnavailable)
        }
    }
    func testDuplicateOrMissingSourceOccurrenceRejectsWholeQueue() throws {
        var row = CrossClientFixtures.row()
        row["NowPlayingQueue"] = [
            ["Id": CrossClientFixtures.first, "PlaylistItemId": "same"],
            ["Id": CrossClientFixtures.current, "PlaylistItemId": "same"],
        ]
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .invalid)
        }
        row = CrossClientFixtures.row()
        row["PlaylistItemId"] = "absent"
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .queueUnavailable)
        }
    }
    func testCurrentItemMustMatchSelectedQueueOccurrence() throws {
        var row = CrossClientFixtures.row()
        row["NowPlayingItem"] = CrossClientFixtures.media(CrossClientFixtures.first)
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .queueUnavailable)
        }
    }
    func testStrictPrimaryOwnerAndOwnDeviceIsolation() throws {
        for user in ["", "00000000000000000000000000000009"] {
            var row = CrossClientFixtures.row()
            row["UserId"] = user
            row["AdditionalUsers"] = [["UserId": CrossClientFixtures.owner]]
            XCTAssertThrowsError(try CrossClientFixtures.offer(row))
        }
        var row = CrossClientFixtures.row()
        row["DeviceId"] = "OWN-DEVICE"
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
    }
    func testStaleFutureInvalidPositionOrRepeatDoesNotApply() throws {
        for age in [91.0, -6.0] {
            var row = CrossClientFixtures.row()
            row["LastPlaybackCheckIn"] = ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-age))
            XCTAssertThrowsError(try CrossClientFixtures.offer(row))
        }
        var row = CrossClientFixtures.row(position: -1)
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
        row["PlayState"] = ["PositionTicks": 1, "IsPaused": false, "RepeatMode": "unknown"]
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
    }
    func testBudgetAndURLPathIDsRejectUnsafeInputs() throws {
        XCTAssertThrowsError(
            try FoundationRemoteContinuationOffer.decode(
                Data(repeating: 0, count: 4_194_305),
                sessionID: CrossClientFixtures.sourceSession, userID: CrossClientFixtures.owner,
                ownDeviceID: "own-device", scope: "fixture",
                catalogSource: CrossClientFixtures.source(), now: Date()))
        XCTAssertThrowsError(
            try FoundationRemoteContinuationOffer.decode(
                CrossClientFixtures.data([CrossClientFixtures.row()]),
                sessionID: "../other/Stop", userID: CrossClientFixtures.owner,
                ownDeviceID: "own-device", scope: "fixture",
                catalogSource: CrossClientFixtures.source(), now: Date()))
    }
    func testPositionRefreshMatchesButQueueOrRepeatChangeDoesNot() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row())
        let advanced = try CrossClientFixtures.offer(CrossClientFixtures.row(position: 30_000_000))
        XCTAssertEqual(try advanced.matching(offer).position, 3)
        XCTAssertThrowsError(
            try CrossClientFixtures.offer(CrossClientFixtures.row(changed: true)).matching(offer))
        var row = CrossClientFixtures.row()
        row["PlayState"] = ["PositionTicks": 1, "IsPaused": false, "RepeatMode": "RepeatOne"]
        XCTAssertThrowsError(try CrossClientFixtures.offer(row).matching(offer))
    }
    func testQueueCountCeilingAndNonAudioFullItemsRejectEntireTransfer() throws {
        var row = CrossClientFixtures.row()
        row["NowPlayingQueue"] = (0...10_000).map {
            ["Id": CrossClientFixtures.current, "PlaylistItemId": "playlistItem\($0)"]
        }
        XCTAssertThrowsError(try CrossClientFixtures.offer(row)) { error in
            XCTAssertEqual(error as? FoundationHandoffError, .tooLarge)
        }
        row = CrossClientFixtures.row()
        var movie = CrossClientFixtures.media(CrossClientFixtures.first)
        movie["Type"] = "Movie"
        row["NowPlayingQueueFullItems"] = [
            movie, CrossClientFixtures.media(CrossClientFixtures.current),
        ]
        XCTAssertThrowsError(try CrossClientFixtures.offer(row))
    }

    func testMissingFullMetadataRemainsExplicitlyUnresolved() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row(fullItems: false))
        XCTAssertEqual(offer.missingItemIDs, [CrossClientFixtures.first])
        XCTAssertThrowsError(
            try offer.payload(scope: String(repeating: "a", count: 64), id: UUID()))
    }
    func testStoppedConfirmationNeverTrustsMissingOrOtherUserSession() throws {
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row())
        XCTAssertFalse(
            try FoundationRemoteContinuationOffer.stopped(
                CrossClientFixtures.data([]), expected: offer, userID: CrossClientFixtures.owner))
        var row = CrossClientFixtures.row()
        row.removeValue(forKey: "NowPlayingItem")
        XCTAssertTrue(
            try FoundationRemoteContinuationOffer.stopped(
                CrossClientFixtures.data([row]), expected: offer, userID: CrossClientFixtures.owner)
        )
        row["UserId"] = "00000000000000000000000000000009"
        XCTAssertFalse(
            try FoundationRemoteContinuationOffer.stopped(
                CrossClientFixtures.data([row]), expected: offer, userID: CrossClientFixtures.owner)
        )
    }
    func testAdapterUsesOneBoundedMissingIDQueryNotPerTrackFanout() async throws {
        let recorder = CrossClientTransport(fullItems: false)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) }
        )
        .scoped(to: "00000000000000000000000000000099")
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        let offer = try await library.prepareRemoteContinuation(activity)
        XCTAssertEqual(offer.entries.count, 3)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET"])
        XCTAssertEqual(requests.last?.url?.path, "/jellyfin/Items")
        let query = URLComponents(url: requests.last!.url!, resolvingAgainstBaseURL: false)?
            .queryItems
        XCTAssertEqual(
            query?.filter { $0.name == "ids" }.compactMap(\.value),
            [CrossClientFixtures.first, CrossClientFixtures.current])
        XCTAssertEqual(query?.filter { $0.name == "ids" }.count, 2)
        XCTAssertNil(query?.first(where: { $0.name == "parentId" }))
        XCTAssertEqual(
            query?.first(where: { $0.name == "userId" })?.value, CrossClientFixtures.owner)
    }
    func testOldAccountCardCannotPrepareAgainstNewAccountOrIssueAnyRequest() async throws {
        let recorder = CrossClientTransport()
        let session = FoundationSession(
            serverURL: CrossClientFixtures.session.serverURL,
            accessToken: "new-fixture-token", userID: "00000000000000000000000000000009",
            deviceID: CrossClientFixtures.session.deviceID)
        let library = FoundationJellyfinLibrary(
            session: session, load: { try await recorder.load($0) })
        let old = try CrossClientFixtures.activity(CrossClientFixtures.row())
        do {
            _ = try await library.prepareRemoteContinuation(old)
            XCTFail("Old account authority")
        } catch {}
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testFullItemDisplayMetadataDoesNotBypassReceivingUserAuthorization() async throws {
        let recorder = CrossClientTransport(missingMetadata: true)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        do {
            _ = try await library.prepareRemoteContinuation(
                CrossClientFixtures.activity(CrossClientFixtures.row()))
            XCTFail("Unauthorized future item")
        } catch { XCTAssertTrue(error is FoundationHandoffError) }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testMoreThanTwoHundredItemsUsesFiniteCompleteBatchesWithoutTruncation() async throws {
        var row = CrossClientFixtures.row()
        let ids = [CrossClientFixtures.current] + (20..<420).map { String(format: "%032x", $0) }
        row["NowPlayingQueue"] = ids.enumerated().map {
            ["Id": $0.element, "PlaylistItemId": "playlistItem\($0.offset)"]
        }
        row["PlaylistItemId"] = "playlistItem0"
        row["NowPlayingQueueFullItems"] = []
        let recorder = CrossClientTransport(customSource: try CrossClientFixtures.data([row]))
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        let offer = try await library.prepareRemoteContinuation(CrossClientFixtures.activity(row))
        XCTAssertEqual(offer.entries.map(\.item.id), ids)
        let requests = await recorder.requests.filter { $0.url?.path.hasSuffix("/Items") == true }
        let batches = requests.map { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "ids" }.compactMap(\.value) ?? []
        }
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(batches.map(\.count), [200, 200, 1])
        XCTAssertEqual(batches.flatMap { $0 }, ids.sorted())
        XCTAssertEqual(Set(batches.flatMap { $0 }), Set(ids))
    }
    func testCumulativeMetadataBudgetFailsWholePreparationWithoutControl() async throws {
        let recorder = CrossClientTransport(largeMetadata: true)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        do {
            _ = try await library.prepareRemoteContinuation(
                CrossClientFixtures.activity(CrossClientFixtures.row()))
            XCTFail("Oversized response")
        } catch { XCTAssertEqual(error as? FoundationHandoffError, .tooLarge) }
        let stops = await recorder.stopCount
        XCTAssertEqual(stops, 0)
    }
    func testOldDuplicateOccurrenceCardCannotRetargetAReplacementOccurrence() async throws {
        var old = CrossClientFixtures.row()
        old["NowPlayingQueue"] = [
            ["Id": CrossClientFixtures.current, "PlaylistItemId": "playlistItem1"],
            ["Id": CrossClientFixtures.current, "PlaylistItemId": "playlistItem2"],
        ]
        old["NowPlayingQueueFullItems"] = [CrossClientFixtures.media(CrossClientFixtures.current)]
        var fresh = old
        fresh["PlaylistItemId"] = "playlistItem2"
        let recorder = CrossClientTransport(customSource: try CrossClientFixtures.data([fresh]))
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        do {
            _ = try await library.prepareRemoteContinuation(CrossClientFixtures.activity(old))
            XCTFail("Retargeted stale card")
        } catch { XCTAssertEqual(error as? FoundationHandoffError, .changed) }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPartialMetadataQueryFailsRatherThanDroppingRows() async throws {
        let recorder = CrossClientTransport(fullItems: false, missingMetadata: true)
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        do {
            _ = try await library.prepareRemoteContinuation(
                CrossClientFixtures.activity(CrossClientFixtures.row()))
            XCTFail("Incomplete queue")
        } catch { XCTAssertTrue(error is FoundationHandoffError) }
        let observedCount1 = await recorder.stopCount
        XCTAssertEqual(observedCount1, 0)
    }
    func testUnsupportedControlNeverSendsACommandAnd204DoesNotProveStop() async throws {
        let recorder = CrossClientTransport()
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await recorder.load($0) })
        let unsupported = try CrossClientFixtures.offer(CrossClientFixtures.row(control: false))
        do {
            try await library.stopRemoteContinuation(unsupported)
            XCTFail("Unsupported control")
        } catch {}
        let observedCount2 = await recorder.stopCount
        XCTAssertEqual(observedCount2, 0)
        let offer = try CrossClientFixtures.offer(CrossClientFixtures.row())
        try await library.stopRemoteContinuation(offer)
        let confirmed = try await library.confirmRemoteContinuationStopped(offer)
        XCTAssertFalse(confirmed)
        let observedCount3 = await recorder.stopCount
        XCTAssertEqual(observedCount3, 1)
        let commands = await recorder.requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(
            commands.map { $0.url?.path },
            ["/jellyfin/Sessions/" + CrossClientFixtures.sourceSession + "/Playing/Stop"])
        XCTAssertNil(commands.first?.httpBody)
        XCTAssertTrue(
            commands.first?.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token")
                == true)
    }
}

private actor CrossClientResourceGate {
    nonisolated let entered = XCTestExpectation(description: "remote resource held")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        entered.fulfill()
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor CrossClientTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var stopCount = 0
    private(set) var readCount = 0
    private(set) var metadataCount = 0
    nonisolated let stopObserved = XCTestExpectation(description: "one Stop observed")
    let songOnly: Bool
    let fullItems: Bool
    let missingMetadata: Bool
    let changedAtRead: Int?
    let failStop: Bool
    let confirmsStop: Bool
    let supportsControl: Bool
    let customSource: Data?
    let largeMetadata: Bool
    let metadataGate: CrossClientResourceGate?
    let metadataVariants: Bool
    let holdRead: Int?
    let readGate: CrossClientResourceGate?
    var onStop: (@Sendable () async -> Void)?
    init(
        fullItems: Bool = true, missingMetadata: Bool = false, changedAtRead: Int? = nil,
        failStop: Bool = false, confirmsStop: Bool = false, supportsControl: Bool = true,
        holdRead: Int? = nil,
        readGate: CrossClientResourceGate? = nil, customSource: Data? = nil,
        largeMetadata: Bool = false, metadataGate: CrossClientResourceGate? = nil,
        metadataVariants: Bool = false, songOnly: Bool = false
    ) {
        self.songOnly = songOnly
        self.fullItems = fullItems
        self.missingMetadata = missingMetadata
        self.changedAtRead = changedAtRead
        self.failStop = failStop
        self.confirmsStop = confirmsStop
        self.supportsControl = supportsControl
        self.holdRead = holdRead
        self.readGate = readGate
        self.customSource = customSource
        self.largeMetadata = largeMetadata
        self.metadataGate = metadataGate
        self.metadataVariants = metadataVariants
    }
    func observeStop(_ callback: @escaping @Sendable () async -> Void) { onStop = callback }
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        if request.httpMethod == "POST" {
            stopCount += 1
            await onStop?()
            stopObserved.fulfill()
            return (Data(), CrossClientFixtures.response(request, code: failStop ? 500 : 204))
        }
        if request.url?.path.hasSuffix("/Items") == true {
            metadataCount += 1
            if metadataCount == 1, let metadataGate { await metadataGate.wait() }
            try Task.checkCancellation()
            let ids =
                URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "ids" }.compactMap(\.value) ?? []
            guard !ids.isEmpty,
                ids.allSatisfy({ FoundationRemoteListeningActivity.catalogID($0) == $0 })
            else { throw FoundationLibraryError.invalidResponse }
            let rows =
                missingMetadata
                ? []
                : ids.map {
                    CrossClientFixtures.media(metadataVariants ? CrossClientFixtures.guidD($0) : $0)
                }
            var response: [String: Any] = [
                "Items": rows, "StartIndex": 0, "TotalRecordCount": rows.count,
            ]
            if largeMetadata { response["Unused"] = String(repeating: "x", count: 4_194_304) }
            return (
                try JSONSerialization.data(withJSONObject: response),
                CrossClientFixtures.response(request)
            )
        }
        readCount += 1
        let read = readCount
        if holdRead == read, let readGate { await readGate.wait() }
        try Task.checkCancellation()
        if let customSource { return (customSource, CrossClientFixtures.response(request)) }
        var row = CrossClientFixtures.row(
            position: Int64(read) * 10_000_000,
            changed: changedAtRead == read, fullItems: fullItems, control: supportsControl)
        if songOnly {
            row.removeValue(forKey: "NowPlayingQueue")
            row.removeValue(forKey: "NowPlayingQueueFullItems")
            if changedAtRead == read { row["PlaylistItemId"] = "new-source-occurrence" }
        }
        if confirmsStop && stopCount > 0 {
            if songOnly {
                var state = row["PlayState"] as! [String: Any]
                state["IsPaused"] = true
                row["PlayState"] = state
            } else {
                row.removeValue(forKey: "NowPlayingItem")
            }
        }
        return (try CrossClientFixtures.data([row]), CrossClientFixtures.response(request))
    }
}

@MainActor private final class CrossClientNetworkPolicy {
    var allowed = true
}

@MainActor
final class FoundationRemoteContinuationControllerTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private func make(
        _ transport: CrossClientTransport, resourceGate: CrossClientResourceGate? = nil,
        activationGate: CrossClientResourceGate? = nil, failResolution: Bool = false
    ) -> (FoundationHandoffController, FoundationPlayer, FoundationJellyfinLibrary) {
        let player = FoundationPlayer(
            resolve: { _ in
                if let resourceGate { await resourceGate.wait() }
                if failResolution { throw FoundationHandoffError.unavailable }
                guard let url = try FoundationTestTones.resolve(FoundationTestTones.items[0]) else {
                    throw FoundationHandoffError.unavailable
                }
                return url
            }, activateSession: { if let activationGate { await activationGate.wait() } },
            deactivateSession: {})
        player.nativePlayer.volume = 0
        let original = FoundationQueueEntry(item: FoundationTestTones.items[2])
        player.restoreSession(
            .init(
                entries: [original], selectedEntryID: original.id,
                shuffleEnabled: false, repeatMode: .off))
        let controller = FoundationHandoffController(publish: { _ in })
        controller.configure(scope: scope, player: player, resolve: { $0 }, navigate: { _ in })
        let library = FoundationJellyfinLibrary(
            session: CrossClientFixtures.session, load: { try await transport.load($0) })
        return (controller, player, library)
    }
    private func prepare(
        _ controller: FoundationHandoffController, library: FoundationJellyfinLibrary,
        onStarted: @escaping @MainActor () -> Void = {},
        allowsNetworking: @escaping @MainActor () -> Bool = { true },
        selection: FoundationRemoteContinuationSelection = .fullQueue
    ) async throws {
        let ready = expectation(description: "source queue confirmation")
        let token = controller.$pending.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        controller.prepareRemoteContinuation(
            try CrossClientFixtures.activity(CrossClientFixtures.row()), library: library,
            selection: selection, allowsNetworking: allowsNetworking, onStarted: onStarted)
        await fulfillment(of: [ready], timeout: 5)
        token.cancel()
        XCTAssertNotNil(controller.pending?.remoteOffer)
    }
    private func notice(_ controller: FoundationHandoffController) async {
        let ready = expectation(description: "remote continuation result")
        let token = controller.$notice.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        token.cancel()
    }
    func testAutomaticControllerPreparesConcreteSongWhenQueueIsNotShared() async throws {
        let transport = CrossClientTransport(songOnly: true)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library, selection: .automatic)
        XCTAssertEqual(controller.pending?.remoteOffer?.selection, .currentSong)
        XCTAssertEqual(controller.pending?.payload.session?.entries.count, 1)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod != "POST" })
    }

    func testExplicitSongActualStartPausesOnceAndKeepsOneSongReceiverQueue() async throws {
        let transport = CrossClientTransport(confirmsStop: true, songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        await transport.observeStop {
            await MainActor.run {
                XCTAssertEqual(player.nativePlayer.timeControlStatus, .playing)
                XCTAssertTrue(player.isNativeContinuationPlaying(
                    generation: player.continuationGeneration, occurrence: player.selectedEntryID!))
                XCTAssertEqual(player.nativePlayer.currentTime().seconds, 3, accuracy: 0.75)
            }
        }
        try await prepare(controller, library: library, selection: .currentSong)
        XCTAssertEqual(controller.pending?.remoteOffer?.selection, .currentSong)
        controller.acceptPending()
        controller.acceptPending()
        await fulfillment(of: [transport.stopObserved], timeout: 8)
        XCTAssertEqual(player.persistedQueue.map(\.item.id), [CrossClientFixtures.current])
        XCTAssertFalse(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .off)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.map { $0.url?.lastPathComponent }, ["Pause"])
    }

    func testSongNativeResourceFailureSendsNoSourcePause() async throws {
        let transport = CrossClientTransport(songOnly: true)
        let (controller, player, library) = make(transport, failResolution: true)
        defer { controller.invalidate(); player.stop() }
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await notice(controller)
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
    }

    func testSongUserPauseDuringResolutionCancelsWithoutSourcePause() async throws {
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport(songOnly: true)
        let (controller, player, library) = make(transport, resourceGate: gate)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 5)
        player.pause()
        await gate.release()
        let noStart = expectation(description: "no start after explicit receiving pause")
        noStart.isInverted = true
        let token = player.$state.filter { $0 == .playing }.sink { _ in noStart.fulfill() }
        await fulfillment(of: [noStart], timeout: 0.2)
        token.cancel()
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
        XCTAssertNil(controller.notice)
        XCTAssertFalse(player.wantsPlayback)
    }

    func testUnsupportedSongPauseStillAllowsReceiverStartWithHonestNotice() async throws {
        let transport = CrossClientTransport(supportsControl: false, songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await notice(controller)
        XCTAssertEqual(player.persistedQueue.map(\.item.id), [CrossClientFixtures.current])
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
        XCTAssertTrue(controller.notice?.contains("pausing") == true)
    }

    func testExplicitSongCancellationDoesNotReplaceQueueOrPause() async throws {
        let transport = CrossClientTransport(songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        let original = player.persistedQueue
        try await prepare(controller, library: library, selection: .currentSong)
        controller.dismissPending()
        XCTAssertEqual(player.persistedQueue, original)
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
    }

    func testSongReceiverFailureBeforeStartCannotPauseSource() async throws {
        let transport = CrossClientTransport(changedAtRead: 2, songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        let original = player.persistedQueue
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await notice(controller)
        XCTAssertEqual(player.persistedQueue, original)
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
    }

    func testChangedSongAfterReceiverStartNeverPausesNewSource() async throws {
        let transport = CrossClientTransport(changedAtRead: 4, songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await notice(controller)
        let commands = await transport.stopCount
        XCTAssertEqual(commands, 0)
        XCTAssertTrue(controller.notice?.contains("pausing") == true)
    }

    func testFailedSongPauseDoesNotRetryOrClaimSourceStopped() async throws {
        let transport = CrossClientTransport(failStop: true, songOnly: true)
        let (controller, player, library) = make(transport)
        defer { controller.invalidate(); player.stop() }
        try await prepare(controller, library: library, selection: .currentSong)
        controller.acceptPending()
        await notice(controller)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.map { $0.url?.lastPathComponent }, ["Pause"])
        XCTAssertTrue(controller.notice?.contains("pausing") == true)
        XCTAssertEqual(player.persistedQueue.count, 1)
    }

    func testV12EmptyOrStaleSourceQueueExplainsFailureWithoutMovingPlayback() async throws {
        let queues: [[[String: String]]] = [
            [], [["Id": CrossClientFixtures.first, "PlaylistItemId": "stale-occurrence"]],
        ]
        for queue in queues {
            var row = CrossClientFixtures.row()
            row["NowPlayingQueue"] = queue
            let transport = CrossClientTransport(customSource: try CrossClientFixtures.data([row]))
            let (controller, player, library) = make(transport)
            defer {
                controller.invalidate()
                player.stop()
            }
            let original = player.persistedQueue
            let ready = expectation(description: "unusable current queue explanation")
            let token = controller.$notice.compactMap { $0 }.prefix(1).sink { _ in ready.fulfill() }
            controller.prepareRemoteContinuation(
                try CrossClientFixtures.activity(row), library: library, selection: .fullQueue)
            await fulfillment(of: [ready], timeout: 5)
            token.cancel()
            XCTAssertEqual(
                controller.notice,
                "This player hasn’t shared a usable current queue. Playback hasn’t moved.")
            XCTAssertNil(controller.pending)
            XCTAssertEqual(player.persistedQueue, original)
            XCTAssertNil(player.nativePlayer.currentItem)
            let stops = await transport.stopCount
            let requests = await transport.requests
            XCTAssertEqual(stops, 0)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.httpMethod, "GET")
            XCTAssertEqual(requests.first?.url?.path, "/jellyfin/Sessions")
        }
    }

    func testPreparationAndCancelDoNotReplaceQueueResolveAudioOrStopSource() async throws {
        let transport = CrossClientTransport()
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let original = player.persistedQueue
        try await prepare(controller, library: library)
        XCTAssertEqual(player.persistedQueue, original)
        XCTAssertNil(player.nativePlayer.currentItem)
        let observedCount4 = await transport.stopCount
        XCTAssertEqual(observedCount4, 0)
        controller.dismissPending()
        XCTAssertEqual(player.persistedQueue, original)
    }
    func testLeavingAnAlreadyPreparedCardRetiresOnlyItsUnconfirmedTransfer() async throws {
        let transport = CrossClientTransport()
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let original = player.persistedQueue
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        try await prepare(controller, library: library)
        controller.cancelRemotePreparation(activityID: "unrelated-card")
        XCTAssertNotNil(controller.pending?.remoteOffer)
        controller.cancelRemotePreparation(activityID: activity.id)
        XCTAssertNil(controller.pending)
        XCTAssertEqual(player.persistedQueue, original)
        XCTAssertNil(player.nativePlayer.currentItem)
        let stops = await transport.stopCount
        XCTAssertEqual(stops, 0)
    }

    func testDismissDuringHeldPreparationCannotPresentLateConfirmationOrTouchPlayback() async throws
    {
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport(metadataGate: gate)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        let original = player.persistedQueue
        let noPending = expectation(description: "no late confirmation after card dismissal")
        noPending.isInverted = true
        let token = controller.$pending.compactMap { $0 }.sink { _ in noPending.fulfill() }
        controller.prepareRemoteContinuation(activity, library: library)
        await fulfillment(of: [gate.entered], timeout: 5)
        controller.cancelRemotePreparation(activityID: activity.id)
        await gate.release()
        await fulfillment(of: [noPending], timeout: 0.2)
        token.cancel()
        XCTAssertEqual(player.persistedQueue, original)
        XCTAssertNil(player.nativePlayer.currentItem)
        let stops = await transport.stopCount
        XCTAssertEqual(stops, 0)
    }
    func testActualStartRetiresOnlyKnownSourceCardWithoutSuppressingAnotherActivity() async throws {
        let transport = CrossClientTransport(confirmsStop: true)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let activity = try CrossClientFixtures.activity(CrossClientFixtures.row())
        let memory = FoundationContinueListeningDismissals()
        memory.configure(scope: library.listeningActivityScope)
        try await prepare(
            controller, library: library,
            onStarted: {
                memory.dismiss(activity.id, scope: library.listeningActivityScope)
            })
        XCTAssertTrue(memory.keys.isEmpty)
        controller.acceptPending()
        await fulfillment(of: [transport.stopObserved], timeout: 8)
        XCTAssertEqual(memory.keys, [activity.id])
        var other = CrossClientFixtures.row()
        other["NowPlayingItem"] = CrossClientFixtures.media(CrossClientFixtures.first)
        other["PlaylistItemId"] = "playlistItem0"
        let next = try CrossClientFixtures.activity(other)
        XCTAssertNotEqual(next.id, activity.id)
        XCTAssertEqual(
            FoundationContinueListeningSelection.select([next], dismissed: memory.keys)?.id, next.id
        )
    }

    func testNewReceiverIntentBeforeAcceptKeepsItsQueueAndNeverStopsSource() async throws {
        let transport = CrossClientTransport()
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        player.enqueue([FoundationTestTones.items[1]], position: .last)
        let newer = player.persistedQueue
        controller.acceptPending()
        XCTAssertEqual(player.persistedQueue, newer)
        let observedCount5 = await transport.stopCount
        XCTAssertEqual(observedCount5, 0)
    }
    func testStopFollowsActualNativeStartAndFinalReadinessPosition() async throws {
        let transport = CrossClientTransport(confirmsStop: true)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        await transport.observeStop {
            await MainActor.run {
                XCTAssertEqual(player.nativePlayer.timeControlStatus, .playing)
                XCTAssertTrue(
                    player.isNativeContinuationPlaying(
                        generation: player.continuationGeneration,
                        occurrence: player.selectedEntryID!))
                XCTAssertEqual(player.nativePlayer.currentTime().seconds, 3, accuracy: 0.75)
            }
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await fulfillment(of: [transport.stopObserved], timeout: 8)
        XCTAssertEqual(
            player.persistedQueue.map(\.item.id),
            [CrossClientFixtures.first, CrossClientFixtures.current, CrossClientFixtures.first])
        XCTAssertEqual(Set(player.persistedQueue.map(\.id)).count, 3)
        XCTAssertFalse(player.shuffleEnabled)
        XCTAssertEqual(player.repeatMode, .all)
        let observedCount6 = await transport.stopCount
        XCTAssertEqual(observedCount6, 1)
    }
    func testChangedSourceAtAuthorizationKeepsExistingReceiverQueue() async throws {
        let transport = CrossClientTransport(changedAtRead: 2)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let original = player.persistedQueue
        try await prepare(controller, library: library)
        controller.acceptPending()
        await notice(controller)
        XCTAssertEqual(player.persistedQueue, original)
        XCTAssertNil(player.nativePlayer.currentItem)
        let observedCount7 = await transport.stopCount
        XCTAssertEqual(observedCount7, 0)
    }
    func testLocalOnlyPolicyChangeBeforeReadinessPreventsFurtherServerReadOrStart() async throws {
        let policy = CrossClientNetworkPolicy()
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport()
        let (controller, player, library) = make(transport, resourceGate: gate)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library, allowsNetworking: { policy.allowed })
        controller.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 5)
        policy.allowed = false
        await gate.release()
        await notice(controller)
        XCTAssertFalse(player.nativePlayer.timeControlStatus == .playing)
        let reads = await transport.readCount
        let stops = await transport.stopCount
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(stops, 0)
    }

    func testChangedSourceDuringHeldReadinessCannotStartOrStop() async throws {
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport(changedAtRead: 3)
        let (controller, player, library) = make(transport, resourceGate: gate)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 5)
        let observedCount8 = await transport.readCount
        XCTAssertEqual(observedCount8, 2)
        await gate.release()
        await notice(controller)
        XCTAssertFalse(player.nativePlayer.timeControlStatus == .playing)
        let observedCount9 = await transport.stopCount
        XCTAssertEqual(observedCount9, 0)
    }
    func testChangedSourceAfterNativeStartReceivesNoStop() async throws {
        let transport = CrossClientTransport(changedAtRead: 4)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await notice(controller)
        XCTAssertEqual(player.state, .playing)
        let observedCount10 = await transport.stopCount
        XCTAssertEqual(observedCount10, 0)
    }
    func testUnsupportedSourceControlStillReportsUnconfirmedAfterReceiverStarts() async throws {
        let transport = CrossClientTransport(supportsControl: false)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        XCTAssertFalse(try XCTUnwrap(controller.pending?.remoteOffer).supportsRemoteControl)
        controller.acceptPending()
        await notice(controller)
        XCTAssertEqual(player.state, .playing)
        let stops = await transport.stopCount
        XCTAssertEqual(stops, 0)
        XCTAssertTrue(controller.notice?.contains("original player may still be playing") == true)
    }

    func testFailedStopDoesNotRetryAndReportsOriginalMayStillPlay() async throws {
        let transport = CrossClientTransport(failStop: true)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await notice(controller)
        XCTAssertTrue(controller.notice?.contains("original player may still be playing") == true)
        let observedCount11 = await transport.stopCount
        XCTAssertEqual(observedCount11, 1)
        let observedCount12 = await transport.readCount
        XCTAssertEqual(observedCount12, 4)
    }
    func testAccountRetirementDuringMetadataBatchStopsBeforeNextRequestOrConfirmation() async throws
    {
        let gate = CrossClientResourceGate()
        var row = CrossClientFixtures.row()
        let ids = [CrossClientFixtures.current] + (20..<420).map { String(format: "%032x", $0) }
        row["NowPlayingQueue"] = ids.enumerated().map {
            ["Id": $0.element, "PlaylistItemId": "playlistItem\($0.offset)"]
        }
        row["PlaylistItemId"] = "playlistItem0"
        row["NowPlayingQueueFullItems"] = []
        let transport = CrossClientTransport(
            customSource: try CrossClientFixtures.data([row]), metadataGate: gate)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        let original = player.persistedQueue
        let noPending = expectation(description: "no confirmation after account retirement")
        noPending.isInverted = true
        let token = controller.$pending.compactMap { $0 }.sink { _ in noPending.fulfill() }
        controller.prepareRemoteContinuation(
            try CrossClientFixtures.activity(row), library: library)
        await fulfillment(of: [gate.entered], timeout: 5)
        controller.invalidate()
        await gate.release()
        await fulfillment(of: [noPending], timeout: 0.2)
        token.cancel()
        XCTAssertEqual(player.persistedQueue, original)
        XCTAssertNil(player.nativePlayer.currentItem)
        let metadataRequests = await transport.metadataCount
        let stops = await transport.stopCount
        XCTAssertEqual(metadataRequests, 1)
        XCTAssertEqual(stops, 0)
    }

    func testAccountRetirementDuringHeldActivationPreventsStartAndStop() async throws {
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport()
        let (controller, player, library) = make(transport, activationGate: gate)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 8)
        controller.invalidate()
        await gate.release()
        let noStart = expectation(description: "no retired playback start")
        noStart.isInverted = true
        let token = player.$state.filter { $0 == .playing }.sink { _ in noStart.fulfill() }
        await fulfillment(of: [noStart], timeout: 0.2)
        token.cancel()
        let observedCount13 = await transport.stopCount
        XCTAssertEqual(observedCount13, 0)
    }
    func testNewReceiverIntentDuringPostStartReadPreventsStop() async throws {
        let gate = CrossClientResourceGate()
        let transport = CrossClientTransport(holdRead: 4, readGate: gate)
        let (controller, player, library) = make(transport)
        defer {
            controller.invalidate()
            player.stop()
        }
        try await prepare(controller, library: library)
        controller.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 8)
        let replacement = FoundationQueueEntry(item: FoundationTestTones.items[1])
        player.restoreSession(
            .init(
                entries: [replacement], selectedEntryID: replacement.id,
                shuffleEnabled: false, repeatMode: .off))
        let newer = player.persistedQueue
        await gate.release()
        let noStop = expectation(description: "no Stop after new receiver intent")
        noStop.isInverted = true
        await transport.observeStop { noStop.fulfill() }
        await fulfillment(of: [noStop], timeout: 0.2)
        XCTAssertEqual(player.persistedQueue, newer)
        let observedCount14 = await transport.stopCount
        XCTAssertEqual(observedCount14, 0)
    }
}
