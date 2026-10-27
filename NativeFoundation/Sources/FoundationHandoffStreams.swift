import Foundation

/// Native Handoff supplies these streams. They are handed to the main-run-loop
/// owner once; no playback URLs, sockets, files or credentials are opened here.
struct FoundationHandoffNativeStreams: @unchecked Sendable {
    let input: InputStream
    let output: OutputStream
}

/// One offer, authorization, readiness clock exchange and native-start acknowledgement. Each callback
/// processes at most64KiB, then yields; encoding/decoding belongs off the UI thread.
@MainActor
final class FoundationHandoffStreamExchange: NSObject, @preconcurrency StreamDelegate {
    private let streams: FoundationHandoffNativeStreams
    private let message: (Data) -> Void
    private let failure: (FoundationHandoffError) -> Void
    private var frame: FoundationHandoffFrame
    private let maximumOutgoingMessages: Int
    private let maximumIncomingMessages: Int
    private var outgoing: Data?
    private var written = 0
    private var inputEnded = false
    private var requiresPeerUntilNativeStart = false
    private var received = false
    private var receivedMessages = 0
    private var sentMessages = 0
    private var opened = false
    private var finished = false
    private var readPump: Task<Void, Never>?
    private var writePump: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var openedAt: TimeInterval?
    var didSend: (() -> Void)?

    init(
        streams: FoundationHandoffNativeStreams,
        maximumIncomingBytes: Int = FoundationHandoffPayload.maximumBytes,
        maximumOutgoingMessages: Int = 4, maximumIncomingMessages: Int = 4,
        message: @escaping (Data) -> Void,
        failure: @escaping (FoundationHandoffError) -> Void
    ) {
        self.streams = streams
        self.maximumOutgoingMessages = min(4, max(1, maximumOutgoingMessages))
        self.maximumIncomingMessages = min(4, max(1, maximumIncomingMessages))
        frame = .init(maximumBytes: maximumIncomingBytes)
        self.message = message
        self.failure = failure
    }

    func open() {
        guard !opened, !finished else { return }
        opened = true
        openedAt = ProcessInfo.processInfo.systemUptime
        streams.input.delegate = self
        streams.output.delegate = self
        streams.input.schedule(in: .main, forMode: .common)
        streams.output.schedule(in: .main, forMode: .common)
        streams.input.open()
        streams.output.open()
        extendLifetime(to: 30)
    }

    func send(_ data: Data) throws {
        guard !finished, outgoing == nil, sentMessages < maximumOutgoingMessages else {
            throw FoundationHandoffError.invalid
        }
        outgoing = try FoundationHandoffFrame.encode(data)
        sentMessages += 1
        written = 0
        writeAvailable()
    }

    func expectAcknowledgement() throws {
        guard !finished, !inputEnded, received, receivedMessages < maximumIncomingMessages else {
            throw FoundationHandoffError.invalid
        }
        frame = .init(maximumBytes: 512)
        received = false
        extendLifetime(to: 120)
    }

    /// Playback alone must keep the sending peer alive through readiness, seek and
    /// activation. Generic/browse exchanges retain their completed-frame EOF behavior.
    func requirePeerUntilNativeStart() throws {
        guard !finished, !inputEnded else { throw FoundationHandoffError.interrupted }
        requiresPeerUntilNativeStart = true
    }

    func nativePlaybackStarted() {
        requiresPeerUntilNativeStart = false
    }

    /// A user-confirmation window, still bounded from the original stream opening.
    func extendLifetime(to seconds: TimeInterval) {
        guard let openedAt, !finished else { return }
        deadline?.cancel()
        let remaining = max(
            0, min(120, seconds) - (ProcessInfo.processInfo.systemUptime - openedAt))
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            self?.fail(.interrupted)
        }
    }

    func close() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        readPump?.cancel()
        writePump?.cancel()
        streams.input.delegate = nil
        streams.output.delegate = nil
        streams.input.remove(from: .main, forMode: .common)
        streams.output.remove(from: .main, forMode: .common)
        streams.input.close()
        streams.output.close()
        outgoing = nil
        didSend = nil
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard !finished else { return }
        if eventCode.contains(.errorOccurred) {
            fail(.interrupted)
            return
        }
        if aStream === streams.input, eventCode.contains(.hasBytesAvailable) {
            readAvailable()
        }
        if aStream === streams.output, eventCode.contains(.hasSpaceAvailable) {
            writeAvailable()
        }
        if eventCode.contains(.endEncountered), aStream === streams.input {
            inputEnded = true
            if !received || requiresPeerUntilNativeStart { fail(.interrupted) }
        }
    }

    private func readAvailable() {
        guard opened, !finished else { return }
        var budget = 65_536
        var scratch = [UInt8](repeating: 0, count: 16_384)
        while streams.input.hasBytesAvailable, budget > 0, !finished {
            let count = streams.input.read(&scratch, maxLength: min(scratch.count, budget))
            guard count > 0 else {
                if count < 0 { fail(.interrupted) }
                return
            }
            guard !received else {
                fail(.invalid)
                return
            }
            budget -= count
            do {
                if let data = try frame.append(Data(scratch.prefix(count))) {
                    received = true
                    receivedMessages += 1
                    message(data)
                }
            } catch {
                fail(error as? FoundationHandoffError ?? .invalid)
            }
        }
        if !finished, streams.input.hasBytesAvailable, readPump == nil {
            readPump = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.readPump = nil
                self.readAvailable()
            }
        }
    }

    private func writeAvailable() {
        guard opened, !finished, let outgoing else { return }
        var budget = 65_536
        while streams.output.hasSpaceAvailable, written < outgoing.count, budget > 0 {
            let count = outgoing.withUnsafeBytes { bytes in
                streams.output.write(
                    bytes.bindMemory(to: UInt8.self).baseAddress!.advanced(by: written),
                    maxLength: min(outgoing.count - written, budget))
            }
            guard count > 0 else {
                if count < 0 { fail(.interrupted) }
                return
            }
            written += count
            budget -= count
        }
        if written == outgoing.count {
            self.outgoing = nil
            let completion = didSend
            didSend = nil
            completion?()
        } else if streams.output.hasSpaceAvailable, writePump == nil {
            writePump = Task { [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.writePump = nil
                self.writeAvailable()
            }
        }
    }

    private func fail(_ error: FoundationHandoffError) {
        guard !finished else { return }
        close()
        failure(error)
    }
}
