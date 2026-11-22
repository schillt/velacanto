import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

// Listening-report fixtures use DEBUG-only FoundationTestTones.
#if DEBUG
    @MainActor
    final class FoundationPlaybackReportingTests: XCTestCase {
        private func waitForReport(
            _ owner: FoundationPlaybackReporting, recorder: ReportRecorder
        ) async -> Bool {
            guard let task = owner.task else { return true }
            let finished = XCTestExpectation(description: "report worker finished")
            let observer = Task {
                await task.value
                finished.fulfill()
            }
            guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
                owner.invalidate()
                task.cancel()
                await recorder.release()
                observer.cancel()
                XCTFail("Report worker did not finish within 5 seconds")
                return false
            }
            return true
        }

        func testNegotiatedSessionStaysWithItsOccurrenceAcrossReplacement() async {
            let recorder = ReportRecorder()
            let owner = FoundationPlaybackReporting { await recorder.append($0) }
            let first = FoundationPlaybackSource(
                delivery: .hlsAAC, mediaSourceID: "a", serverSessionID: "session-a")
            let second = FoundationPlaybackSource(
                delivery: .hlsAAC, mediaSourceID: "b", serverSessionID: "session-b")
            owner.begin(itemID: "same-track", position: 0, source: first)
            owner.progress(position: 1, paused: true)
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.stop(position: 1)
            owner.begin(itemID: "same-track", position: 0, source: second)
            owner.stop(position: 2)
            guard await waitForReport(owner, recorder: recorder) else { return }
            let events = await recorder.events
            XCTAssertEqual(events.map(\.source), [first, first, first, second, second])
            XCTAssertEqual(Set(events.map(\.occurrenceID)).count, 2)
            XCTAssertFalse(
                events.contains { $0.source?.serverSessionID == $0.occurrenceID.uuidString })
        }

        func testProgressThrottlesAndPauseResumeSeekUseSameOccurrence() async {
            let recorder = ReportRecorder()
            var clock = 0.0
            let owner = FoundationPlaybackReporting(
                now: { clock }, send: { await recorder.append($0) })
            owner.begin(itemID: "track", position: 0)
            guard await waitForReport(owner, recorder: recorder) else { return }
            for position in 1...9 {
                clock = Double(position)
                owner.progress(position: clock, paused: false)
            }
            XCTAssertNil(owner.task)
            clock = 10
            owner.progress(position: 10, paused: false)
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.progress(position: 10, paused: true)
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.progress(position: 2, paused: true, seek: true)
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.progress(position: 2, paused: false)
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.stop(position: 3)
            guard await waitForReport(owner, recorder: recorder) else { return }
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
            guard await waitForReport(owner, recorder: recorder) else { return }
            let events = await recorder.events
            XCTAssertEqual(events.map(\.kind), [.start, .stop, .start, .stop, .start, .stop])
            XCTAssertEqual(Set(events.map(\.occurrenceID)).count, 3)
            for index in stride(from: 0, to: events.count, by: 2) {
                XCTAssertEqual(events[index].occurrenceID, events[index + 1].occurrenceID)
            }
        }

        func testBlockedTransportBoundsQueueAndPreservesAdmittedLifecyclePairs() async throws {
            let recorder = ReportRecorder(holdFirst: true)
            let owner = FoundationPlaybackReporting { await recorder.append($0) }
            addTeardownBlock { @MainActor in
                owner.invalidate()
                await recorder.release()
                _ = await self.waitForReport(owner, recorder: recorder)
            }
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
            guard await waitForReport(owner, recorder: recorder) else { return }
            let events = await recorder.events
            XCTAssertLessThanOrEqual(events.count, 33)
            for index in stride(from: 0, to: events.count, by: 2) {
                XCTAssertEqual(events[index].kind, .start)
                XCTAssertEqual(events[index + 1].kind, .stop)
                XCTAssertEqual(events[index].occurrenceID, events[index + 1].occurrenceID)
            }
            owner.begin(itemID: "later", position: 0)
            owner.stop(position: 1)
            guard await waitForReport(owner, recorder: recorder) else { return }
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
            guard await waitForReport(owner, recorder: recorder) else { return }
            owner.begin(itemID: "b", position: 0)
            owner.stop(position: 2)
            guard await waitForReport(owner, recorder: recorder) else { return }
            let events = await recorder.events
            XCTAssertEqual(events.count, 4)
            XCTAssertEqual(events.map(\.itemID), ["a", "a", "b", "b"])
        }

        func testInvalidationDropsPendingWorkAndRejectsLateCompletion() async throws {
            let entered = XCTestExpectation(description: "report transport entered")
            let recorder = HeldInvalidationReport { entered.fulfill() }
            let owner = FoundationPlaybackReporting { await recorder.append($0) }
            defer {
                owner.invalidate()
                Task { await recorder.release() }
            }
            owner.begin(itemID: "old", position: 0)
            let admission = await XCTWaiter.fulfillment(of: [entered], timeout: 3)
            guard admission == .completed else {
                XCTFail("Report transport did not enter before the deadline")
                return
            }
            owner.stop(position: 10)
            let task = try XCTUnwrap(owner.task)
            owner.invalidate()
            owner.begin(itemID: "new", position: 0)
            let finished = XCTestExpectation(description: "invalidated report worker finished")
            let observer = Task {
                await task.value
                finished.fulfill()
            }
            defer {
                task.cancel()
                observer.cancel()
            }
            await recorder.release()
            let completion = await XCTWaiter.fulfillment(of: [finished], timeout: 3)
            guard completion == .completed else {
                XCTFail("Invalidated report worker did not finish before the deadline")
                return
            }
            XCTAssertTrue(owner.pending.isEmpty)
            let events = await recorder.events
            let unexpectedEntry = await recorder.unexpectedEntry
            XCTAssertEqual(events.count, 1)
            XCTAssertFalse(unexpectedEntry, "A second report entered the held transport")
        }

        func testInvalidationFixtureDuplicateDoesNotStrandHeldReport() async throws {
            let entered = XCTestExpectation(description: "first report entered")
            let firstFinished = XCTestExpectation(description: "first report released")
            let secondFinished = XCTestExpectation(description: "duplicate report returned")
            let recorder = HeldInvalidationReport { entered.fulfill() }
            let event = FoundationPlaybackReport(
                kind: .start, occurrenceID: UUID(), itemID: "fixture", position: 0, paused: false)
            let first = Task {
                await recorder.append(event)
                firstFinished.fulfill()
            }
            defer {
                first.cancel()
                Task { await recorder.release() }
            }
            guard await XCTWaiter.fulfillment(of: [entered], timeout: 3) == .completed else {
                XCTFail("First report did not enter before the deadline")
                return
            }
            let second = Task {
                await recorder.append(event)
                secondFinished.fulfill()
            }
            defer { second.cancel() }
            guard await XCTWaiter.fulfillment(of: [secondFinished], timeout: 3) == .completed else {
                XCTFail("Duplicate report did not return before the deadline")
                return
            }
            let unexpected = await recorder.unexpectedEntry
            XCTAssertTrue(unexpected)
            await recorder.release()
            guard await XCTWaiter.fulfillment(of: [firstFinished], timeout: 3) == .completed else {
                XCTFail("First report was stranded after release")
                return
            }
            let events = await recorder.events
            XCTAssertEqual(events.count, 2)
        }

        func testInvalidationFixtureReleaseBeforeEntryIsLatched() async throws {
            let entered = XCTestExpectation(description: "report entered after early release")
            let finished = XCTestExpectation(description: "early-released report returned")
            let recorder = HeldInvalidationReport { entered.fulfill() }
            await recorder.release()
            let event = FoundationPlaybackReport(
                kind: .start, occurrenceID: UUID(), itemID: "fixture", position: 0, paused: false)
            let task = Task {
                await recorder.append(event)
                finished.fulfill()
            }
            defer {
                task.cancel()
                Task { await recorder.release() }
            }
            guard await XCTWaiter.fulfillment(of: [entered, finished], timeout: 3) == .completed
            else {
                XCTFail("Early release did not let the report return before the deadline")
                return
            }
            let unexpected = await recorder.unexpectedEntry
            XCTAssertFalse(unexpected)
        }

        func testGoingOfflineDiscardsQueuedHistoryAndLateWorkCannotClearNewWorker() async throws {
            let oldEntered = XCTestExpectation(description: "old report transport entered")
            let newEntered = XCTestExpectation(description: "new report transport entered")
            let recorder = OfflineReportingProbe(
                oldEntered: { oldEntered.fulfill() }, newEntered: { newEntered.fulfill() })
            let owner = FoundationPlaybackReporting { await recorder.append($0) }
            defer {
                owner.invalidate()
                Task { await recorder.releaseAll() }
            }
            owner.begin(itemID: "old", position: 0)
            guard await XCTWaiter.fulfillment(of: [oldEntered], timeout: 3) == .completed else {
                XCTFail("Old report transport did not enter before the deadline")
                return
            }
            owner.stop(position: 20)
            let oldTask = try XCTUnwrap(owner.task)
            owner.cancelPending()
            owner.begin(itemID: "new", position: 0)
            owner.stop(position: 1)
            let heldEvents = await recorder.events
            XCTAssertEqual(heldEvents.count, 1, "Cancellation must not overlap a held transport")
            let oldFinished = XCTestExpectation(description: "old report worker finished")
            let oldObserver = Task {
                await oldTask.value
                oldFinished.fulfill()
            }
            defer {
                oldTask.cancel()
                oldObserver.cancel()
            }
            await recorder.releaseOld()
            guard await XCTWaiter.fulfillment(of: [oldFinished], timeout: 3) == .completed else {
                XCTFail("Old report worker did not finish before the deadline")
                return
            }
            guard await XCTWaiter.fulfillment(of: [newEntered], timeout: 3) == .completed else {
                XCTFail("New report transport did not enter before the deadline")
                return
            }
            let newTask = try XCTUnwrap(owner.task)
            let newFinished = XCTestExpectation(description: "new report worker finished")
            let newObserver = Task {
                await newTask.value
                newFinished.fulfill()
            }
            defer {
                newTask.cancel()
                newObserver.cancel()
            }
            await recorder.releaseNew()
            guard await XCTWaiter.fulfillment(of: [newFinished], timeout: 3) == .completed else {
                XCTFail("New report worker did not finish before the deadline")
                return
            }
            let events = await recorder.events
            let overlap = await recorder.overlap
            let unexpected = await recorder.unexpectedEntry
            XCTAssertFalse(overlap, "Cancellation must not overlap a held transport")
            XCTAssertFalse(unexpected, "Unexpected additional report entry")
            XCTAssertEqual(events.map(\.itemID), ["old", "new", "new"])
            XCTAssertEqual(events.map(\.kind), [.start, .start, .stop])
            XCTAssertNil(owner.task)
        }

        func testNativeCommitAndRepeatOneReportDistinctOccurrencesWithoutChangingQueue()
            async throws
        {
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

    /// A latched release makes early cleanup safe even if admission never occurs.
    private actor HeldInvalidationReport {
        private let entered: @Sendable () -> Void
        private(set) var events: [FoundationPlaybackReport] = []
        private(set) var unexpectedEntry = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(entered: @escaping @Sendable () -> Void) { self.entered = entered }

        func append(_ event: FoundationPlaybackReport) async {
            // Only the first report can be held. Record at most one extra report
            // and return immediately so a duplicate cannot strand the first.
            guard events.isEmpty else {
                unexpectedEntry = true
                if events.count == 1 { events.append(event) }
                return
            }
            events.append(event)
            guard !released else {
                entered()
                return
            }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                entered()
            }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Holds the old and new starts separately, with latched release on every exit.
    private actor OfflineReportingProbe {
        private let oldEntered: @Sendable () -> Void
        private let newEntered: @Sendable () -> Void
        private(set) var events: [FoundationPlaybackReport] = []
        private(set) var overlap = false
        private(set) var unexpectedEntry = false
        private var oldHolding = false
        private var sawOld = false
        private var sawNew = false
        private var oldReleased = false
        private var newReleased = false
        private var oldContinuation: CheckedContinuation<Void, Never>?
        private var newContinuation: CheckedContinuation<Void, Never>?

        init(oldEntered: @escaping @Sendable () -> Void, newEntered: @escaping @Sendable () -> Void)
        {
            self.oldEntered = oldEntered
            self.newEntered = newEntered
        }

        func append(_ event: FoundationPlaybackReport) async {
            if oldHolding { overlap = true }
            if events.count < 4 { events.append(event) } else { unexpectedEntry = true }
            if event.itemID == "old", event.kind == .start, !sawOld {
                sawOld = true
                oldHolding = true
                if !oldReleased {
                    await withCheckedContinuation { continuation in
                        oldContinuation = continuation
                        oldEntered()
                    }
                } else {
                    oldEntered()
                }
                oldHolding = false
            } else if event.itemID == "new", event.kind == .start, !sawNew {
                sawNew = true
                if !newReleased {
                    await withCheckedContinuation { continuation in
                        newContinuation = continuation
                        newEntered()
                    }
                } else {
                    newEntered()
                }
            }
        }

        func releaseOld() {
            oldReleased = true
            oldContinuation?.resume()
            oldContinuation = nil
        }

        func releaseNew() {
            newReleased = true
            newContinuation?.resume()
            newContinuation = nil
        }

        func releaseAll() {
            releaseOld()
            releaseNew()
        }
    }

    private actor ReportRecorder {
        private(set) var events: [FoundationPlaybackReport] = []
        private var holdFirst: Bool
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        init(holdFirst: Bool = false) { self.holdFirst = holdFirst }
        func append(_ event: FoundationPlaybackReport) async {
            events.append(event)
            if holdFirst {
                holdFirst = false
                if !released { await withCheckedContinuation { continuation = $0 } }
            }
        }
        func release() {
            released = true
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
#endif

@MainActor
final class FoundationHLSCleanupTests: XCTestCase {
    private func waitForCleanup(
        _ owner: FoundationHLSCleanup, recorder: CleanupRecorder
    ) async -> Bool {
        let finished = XCTestExpectation(description: "cleanup worker drained")
        let observer = Task {
            while !Task.isCancelled, let task = await owner.task { await task.value }
            guard !Task.isCancelled else { return }
            finished.fulfill()
        }
        guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
            (await owner.task)?.cancel()
            await recorder.release()
            observer.cancel()
            XCTFail("Cleanup worker did not drain within 5 seconds")
            return false
        }
        return true
    }

    func testHeldCleanupBoundsPendingAndCoalescesKeys() async throws {
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup()
        addTeardownBlock { @MainActor in
            await recorder.release()
            _ = await self.waitForCleanup(owner, recorder: recorder)
        }
        await owner.enqueue(key: "active") { await recorder.record(0, hold: true) }
        try await recorder.waitForCount(1)
        await owner.enqueue(key: "active") { await recorder.record(-1) }
        for index in 1...40 {
            await owner.enqueue(key: "job-\(index)") { await recorder.record(index) }
        }
        await owner.enqueue(key: "job-1") { await recorder.record(-2) }
        let pending = await owner.pendingCount
        let dropped = await owner.overflowDrops
        let held = await recorder.events
        XCTAssertEqual(pending, 32)
        XCTAssertEqual(dropped, 8)
        XCTAssertEqual(held, [0], "Enqueue must return without waiting for the held transport")
        await recorder.release()
        guard await waitForCleanup(owner, recorder: recorder) else { return }
        let events = await recorder.events
        XCTAssertEqual(events, Array(0...32))
    }

    func testExpiredPendingJobsAreDiscardedAndNewWorkContinues() async throws {
        let clock = CleanupClock()
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup(now: { clock.value })
        addTeardownBlock { @MainActor in
            await recorder.release()
            _ = await self.waitForCleanup(owner, recorder: recorder)
        }
        await owner.enqueue(key: "active") { await recorder.record(0, hold: true) }
        try await recorder.waitForCount(1)
        await owner.enqueue(key: "old") { await recorder.record(1) }
        clock.advance(to: 10)
        await recorder.release()
        guard await waitForCleanup(owner, recorder: recorder) else { return }
        let expired = await owner.expiredDrops
        XCTAssertEqual(expired, 1)
        await owner.enqueue(key: "new") { await recorder.record(2) }
        guard await waitForCleanup(owner, recorder: recorder) else { return }
        let events = await recorder.events
        XCTAssertEqual(events, [0, 2])
    }

    func testLeaseReleasesExactOperationOnlyOnceIncludingConcurrentRelease() async throws {
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup()
        let lease = FoundationHLSLease(owner: owner, key: "session") {
            await recorder.record(1, hold: true)
        }
        addTeardownBlock { @MainActor in
            await recorder.release()
            _ = await self.waitForCleanup(owner, recorder: recorder)
        }
        async let first: Void = lease.release()
        async let second: Void = lease.release()
        _ = await (first, second)
        try await recorder.waitForCount(1)
        await recorder.release()
        guard await waitForCleanup(owner, recorder: recorder) else { return }
        await lease.release()
        let task = await owner.task
        let events = await recorder.events
        XCTAssertNil(task)
        XCTAssertEqual(events, [1])
    }
}

private final class CleanupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    var value: TimeInterval { lock.withLock { instant } }
    func advance(to instant: TimeInterval) { lock.withLock { self.instant = instant } }
}

private actor CleanupRecorder {
    private(set) var events: [Int] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func record(_ value: Int, hold: Bool = false) async {
        events.append(value)
        if hold && !released { await withCheckedContinuation { continuation = $0 } }
    }
    func release() {
        released = true
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
