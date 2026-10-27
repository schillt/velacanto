import Foundation
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationHandoffStreamTests: XCTestCase {
    func testNativeBoundStreamsTransferLargeFrameThenCorrelatedAcknowledgement() async throws {
        let pair = try Self.pair(buffer: 257)
        let response = Data(repeating: 42, count: 200_000)
        let request = Data("request".utf8)
        let acknowledgement = Data("ack".utf8)
        let completed = expectation(description: "all bounded messages")
        var source: FoundationHandoffStreamExchange!
        var receiver: FoundationHandoffStreamExchange!
        var sourceMessages = 0
        source = FoundationHandoffStreamExchange(
            streams: pair.0, maximumIncomingBytes: 2_048,
            message: { data in
                sourceMessages += 1
                if sourceMessages == 1 {
                    XCTAssertEqual(data, request)
                    do {
                        try source.expectAcknowledgement()
                        try source.send(response)
                    } catch { XCTFail("Source frame rejected") }
                } else {
                    XCTAssertEqual(data, acknowledgement)
                    completed.fulfill()
                }
            }, failure: { error in XCTFail("Source stream failed: \(error)") })
        receiver = FoundationHandoffStreamExchange(
            streams: pair.1,
            message: { data in
                XCTAssertEqual(data, response)
                do { try receiver.send(acknowledgement) } catch {
                    XCTFail("Acknowledgement rejected")
                }
            }, failure: { error in XCTFail("Receiver stream failed: \(error)") })
        defer {
            source.close()
            receiver.close()
        }
        source.open()
        receiver.open()
        try receiver.send(request)
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(sourceMessages, 2)
    }

    func testBoundedOfferAuthorizationClockAndStartUseFourReceiverMessagesOnly() async throws {
        let pair = try Self.pair(buffer: 257)
        let payload = Data(repeating: 42, count: 200_000)
        let completed = expectation(description: "bounded readiness-clock exchange")
        var source: FoundationHandoffStreamExchange!
        var receiver: FoundationHandoffStreamExchange!
        var sourceCount = 0
        var receiverCount = 0
        source = FoundationHandoffStreamExchange(
            streams: pair.0, maximumIncomingBytes: 2_048,
            maximumOutgoingMessages: 3,
            message: { data in
                sourceCount += 1
                do {
                    switch sourceCount {
                    case 1:
                        XCTAssertEqual(data, Data("offer".utf8))
                        try source.expectAcknowledgement()
                        try source.send(payload)
                    case 2:
                        XCTAssertEqual(data, Data("authorize".utf8))
                        try source.expectAcknowledgement()
                        try source.send(Data("authorized".utf8))
                    case 3:
                        XCTAssertEqual(data, Data("position".utf8))
                        try source.expectAcknowledgement()
                        try source.send(Data("42.125".utf8))
                    case 4:
                        XCTAssertEqual(data, Data("native-start".utf8))
                        XCTAssertThrowsError(try source.expectAcknowledgement())
                        completed.fulfill()
                    default: XCTFail("Unexpected extra source message")
                    }
                } catch { XCTFail("Bounded source stage failed: \(error)") }
            }, failure: { XCTFail("Source failed: \($0)") })
        receiver = FoundationHandoffStreamExchange(
            streams: pair.1, maximumIncomingMessages: 3,
            message: { data in
                receiverCount += 1
                do {
                    switch receiverCount {
                    case 1:
                        XCTAssertEqual(data, payload)
                        try receiver.expectAcknowledgement()
                        try receiver.send(Data("authorize".utf8))
                    case 2:
                        XCTAssertEqual(data, Data("authorized".utf8))
                        try receiver.expectAcknowledgement()
                        try receiver.send(Data("position".utf8))
                    case 3:
                        XCTAssertEqual(data, Data("42.125".utf8))
                        try receiver.send(Data("native-start".utf8))
                    default: XCTFail("Unexpected extra receiver message")
                    }
                } catch { XCTFail("Bounded receiver stage failed: \(error)") }
            }, failure: { XCTFail("Receiver failed: \($0)") })
        defer {
            source.close()
            receiver.close()
        }
        source.open()
        receiver.open()
        try receiver.send(Data("offer".utf8))
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertEqual(sourceCount, 4)
        XCTAssertEqual(receiverCount, 3)
        XCTAssertThrowsError(try receiver.send(Data("fifth-message".utf8)))
        XCTAssertThrowsError(try source.send(Data("fourth-source-message".utf8)))
    }

    func testRoleSpecificFrameLimitRejectsOversizedHeaderBeforeBodyArrives() async throws {
        let pair = try Self.pair(buffer: 257)
        let rejected = expectation(description: "header length rejected")
        let source = FoundationHandoffStreamExchange(
            streams: pair.0, maximumIncomingBytes: 2_048,
            message: { _ in XCTFail("Oversized request delivered") },
            failure: { error in
                XCTAssertEqual(error, .tooLarge)
                rejected.fulfill()
            })
        let receiver = FoundationHandoffStreamExchange(
            streams: pair.1, message: { _ in }, failure: { _ in })
        defer {
            source.close()
            receiver.close()
        }
        source.open()
        receiver.open()
        try receiver.send(Data(repeating: 1, count: 3_000))
        await fulfillment(of: [rejected], timeout: 5)
    }

    func testPlaybackOptInTreatsPeerEOFAsFailureEvenAfterACompleteFrame() async throws {
        let pair = try Self.pair()
        let failed = expectation(description: "unstarted playback loses peer")
        var receiver: FoundationHandoffStreamExchange!
        let source = FoundationHandoffStreamExchange(
            streams: pair.0, message: { _ in }, failure: { _ in })
        receiver = FoundationHandoffStreamExchange(
            streams: pair.1,
            message: { data in
                XCTAssertEqual(data, Data("position-reply".utf8))
                do { try receiver.requirePeerUntilNativeStart() } catch {
                    XCTFail("Peer was not open")
                }
                source.close()
            },
            failure: { error in
                XCTAssertEqual(error, .interrupted)
                failed.fulfill()
            })
        defer {
            source.close()
            receiver.close()
        }
        source.open()
        receiver.open()
        try source.send(Data("position-reply".utf8))
        await fulfillment(of: [failed], timeout: 5)
    }

    func testNativeStartReleasesPeerEOFRequirementWithoutAFalseFailure() async throws {
        let pair = try Self.pair()
        let received = expectation(description: "completed native-start boundary")
        let noFailure = expectation(description: "completed exchange may close normally")
        noFailure.isInverted = true
        var receiver: FoundationHandoffStreamExchange!
        let source = FoundationHandoffStreamExchange(
            streams: pair.0, message: { _ in }, failure: { _ in })
        receiver = FoundationHandoffStreamExchange(
            streams: pair.1,
            message: { _ in
                do { try receiver.requirePeerUntilNativeStart() } catch {
                    XCTFail("Peer was not open")
                }
                receiver.nativePlaybackStarted()
                source.close()
                received.fulfill()
            }, failure: { _ in noFailure.fulfill() })
        defer {
            source.close()
            receiver.close()
        }
        source.open()
        receiver.open()
        try source.send(Data("position-reply".utf8))
        await fulfillment(of: [received], timeout: 5)
        await fulfillment(of: [noFailure], timeout: 0.2)
    }

    func testClosingOwnerDropsBufferedMessagesAndLateEvents() async throws {
        let pair = try Self.pair(buffer: 257)
        let source = FoundationHandoffStreamExchange(
            streams: pair.0, message: { _ in XCTFail("Retired stream delivered data") },
            failure: { _ in XCTFail("Retired stream surfaced an error") })
        let receiver = FoundationHandoffStreamExchange(
            streams: pair.1, message: { _ in }, failure: { _ in })
        defer { receiver.close() }
        source.open()
        receiver.open()
        source.close()
        source.stream(pair.0.input, handle: [.errorOccurred, .endEncountered])
        XCTAssertThrowsError(try source.send(Data([1])))
    }

    static func pair(buffer: Int = 1_024) throws -> (
        FoundationHandoffNativeStreams, FoundationHandoffNativeStreams
    ) {
        var firstInput: InputStream?
        var firstOutput: OutputStream?
        var secondInput: InputStream?
        var secondOutput: OutputStream?
        Stream.getBoundStreams(
            withBufferSize: buffer, inputStream: &firstInput, outputStream: &firstOutput)
        Stream.getBoundStreams(
            withBufferSize: buffer, inputStream: &secondInput, outputStream: &secondOutput)
        return (
            .init(input: try XCTUnwrap(firstInput), output: try XCTUnwrap(secondOutput)),
            .init(input: try XCTUnwrap(secondInput), output: try XCTUnwrap(firstOutput))
        )
    }
}
