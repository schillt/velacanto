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

    func testTransferStagesOriginalAndPassesNativeConnectionPolicy() async throws {
        let fixture = try DownloadFileFixture()
        defer { fixture.remove() }
        try await FoundationDownloadTransport.transfer(
            source: fixture.source, to: fixture.destination, allowsCellular: false,
            progress: { _, _ in },
            load: { request, cellular, progress in
                XCTAssertFalse(cellular)
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
                    progress: { _, _ in }, load: { _, _, _ in (fixture.temporary, response) },
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
                load: { _, _, _ in (fixture.temporary, fixture.response()) }, validate: { _ in })
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
                    load: { _, _, _ in (fixture.temporary, fixture.response()) },
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
