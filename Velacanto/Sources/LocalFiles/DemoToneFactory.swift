import AVFoundation

enum DemoToneFactory {
    static let duration: TimeInterval = 60

    static func makeURL() async throws -> URL {
        try await DemoToneStore.shared.makeURL()
    }
}

private actor DemoToneStore {
    static let shared = DemoToneStore()

    func makeURL() throws -> URL {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Velacanto", isDirectory: true)
        let url = directory.appendingPathComponent("playback-test-tone-60s.caf")

        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if isValidTone(at: url) {
            return url
        }

        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let pendingURL = directory.appendingPathComponent(
            "playback-test-tone-\(UUID().uuidString).caf"
        )
        defer {
            try? fileManager.removeItem(at: pendingURL)
        }

        let format = try makeFormat()
        let buffer = try makeBuffer(format: format)
        let audioFile = try AVAudioFile(forWriting: pendingURL, settings: format.settings)
        try audioFile.write(from: buffer)
        try fileManager.moveItem(at: pendingURL, to: url)
        return url
    }

    private func isValidTone(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
            let file = try? AVAudioFile(forReading: url),
            file.processingFormat.sampleRate > 0
        else {
            return false
        }

        let measuredDuration = Double(file.length) / file.processingFormat.sampleRate
        return abs(measuredDuration - DemoToneFactory.duration) < 0.01
    }

    private func makeFormat() throws -> AVAudioFormat {
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: 44_100,
                channels: 1
            )
        else {
            throw DemoToneError.couldNotCreateAudioFormat
        }
        return format
    }

    private func makeBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let sampleRate = format.sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * DemoToneFactory.duration)
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
            ), let samples = buffer.floatChannelData?[0]
        else {
            throw DemoToneError.couldNotCreateAudioBuffer
        }

        buffer.frameLength = frameCount

        let frequency = 440.0
        let fadeFrames = max(Int(sampleRate * 0.03), 1)
        for frame in 0..<Int(frameCount) {
            let attack = min(Double(frame) / Double(fadeFrames), 1)
            let release = min(Double(Int(frameCount) - frame) / Double(fadeFrames), 1)
            let envelope = min(attack, release)
            let sample = sin(2 * .pi * frequency * Double(frame) / sampleRate)
            samples[frame] = Float(sample * envelope * 0.12)
        }

        return buffer
    }
}

enum DemoToneError: LocalizedError {
    case couldNotCreateAudioFormat
    case couldNotCreateAudioBuffer

    var errorDescription: String? {
        switch self {
        case .couldNotCreateAudioFormat:
            "Velacanto could not create the test tone format."
        case .couldNotCreateAudioBuffer:
            "Velacanto could not create the test tone buffer."
        }
    }
}
