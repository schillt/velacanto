import AVFoundation
import Combine
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationHandoffControllerTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)

    func testPausedFullQueueRequiresConfirmationAndDoesNotResolveAudio() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        let original = fixture.receiverPlayer.persistedQueue
        try await offer(fixture)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, original)
        await assertNoAudio(fixture)
        fixture.receiver.acceptPending()
        await restored(fixture)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue.map(\.id), fixture.entries.map(\.id))
        XCTAssertEqual(fixture.receiverPlayer.selectedEntryID, fixture.entries[1].id)
        XCTAssertTrue(fixture.receiverPlayer.shuffleEnabled)
        XCTAssertEqual(fixture.receiverPlayer.repeatMode, .all)
        XCTAssertEqual(fixture.receiverPlayer.elapsed, 3)
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        await assertNoAudio(fixture)
    }

    func testControllerRestoresFullRawQueueAndSourceEffectiveVisibleIDs() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        let visible = Array(fixture.entries.prefix(2)).map(\.id)
        fixture.sourcePlayer.restoreSession(
            .init(
                entries: fixture.entries,
                selectedEntryID: fixture.entries[1].id, shuffleEnabled: true, repeatMode: .one,
                visibleEntryIDs: visible))
        fixture.source.configure(
            scope: scope, player: fixture.sourcePlayer,
            resolve: { $0 }, navigate: { _ in })
        try await offer(fixture)
        fixture.receiver.acceptPending()
        await restored(fixture)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue.map(\.id), fixture.entries.map(\.id))
        XCTAssertEqual(fixture.receiverPlayer.queue.map(\.id), visible)
        XCTAssertEqual(fixture.receiverPlayer.persistedVisibleEntryIDs, visible)
        fixture.receiverPlayer.setRepeat(.all)
        XCTAssertEqual(fixture.receiverPlayer.queue.map(\.id), visible)
        await assertNoAudio(fixture)
    }

    func testExplicitNavigationRetiresCompletedButUnconsumedBrowseRequest() throws {
        let controller = FoundationHandoffController(publish: { _ in })
        let item = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        controller.requestBrowse(item)
        XCTAssertNotNil(controller.browseRequest)
        controller.navigationChangedByUser()
        XCTAssertNil(controller.takeBrowseRequest())
        controller.requestBrowse(item)
        XCTAssertEqual(controller.takeBrowseRequest(), item)
        XCTAssertNil(controller.takeBrowseRequest())
    }

    func testCancellationPreservesBothDeviceQueuesAndSourceIntent() async throws {
        let fixture = try Fixture(scope: scope, playing: true)
        defer { fixture.invalidate() }
        let previous = fixture.receiverPlayer.persistedQueue
        try await offer(fixture)
        fixture.receiver.dismissPending()
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue, fixture.entries)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
    }

    func testNewReceiverIntentRetiresConfirmationAndCannotReplaceNewQueue() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        try await offer(fixture)
        fixture.receiverPlayer.enqueue([FoundationTestTones.items[2]], position: .last)
        let latest = fixture.receiverPlayer.persistedQueue
        fixture.receiver.acceptPending()
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, latest)
        await assertNoAudio(fixture)
    }

    func testExplicitPauseWhileAlreadyPausedRetiresReceiverConfirmation() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        try await offer(fixture)
        let previous = fixture.receiverPlayer.persistedQueue
        fixture.receiverPlayer.pause()
        fixture.receiver.acceptPending()
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        await assertNoAudio(fixture)
    }

    func testExplicitSeekRetiresConfirmationBeforeNativeCompletion() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        try await offer(fixture)
        let previous = fixture.receiverPlayer.persistedQueue
        fixture.receiverPlayer.seek(
            to: 2, entryID: try XCTUnwrap(fixture.receiverPlayer.selectedEntryID))
        XCTAssertNil(fixture.receiver.pending)
        fixture.receiver.acceptPending()
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        await assertNoAudio(fixture)
    }

    func testDifferentAuthorizedAccountDoesNotRequestOrReplaceQueue() async throws {
        let fixture = try Fixture(scope: scope, receivingScope: String(repeating: "b", count: 64))
        defer { fixture.invalidate() }
        let rejected = expectation(description: "account mismatch")
        var observer: AnyCancellable?
        observer = fixture.receiver.$notice.compactMap { $0 }.sink { _ in rejected.fulfill() }
        defer { observer?.cancel() }
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        XCTAssertEqual(fixture.metadataResolutions, 0)
        await assertNoAudio(fixture)
    }

    func testSignOutInvalidatesPendingAndLateConfirmation() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        try await offer(fixture)
        let previous = fixture.receiverPlayer.persistedQueue
        fixture.receiver.invalidate()
        fixture.receiver.acceptPending()
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        XCTAssertNil(fixture.receiver.pending)
    }

    func testBrowseOwnAccountResolutionRoutesWithoutAudioOrQueueChanges() async throws {
        let fixture = try Fixture(scope: scope)
        defer { fixture.invalidate() }
        let album = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        let first = UUID()
        let latest = UUID()
        fixture.source.beginBrowse(album, owner: first)
        fixture.source.beginBrowse(album, owner: latest)
        fixture.source.endBrowse(owner: first)
        let routed = expectation(description: "own resolved browse")
        fixture.onNavigate = { item in
            XCTAssertEqual(item.id, album.id)
            routed.fulfill()
        }
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [routed], timeout: 5)
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        await assertNoAudio(fixture)
        fixture.source.endBrowse(owner: latest)
        let headerData = try XCTUnwrap(
            fixture.source.activity?.userInfo?[FoundationHandoffPayload.userInfoKey] as? Data)
        XCTAssertEqual(try FoundationHandoffPayload.Header.decode(headerData).kind, .playback)
    }

    func testSuccessfulNativeStartAcknowledgementClearsOnlyOriginalSourceSession() async throws {
        let fixture = try Fixture(scope: scope, playing: true)
        defer { fixture.invalidate() }
        try await offer(fixture)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        let paused = expectation(description: "confirmed native receiver cleared source")
        let observer = fixture.sourcePlayer.$queue.dropFirst().sink { entries in
            if entries.isEmpty { paused.fulfill() }
        }
        defer { observer.cancel() }
        fixture.receiver.acceptPending()
        await fulfillment(of: [paused], timeout: 8)
        await fulfillment(of: [fixture.sourceLifecycle.deactivated], timeout: 5)
        XCTAssertEqual(fixture.sourceLifecycle.count, 1)
        XCTAssertTrue(fixture.receiverPlayer.wantsPlayback)
        XCTAssertEqual(fixture.receiverPlayer.state, .playing)
        XCTAssertFalse(fixture.sourcePlayer.wantsPlayback)
        XCTAssertTrue(fixture.sourcePlayer.persistedQueue.isEmpty)
        XCTAssertNil(fixture.sourcePlayer.selectedEntryID)
        XCTAssertNil(fixture.sourcePlayer.nativePlayer.currentItem)
        XCTAssertNil(fixture.receiver.notice)
        XCTAssertEqual(fixture.receiverPlayer.selectedEntryID, fixture.entries[1].id)
    }

    func testFailedReceiverSeekCannotAcknowledgeOrPauseHealthySource() async throws {
        let fixture = try Fixture(scope: scope, playing: true, failReceiverSeek: true)
        defer { fixture.invalidate() }
        try await offer(fixture)
        let failed = expectation(description: "receiver initial seek failed")
        let observer = fixture.receiverPlayer.$state.filter { $0 == .failed }.prefix(1).sink { _ in
            failed.fulfill()
        }
        defer { observer.cancel() }
        fixture.receiver.acceptPending()
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        XCTAssertFalse(
            fixture.receiverPlayer.isNativeContinuationPlaying(
                generation: fixture.receiverPlayer.continuationGeneration,
                occurrence: fixture.entries[1].id))
    }

    func testNewSourceIntentDuringPromptsRejectsBeforeReplacingReceiverQueue() async throws {
        let fixture = try Fixture(scope: scope, playing: true)
        defer { fixture.invalidate() }
        try await offer(fixture)
        let original = fixture.receiverPlayer.persistedQueue
        let rejected = expectation(description: "superseded source rejected")
        let observer = fixture.receiver.$notice.compactMap { $0 }.prefix(1).sink { _ in
            rejected.fulfill()
        }
        defer { observer.cancel() }
        fixture.sourcePlayer.enqueue([FoundationTestTones.items[2]], position: .last)
        fixture.receiver.acceptPending()
        await fulfillment(of: [rejected], timeout: 5)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, original)
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue.count, 4)
        XCTAssertEqual(fixture.sourceLifecycle.count, 0)
    }

    func testFinalNativeClockIsCapturedAfterPromptsAndHeldReceiverResourceBeforeOneSeek()
        async throws
    {
        let gate = ResourceHold()
        let probe = ReceiverSeekProbe()
        let fixture = try Fixture(scope: scope, playing: true, resourceHold: gate, seekProbe: probe)
        defer {
            fixture.invalidate()
            Task { await gate.release() }
        }
        await sourcePlaying(fixture)
        try await offer(fixture)
        let offered = try XCTUnwrap(fixture.receiver.pending?.payload.session?.position)
        await advanceNativeClock(fixture.sourcePlayer, to: 4)
        fixture.receiver.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 5)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue, fixture.entries)
        XCTAssertNil(fixture.receiverPlayer.nativePlayer.currentItem)
        XCTAssertTrue(probe.requests.isEmpty)
        await advanceNativeClock(fixture.sourcePlayer, to: 5.25)
        await gate.release()
        await fulfillment(of: [probe.requested], timeout: 5)
        let target = try XCTUnwrap(probe.requests.first).time.seconds
        let current = fixture.sourcePlayer.nativePlayer.currentTime().seconds
        XCTAssertGreaterThan(target, offered + 1)
        XCTAssertGreaterThanOrEqual(target, 5.2)
        XCTAssertEqual(target, current, accuracy: 0.4)
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(fixture.sourceLifecycle.count, 0)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue, fixture.entries)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue.map(\.id), fixture.entries.map(\.id))
        XCTAssertTrue(fixture.receiverPlayer.shuffleEnabled)
        XCTAssertEqual(fixture.receiverPlayer.repeatMode, .all)
        let cleared = expectation(description: "only native receiver start clears source")
        let observer = fixture.sourcePlayer.$queue.filter { $0.isEmpty }.prefix(1).sink { _ in
            cleared.fulfill()
        }
        defer { observer.cancel() }
        probe.release()
        await fulfillment(of: [cleared], timeout: 8)
        await fulfillment(of: [fixture.sourceLifecycle.deactivated], timeout: 5)
        XCTAssertEqual(fixture.sourceLifecycle.count, 1)
        XCTAssertEqual(fixture.receiverPlayer.state, .playing)
        XCTAssertTrue(fixture.sourcePlayer.persistedQueue.isEmpty)
        XCTAssertNil(fixture.sourcePlayer.selectedEntryID)
    }

    func testReceiverStopDuringHeldReadinessCannotLateSeekPlayOrClearSource() async throws {
        let gate = ResourceHold()
        let probe = ReceiverSeekProbe()
        let fixture = try Fixture(scope: scope, playing: true, resourceHold: gate, seekProbe: probe)
        defer {
            fixture.invalidate()
            Task { await gate.release() }
        }
        await sourcePlaying(fixture)
        try await offer(fixture)
        fixture.receiver.acceptPending()
        await fulfillment(of: [gate.entered], timeout: 5)
        fixture.receiverPlayer.stop()
        await gate.release()
        let noSeek = expectation(description: "retired readiness cannot seek")
        noSeek.isInverted = true
        probe.forbiddenSeek = noSeek
        await fulfillment(of: [noSeek], timeout: 0.2)
        XCTAssertTrue(probe.requests.isEmpty)
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        XCTAssertNil(fixture.receiverPlayer.nativePlayer.currentItem)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue, fixture.entries)
        XCTAssertEqual(fixture.sourceLifecycle.count, 0)
    }

    func testNewSourceIntentAfterFinalClockCancelsReceiverBeforeLateSeekCompletion() async throws {
        let probe = ReceiverSeekProbe()
        let fixture = try Fixture(scope: scope, playing: true, seekProbe: probe)
        defer { fixture.invalidate() }
        try await offer(fixture)
        fixture.receiver.acceptPending()
        await fulfillment(of: [probe.requested], timeout: 5)
        XCTAssertEqual(probe.requests.count, 1)
        let cancelled = expectation(description: "source closure retires unstarted continuation")
        let cancellation = fixture.receiver.$notice.compactMap { $0 }.prefix(1).sink { _ in
            cancelled.fulfill()
        }
        fixture.sourcePlayer.enqueue([FoundationTestTones.items[2]], position: .last)
        await fulfillment(of: [cancelled], timeout: 5)
        cancellation.cancel()
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        XCTAssertEqual(fixture.receiverPlayer.nativePlayer.rate, 0)
        let noStart = expectation(description: "late retired seek cannot start old playback")
        noStart.isInverted = true
        let observation = fixture.receiverPlayer.$state.filter { $0 == .playing }.sink { _ in
            noStart.fulfill()
        }
        probe.completeWithoutSeeking()
        await fulfillment(of: [noStart], timeout: 0.2)
        observation.cancel()
        XCTAssertEqual(probe.requests.count, 1)
        XCTAssertEqual(
            fixture.receiverPlayer.nativePlayer.currentTime().seconds, 0, accuracy: 0.001)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue.count, 4)
        XCTAssertEqual(fixture.sourceLifecycle.count, 0)
    }

    func testSourceClosureDuringHeldActivationPreventsLateOldNativeStart() async throws {
        let activation = ResourceHold()
        let fixture = try Fixture(scope: scope, playing: true, activationHold: activation)
        defer {
            fixture.invalidate()
            Task { await activation.release() }
        }
        try await offer(fixture)
        fixture.receiver.acceptPending()
        await fulfillment(of: [activation.entered], timeout: 5)
        XCTAssertEqual(fixture.receiverPlayer.nativePlayer.rate, 0)
        XCTAssertNotEqual(fixture.receiverPlayer.state, .playing)
        let cancelled = expectation(description: "source closure cancels pending activation")
        let cancellation = fixture.receiver.$notice.compactMap { $0 }.prefix(1).sink { _ in
            cancelled.fulfill()
        }
        fixture.sourcePlayer.enqueue([FoundationTestTones.items[2]], position: .last)
        await fulfillment(of: [cancelled], timeout: 5)
        cancellation.cancel()
        let noStart = expectation(
            description: "retired activation cannot start old receiver playback")
        noStart.isInverted = true
        let observation = fixture.receiverPlayer.$state.filter { $0 == .playing }.sink { _ in
            noStart.fulfill()
        }
        await activation.release()
        await fulfillment(of: [noStart], timeout: 0.2)
        observation.cancel()
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        XCTAssertEqual(fixture.receiverPlayer.nativePlayer.rate, 0)
        XCTAssertTrue(fixture.sourcePlayer.wantsPlayback)
        XCTAssertEqual(fixture.sourcePlayer.persistedQueue.count, 4)
        XCTAssertEqual(fixture.sourceLifecycle.count, 0)
    }

    func testPlayingAudioOverridesBrowseAndPauseResumeSwitchTheAdvertisedKind() async throws {
        let fixture = try Fixture(scope: scope, playing: true)
        defer { fixture.invalidate() }
        await sourcePlaying(fixture)
        let album = FoundationItem(
            id: "album", title: "Album", subtitle: "", kind: .album, duration: nil)
        fixture.source.beginBrowse(album, owner: UUID())
        var header = try activityHeader(fixture.source)
        XCTAssertEqual(header.kind, .playback)
        XCTAssertNotNil(header.sourceDevice)
        try await offer(fixture)
        XCTAssertEqual(
            fixture.receiver.pending?.payload.session?.entries.map(\.occurrence),
            fixture.entries.map(\.id))
        XCTAssertEqual(fixture.receiver.pending?.selectedItem.kind, .track)
        fixture.receiver.dismissPending()
        let paused = expectation(description: "paused audio advertises browse")
        let observer = fixture.publications.filter { $0.kind == .browse }.prefix(1).sink { _ in
            paused.fulfill()
        }
        fixture.sourcePlayer.pause()
        await fulfillment(of: [paused], timeout: 5)
        observer.cancel()
        header = try activityHeader(fixture.source)
        XCTAssertEqual(header.kind, .browse)
        let oldID = header.id
        let resumed = expectation(description: "resumed audio advertises playback")
        let resumedObserver = fixture.publications.filter { $0.kind == .playback }.prefix(1).sink {
            _ in resumed.fulfill()
        }
        fixture.sourcePlayer.play()
        await fulfillment(of: [resumed], timeout: 5)
        resumedObserver.cancel()
        header = try activityHeader(fixture.source)
        XCTAssertEqual(header.kind, .playback)
        XCTAssertNotEqual(header.id, oldID)
    }

    func testLegacyOfferIsRejectedBeforeStreamsOrReceiverQueueReplacement() throws {
        var streamRequests = 0
        let controller = FoundationHandoffController(
            publish: { _ in }, requestStreams: { _, _ in streamRequests += 1 })
        let player = FoundationPlayer(
            resolve: { item in
                guard let url = try FoundationTestTones.resolve(item) else {
                    throw FoundationHandoffError.unavailable
                }
                return url
            }, activateSession: {}, deactivateSession: {})
        defer {
            controller.invalidate()
            player.stop()
        }
        let entry = FoundationQueueEntry(item: FoundationTestTones.items[2])
        player.restoreSession(
            .init(
                entries: [entry], selectedEntryID: entry.id, shuffleEnabled: false, repeatMode: .off
            ))
        controller.configure(
            scope: scope, player: player, resolve: { $0 },
            navigate: { _ in XCTFail("Legacy browse routed") })
        let header = FoundationHandoffPayload.Header(scope: scope, kind: .playback)
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: header.encoded()) as? [String: Any])
        json["version"] = 1
        let activity = NSUserActivity(activityType: FoundationHandoffPayload.activityType)
        activity.userInfo = [
            FoundationHandoffPayload.userInfoKey: try JSONSerialization.data(withJSONObject: json)
        ]
        XCTAssertTrue(controller.receive(activity) { true })
        XCTAssertEqual(controller.notice, FoundationHandoffError.unsupported.errorDescription)
        XCTAssertEqual(streamRequests, 0)
        XCTAssertEqual(player.persistedQueue, [entry])
        XCTAssertNil(controller.pending)
    }

    func testWrongAuthorizationNonceOnBoundStreamsCannotReplaceQueueOrResolveAudio() async throws {
        let pair = try FoundationHandoffStreamTests.pair()
        let receiver = FoundationHandoffController(
            publish: { _ in },
            requestStreams: { _, completion in
                completion(pair.1.input, pair.1.output, nil)
            })
        let audio = AudioCounter()
        let player = FoundationPlayer(
            resolve: { try await audio.resolve($0) }, activateSession: {}, deactivateSession: {})
        let original = FoundationQueueEntry(item: FoundationTestTones.items[2])
        player.restoreSession(
            .init(
                entries: [original], selectedEntryID: original.id, shuffleEnabled: false,
                repeatMode: .off))
        receiver.configure(
            scope: scope, player: player, resolve: { $0 },
            navigate: { _ in XCTFail("Playback routed as browse") })
        let selected = FoundationQueueEntry(item: FoundationTestTones.items[0])
        let header = FoundationHandoffPayload.Header(scope: scope, kind: .playback)
        let payload = FoundationHandoffPayload(
            header: header,
            session: .init(
                entries: [.init(selected)], selected: selected.id, position: 3,
                shuffle: false, repeatMode: .off, wasPlaying: false), destination: nil)
        var source: FoundationHandoffStreamExchange!
        var messageCount = 0
        source = FoundationHandoffStreamExchange(
            streams: pair.0, maximumIncomingBytes: 2_048,
            message: { data in
                messageCount += 1
                do {
                    if messageCount == 1 {
                        XCTAssertEqual(
                            try FoundationHandoffPayload.Header.decode(data).id, header.id)
                        try source.expectAcknowledgement()
                        try source.send(payload.encoded())
                    } else {
                        let command = try FoundationHandoffControl.decode(data)
                        XCTAssertEqual(command.kind, .authorize)
                        try source.send(
                            FoundationHandoffControl(
                                kind: .authorized,
                                transfer: header.id, occurrence: selected.id, nonce: UUID()
                            ).encoded())
                    }
                } catch { XCTFail("Synthetic peer failed: \(error)") }
            }, failure: { _ in })
        defer {
            source.close()
            receiver.invalidate()
            player.stop()
        }
        source.open()
        let offered = expectation(description: "receiver confirmation")
        let offeredObservation = receiver.$pending.compactMap { $0 }.prefix(1).sink { _ in
            offered.fulfill()
        }
        let activity = NSUserActivity(activityType: FoundationHandoffPayload.activityType)
        activity.userInfo = [FoundationHandoffPayload.userInfoKey: try header.encoded()]
        XCTAssertTrue(receiver.receive(activity) { true })
        await fulfillment(of: [offered], timeout: 5)
        offeredObservation.cancel()
        let rejected = expectation(description: "wrong authorization nonce rejected")
        let observation = receiver.$notice.compactMap { $0 }.prefix(1).sink { _ in
            rejected.fulfill()
        }
        receiver.acceptPending()
        await fulfillment(of: [rejected], timeout: 5)
        observation.cancel()
        XCTAssertEqual(player.persistedQueue, [original])
        XCTAssertFalse(player.wantsPlayback)
        let calls = await audio.count
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(messageCount, 2)
    }

    private func activityHeader(_ controller: FoundationHandoffController) throws
        -> FoundationHandoffPayload.Header
    {
        let data = try XCTUnwrap(
            controller.activity?.userInfo?[FoundationHandoffPayload.userInfoKey] as? Data)
        return try FoundationHandoffPayload.Header.decode(data)
    }

    private func sourcePlaying(_ fixture: Fixture) async {
        let ready = expectation(description: "source native playback")
        let observation = fixture.sourcePlayer.$state.filter { $0 == .playing }.prefix(1).sink {
            _ in ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 8)
        observation.cancel()
    }

    private func advanceNativeClock(_ player: FoundationPlayer, to seconds: Double) async {
        // Move the actual native clock without emitting a new app command/intent.
        // This makes elapsed playback deterministic while retaining the original session.
        let ready = expectation(description: "native source clock advanced")
        player.nativePlayer.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        ) { finished in
            XCTAssertTrue(finished)
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 5)
    }

    private func restored(_ fixture: Fixture) async {
        let ready = expectation(description: "authorized full queue restored")
        let expected = fixture.sourcePlayer.queue.map(\.id)
        let observation = fixture.receiverPlayer.$queue.filter { $0.map(\.id) == expected }.prefix(
            1
        ).sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 5)
        observation.cancel()
    }

    private func assertNoAudio(_ fixture: Fixture) async {
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
    }

    private func offer(_ fixture: Fixture) async throws {
        if fixture.sourcePlayer.wantsPlayback { await sourcePlaying(fixture) }
        let ready = expectation(description: "validated own-account confirmation")
        let observer = fixture.receiver.$pending.compactMap { $0 }.prefix(1).sink { _ in
            ready.fulfill()
        }
        defer { observer.cancel() }
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotNil(fixture.receiver.pending)
    }

    @MainActor
    fileprivate final class Fixture {
        let source: FoundationHandoffController
        let publications: PassthroughSubject<FoundationHandoffPayload.Header, Never>
        let receiver: FoundationHandoffController
        let sourcePlayer: FoundationPlayer
        let receiverPlayer: FoundationPlayer
        let entries: [FoundationQueueEntry]
        let audio = AudioCounter()
        let sourceLifecycle: SourceLifecycle
        var metadataResolutions = 0
        var onNavigate: ((FoundationItem) -> Void)?

        init(
            scope: String, receivingScope: String? = nil, playing: Bool = false,
            failReceiverSeek: Bool = false, catalogItems: [FoundationItem]? = nil,
            resourceHold: ResourceHold? = nil, seekProbe: ReceiverSeekProbe? = nil,
            activationHold: ResourceHold? = nil
        ) throws {
            let publications = PassthroughSubject<FoundationHandoffPayload.Header, Never>()
            self.publications = publications
            source = FoundationHandoffController(publish: { activity in
                if let data = activity.userInfo?[FoundationHandoffPayload.userInfoKey] as? Data,
                    let header = try? FoundationHandoffPayload.Header.decode(data)
                {
                    publications.send(header)
                }
            })
            let native = try FoundationHandoffStreamTests.pair()
            let sourceOwner = source
            receiver = FoundationHandoffController(
                publish: { _ in },
                requestStreams: { activity, completion in
                    sourceOwner.userActivity(
                        activity, didReceive: native.0.input, outputStream: native.0.output)
                    completion(native.1.input, native.1.output, nil)
                })
            let audio = audio
            let sourceLifecycle = SourceLifecycle()
            self.sourceLifecycle = sourceLifecycle
            sourcePlayer = FoundationPlayer(
                resolve: { item in try await audio.resolve(item) }, activateSession: {},
                deactivateSession: { sourceLifecycle.deactivate() })
            receiverPlayer = FoundationPlayer(
                resolve: { item in
                    if let resourceHold { await resourceHold.wait() }
                    return try await audio.resolve(item)
                },
                activateSession: {
                    if let activationHold { await activationHold.wait() }
                },
                deactivateSession: {},
                seekForContinuation: { player, time, completion in
                    if let seekProbe {
                        seekProbe.record(player, time: time, completion: completion)
                    } else if failReceiverSeek {
                        completion(false)
                    } else {
                        player.seek(
                            to: time, toleranceBefore: .zero, toleranceAfter: .zero,
                            completionHandler: completion)
                    }
                })
            sourcePlayer.nativePlayer.volume = 0
            receiverPlayer.nativePlayer.volume = 0
            let items = catalogItems ?? FoundationTestTones.items
            entries = [
                .init(item: items[0]),
                .init(item: items[1]),
                .init(item: items[1]),
            ]
            sourcePlayer.continueSession(
                .init(
                    entries: entries, selectedEntryID: entries[1].id, shuffleEnabled: true,
                    repeatMode: .all), position: 3, wasPlaying: playing)
            let previous = FoundationQueueEntry(item: FoundationTestTones.items[2])
            receiverPlayer.restoreSession(
                .init(
                    entries: [previous], selectedEntryID: previous.id,
                    shuffleEnabled: false, repeatMode: .off))
            source.configure(
                scope: scope, player: sourcePlayer, resolve: { $0 }, navigate: { _ in })
            receiver.configure(
                scope: receivingScope ?? scope, player: receiverPlayer,
                resolve: { [weak self] item in
                    self?.metadataResolutions += 1
                    return FoundationTestTones.items.first(where: { $0.id == item.id }) ?? item
                }, navigate: { [weak self] item in self?.onNavigate?(item) })
        }

        func invalidate() {
            source.invalidate()
            receiver.invalidate()
            sourcePlayer.stop()
            receiverPlayer.stop()
        }
    }
}

