import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

// Listening-report fixtures use DEBUG-only FoundationTestTones.
#if DEBUG
    @MainActor
    final class FoundationPlaybackReportingTests: XCTestCase {
        func testNegotiatedSessionStaysWithItsOccurrenceAcrossReplacement() async {
            let recorder = ReportRecorder()
            let owner = FoundationPlaybackReporting { await recorder.append($0) }
            let first = FoundationPlaybackSource(
                delivery: .hlsAAC, mediaSourceID: "a", serverSessionID: "session-a")
            let second = FoundationPlaybackSource(
                delivery: .hlsAAC, mediaSourceID: "b", serverSessionID: "session-b")
            owner.begin(itemID: "same-track", position: 0, source: first)
            owner.progress(position: 1, paused: true)
            await owner.task?.value
            owner.stop(position: 1)
            owner.begin(itemID: "same-track", position: 0, source: second)
            owner.stop(position: 2)
            await owner.task?.value
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
#endif

@MainActor
final class FoundationHLSCleanupTests: XCTestCase {
    func testHeldCleanupBoundsPendingAndCoalescesKeys() async throws {
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup()
        await owner.enqueue(key: "active") { await recorder.record(0, hold: true) }
        try await recorder.waitForCount(1)
        defer { Task { await recorder.release() } }
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
        while let task = await owner.task { await task.value }
        let events = await recorder.events
        XCTAssertEqual(events, Array(0...32))
    }

    func testExpiredPendingJobsAreDiscardedAndNewWorkContinues() async throws {
        let clock = CleanupClock()
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup(now: { clock.value })
        await owner.enqueue(key: "active") { await recorder.record(0, hold: true) }
        try await recorder.waitForCount(1)
        defer { Task { await recorder.release() } }
        await owner.enqueue(key: "old") { await recorder.record(1) }
        clock.advance(to: 10)
        await recorder.release()
        while let task = await owner.task { await task.value }
        let expired = await owner.expiredDrops
        XCTAssertEqual(expired, 1)
        await owner.enqueue(key: "new") { await recorder.record(2) }
        while let task = await owner.task { await task.value }
        let events = await recorder.events
        XCTAssertEqual(events, [0, 2])
    }

    func testLeaseReleasesExactOperationOnlyOnceIncludingConcurrentRelease() async throws {
        let recorder = CleanupRecorder()
        let owner = FoundationHLSCleanup()
        let lease = FoundationHLSLease(owner: owner, key: "session") {
            await recorder.record(1, hold: true)
        }
        async let first: Void = lease.release()
        async let second: Void = lease.release()
        _ = await (first, second)
        try await recorder.waitForCount(1)
        await recorder.release()
        while let task = await owner.task { await task.value }
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
    func record(_ value: Int, hold: Bool = false) async {
        events.append(value)
        if hold { await withCheckedContinuation { continuation = $0 } }
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

// Kept self-contained so the shipping HLS path can run in a focused Release harness.
final class FoundationHLSProductionTests: XCTestCase {
    // Deliberately outside DEBUG: the shipping entry point must negotiate HLS,
    // regardless of the old comparison preference retained by an upgraded install.
    func testProductionPlaybackIgnoresLegacyDeliverySelectionAndNegotiatesHLS() async throws {
        let key = "foundationDeliveryComparison"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let cases = ["directPreferred", "hlsAAC", "hlsMP3Copy", "unknown"].flatMap { legacy in
            ["mp3", "opus"].flatMap { codec in
                FoundationStreamingQuality.allCases.map { (legacy, codec, $0) }
            }
        }
        for (legacy, codec, quality) in cases {
            UserDefaults.standard.set(legacy, forKey: key)
            let recorder = HLSProductionRecorder()
            let admission = FoundationNetworkAdmission(limit: 2)
            let held = try await admission.acquire()
            let copy = codec == "mp3" && quality == .original
            let outputCodec = copy ? "mp3" : "aac"
            let bitrate = copy ? 50_000_000 : (quality.aacBitrate ?? 320_000)
            // Jellyfin's audio StreamInfo leaves AudioStreamIndex unset in ToUrl.
            let returnedIndex = quality == .original ? "&AudioStreamIndex=0" : ""
            let itemID = self.itemID
            let deviceID = session.deviceID
            let audio = """
                {"Type":"Audio","Codec":"\(codec)","Index":0,"BitRate":256000,
                "SampleRate":44100,"Channels":2}
                """
            let library = FoundationJellyfinLibrary(
                session: session, streamingQuality: { quality },
                load: { request in
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
                                #EXT-X-STREAM-INF:BANDWIDTH=50000000
                                main.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=copy&SegmentContainer=ts&AudioBitrate=50000000&AudioStreamIndex=0
                                """.utf8), Self.response(request)
                        )
                    }
                    return (
                        Data(
                            """
                            {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                            "MediaStreams":[\(audio)],"SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                            "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=\(outputCodec)&SegmentContainer=ts&AudioBitrate=\(bitrate)\(returnedIndex)"}]}
                            """.utf8), Self.response(request)
                    )
                }, networkAdmission: admission)
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
            let preparation = Task { try await library.playbackResource(for: item) }
            let requiredRequests = copy ? 3 : 2
            for _ in 0..<100 {
                if await recorder.requests.count >= requiredRequests { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let progressed = await recorder.requests.count >= requiredRequests
            await admission.release(held)
            let resource = try await preparation.value
            XCTAssertTrue(progressed, "Audio preparation must not await optional admission")
            XCTAssertEqual(resource.source.delivery, copy ? .hlsCopy : .hlsAAC)
            if quality != .original {
                let indices = URLComponents(url: resource.url, resolvingAgainstBaseURL: false)?
                    .queryItems?.filter { $0.name.lowercased() == "audiostreamindex" }
                XCTAssertEqual(indices?.count, 1)
                XCTAssertEqual(indices?.first?.value, "0")
            }
            XCTAssertTrue(resource.url.path.hasSuffix(copy ? "/main.m3u8" : "/master.m3u8"))
            let requests = await recorder.requests
            XCTAssertEqual(
                requests.map(\.httpMethod), copy ? ["GET", "POST", "GET"] : ["GET", "POST"])
            let body = try XCTUnwrap(requests.first(where: { $0.httpMethod == "POST" })?.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["AllowAudioStreamCopy"] as? Bool, copy)
            XCTAssertEqual(json["MaxStreamingBitrate"] as? Int, bitrate)
            let profile = try XCTUnwrap(json["DeviceProfile"] as? [String: Any])
            XCTAssertEqual(profile["MaxStreamingBitrate"] as? Int, bitrate)
            XCTAssertEqual(profile["MusicStreamingTranscodingBitrate"] as? Int, bitrate)
            let transcodes = try XCTUnwrap(profile["TranscodingProfiles"] as? [[String: Any]])
            XCTAssertEqual(transcodes.first?["AudioCodec"] as? String, outputCodec)
            XCTAssertEqual(transcodes.first?["Protocol"] as? String, "hls")
            XCTAssertEqual(json["MediaSourceId"] as? String, "source-a")
            XCTAssertEqual(json["AudioStreamIndex"] as? Int, 0)
            XCTAssertEqual(json["EnableDirectPlay"] as? Bool, false)
            XCTAssertEqual(json["EnableDirectStream"] as? Bool, false)
            XCTAssertEqual(json["EnableTranscoding"] as? Bool, true)
            XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/universal") == true })
            // No native player or real server job exists in this fixture. Other tests
            // exercise lease release with the DEBUG cleanup transport injection.
        }
    }

    func testQualityIsSampledOnceAndChangesOnlyTheNextResourceIncludingScopedCopies() async throws {
        let state = HLSQualitySnapshot()
        let recorder = HLSProductionRecorder()
        let itemID = itemID
        let deviceID = session.deviceID
        let audio = """
            {"Type":"Audio","Codec":"mp3","Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}
            """
        let library = FoundationJellyfinLibrary(
            session: session, streamingQuality: { await state.snapshot() },
            load: { request in
                await recorder.append(request)
                if request.httpMethod == "GET" {
                    // A settings change after preparation starts cannot alter its snapshot.
                    await state.change(to: .aac192)
                    return (
                        Data(
                            """
                            {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                            "Protocol":"File","MediaStreams":[\(audio)]}]}
                            """.utf8), Self.response(request)
                    )
                }
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let cap = try XCTUnwrap(json["MaxStreamingBitrate"] as? Int)
                return (
                    Data(
                        """
                        {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                        "MediaStreams":[\(audio)],"SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                        "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=aac&SegmentContainer=ts&AudioBitrate=\(cap)&AudioStreamIndex=0"}]}
                        """.utf8), Self.response(request)
                )
            })
        let item = FoundationItem(
            id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
        let first = try await library.playbackResource(for: item)
        let requestsBeforeNext = await recorder.requests.count
        XCTAssertEqual(requestsBeforeNext, 2)
        let second = try await library.scoped(to: "library-a").playbackResource(for: item)
        let samples = await state.samples
        XCTAssertEqual(samples, 2)
        XCTAssertTrue(first.url.absoluteString.contains("AudioBitrate=128000"))
        XCTAssertTrue(second.url.absoluteString.contains("AudioBitrate=192000"))
    }

    func testFixedAACNormalizesOnlyMissingIndexFromKnownAudioSelection() throws {
        let raw =
            "/audio/\(itemID)/master.m3u8?AudioCodec=aac&SegmentContainer=ts&AudioBitrate=128000"
        let normalized = try FoundationJellyfinLibrary.validateFixedAACURL(
            raw, cap: 128_000, audioIndex: 3)
        let query = try XCTUnwrap(URLComponents(string: normalized)?.queryItems)
        XCTAssertEqual(query.filter { $0.name.lowercased() == "audiostreamindex" }.count, 1)
        XCTAssertEqual(query.first { $0.name == "AudioStreamIndex" }?.value, "3")
        XCTAssertThrowsError(
            try FoundationJellyfinLibrary.validateFixedAACURL(raw, cap: 128_000, audioIndex: nil))
        XCTAssertThrowsError(
            try FoundationJellyfinLibrary.validateFixedAACURL(raw, cap: 128_000, audioIndex: -1))
        XCTAssertThrowsError(
            try FoundationJellyfinLibrary.validateFixedAACURL(
                raw + "&AudioStreamIndex=0", cap: 128_000, audioIndex: 3))
    }

    func testAutoPathChangeAffectsOnlyTheNextResourceIncludingScopedCopies() async throws {
        for codec in ["mp3", "opus"] {
            let state = HLSAutoPathSnapshot()
            let recorder = HLSProductionRecorder()
            let itemID = itemID
            let deviceID = session.deviceID
            let audio = """
                {"Type":"Audio","Codec":"\(codec)","Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}
                """
            let library = FoundationJellyfinLibrary(
                session: session, streamingQuality: { await state.snapshot() },
                load: { request in
                    await recorder.append(request)
                    if request.url?.path.hasSuffix("/Items/\(itemID)") == true {
                        // A path change after preparation starts cannot alter its snapshot.
                        await state.constrainPath()
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
                                #EXT-X-STREAM-INF:BANDWIDTH=50000000
                                main.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=copy&SegmentContainer=ts&AudioBitrate=50000000&AudioStreamIndex=0
                                """.utf8), Self.response(request)
                        )
                    }
                    let body = try XCTUnwrap(request.httpBody)
                    let json = try XCTUnwrap(
                        JSONSerialization.jsonObject(with: body) as? [String: Any])
                    let cap = try XCTUnwrap(json["MaxStreamingBitrate"] as? Int)
                    let copy = json["AllowAudioStreamCopy"] as? Bool == true
                    let outputCodec = copy ? codec : "aac"
                    return (
                        Data(
                            """
                            {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                            "MediaStreams":[\(audio)],"SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                            "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=\(outputCodec)&SegmentContainer=ts&AudioBitrate=\(cap)&AudioStreamIndex=0"}]}
                            """.utf8), Self.response(request)
                    )
                })
            let item = FoundationItem(
                id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
            let first = try await library.playbackResource(for: item)
            let requestsBeforeNext = await recorder.requests.count
            let copy = codec == "mp3"
            XCTAssertEqual(requestsBeforeNext, copy ? 3 : 2)
            XCTAssertEqual(first.source.delivery, copy ? .hlsCopy : .hlsAAC)
            XCTAssertTrue(
                first.url.absoluteString.contains(copy ? "AudioCodec=copy" : "AudioCodec=aac"))
            XCTAssertTrue(
                first.url.absoluteString.contains(
                    copy ? "AudioBitrate=50000000" : "AudioBitrate=320000"))
            let second = try await library.scoped(to: "library-a").playbackResource(for: item)
            let samples = await state.samples
            XCTAssertEqual(samples, 2)
            XCTAssertEqual(second.source.delivery, .hlsAAC)
            XCTAssertTrue(second.url.absoluteString.contains("AudioBitrate=128000"))
        }
    }

    #if os(macOS)
        @MainActor
        func testMacPersistedProfilesPrepareOriginalCompatibleAudio() async throws {
            let name = "FoundationMacStreamingProfiles.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = FoundationPlaybackPreferences(defaults: defaults)
            let itemID = itemID
            let deviceID = session.deviceID
            for quality in [FoundationStreamingQuality.auto, .aac128] {
                preferences.setStreamingWiFiQuality(quality)
                preferences.setStreamingCellularQuality(quality)
                let library = FoundationJellyfinLibrary(
                    session: session,
                    streamingQuality: {
                        await preferences.resolvedStreamingQuality(for: FoundationStreamingPath())
                    },
                    load: { request in
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
                            return (
                                Data(
                                    """
                                    #EXTM3U
                                    #EXT-X-STREAM-INF:BANDWIDTH=50000000
                                    main.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=copy&SegmentContainer=ts&AudioBitrate=50000000&AudioStreamIndex=0
                                    """.utf8), Self.response(request)
                            )
                        }
                        let body = try XCTUnwrap(request.httpBody)
                        let json = try XCTUnwrap(
                            JSONSerialization.jsonObject(with: body) as? [String: Any])
                        XCTAssertEqual(json["AllowAudioStreamCopy"] as? Bool, true)
                        XCTAssertEqual(json["MaxStreamingBitrate"] as? Int, 50_000_000)
                        return (
                            Data(
                                """
                                {"PlaySessionId":"session-a","MediaSources":[{"Id":"source-a",
                                "MediaStreams":[{"Type":"Audio","Codec":"mp3","Index":0,"BitRate":256000,
                                "SampleRate":44100,"Channels":2}],
                                "SupportsTranscoding":true,"TranscodingSubProtocol":"hls",
                                "TranscodingUrl":"/audio/\(itemID)/master.m3u8?MediaSourceId=source-a&PlaySessionId=session-a&DeviceId=\(deviceID)&AudioCodec=mp3&SegmentContainer=ts&AudioBitrate=50000000&AudioStreamIndex=0"}]}
                                """.utf8), Self.response(request)
                        )
                    })
                let item = FoundationItem(
                    id: itemID, title: "Synthetic", subtitle: "", kind: .track, duration: nil)
                let resource = try await library.playbackResource(for: item)
                XCTAssertEqual(resource.source.delivery, .hlsCopy)
            }
        }
    #endif

    func testFixedPolicyRejectsMissingUnsupportedAndUnsafeServerDecisionsWithoutFallback()
        async throws
    {
        for quality in FoundationStreamingQuality.allCases where quality != .original {
            let cap = try XCTUnwrap(quality.aacBitrate)
            let valid = "AudioCodec=aac&SegmentContainer=ts&AudioBitrate=\(cap)&AudioStreamIndex=0"
            let invalidQueries = [
                valid.replacingOccurrences(of: "AudioCodec=aac", with: "AudioCodec=copy"),
                valid.replacingOccurrences(of: "AudioCodec=aac", with: "AudioCodec=opus"),
                valid.replacingOccurrences(
                    of: "AudioBitrate=\(cap)", with: "AudioBitrate=\(cap + 1)"),
                valid.replacingOccurrences(of: "AudioBitrate=\(cap)", with: "AudioBitrate=0"),
                valid.replacingOccurrences(of: "AudioBitrate=\(cap)&", with: ""),
                valid + "&audiobitrate=128000",
                valid.replacingOccurrences(of: "AudioStreamIndex=0", with: "AudioStreamIndex=1"),
                valid.replacingOccurrences(of: "AudioStreamIndex=0", with: "AudioStreamIndex=-1"),
                valid.replacingOccurrences(of: "AudioStreamIndex=0", with: "AudioStreamIndex="),
                valid + "&audiostreamindex=0",
                valid.replacingOccurrences(of: "SegmentContainer=ts", with: "SegmentContainer=mp4"),
            ]
            for query in invalidQueries {
                XCTAssertThrowsError(
                    try FoundationJellyfinLibrary.validateFixedAACURL(
                        "/audio/\(itemID)/master.m3u8?\(query)", cap: cap, audioIndex: 0))
            }
            for flag in ["AllowAudioStreamCopy", "EnableAutoStreamCopy", "Static"] {
                for suffix in ["", "&\(flag)=false", "&\(flag)=FALSE"] {
                    XCTAssertNoThrow(
                        try FoundationJellyfinLibrary.validateFixedAACURL(
                            "/audio/\(itemID)/master.m3u8?\(valid)\(suffix)", cap: cap,
                            audioIndex: 0))
                }
                for suffix in [
                    "&\(flag)=true", "&\(flag)=1", "&\(flag)=", "&\(flag)",
                    "&\(flag)=false&\(flag.lowercased())=false",
                    "&\(flag)=false&\(flag.lowercased())=true",
                ] {
                    XCTAssertThrowsError(
                        try FoundationJellyfinLibrary.validateFixedAACURL(
                            "/audio/\(itemID)/master.m3u8?\(valid)\(suffix)", cap: cap,
                            audioIndex: 0))
                }
            }
            let responses = [
                "{}",
                "{\"ErrorCode\":\"NotAllowed\"}",
                "{\"PlaySessionId\":\"session-a\",\"MediaSources\":[]}",
            ]
            for response in responses {
                let recorder = HLSProductionRecorder()
                let itemID = itemID
                let library = FoundationJellyfinLibrary(
                    session: session, streamingQuality: { quality },
                    load: { request in
                        await recorder.append(request)
                        let body =
                            request.httpMethod == "GET"
                            ? """
                            {"Id":"\(itemID)","Type":"Audio","MediaSources":[{"Id":"source-a",
                            "Protocol":"File","MediaStreams":[{"Type":"Audio","Codec":"mp3",
                            "Index":0,"BitRate":256000,"SampleRate":44100,"Channels":2}]}]}
                            """ : response
                        return (Data(body.utf8), Self.response(request))
                    })
                do {
                    _ = try await library.playbackResource(
                        for: FoundationItem(
                            id: itemID, title: "Synthetic", subtitle: "", kind: .track,
                            duration: nil))
                    XCTFail("Denied HLS must fail explicitly")
                } catch {}
                let requests = await recorder.requests
                XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
                XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/universal") == true })
            }
        }
    }

    private let itemID = "00000000000000000000000000000001"
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid/proxy/jellyfin/")!,
            accessToken: "synthetic-token", userID: "00000000000000000000000000000002",
            deviceID: "00000000-0000-0000-0000-000000000003")
    }
    private static func response(_ request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

private actor HLSProductionRecorder {
    private(set) var requests: [URLRequest] = []
    func append(_ request: URLRequest) { requests.append(request) }
}

private actor HLSQualitySnapshot {
    private var quality = FoundationStreamingQuality.aac128
    private(set) var samples = 0
    func snapshot() -> FoundationStreamingQuality {
        samples += 1
        return quality
    }
    func change(to quality: FoundationStreamingQuality) { self.quality = quality }
}

private actor HLSAutoPathSnapshot {
    private var path = FoundationStreamingPath(isAvailable: true, usesWiFiOrWired: true)
    private(set) var samples = 0
    func snapshot() -> FoundationStreamingQuality {
        samples += 1
        return FoundationStreamingQuality.auto.resolved(for: path)
    }
    func constrainPath() { path.isConstrained = true }
}
