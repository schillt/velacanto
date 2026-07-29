import AVFoundation

enum DemoToneFactory {
    static let duration: TimeInterval = 60

    static func makeURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Velacanto", isDirectory: true)
        let url = directory.appendingPathComponent("playback-test-tone-60s.caf")

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: url.path) {
            return url
        }

        let sampleRate = 44_100.0
        guard
            let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate,
                channels: 1
            )
        else {
            throw DemoToneError.couldNotCreateAudioFormat
        }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
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

        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try audioFile.write(from: buffer)
        return url
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