@MainActor
private final class SourceLifecycle {
    var count = 0
    let deactivated = XCTestExpectation(description: "source audio session deactivated")
    func deactivate() {
        count += 1
        if count == 1 { deactivated.fulfill() }
    }
}

private actor ResourceHold {
    nonisolated let entered = XCTestExpectation(description: "receiver resource held")
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

@MainActor
private final class ReceiverSeekProbe {
    struct Request {
        let player: AVPlayer
        let time: CMTime
        let completion: @Sendable (Bool) -> Void
    }
    var requests: [Request] = []
    let requested = XCTestExpectation(description: "receiver final seek requested")
    var forbiddenSeek: XCTestExpectation?
    func record(_ player: AVPlayer, time: CMTime, completion: @escaping @Sendable (Bool) -> Void) {
        requests.append(.init(player: player, time: time, completion: completion))
        requested.fulfill()
        forbiddenSeek?.fulfill()
    }
    func completeWithoutSeeking() {
        requests.first?.completion(true)
    }
    func release() {
        guard let request = requests.first else { return }
        request.player.seek(
            to: request.time, toleranceBefore: .zero, toleranceAfter: .zero,
            completionHandler: request.completion)
    }
}

private actor AudioCounter {
    private(set) var count = 0
    func resolve(_ item: FoundationItem) throws -> URL {
        count += 1
        guard let value = try FoundationTestTones.resolve(item) else {
            throw FoundationHandoffError.unavailable
        }
        return value
    }
}

/// Exercises the same receiver resolver called by FoundationAppModel, with the
/// real generated-request adapter and synthetic transport; no server or login.
@MainActor
final class FoundationHandoffResolutionTests: XCTestCase {
    private let scope = String(repeating: "a", count: 64)
    private let itemID = "00000000000000000000000000000002"

    func testApplicationResolverAcceptsTrackAndEveryBrowseKind() async throws {
        for (kind, type) in [
            (FoundationItem.Kind.track, "Audio"), (.playlist, "Playlist"),
            (.album, "MusicAlbum"), (.artist, "MusicArtist"),
        ] {
            let item = item(kind)
            let library = library { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertTrue(request.url!.path.hasSuffix("/Items/" + item.id))
                // Pinned SDK GetItem scopes /Items/{id} with userId query.
                let userQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.filter { $0.name == "userId" }
                XCTAssertEqual(
                    userQuery,
                    [URLQueryItem(name: "userId", value: "00000000000000000000000000000001")])
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "MediaBrowser Client=\"Velacanto Native\", Device=\"Apple\", DeviceId=\"synthetic\", Version=\"1\", Token=\"synthetic\""
                )
                return Self.response(request, id: item.id, type: type)
            }
            let result = try await resolve(item, library: library)
            XCTAssertEqual(result.id, item.id)
            XCTAssertEqual(result.kind, kind)
            XCTAssertEqual(result.catalogSource?.identity, library.catalogAccountIdentity)
        }
    }

    func testApplicationResolverRejectsWrongCanonicalIDAndKind() async throws {
        for response in [("00000000000000000000000000000003", "Audio"), (itemID, "Playlist")] {
            let library = library { request in
                Self.response(request, id: response.0, type: response.1)
            }
            do {
                _ = try await resolve(item(.track), library: library)
                XCTFail("Mismatched canonical identity must fail")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .invalidResponse) }
        }
    }

    func testApplicationResolverRejectsForeignAndLocalSourcesBeforeTransport() async throws {
        let library = library { _ in
            XCTFail("Mismatched source must not reach transport")
            throw FoundationLibraryError.unavailable
        }
        for source in [
            try FoundationCatalogSource.jellyfin(scope: String(repeating: "b", count: 64)),
            .local(sourceID: UUID()),
        ] {
            var value = item(.track)
            value.catalogSource = source
            do {
                _ = try await resolve(value, library: library)
                XCTFail("Foreign source must fail")
            } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        }
    }

    func testUnavailableAndCancelledResolutionDoNotSucceed() async throws {
        let unavailable = library { _ in throw FoundationLibraryError.unavailable }
        do {
            _ = try await resolve(item(.track), library: unavailable)
            XCTFail("Unavailable media must fail")
        } catch { XCTAssertEqual(error as? FoundationLibraryError, .unavailable) }
        let gate = HandoffResolutionGate()
        let delayed = library { request in
            await gate.hold()
            return Self.response(request, id: "00000000000000000000000000000002", type: "Audio")
        }
        let task = Task { try await self.resolve(self.item(.track), library: delayed) }
        await gate.waitUntilStarted()
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Late response after cancellation must fail")
        } catch {
            XCTAssertTrue(
                error is CancellationError || error as? FoundationLibraryError == .cancelled)
        }
    }

    func testOfflineApplicationResolverUsesOnlyOwnReadyDownload() async throws {
        let library = library { _ in
            XCTFail("Offline continuation cannot request metadata")
            throw FoundationLibraryError.unavailable
        }
        let track = item(.track)
        let result = try await FoundationHandoffResolution.resolve(
            track, library: library, localOnly: true, localItem: { _ in track })
        XCTAssertEqual(result, track)
        do {
            _ = try await FoundationHandoffResolution.resolve(
                track, library: library, localOnly: true, localItem: { _ in nil })
            XCTFail("Missing ready download must fail")
        } catch { XCTAssertEqual(error as? FoundationHandoffError, .unavailable) }
    }

    func testActualApplicationResolverLeavesQueueAndAudioUntilConfirmation() async throws {
        let track = item(.track)
        let fixture = try FoundationHandoffControllerTests.Fixture(
            scope: scope, catalogItems: [track, track])
        defer { fixture.invalidate() }
        let library = library { request in Self.response(request, id: track.id, type: "Audio") }
        configure(fixture, library: library)
        let previous = fixture.receiverPlayer.persistedQueue
        let ready = expectation(description: "production resolver confirmation")
        let observer = fixture.receiver.$pending.compactMap { $0 }.prefix(1).sink { _ in
            ready.fulfill()
        }
        defer { observer.cancel() }
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
        let restored = expectation(description: "authorized production resolver queue restored")
        let expected = fixture.entries.map(\.id)
        let restoration = fixture.receiverPlayer.sessionChanged.filter {
            fixture.receiverPlayer.persistedQueue.map(\.id) == expected
        }.prefix(1).sink { _ in restored.fulfill() }
        defer { restoration.cancel() }
        fixture.receiver.acceptPending()
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue.map(\.id), fixture.entries.map(\.id))
        XCTAssertEqual(fixture.receiverPlayer.selectedEntryID, fixture.entries[1].id)
        XCTAssertTrue(fixture.receiverPlayer.shuffleEnabled)
        XCTAssertEqual(fixture.receiverPlayer.repeatMode, .all)
        XCTAssertEqual(fixture.receiverPlayer.elapsed, 3)
        XCTAssertFalse(fixture.receiverPlayer.wantsPlayback)
        let after = await fixture.audio.count
        XCTAssertEqual(after, 0)
    }

    func testPlaylistBrowseThroughApplicationResolverDoesNotTouchPlayback() async throws {
        let fixture = try FoundationHandoffControllerTests.Fixture(scope: scope)
        defer { fixture.invalidate() }
        let playlist = item(.playlist)
        let library = library { request in Self.response(request, id: playlist.id, type: "Playlist")
        }
        let navigated = expectation(description: "canonical playlist destination")
        configure(fixture, library: library) { result in
            XCTAssertEqual(result.id, playlist.id)
            XCTAssertEqual(result.kind, .playlist)
            navigated.fulfill()
        }
        fixture.source.beginBrowse(playlist, owner: UUID())
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [navigated], timeout: 5)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        XCTAssertNil(fixture.receiver.pending)
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
    }

    func testRetiredAccountRejectsLateProductionResolutionWithoutQueueChanges() async throws {
        let track = item(.track)
        let fixture = try FoundationHandoffControllerTests.Fixture(
            scope: scope, catalogItems: [track, track])
        defer { fixture.invalidate() }
        let gate = HandoffResolutionGate()
        let library = library { request in
            await gate.hold()
            return Self.response(request, id: track.id, type: "Audio")
        }
        let finished = expectation(description: "retired resolver returned")
        fixture.receiver.configure(
            scope: scope, player: fixture.receiverPlayer,
            resolve: { item in
                defer { finished.fulfill() }
                return try await FoundationHandoffResolution.resolve(
                    item, library: library, localOnly: false, localItem: { _ in nil })
            }, navigate: { _ in XCTFail("Retired account must not navigate") })
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await gate.waitUntilStarted()
        fixture.receiver.invalidate()
        await gate.release()
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
    }

    func testUnavailableProductionResolutionPreservesQueueAndAudio() async throws {
        let track = item(.track)
        let fixture = try FoundationHandoffControllerTests.Fixture(
            scope: scope, catalogItems: [track, track])
        defer { fixture.invalidate() }
        configure(fixture, library: library { _ in throw FoundationLibraryError.unavailable })
        let failed = expectation(description: "unavailable continuation")
        let observer = fixture.receiver.$notice.compactMap { $0 }.prefix(1).sink { _ in
            failed.fulfill()
        }
        defer { observer.cancel() }
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
    }

    func testDecliningProductionConfirmationPreservesQueueAndAudio() async throws {
        let track = item(.track)
        let fixture = try FoundationHandoffControllerTests.Fixture(
            scope: scope, catalogItems: [track, track])
        defer { fixture.invalidate() }
        configure(
            fixture,
            library: library { request in Self.response(request, id: track.id, type: "Audio") })
        let ready = expectation(description: "production confirmation to decline")
        let observer = fixture.receiver.$pending.compactMap { $0 }.prefix(1).sink { _ in
            ready.fulfill()
        }
        defer { observer.cancel() }
        let previous = fixture.receiverPlayer.persistedQueue
        XCTAssertTrue(fixture.receiver.receive(try XCTUnwrap(fixture.source.activity)) { true })
        await fulfillment(of: [ready], timeout: 5)
        fixture.receiver.dismissPending()
        fixture.receiver.acceptPending()
        XCTAssertNil(fixture.receiver.pending)
        XCTAssertEqual(fixture.receiverPlayer.persistedQueue, previous)
        let count = await fixture.audio.count
        XCTAssertEqual(count, 0)
    }

    private func configure(
        _ fixture: FoundationHandoffControllerTests.Fixture,
        library: FoundationJellyfinLibrary,
        navigate: @escaping FoundationHandoffController.Navigate = { _ in }
    ) {
        fixture.receiver.configure(
            scope: scope, player: fixture.receiverPlayer,
            resolve: { item in
                try await FoundationHandoffResolution.resolve(
                    item, library: library, localOnly: false, localItem: { _ in nil })
            }, navigate: navigate)
    }

    private func resolve(_ item: FoundationItem, library: FoundationJellyfinLibrary) async throws
        -> FoundationItem
    {
        try await FoundationHandoffResolution.resolve(
            item, library: library, localOnly: false, localItem: { _ in nil })
    }

    private func item(_ kind: FoundationItem.Kind) -> FoundationItem {
        .init(id: itemID, title: "Synthetic", subtitle: "", kind: kind, duration: nil)
    }

    private func library(_ load: @escaping FoundationJellyfinLibrary.Load)
        -> FoundationJellyfinLibrary
    {
        .init(
            session: .init(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "00000000000000000000000000000001", deviceID: "synthetic"), load: load)
    }

    private nonisolated static func response(_ request: URLRequest, id: String, type: String)
        -> (Data, URLResponse)
    {
        let body = "{\"Id\":\"\(id)\",\"Type\":\"\(type)\",\"Name\":\"Synthetic\"}"
        return (
            Data(body.utf8),
            HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}

private actor HandoffResolutionGate {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        let deadline = Date().addingTimeInterval(5)
        while !started && Date() < deadline { await Task.yield() }
        XCTAssertTrue(started, "Synthetic transport did not start")
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
