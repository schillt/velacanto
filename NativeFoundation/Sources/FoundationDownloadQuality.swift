import Foundation

/// Download intent is independent of streaming. Snapshot it when creating an owner;
/// retry and playlist reconciliation must reuse that snapshot, never the current preference.
nonisolated enum FoundationDownloadQuality: String, CaseIterable, Codable, Sendable {
    case original, aac320, aac192, aac128

    var title: String {
        switch self {
        case .original: "Original"
        case .aac320: "High · 320 kbps"
        case .aac192: "Standard · 192 kbps"
        case .aac128: "Data Saver · 128 kbps"
        }
    }

    var aacBitrate: Int? {
        switch self {
        case .original: nil
        case .aac320: 320_000
        case .aac192: 192_000
        case .aac128: 128_000
        }
    }
}

/// Provider-neutral transfer choice. Only the adapter resolves server-specific policy.
nonisolated enum FoundationDownloadPreparation: Sendable {
    case original(FoundationDownloadSource)
    case converted(FoundationDownloadConversionProposal)

    var fileExtension: String {
        switch self {
        case .original(let source): source.fileExtension
        case .converted: "m4a"
        }
    }
}

/// Transient proposal only. It cannot be passed to the original-file transport or
/// persisted as a ready file. No server conversion has started when it is returned.
nonisolated struct FoundationDownloadConversionProposal: Sendable {
    let request: URLRequest
    let cleanupRequest: URLRequest
    let plan: FoundationDownloadConversionPlan
    let base: URL
    let itemID: String
    let deviceID: String
}

/// A proposed conversion, not download authorization. The adapter must freshly verify
/// the current user, CanDownload, source identity and transcoding policy before using it.
/// Preparing a request neither starts conversion nor grants permission to publish bytes.
/// The converted executor must validate full output and close its session before publication.
nonisolated struct FoundationDownloadConversionPlan: Sendable {
    let quality: FoundationDownloadQuality
    let duration: Double
    let sourceID: String
    let audioStreamIndex: Int
    let sessionID: UUID
    let maximumBytes: Int64

    init(
        quality: FoundationDownloadQuality, duration: Double, sourceID: String,
        audioStreamIndex: Int, sessionID: UUID = UUID()
    ) throws {
        guard let bitrate = quality.aacBitrate,
            duration.isFinite, duration > 0, Self.safeIdentifier(sourceID), audioStreamIndex >= 0
        else { throw FoundationDownloadError.unsupported }
        // Allow bounded mux/encoder overhead, not an original-file size assumption.
        // Overflow and malformed server duration fail before any transfer starts.
        let ceiling = ceil(duration * Double(bitrate) / 8 * 1.15) + 1_048_576
        guard ceiling.isFinite, ceiling > 0, ceiling < Double(Int64.max) else {
            throw FoundationDownloadError.unsupported
        }
        self.quality = quality
        self.duration = duration
        self.sourceID = sourceID
        self.audioStreamIndex = audioStreamIndex
        self.sessionID = sessionID
        maximumBytes = Int64(ceiling)
    }

    /// Only these values may appear on a converted request; a token is header-only.
    /// Device identity is account-owned; the session UUID belongs to this transfer alone.
    func queryItems(deviceID: String) throws -> [URLQueryItem] {
        guard Self.safeIdentifier(deviceID) else { throw FoundationDownloadError.permission }
        return [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "MediaSourceId", value: sourceID),
            URLQueryItem(name: "AudioStreamIndex", value: String(audioStreamIndex)),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "AudioBitRate", value: String(quality.aacBitrate!)),
            URLQueryItem(name: "AudioSampleRate", value: "48000"),
            URLQueryItem(name: "AudioChannels", value: "2"),
            URLQueryItem(name: "AllowAudioStreamCopy", value: "false"),
            URLQueryItem(name: "EnableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "EnableAudioVbrEncoding", value: "false"),
            URLQueryItem(name: "StartTimeTicks", value: "0"),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "PlaySessionId", value: sessionID.uuidString),
        ]
    }

    /// Exact path and complete query contract. Unknown keys, credentials, missing keys,
    /// duplicate keys (including casing aliases) and changed identities all fail closed.
    func accepts(_ request: URLRequest, base: URL, itemID: String, deviceID: String) -> Bool {
        guard Self.validItemID(itemID), Self.safeIdentifier(deviceID),
            request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
            let url = request.url,
            let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let origin = URLComponents(url: base, resolvingAgainstBaseURL: false),
            actual.scheme == "https", origin.scheme == "https", origin.host != nil,
            actual.host == origin.host, actual.port == origin.port,
            actual.user == nil, actual.password == nil, actual.fragment == nil,
            origin.user == nil, origin.password == nil, origin.fragment == nil,
            origin.query == nil || origin.query == "",
            let expected = try? queryItems(deviceID: deviceID)
        else { return false }
        let root = origin.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = root.isEmpty ? "" : "/" + root
        guard actual.percentEncodedPath == prefix + "/Audio/" + itemID + "/stream.m4a",
            let query = actual.queryItems, query.count == expected.count
        else { return false }
        var values: [String: String] = [:]
        for item in query {
            guard let value = item.value, values[item.name.lowercased()] == nil else {
                return false
            }
            values[item.name.lowercased()] = value
        }
        return expected.allSatisfy { values[$0.name.lowercased()] == $0.value }
    }

    /// The original-byte contract is unchanged. Converted bytes have a separate local
    /// ceiling and remain indeterminate until transfer completes and validation succeeds.
    func receiveBudget(availableBytes: Int64) throws -> FoundationDownloadByteBudget {
        try FoundationDownloadByteBudget(
            expectedBytes: maximumBytes, availableBytes: availableBytes)
    }

    /// Metadata checks used by the future native packet reader. Merely playable or a
    /// matching container duration is insufficient: the reader must reach EOF and provide
    /// the final compressed packet's end time. This function does not inspect a file.
    func acceptsOutput(
        codec: String, container: String, sampleRate: Double, channels: Int,
        assetDuration: Double, firstPacketTime: Double, finalPacketEnd: Double,
        reachedEOF: Bool
    ) -> Bool {
        let tolerance = min(1, max(0.1, duration * 0.001))
        return codec == "aac" && ["m4a", "mp4"].contains(container)
            && sampleRate == 48_000 && channels == 2 && reachedEOF
            && assetDuration.isFinite && abs(assetDuration - duration) <= tolerance
            && firstPacketTime.isFinite && abs(firstPacketTime) <= tolerance
            && finalPacketEnd.isFinite && abs(finalPacketEnd - duration) <= tolerance
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 126
            }
    }

    private static func validItemID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
            || (value.utf8.count == 32
                && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                })
    }
}
