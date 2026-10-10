import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationPlaybackReportingTests: XCTestCase {
    func testProgressThrottlesAndPauseResumeSeekUseSameOccurrence() async {
        let recorder = ReportRecorder()
        var clock = 0.0
        let owner = FoundationPlaybackReporting(now: { clock }, send: { await recorder.append($0) })
        owner.begin(itemID: "track", position: 0)
        await owner.task?.value
        for position in 1...9 {
            clock = Double(position)
            owner.progress(position: clock, paused: false)
        }
        XCTAssertNil(owner.task)
        clock = 10
        owner.progress(position: 10, paused: false)
        await owner.task?.value
        owner.progress(position: 10, paused: true)
        await owner.task?.value
        owner.progress(position: 2, paused: true, seek: true)
        await owner.task?.value
        owner.progress(position: 2, paused: false)
        await owner.task?.value
        owner.stop(position: 3)
        await owner.task?.value
        let events = await recorder.events
        XCTAssertEqual(
            events.map(\.kind), [.start, .progress, .progress, .progress, .progress, .stop])
        XCTAssertEqual(events.map(\.position), [0, 10, 10, 2, 2, 3])
        XCTAssertEqual(Set(events.map(\.occurrenceID)).count, 1)
    }

    func testDuplicatesAndRepeatCreateFreshOrderedOccurrences() async {
        let recorder = ReportRecorder()
        let owner = FoundationPlaybackReporting { await recorder.append($0) }
        for _ in 0..<3 {
            owner.begin(itemID: "same-track", position: 0)
            owner.stop(position: 20)
        }
        await owner.task?.value
        let events = await recorder.events
        XCTAssertEqual(events.map(\.kind), [.start, .stop, .start, .stop, .start, .stop])
        XCTAssertEqual(Set(events.map(\.occurrenceID)).count, 3)
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index].occurrenceID, events[index + 1].occurrenceID)
        }
    }

    func testBlockedTransportBoundsQueueAndPreservesAdmittedLifecyclePairs() async throws {
        let recorder = ReportRecorder(holdFirst: true)
        defer { Task { await recorder.release() } }
        let owner = FoundationPlaybackReporting { await recorder.append($0) }
        owner.begin(itemID: "first", position: 0)
        try await recorder.waitForCount(1)
        owner.stop(position: 1)
        for _ in 0..<100 {
            owner.begin(itemID: "same", position: 0)
            for position in 1...30 {
                owner.progress(position: Double(position), paused: true, seek: true)
            }
            owner.stop(position: 30)
            XCTAssertLessThanOrEqual(
                owner.pending.count, FoundationPlaybackReporting.maximumPending)
        }
        await recorder.release()
        await owner.task?.value
        let events = await recorder.events
        XCTAssertLessThanOrEqual(events.count, 33)
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index].kind, .start)
            XCTAssertEqual(events[index + 1].kind, .stop)
            XCTAssertEqual(events[index].occurrenceID, events[index + 1].occurrenceID)
        }
        owner.begin(itemID: "later", position: 0)
        owner.stop(position: 1)
        await owner.task?.value
        let final = await recorder.events
        XCTAssertEqual(final.last?.itemID, "later")
    }

    func testFailureDoesNotRetryOrBlockLaterOccurrences() async {
        let recorder = ReportRecorder()
        let owner = FoundationPlaybackReporting {
            await recorder.append($0)
            throw URLError(.notConnectedToInternet)
        }
        owner.begin(itemID: "a", position: 0)
        owner.stop(position: 1)
        await owner.task?.value
        owner.begin(itemID: "b", position: 0)
        owner.stop(position: 2)
        await owner.task?.value
        let events = await recorder.events
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events.map(\.itemID), ["a", "a", "b", "b"])
    }

    func testInvalidationDropsPendingWorkAndRejectsLateCompletion() async throws {
        let recorder = ReportRecorder(holdFirst: true)
        defer { Task { await recorder.release() } }
        let owner = FoundationPlaybackReporting { await recorder.append($0) }
        owner.begin(itemID: "old", position: 0)
        try await recorder.waitForCount(1)
        owner.stop(position: 10)
        let task = owner.task
        owner.invalidate()
        owner.begin(itemID: "new", position: 0)
        await recorder.release()
        await task?.value
        XCTAssertTrue(owner.pending.isEmpty)
        let events = await recorder.events
        XCTAssertEqual(events.count, 1)
    }

    func testGoingOfflineDiscardsQueuedHistoryAndLateWorkCannotClearNewWorker() async throws {
        let recorder = ReportRecorder(holdFirst: true)
        defer { Task { await recorder.release() } }
        let owner = FoundationPlaybackReporting { await recorder.append($0) }
        owner.begin(itemID: "old", position: 0)
        try await recorder.waitForCount(1)
        owner.stop(position: 20)
        let oldTask = owner.task
        owner.cancelPending()
        owner.begin(itemID: "new", position: 0)
        owner.stop(position: 1)
        await Task.yield()
        let heldEvents = await recorder.events
        XCTAssertEqual(heldEvents.count, 1, "Cancellation must not overlap a held transport")
        await recorder.release()
        await oldTask?.value
        await owner.task?.value
        let events = await recorder.events
        XCTAssertEqual(events.map(\.itemID), ["old", "new", "new"])
        XCTAssertEqual(events.map(\.kind), [.start, .start, .stop])
        XCTAssertNil(owner.task)
    }

    func testNativeCommitAndRepeatOneReportDistinctOccurrencesWithoutChangingQueue() async throws {
        let recorder = ReportRecorder()
        let item = FoundationTestTones.items[0]
        let url = try XCTUnwrap(FoundationTestTones.resolve(item))
        let player = FoundationPlayer(
            resolve: { _ in url }, activateSession: {}, deactivateSession: {},
            reportPlayback: { await recorder.append($0) })
        player.nativePlayer.isMuted = true
        defer {
            player.stop()
            player.invalidateReporting()
        }
        player.setQueue([item, item], selectedIndex: 0)
        let selected = player.selectedEntryID
        try await recorder.waitForCount(1)
        XCTAssertEqual(player.state, .playing)
        player.setRepeat(.one)
        player.didReachEnd(try XCTUnwrap(player.nativePlayer.currentItem))
        try await recorder.waitForCount(3)
        XCTAssertEqual(player.selectedEntryID, selected)
        XCTAssertEqual(player.queue.count, 2)
        player.stop()
        try await recorder.waitForCount(4)
        let events = await recorder.events
        XCTAssertEqual(events.map(\.kind), [.start, .stop, .start, .stop])
        XCTAssertNotEqual(events[0].occurrenceID, events[2].occurrenceID)
        XCTAssertEqual(events[0].occurrenceID, events[1].occurrenceID)
        XCTAssertEqual(events[2].occurrenceID, events[3].occurrenceID)
    }

    func testOfflineNativePlaybackDoesNotCreateOrBackfillListening() async throws {
        let recorder = ReportRecorder()
        let item = FoundationTestTones.items[0]
        let url = try XCTUnwrap(FoundationTestTones.resolve(item))
        let player = FoundationPlayer(
            resolve: { _ in url }, activateSession: {}, deactivateSession: {},
            reportPlayback: { await recorder.append($0) }, reportingAllowed: { false })
        player.nativePlayer.isMuted = true
        defer {
            player.stop()
            player.invalidateReporting()
        }
        player.setQueue([item], selectedIndex: 0)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while player.state != .playing, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(player.state, .playing)
        player.pause()
        player.stop()
        await Task.yield()
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }

    func testRequestedButRejectedNativeStartDoesNotReportListening() async throws {
        let recorder = ReportRecorder()
        let item = FoundationTestTones.items[0]
        let url = try XCTUnwrap(FoundationTestTones.resolve(item))
        let player = FoundationPlayer(
            resolve: { _ in url }, activateSession: {}, deactivateSession: {},
            startPlayback: { _ in }, reportPlayback: { await recorder.append($0) })
        player.setQueue([item], selectedIndex: 0)
        await player.selectionTask?.value
        await player.playTask?.value
        player.pause()
        player.stop()
        await Task.yield()
        let events = await recorder.events
        XCTAssertTrue(events.isEmpty)
    }
}

private actor ReportRecorder {
    private(set) var events: [FoundationPlaybackReport] = []
    private var holdFirst: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
    func append(_ event: FoundationPlaybackReport) async {
        events.append(event)
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { continuation = $0 }
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func waitForCount(_ count: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while events.count < count {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
