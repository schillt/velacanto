import AVFoundation
import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationDownloadTransportTests: XCTestCase {
    private let itemID = "00000000000000000000000000000001"
    private var track: FoundationItem {
        FoundationItem(id: itemID, title: "Fixture", subtitle: "", kind: .track, duration: 1)
    }
    private var session: FoundationSession {
        FoundationSession(
            serverURL: URL(string: "https://example.invalid")!, accessToken: "fixture-token",
            userID: "00000000000000000000000000000002", deviceID: "fixture-device")
    }
    private func library(container: String = "flac", codec: String = "flac", allowed: Bool = true)
        -> FoundationJellyfinLibrary
    {
        let id = itemID
        return FoundationJellyfinLibrary(session: session) { request in
            XCTAssertEqual(request.url?.path, "/Items/\(id)")
            let json = """
                {"Id":"\(id)","Type":"Audio","CanDownload":\(allowed),
                 "MediaSources":[{"Protocol":"File","Container":"\(container)","Size":123,
                    "MediaStreams":[{"Type":"Audio","Codec":"\(codec)"}]}]}
                """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    func testSourceUsesVerifiedOriginalAndTransientHeaderAuthentication() async throws {
        let source = try await library().downloadSource(for: track)
        XCTAssertEqual(source.request.url?.path, "/Items/\(itemID)/Download")
        XCTAssertFalse(source.request.url!.absoluteString.contains("fixture-token"))
        XCTAssertEqual(
            URLComponents(url: source.request.url!, resolvingAgainstBaseURL: false)?.queryItems
                ?? [], [])
        XCTAssertTrue(
            source.request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token")
                == true)
        XCTAssertEqual(source.fileExtension, "flac")
        XCTAssertEqual(source.expectedBytes, 123)
        XCTAssertEqual(source.request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testUnsupportedOriginalAndDeniedDownloadStayUnavailable() async {
        for library in [library(container: "ogg", codec: "opus"), library(allowed: false)] {
            do {
                _ = try await library.downloadSource(for: track)
                XCTFail("Ineligible originals must not fall back to transcoding")
            } catch { XCTAssertEqual(error as? FoundationDownloadError, .unsupported) }
        }
    }

    func testAmbiguousOriginalSourcesAreRejectedBeforeReturningDownloadRequest() async {
        let id = itemID
        let library = FoundationJellyfinLibrary(session: session) { request in
            XCTAssertEqual(request.url?.path, "/Items/\(id)")
            let json = """
                {"Id":"\(id)","Type":"Audio","CanDownload":true,
                 "MediaSources":[
                    {"Protocol":"File","Container":"flac","Size":123,
                     "MediaStreams":[{"Type":"Audio","Codec":"flac"}]},
                    {"Protocol":"File","Container":"mp3","Size":456,
                     "MediaStreams":[{"Type":"Audio","Codec":"mp3"}]}]}
                """
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await library.downloadSource(for: track)
            XCTFail("An unqualified original endpoint must not guess between multiple sources")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .unsupported) }
    }

    func testNativePolicyRequiresExplicitCellularOptIn() {
        let wifi = FoundationDownloadTransport.configuration(allowsCellular: false)
        XCTAssertFalse(wifi.allowsCellularAccess)
        XCTAssertFalse(wifi.allowsExpensiveNetworkAccess)
        XCTAssertFalse(wifi.allowsConstrainedNetworkAccess)
        XCTAssertNil(wifi.urlCache)
        XCTAssertFalse(wifi.waitsForConnectivity)
        XCTAssertGreaterThan(wifi.timeoutIntervalForResource, 0)
        let cellular = FoundationDownloadTransport.configuration(allowsCellular: true)
        XCTAssertTrue(cellular.allowsCellularAccess)
        XCTAssertTrue(cellular.allowsExpensiveNetworkAccess)
    }

    func testReceiveBudgetRejectsForgedMetadataAndBoundsUnknownLengths() throws {
        XCTAssertThrowsError(
            try FoundationDownloadByteBudget(expectedBytes: Int64.max, availableBytes: 16)
        ) { XCTAssertEqual($0 as? FoundationDownloadError, .storage) }
        XCTAssertThrowsError(
            try FoundationDownloadByteBudget(expectedBytes: nil, availableBytes: 0)
        ) { XCTAssertEqual($0 as? FoundationDownloadError, .storage) }
        let unknown = try FoundationDownloadByteBudget(expectedBytes: nil, availableBytes: 16)
        XCTAssertNoThrow(try unknown.check(received: 16, announced: -1))
        XCTAssertThrowsError(try unknown.check(received: 17, announced: -1)) {
            XCTAssertEqual($0 as? FoundationDownloadError, .storage)
        }
        XCTAssertThrowsError(try unknown.check(received: 1, announced: Int64.max)) {
            XCTAssertEqual($0 as? FoundationDownloadError, .storage)
        }
    }

    func testNativeDelegateCancelsOversizedAnnouncedChunkedAndFalseLengths() throws {
        let budget = try FoundationDownloadByteBudget(expectedBytes: 4, availableBytes: 16)
        for (received, announced) in [(1, 5), (5, -1), (5, 1)] {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let task = session.downloadTask(with: URL(string: "https://example.invalid/original")!)
            let delegate = FoundationDownloadDelegate(budget: budget) { _, _ in
                XCTFail("Rejected bytes must not be published as ordinary progress")
            }
            delegate.urlSession(
                session, downloadTask: task, didWriteData: 1,
                totalBytesWritten: Int64(received), totalBytesExpectedToWrite: Int64(announced))
            XCTAssertEqual(delegate.failure, .incomplete)
            XCTAssertNotEqual(task.state, .suspended)
            // A later callback cannot revive progress or erase the first budget failure.
            delegate.urlSession(
                session, downloadTask: task, didWriteData: 0,
                totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
            XCTAssertEqual(delegate.failure, .incomplete)
        }
    }

    func testNativeDelegateAcceptsExactExpectedOriginal() throws {
        let budget = try FoundationDownloadByteBudget(expectedBytes: 4, availableBytes: 16)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/original")!)
        let progress = expectation(description: "Permitted original progress")
        let delegate = FoundationDownloadDelegate(budget: budget) { bytes, total in
            XCTAssertEqual(bytes, 4)
            XCTAssertEqual(total, 4)
            progress.fulfill()
        }
        delegate.urlSession(
            session, downloadTask: task, didWriteData: 4,
            totalBytesWritten: 4, totalBytesExpectedToWrite: 4)
        XCTAssertNil(delegate.failure)
        XCTAssertEqual(task.state, .suspended)
        wait(for: [progress], timeout: 1)
    }

    func testOversizedCompletedFileCannotBypassBudgetThroughInjectedLoader() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        try Data(repeating: 0, count: 8_192).write(to: fixture.temporary)
        do {
            try await FoundationDownloadTransport.transfer(
                source: fixture.source, to: fixture.destination, allowsCellular: false,
                progress: { _, _ in },
                load: { _, _, _, _ in
                    (fixture.temporary, fixture.response(length: 8_192))
                }, validate: { _ in XCTFail("Oversized bytes must not reach native validation") })
            XCTFail("Injected loaders cannot publish oversized files")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testOriginalBeyondLocalFreeSpaceFailsBeforeNetworkLoad() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        let source = FoundationDownloadSource(
            request: fixture.source.request, fileExtension: "m4a", expectedBytes: Int64.max)
        do {
            try await FoundationDownloadTransport.transfer(
                source: source, to: fixture.destination, allowsCellular: false,
                progress: { _, _ in },
                load: { _, _, _, _ in
                    XCTFail("Insufficient local space must stop before loading")
                    return (fixture.temporary, fixture.response())
                }, validate: { _ in XCTFail("No file may be promoted") })
            XCTFail("Server metadata cannot enlarge the local storage budget")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .storage) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testTransferStagesOriginalAndPassesNativeConnectionPolicy() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        try await FoundationDownloadTransport.transfer(
            source: fixture.source, to: fixture.destination, allowsCellular: false,
            progress: { _, _ in },
            load: { request, cellular, budget, progress in
                XCTAssertFalse(cellular)
                XCTAssertEqual(budget.maximumBytes, 4)
                XCTAssertFalse(request.allowsCellularAccess)
                XCTAssertFalse(request.allowsExpensiveNetworkAccess)
                progress(4, 4)
                return (fixture.temporary, fixture.response())
            },
            validate: { url in
                XCTAssertEqual(url, fixture.destination)
                XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3, 4]))
            })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
        XCTAssertEqual(
            try fixture.destination.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, true)
    }

    func testUnverifiedResponseAndTruncatedBytesNeverBecomeReady() async throws {
        for responseCase in 0..<3 {
            let fixture = try DownloadFileFixture()
            defer { fixture.remove() }
            let response = fixture.response(
                status: responseCase == 0 ? 302 : 200,
                url: responseCase == 1 ? URL(string: "https://elsewhere.invalid/file") : nil,
                length: responseCase == 2 ? 5 : 4)
            do {
                try await FoundationDownloadTransport.transfer(
                    source: fixture.source, to: fixture.destination, allowsCellular: false,
                    progress: { _, _ in }, load: { _, _, _, _ in (fixture.temporary, response) },
                    validate: { _ in XCTFail("Rejected response must not reach validation") })
                XCTFail("Unverified download must fail")
            } catch {
                XCTAssertEqual(
                    error as? FoundationDownloadError, responseCase == 2 ? .incomplete : .response)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
        }
    }

    func testMetadataSizeMismatchRemovesPartialFile() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        let source = FoundationDownloadSource(
            request: fixture.source.request, fileExtension: "m4a", expectedBytes: 7)
        do {
            try await FoundationDownloadTransport.transfer(
                source: source, to: fixture.destination, allowsCellular: false,
                progress: { _, _ in },
                load: { _, _, _, _ in (fixture.temporary, fixture.response()) }, validate: { _ in })
            XCTFail("Server metadata length must be honored")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
    }

    func testCancellationAndCorruptionRemoveStaging() async throws {
        for cancelled in [true, false] {
            let fixture = try DownloadFileFixture()
            defer { fixture.remove() }
            do {
                try await FoundationDownloadTransport.transfer(
                    source: fixture.source, to: fixture.destination, allowsCellular: false,
                    progress: { _, _ in },
                    load: { _, _, _, _ in (fixture.temporary, fixture.response()) },
                    validate: { _ in
                        if cancelled { throw CancellationError() }
                        throw FoundationDownloadError.incomplete
                    })
                XCTFail("Incomplete downloads must remain unavailable")
            } catch {
                XCTAssertEqual(
                    error as? FoundationDownloadError, cancelled ? .cancelled : .incomplete)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        }
    }

    func testNativeAssetValidationAcceptsFinitePCMOriginal() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        let audio = fixture.root.appendingPathComponent("synthetic.wav")
        var bytes = Data("RIFF".utf8)
        func word(_ value: UInt32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        func short(_ value: UInt16) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes.append(contentsOf: $0) }
        }
        word(1636)
        bytes.append(Data("WAVEfmt ".utf8))
        word(16)
        short(1)
        short(1)
        word(8000)
        word(16000)
        short(2)
        short(16)
        bytes.append(Data("data".utf8))
        word(1600)
        bytes.append(Data(repeating: 0, count: 1600))
        try bytes.write(to: audio)
        try await FoundationDownloadTransport.validateAsset(audio)
    }

    func testNativeAssetValidationRejectsSyntheticGarbage() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        do {
            try await FoundationDownloadTransport.validateAsset(fixture.temporary)
            XCTFail("Garbage must not be promoted to ready audio")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
    }
}

final class FoundationDownloadQualityTests: XCTestCase {
    private let base = URL(string: "https://example.invalid/jellyfin")!

    private func proposalLibrary(
        userID: String = "00000000000000000000000000000002",
        policy: String = """
        "IsDisabled":false,"EnableMediaPlayback":true,
        "EnableContentDownloading":true,"EnableAudioPlaybackTranscoding":true
        """,
        metadata: String? = nil
    ) -> FoundationJellyfinLibrary {
        let itemID = "00000000000000000000000000000001"
        let metadata =
            metadata ?? """
                {"Id":"\(itemID)","Type":"Audio","CanDownload":true,"RunTimeTicks":1800000000,
                 "MediaSources":[{"Id":"fixture-source","Protocol":"File","RunTimeTicks":1800000000,
                   "MediaStreams":[{"Type":"Audio","Codec":"opus","Index":0}]}]}
                """
        let session = FoundationSession(
            serverURL: base, accessToken: "fixture-token",
            userID: "00000000000000000000000000000002", deviceID: "fixture-device")
        return FoundationJellyfinLibrary(session: session) { request in
            let path = request.url!.path
            let json: String
            if path == "/jellyfin/Users/00000000000000000000000000000002" {
                let permissions = policy.isEmpty ? "" : "," + policy
                json = """
                    {"Id":"\(userID)","Policy":{
                      "AuthenticationProviderId":"fixture-auth",
                      "PasswordResetProviderId":"fixture-reset"\(permissions)}}
                    """
            } else {
                XCTAssertEqual(path, "/jellyfin/Items/\(itemID)")
                json = metadata
            }
            return (
                Data(json.utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
    }

    private var proposalTrack: FoundationItem {
        FoundationItem(
            id: "00000000000000000000000000000001", title: "Fixture", subtitle: "", kind: .track,
            duration: 180)
    }

    private func convertedFixture() throws -> (root: URL, temporary: URL, destination: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (
            root, root.appendingPathComponent("received.m4a"),
            root.appendingPathComponent("stage.m4a")
        )
    }

    private static func rendition() -> FoundationConvertedDownloadRendition {
        .init(container: "m4a", codec: "aac", sampleRate: 48_000, channels: 2, duration: 180)
    }

    func testConvertedTransferUsesCeilingRatherThanOriginalSizeAndRecordsActualRendition()
        async throws
    {
        let proposal = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        let fixture = try convertedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bytes = Data(repeating: 7, count: 64)
        try bytes.write(to: fixture.temporary)
        let cleanup = ConvertedDownloadCleanupRecorder()
        let verified = try await FoundationConvertedDownload.transfer(
            proposal: proposal, to: fixture.destination, allowsCellular: false,
            progress: { _, total in XCTAssertNil(total) },
            load: { request, cellular, budget, progress in
                XCTAssertFalse(cellular)
                XCTAssertFalse(request.allowsCellularAccess)
                XCTAssertEqual(budget.maximumBytes, proposal.plan.maximumBytes)
                XCTAssertGreaterThan(budget.maximumBytes, Int64(bytes.count))
                progress(64, 64)
                return (
                    fixture.temporary,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Length": "64"])!
                )
            }, inspect: { _, _ in Self.rendition() },
            cleanup: { request in
                await cleanup.record(request)
                return true
            })
        XCTAssertEqual(verified.bytes, 64)
        XCTAssertEqual(verified.rendition, Self.rendition())
        XCTAssertEqual(verified.digest, try FoundationDownloadStorage.digest(fixture.destination))
        let calls = await cleanup.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.url, proposal.cleanupRequest.url)
        let record = FoundationDownloadManifest.File(
            name: "verified.m4a", bytes: verified.bytes, digest: verified.digest,
            convertedRendition: verified.rendition)
        let restored = try JSONDecoder().decode(
            FoundationDownloadManifest.File.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.convertedRendition, verified.rendition)
    }

    func testConvertedFailureAndCleanupFailureNeverLeaveStagedFiles() async throws {
        let proposal = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        for mode in 0..<4 {
            let fixture = try convertedFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try Data(repeating: 0, count: 64).write(to: fixture.temporary)
            let cleanup = ConvertedDownloadCleanupRecorder()
            do {
                _ = try await FoundationConvertedDownload.transfer(
                    proposal: proposal, to: fixture.destination, allowsCellular: false,
                    progress: { _, _ in },
                    load: { request, _, _, _ in
                        if mode == 0 { throw URLError(.networkConnectionLost) }
                        return (
                            fixture.temporary,
                            HTTPURLResponse(
                                url: request.url!, statusCode: mode == 1 ? 302 : 200,
                                httpVersion: nil, headerFields: nil)!
                        )
                    },
                    inspect: { _, _ in
                        if mode == 2 { throw FoundationDownloadError.incomplete }
                        return Self.rendition()
                    },
                    cleanup: { request in
                        await cleanup.record(request)
                        return mode != 3
                    })
                XCTFail("Unverified conversion must not be returned for publication")
            } catch {
                XCTAssertEqual(
                    error as? FoundationDownloadError,
                    mode == 0
                        ? .network
                        : mode == 1 ? .response : mode == 2 ? .incomplete : .conversionCleanup)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            if mode != 0 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
            }
            let calls = await cleanup.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testConvertedCancellationAwaitsOwnedCleanupAndDeletesStagedFile() async throws {
        let proposal = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        let fixture = try convertedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data(repeating: 0, count: 64).write(to: fixture.temporary)
        let inspected = expectation(description: "Inspector reached")
        let cleanup = ConvertedDownloadCleanupRecorder()
        let task = Task {
            try await FoundationConvertedDownload.transfer(
                proposal: proposal, to: fixture.destination, allowsCellular: false,
                progress: { _, _ in },
                load: { request, _, _, _ in
                    (
                        fixture.temporary,
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                },
                inspect: { _, _ in
                    inspected.fulfill()
                    try await Task.sleep(for: .seconds(30))
                    return Self.rendition()
                },
                cleanup: { request in
                    XCTAssertFalse(Task.isCancelled)
                    await cleanup.record(request)
                    return true
                })
        }
        await fulfillment(of: [inspected], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled transfer must not return ready bytes")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .cancelled) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let calls = await cleanup.requests
        XCTAssertEqual(calls.count, 1)
    }

    func testConvertedOversizeAndSymlinkNeverReachInspection() async throws {
        let proposal = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        for symlink in [false, true] {
            let fixture = try convertedFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let backing = fixture.root.appendingPathComponent("backing")
            if symlink {
                try Data([1, 2, 3]).write(to: backing)
                try FileManager.default.createSymbolicLink(
                    at: fixture.temporary, withDestinationURL: backing)
            } else {
                XCTAssertTrue(
                    FileManager.default.createFile(atPath: fixture.temporary.path, contents: nil))
                let handle = try FileHandle(forWritingTo: fixture.temporary)
                try handle.truncate(atOffset: UInt64(proposal.plan.maximumBytes + 1))
                try handle.close()
            }
            let cleanup = ConvertedDownloadCleanupRecorder()
            do {
                _ = try await FoundationConvertedDownload.transfer(
                    proposal: proposal, to: fixture.destination, allowsCellular: false,
                    progress: { _, _ in },
                    load: { request, _, _, _ in
                        (
                            fixture.temporary,
                            HTTPURLResponse(
                                url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: nil)!
                        )
                    },
                    inspect: { _, _ in
                        XCTFail("Unverified file must not reach inspection")
                        return Self.rendition()
                    },
                    cleanup: { request in
                        await cleanup.record(request)
                        return true
                    })
                XCTFail("Oversize/symlink output cannot be published")
            } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.path))
            if symlink { XCTAssertEqual(try Data(contentsOf: backing), Data([1, 2, 3])) }
            let calls = await cleanup.requests
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testLegacyFileRecordWithoutRenditionRemainsOriginal() throws {
        let data = Data("{\"name\":\"existing.m4a\",\"bytes\":64,\"digest\":\"fixture\"}".utf8)
        let file = try JSONDecoder().decode(FoundationDownloadManifest.File.self, from: data)
        XCTAssertNil(file.convertedRendition)
        XCTAssertEqual(file.name, "existing.m4a")
    }

    func testConvertedDotPathAndWrongSessionCleanupFailBeforeTransfer() async throws {
        let good = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        let fixture = try convertedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for itemID in [".", "..", "not-a-jellyfin-id"] {
            XCTAssertFalse(
                good.plan.accepts(
                    good.request, base: base, itemID: itemID, deviceID: "fixture-device"))
        }
        var cleanup = good.cleanupRequest
        cleanup.url = URL(
            string:
                "https://example.invalid/jellyfin/Videos/ActiveEncodings?deviceId=fixture-device&playSessionId=other"
        )!
        let bad = FoundationDownloadConversionProposal(
            request: good.request, cleanupRequest: cleanup, plan: good.plan,
            base: good.base, itemID: good.itemID, deviceID: good.deviceID)
        do {
            _ = try await FoundationConvertedDownload.transfer(
                proposal: bad, to: fixture.destination, allowsCellular: false,
                progress: { _, _ in },
                load: { _, _, _, _ in
                    XCTFail("Invalid cleanup ownership must fail before network work")
                    throw FoundationDownloadError.network
                },
                inspect: { _, _ in
                    XCTFail("No file may be inspected")
                    return Self.rendition()
                },
                cleanup: { _ in
                    XCTFail("Invalid cleanup must never be sent")
                    return true
                })
            XCTFail("Wrong-session cleanup must fail")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .response) }
    }

    private func writeAAC(_ url: URL) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
            ])
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        if let channels = buffer.floatChannelData {
            for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: 48_000) }
        }
        try file.write(from: buffer)
    }

    func testNativeInspectorReadsAACToEOFAndRejectsTruncatedOrWrongFormatFile() async throws {
        let fixture = try convertedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeAAC(fixture.temporary)
        let plan = try FoundationDownloadConversionPlan(
            quality: .aac128, duration: 1, sourceID: "fixture-source", audioStreamIndex: 0)
        let actual = try await FoundationConvertedDownload.inspectFile(fixture.temporary, plan)
        XCTAssertEqual(actual.codec, "aac")
        XCTAssertEqual(actual.sampleRate, 48_000)
        XCTAssertEqual(actual.channels, 2)
        XCTAssertEqual(actual.duration, 1, accuracy: 0.1)
        let original = try Data(contentsOf: fixture.temporary)
        try original.prefix(original.count / 2).write(to: fixture.destination)
        do {
            _ = try await FoundationConvertedDownload.inspectFile(fixture.destination, plan)
            XCTFail("Truncated data must not validate even if a prefix is playable")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
        try Data("RIFF synthetic not MPEG4".utf8).write(to: fixture.destination)
        do {
            _ = try await FoundationConvertedDownload.inspectFile(fixture.destination, plan)
            XCTFail("A renamed file is not an AAC/M4A rendition")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
    }

    func testNativeInspectorStillRejectsCompleteAACWithShorterThanExpectedDuration() async throws {
        let fixture = try convertedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeAAC(fixture.temporary)
        let longer = try FoundationDownloadConversionPlan(
            quality: .aac128, duration: 2, sourceID: "fixture-source", audioStreamIndex: 0)
        do {
            _ = try await FoundationConvertedDownload.inspectFile(fixture.temporary, longer)
            XCTFail("Reader EOF and valid AAC cannot substitute for complete expected duration")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .incomplete) }
    }

    func testFreshAuthorizedProposalIsHeaderAuthenticatedAndDoesNotStartTransfer() async throws {
        let proposal = try await proposalLibrary().convertedDownloadProposal(
            for: proposalTrack, quality: .aac128)
        XCTAssertTrue(
            proposal.plan.accepts(
                proposal.request, base: base, itemID: proposalTrack.id, deviceID: "fixture-device"))
        XCTAssertTrue(
            proposal.request.value(forHTTPHeaderField: "Authorization")?.contains("fixture-token")
                == true)
        XCTAssertFalse(proposal.request.url!.absoluteString.contains("fixture-token"))
        XCTAssertEqual(proposal.plan.duration, 180)
        XCTAssertEqual(proposal.plan.quality, .aac128)
        XCTAssertEqual(proposal.cleanupRequest.httpMethod, "DELETE")
        XCTAssertEqual(proposal.cleanupRequest.url?.path, "/jellyfin/Videos/ActiveEncodings")
        XCTAssertEqual(
            URLComponents(url: proposal.cleanupRequest.url!, resolvingAgainstBaseURL: false)?
                .queryItems,
            [
                URLQueryItem(name: "deviceId", value: "fixture-device"),
                URLQueryItem(name: "playSessionId", value: proposal.plan.sessionID.uuidString),
            ])
        XCTAssertEqual(
            proposal.cleanupRequest.value(forHTTPHeaderField: "Authorization"),
            proposal.request.value(forHTTPHeaderField: "Authorization"))
        // The fixture rejects any endpoint except the fresh user and item metadata reads.
        // Original transport still rejects the proposed query before network/file work.
    }

    func testUnknownDeniedAndMismatchedAccountPoliciesCannotProposeConversion() async {
        let valid: [String: Bool] = [
            "IsDisabled": false, "EnableMediaPlayback": true,
            "EnableContentDownloading": true, "EnableAudioPlaybackTranscoding": true,
        ]
        var policies = [""]
        for key in valid.keys {
            var denied = valid
            denied[key] = !(valid[key]!)
            var missing = valid
            missing[key] = nil
            for policy in [denied, missing] {
                policies.append(
                    policy.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }
                        .joined(separator: ","))
            }
        }
        for policy in policies {
            do {
                _ = try await proposalLibrary(policy: policy).convertedDownloadProposal(
                    for: proposalTrack, quality: .aac192)
                XCTFail("Unknown or denied permissions must remain unavailable")
            } catch { XCTAssertEqual(error as? FoundationDownloadError, .permission) }
        }
        do {
            _ = try await proposalLibrary(userID: "other").convertedDownloadProposal(
                for: proposalTrack, quality: .aac192)
            XCTFail("A different account policy must not authorize this transfer")
        } catch { XCTAssertEqual(error as? FoundationDownloadError, .permission) }
    }

    func testUnknownDeniedAndMismatchedItemCannotProposeConversion() async {
        for metadata in [
            "{\"Id\":\"other\",\"Type\":\"Audio\",\"CanDownload\":true}",
            "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Audio\"}",
            "{\"Id\":\"00000000000000000000000000000001\",\"Type\":\"Audio\",\"CanDownload\":false}",
        ] {
            do {
                _ = try await proposalLibrary(metadata: metadata).convertedDownloadProposal(
                    for: proposalTrack, quality: .aac192)
                XCTFail("Current item permission and identity are mandatory")
            } catch { XCTAssertEqual(error as? FoundationDownloadError, .permission) }
        }
    }

    private func plan(_ quality: FoundationDownloadQuality = .aac192) throws
        -> FoundationDownloadConversionPlan
    {
        try FoundationDownloadConversionPlan(
            quality: quality, duration: 180, sourceID: "fixture-source", audioStreamIndex: 0)
    }

    private func request(_ plan: FoundationDownloadConversionPlan) throws -> URLRequest {
        var components = URLComponents(
            url: base.appendingPathComponent("Audio/00000000000000000000000000000001/stream.m4a"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = try plan.queryItems(deviceID: "fixture-device")
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        return request
    }

    func testPresetsAreIndependentAndConversionHasFiniteBitrateBudget() throws {
        XCTAssertNil(FoundationDownloadQuality.original.aacBitrate)
        for (quality, bitrate) in [
            (FoundationDownloadQuality.aac320, 320_000), (.aac192, 192_000), (.aac128, 128_000),
        ] {
            let plan = try plan(quality)
            XCTAssertEqual(quality.aacBitrate, bitrate)
            XCTAssertGreaterThan(plan.maximumBytes, Int64(180 * bitrate / 8))
            let budget = try plan.receiveBudget(availableBytes: plan.maximumBytes + 1)
            XCTAssertEqual(budget.maximumBytes, plan.maximumBytes)
            XCTAssertNoThrow(try budget.check(received: plan.maximumBytes, announced: -1))
            XCTAssertThrowsError(try budget.check(received: plan.maximumBytes + 1, announced: -1))
            XCTAssertThrowsError(try plan.receiveBudget(availableBytes: plan.maximumBytes - 1))
        }
    }

    func testConversionRejectsInvalidDurationIdentityAndOriginal() {
        for duration in [0, -1, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(
                try FoundationDownloadConversionPlan(
                    quality: .aac128, duration: duration, sourceID: "source", audioStreamIndex: 0))
        }
        for (quality, source, index) in [
            (FoundationDownloadQuality.original, "source", 0), (.aac128, "", 0),
            (.aac128, "../source", 0), (.aac128, "source", -1),
        ] {
            XCTAssertThrowsError(
                try FoundationDownloadConversionPlan(
                    quality: quality, duration: 180, sourceID: source, audioStreamIndex: index))
        }
    }

    func testConvertedRequestRejectsUnknownDuplicateMissingAndChangedParameters() throws {
        let plan = try plan()
        let original = try request(plan)
        XCTAssertTrue(
            plan.accepts(
                original, base: base, itemID: "00000000000000000000000000000001",
                deviceID: "fixture-device"))
        let components = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
        let validItems = components.queryItems!
        for index in validItems.indices {
            var mutations = [[URLQueryItem]]()
            var missing = validItems
            missing.remove(at: index)
            mutations.append(missing)
            var changed = validItems
            changed[index].value = "invalid"
            mutations.append(changed)
            mutations.append(validItems + [validItems[index]])
            mutations.append(
                validItems + [
                    URLQueryItem(
                        name: validItems[index].name.lowercased(), value: validItems[index].value)
                ])
            for items in mutations {
                var changed = components
                changed.queryItems = items
                var request = original
                request.url = changed.url
                XCTAssertFalse(
                    plan.accepts(
                        request, base: base, itemID: "00000000000000000000000000000001",
                        deviceID: "fixture-device"))
            }
        }
        for extra in ["ApiKey", "api_key", "Token", "Params", "LiveStreamId", "Container"] {
            var changed = components
            changed.queryItems = validItems + [URLQueryItem(name: extra, value: "fixture")]
            var request = original
            request.url = changed.url
            XCTAssertFalse(
                plan.accepts(
                    request, base: base, itemID: "00000000000000000000000000000001",
                    deviceID: "fixture-device"))
        }
    }

    func testConvertedRequestRejectsOriginPathSessionAndBodyDrift() throws {
        let plan = try plan()
        let original = try request(plan)
        for key in ["scheme", "host", "path", "fragment", "user", "port"] {
            var components = URLComponents(url: original.url!, resolvingAgainstBaseURL: false)!
            switch key {
            case "scheme": components.scheme = "http"
            case "host": components.host = "elsewhere.invalid"
            case "path": components.path = "/Audio/other/stream.m4a"
            case "fragment": components.fragment = "fragment"
            case "user": components.user = "user"
            default: components.port = 444
            }
            var request = original
            request.url = components.url
            XCTAssertFalse(
                plan.accepts(
                    request, base: base, itemID: "00000000000000000000000000000001",
                    deviceID: "fixture-device"))
        }
        XCTAssertFalse(
            try self.plan().accepts(
                original, base: base, itemID: "00000000000000000000000000000001",
                deviceID: "fixture-device"))
        var body = original
        body.httpBody = Data([1])
        XCTAssertFalse(
            plan.accepts(
                body, base: base, itemID: "00000000000000000000000000000001",
                deviceID: "fixture-device"))
    }

    func testPlayablePrefixAndWrongAudioFormatAreInsufficient() throws {
        let plan = try plan()
        XCTAssertTrue(
            plan.acceptsOutput(
                codec: "aac", container: "m4a", sampleRate: 48_000, channels: 2, assetDuration: 180,
                firstPacketTime: 0, finalPacketEnd: 180, reachedEOF: true))
        for (codec, rate, channels, duration, start, end, eof) in [
            ("alac", 48_000.0, 2, 180.0, 0.0, 180.0, true),
            ("aac", 44_100, 2, 180, 0, 180, true), ("aac", 48_000, 6, 180, 0, 180, true),
            ("aac", 48_000, 2, 90, 0, 90, true), ("aac", 48_000, 2, 180, 0, 90, true),
            ("aac", 48_000, 2, 180, 5, 180, true), ("aac", 48_000, 2, 180, 0, 180, false),
            ("aac", 48_000, 2, .nan, 0, 180, true),
        ] {
            XCTAssertFalse(
                plan.acceptsOutput(
                    codec: codec, container: "m4a", sampleRate: rate, channels: channels,
                    assetDuration: duration, firstPacketTime: start, finalPacketEnd: end,
                    reachedEOF: eof))
        }
    }

    func testExistingManifestWithoutQualityMeansOriginalAndNewIntentRoundTrips() throws {
        let item = FoundationStoredDownloadItem(
            FoundationItem(id: "track", title: "Fixture", subtitle: "", kind: .track, duration: 1))
        var owner = FoundationDownloadManifest.Owner(
            id: "track:track", item: item, tracks: [item], paused: false, expanded: true)
        let legacy = try JSONEncoder().encode(owner)
        XCTAssertNil(
            try JSONDecoder().decode(FoundationDownloadManifest.Owner.self, from: legacy)
                .requestedQuality)
        owner.requestedQuality = .aac128
        let encoded = try JSONEncoder().encode(owner)
        XCTAssertEqual(
            try JSONDecoder().decode(FoundationDownloadManifest.Owner.self, from: encoded)
                .requestedQuality, .aac128)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("PlaySessionId"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Authorization"))
    }
}

private actor ConvertedDownloadCleanupRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) { requests.append(request) }
}

private struct DownloadFileFixture: Sendable {
    let root: URL
    let temporary: URL
    let destination: URL
    let source: FoundationDownloadSource

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporary = root.appendingPathComponent("transfer.tmp")
        destination = root.appendingPathComponent("staging.m4a")
        try Data([1, 2, 3, 4]).write(to: temporary)
        source = FoundationDownloadSource(
            request: URLRequest(url: URL(string: "https://example.invalid/original")!),
            fileExtension: "m4a", expectedBytes: 4)
    }

    func response(status: Int = 200, url: URL? = nil, length: Int = 4) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url ?? source.request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Length": String(length)])!
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
