import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

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
            // Register before the first observation can throw or be cancelled.
            // These resources represent injected negotiation, not real server jobs;
            // do not route synthetic release through the production cleanup transport.
            addTeardownBlock { @MainActor in
                preparation.cancel()
                await admission.release(held)
                let returned = XCTestExpectation(description: "HLS preparation cleanup returned")
                let observer = Task {
                    _ = await preparation.result
                    returned.fulfill()
                }
                guard await XCTWaiter.fulfillment(of: [returned], timeout: 5) == .completed else {
                    observer.cancel()
                    XCTFail("HLS preparation cleanup did not return within 5 seconds")
                    return
                }
            }
            let requiredRequests = copy ? 3 : 2
            let requestDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while await recorder.requests.count < requiredRequests,
                ContinuousClock.now < requestDeadline
            {
                try await Task.sleep(for: .milliseconds(10))
            }
            let progressed = await recorder.requests.count >= requiredRequests
            await admission.release(held)
            let finished = XCTestExpectation(description: "HLS preparation returned")
            let observer = Task {
                let result = await preparation.result
                finished.fulfill()
                return result
            }
            guard await XCTWaiter.fulfillment(of: [finished], timeout: 5) == .completed else {
                preparation.cancel()
                observer.cancel()
                XCTFail("HLS preparation did not return within 5 seconds")
                return
            }
            let resource = try await observer.value.get()
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
