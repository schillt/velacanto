import AVFoundation
import Foundation

/// Actual inspected output, independent of the owner's requested bitrate.
nonisolated struct FoundationConvertedDownloadRendition: Codable, Equatable, Sendable {
    let container: String
    let codec: String
    let sampleRate: Double
    let channels: Int
    let duration: Double
}

/// Native HLS verification records requested intent and declared codec metadata.
/// It never claims file-reader sample rate/channels or a measured encoded bitrate.
nonisolated struct FoundationNativeDownloadRendition: Codable, Equatable, Sendable {
    let requestedQuality: FoundationDownloadQuality
    let declaredAudioCodec: String
    let container: String
    let duration: Double
}

nonisolated struct FoundationVerifiedConvertedDownload: Sendable {
    let bytes: Int64
    let digest: String
    let rendition: FoundationConvertedDownloadRendition
}

/// Only a fully validated staged file can be returned. The sequential manager
/// retains its existing ownership/lease-aware atomic publication boundary.
nonisolated enum FoundationConvertedDownload {
    typealias Inspect =
        @Sendable (URL, FoundationDownloadConversionPlan) async throws
        -> FoundationConvertedDownloadRendition
    typealias Cleanup = @Sendable (URLRequest) async -> Bool

    static func transfer(
        proposal: FoundationDownloadConversionProposal, to destination: URL, allowsCellular: Bool,
        progress: @escaping FoundationDownloadTransport.Progress,
        load: FoundationDownloadTransport.Load = FoundationDownloadTransport.nativeLoad,
        inspect: Inspect = inspectFile, cleanup: @escaping Cleanup = cleanSession
    ) async throws -> FoundationVerifiedConvertedDownload {
        guard
            proposal.plan.accepts(
                proposal.request, base: proposal.base, itemID: proposal.itemID,
                deviceID: proposal.deviceID), validCleanup(proposal),
            destination.isFileURL, destination.pathExtension.lowercased() == "m4a",
            !FileManager.default.fileExists(atPath: destination.path),
            proposal.request.value(forHTTPHeaderField: "Authorization")?.isEmpty == false
        else { throw FoundationDownloadError.response }
        // Reuse the sampled filesystem reserve without treating the ceiling as an exact
        // expected content length. The original transfer's equality contract is untouched.
        let source = FoundationDownloadSource(
            request: proposal.request, fileExtension: "m4a", expectedBytes: nil)
        let capacity = try FoundationDownloadTransport.receiveBudget(
            source: source, destination: destination
        ).maximumBytes
        let budget = try proposal.plan.receiveBudget(availableBytes: capacity)
        var request = proposal.request
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        request.allowsConstrainedNetworkAccess = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var cleanupRequest = proposal.cleanupRequest
        cleanupRequest.allowsCellularAccess = allowsCellular
        cleanupRequest.allowsExpensiveNetworkAccess = allowsCellular
        cleanupRequest.allowsConstrainedNetworkAccess = false
        var temporary: URL?
        var ownsDestination = false
        var started = false
        let outcome: Result<FoundationVerifiedConvertedDownload, Error>
        do {
            try Task.checkCancellation()
            started = true
            let (location, response) = try await load(request, allowsCellular, budget) { bytes, _ in
                // Conversion has no exact expected output length. Never infer a percentage
                // from the original file size or an announced maximum.
                progress(bytes, nil)
            }
            temporary = location
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse,
                response.statusCode == 401 || response.statusCode == 403
            {
                throw FoundationDownloadError.permission
            }
            guard let response = response as? HTTPURLResponse,
                response.statusCode == 200, response.url == request.url,
                response.value(forHTTPHeaderField: "Content-Range") == nil,
                response.value(forHTTPHeaderField: "Content-Encoding") == nil
                    || response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                        == "identity"
            else { throw FoundationDownloadError.response }
            let bytes = try regularFileBytes(location)
            try budget.check(received: bytes, announced: response.expectedContentLength)
            guard response.expectedContentLength < 0 || response.expectedContentLength == bytes
            else {
                throw FoundationDownloadError.incomplete
            }
            try FileManager.default.moveItem(at: location, to: destination)
            temporary = nil
            ownsDestination = true
            try FoundationDownloadStorage.protect(destination)
            let rendition = try await inspect(destination, proposal.plan)
            try Task.checkCancellation()
            guard rendition.codec == "aac", rendition.container == "m4a",
                rendition.sampleRate == 48_000, rendition.channels == 2,
                rendition.duration.isFinite,
                abs(rendition.duration - proposal.plan.duration)
                    <= min(1, max(0.1, proposal.plan.duration * 0.001))
            else { throw FoundationDownloadError.incomplete }
            guard try regularFileBytes(destination) == bytes else {
                throw FoundationDownloadError.incomplete
            }
            let digest = try await FoundationDownloadStorage.digestOffMain(destination)
            try Task.checkCancellation()
            outcome = .success(.init(bytes: bytes, digest: digest, rendition: rendition))
        } catch {
            outcome = .failure(error)
        }
        // Parent cancellation cannot skip cleanup. This separate task owns only the
        // completed/cancelled conversion's session; native cleanup is bounded to 8 seconds.
        // The transfer remains awaited until this one cleanup attempt has returned.
        let cleaned: Bool
        if started {
            let cleanupRequest = cleanupRequest
            cleaned = await Task.detached(priority: .utility) {
                await cleanup(cleanupRequest)
            }.value
        } else {
            cleaned = true
        }
        do {
            guard cleaned else { throw FoundationDownloadError.conversionCleanup }
            try Task.checkCancellation()
            let result = try outcome.get()
            progress(result.bytes, nil)
            return result
        } catch {
            do {
                if let temporary { try FileManager.default.removeItem(at: temporary) }
                if ownsDestination { try FileManager.default.removeItem(at: destination) }
            } catch { throw FoundationDownloadError.cleanup }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw FoundationDownloadError.cancelled
            }
            if let error = error as? FoundationDownloadError { throw error }
            if error is CocoaError || (error as? URLError)?.code == .cannotWriteToFile {
                throw FoundationDownloadError.storage
            }
            throw FoundationDownloadError.network
        }
    }

    private static func regularFileBytes(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            let bytes = values.fileSize, bytes > 0
        else { throw FoundationDownloadError.incomplete }
        return Int64(bytes)
    }

    private static func validCleanup(_ proposal: FoundationDownloadConversionProposal) -> Bool {
        let request = proposal.cleanupRequest
        guard request.httpMethod == "DELETE", request.httpBody == nil,
            request.httpBodyStream == nil,
            request.value(forHTTPHeaderField: "Authorization")
                == proposal.request.value(forHTTPHeaderField: "Authorization"),
            let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let base = URLComponents(url: proposal.base, resolvingAgainstBaseURL: false),
            components.scheme == "https", components.host == base.host,
            components.port == base.port, components.user == nil, components.password == nil,
            components.fragment == nil,
            let query = components.queryItems, query.count == 2
        else { return false }
        var path = base.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return components.percentEncodedPath == path + "/Videos/ActiveEncodings"
            && Set(query.map(\.name)) == Set(["deviceId", "playSessionId"])
            && query.first(where: { $0.name == "deviceId" })?.value == proposal.deviceID
            && query.first(where: { $0.name == "playSessionId" })?.value
                == proposal.plan.sessionID.uuidString
    }

    static let cleanSession: Cleanup = { request in
        let configuration = FoundationDownloadTransport.configuration(
            allowsCellular: request.allowsCellularAccess)
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = request
        request.timeoutInterval = 8
        do {
            let budget = try FoundationDownloadByteBudget(
                expectedBytes: 4_096, availableBytes: 4_096)
            let delegate = FoundationDownloadDelegate(budget: budget) { _, _ in }
            let (temporary, response) = try await session.download(for: request, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let response = response as? HTTPURLResponse,
                response.url == request.url, response.statusCode == 204, delegate.failure == nil
            else { return false }
            return true
        } catch { return false }
    }

    static let inspectFile: Inspect = { url, plan in
        let task = Task.detached(priority: .utility) {
            try await inspectNativeFile(url, plan: plan)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func inspectNativeFile(_ url: URL, plan: FoundationDownloadConversionPlan)
        async throws -> FoundationConvertedDownloadRendition
    {
        do {
            try Task.checkCancellation()
            _ = try regularFileBytes(url)
            // A renamed raw AAC/WAV file must not pass as M4A. AVAsset's compressed
            // track reader then walks the complete ISO BMFF file, not a playable prefix.
            let handle = try FileHandle(forReadingFrom: url)
            let header: Data
            do { header = try handle.read(upToCount: 12) ?? Data() } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
            guard header.count == 12, String(decoding: header[4..<8], as: UTF8.self) == "ftyp"
            else {
                throw FoundationDownloadError.incomplete
            }
            return try await inspectCompressedAsset(AVURLAsset(url: url), plan: plan)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw FoundationDownloadError.incomplete
        }
    }

    struct NativeVariant: Sendable {
        let declaredAudioFormats: [UInt32]
        let declaresVideo: Bool
    }
    struct NativePackageSnapshot: Sendable {
        let completeOffline: Bool
        let duration: Double
        let variants: [NativeVariant]
    }
    typealias NativePackageLoad = @Sendable (AVURLAsset) async throws -> NativePackageSnapshot

    /// A completed native task plus the caller's finite-VOD/owned/protected allocation
    /// is validated through HLS APIs, not the unrelated file-only packet reader.
    static func inspectNativePackage(
        _ url: URL, plan: FoundationDownloadConversionPlan,
        load: NativePackageLoad = { asset in
            let complete = asset.assetCache?.isPlayableOffline == true
            let duration = try await asset.load(.duration).seconds
            let variants = try await asset.load(.variants)
            return NativePackageSnapshot(
                completeOffline: complete, duration: duration,
                variants: variants.prefix(2).map { variant in
                    NativeVariant(
                        declaredAudioFormats: variant.audioAttributes?.formatIDs ?? [],
                        declaresVideo: variant.videoAttributes != nil)
                })
        }
    ) async throws -> FoundationNativeDownloadRendition {
        let asset = AVURLAsset(
            url: url,
            options: [
                AVURLAssetReferenceRestrictionsKey:
                    NSNumber(
                        value: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote.rawValue),
                AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                AVURLAssetAllowsConstrainedNetworkAccessKey: false,
            ])
        #if DEBUG
            enum Stage: String { case snapshot, intent, cache, duration, variant, codec }
            var stage = Stage.snapshot
            var variantCount = -1
            var complete = false
        #endif
        do {
            try Task.checkCancellation()
            let snapshot = try await load(asset)
            #if DEBUG
                stage = .intent
                variantCount = min(2, snapshot.variants.count)
                complete = snapshot.completeOffline
            #endif
            guard plan.quality.aacBitrate != nil else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                stage = .cache
            #endif
            guard snapshot.completeOffline else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                stage = .duration
            #endif
            let tolerance = min(1, max(0.1, plan.duration * 0.001))
            guard snapshot.duration.isFinite, abs(snapshot.duration - plan.duration) <= tolerance
            else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                stage = .variant
            #endif
            guard snapshot.variants.count == 1, let variant = snapshot.variants.first,
                !variant.declaresVideo
            else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                stage = .codec
            #endif
            guard variant.declaredAudioFormats == [kAudioFormatMPEG4AAC] else {
                throw FoundationDownloadError.incomplete
            }
            try Task.checkCancellation()
            return .init(
                requestedQuality: plan.quality, declaredAudioCodec: "aac", container: "hls",
                duration: snapshot.duration)
        } catch {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload") {
                    FoundationJournal.shared.record(
                        "download.native stage=rendition.native substage=\(stage.rawValue) outcome=failed completeOffline=\(complete ? 1 : 0) variants=\(variantCount) "
                            + FoundationNativeDownloadErrorFields.scalars(error))
                }
            #endif
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw FoundationDownloadError.incomplete
        }
    }

    private static func inspectCompressedAsset(
        _ asset: AVURLAsset, plan: FoundationDownloadConversionPlan
    )
        async throws -> FoundationConvertedDownloadRendition
    {
        #if DEBUG
            var diagnostic = RenditionDiagnostic()
            let diagnose = ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload")
            if diagnose { diagnostic.readable = try? await asset.load(.isReadable) }
        #endif
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            #if DEBUG
                diagnostic.audioTracks = tracks.count
            #endif
            guard tracks.count == 1, let track = tracks.first else {
                throw FoundationDownloadError.incomplete
            }
            #if DEBUG
                diagnostic.stage = .videoTracks
            #endif
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            #if DEBUG
                diagnostic.videoTracks = videoTracks.count
            #endif
            guard videoTracks.isEmpty else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                diagnostic.stage = .formats
            #endif
            let formats = try await track.load(.formatDescriptions)
            #if DEBUG
                diagnostic.formats = formats.count
            #endif
            guard formats.count == 1, let format = formats.first else {
                throw FoundationDownloadError.incomplete
            }
            #if DEBUG
                diagnostic.stage = .audioDescription
            #endif
            guard
                let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            else { throw FoundationDownloadError.incomplete }
            #if DEBUG
                diagnostic.stage = .codec
            #endif
            guard description.mFormatID == kAudioFormatMPEG4AAC else {
                throw FoundationDownloadError.incomplete
            }
            #if DEBUG
                diagnostic.stage = .sampleRate
            #endif
            guard description.mSampleRate == 48_000 else {
                throw FoundationDownloadError.incomplete
            }
            #if DEBUG
                diagnostic.stage = .channels
            #endif
            guard description.mChannelsPerFrame == 2 else {
                throw FoundationDownloadError.incomplete
            }
            #if DEBUG
                diagnostic.stage = .duration
            #endif
            let assetDuration = try await asset.load(.duration).seconds
            #if DEBUG
                diagnostic.stage = .readerInit
            #endif
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            #if DEBUG
                diagnostic.stage = .readerOutput
            #endif
            guard reader.canAdd(output) else { throw FoundationDownloadError.incomplete }
            let provider = reader.outputProvider(for: output)
            #if DEBUG
                diagnostic.stage = .readerStart
            #endif
            try reader.start()
            defer { reader.cancelReading() }
            var first: Double?
            var end: Double = 0
            var lastStart = -Double.infinity
            var readBytes: Int64 = 0
            #if DEBUG
                diagnostic.stage = .readerNext
            #endif
            while let sample = try await provider.next() {
                try Task.checkCancellation()
                // With compressed outputSettings=nil, AVAssetReader also emits
                // marker-only buffers (zero samples). They carry edit/end metadata,
                // not audio packets. Continue through them to actual reader EOF;
                // nonempty packets and the complete expected duration remain mandatory.
                #if DEBUG
                    diagnostic.stage = .marker
                #endif
                if sample.sampleCount == 0 {
                    guard sample.totalSampleSize == 0 else {
                        throw FoundationDownloadError.incomplete
                    }
                    #if DEBUG
                        diagnostic.stage = .readerNext
                    #endif
                    continue
                }
                #if DEBUG
                    diagnostic.stage = .packet
                #endif
                guard sample.sampleCount > 0 else {
                    throw FoundationDownloadError.incomplete
                }
                let start = sample.presentationTimeStamp.seconds
                let duration = sample.duration.seconds
                let size = sample.totalSampleSize
                guard start.isFinite, duration.isFinite, duration > 0, size > 0,
                    start >= lastStart, first == nil || abs(start - end) <= 0.05,
                    Int64(size) <= plan.maximumBytes - readBytes
                else { throw FoundationDownloadError.incomplete }
                if first == nil { first = start }
                lastStart = start
                end = start + duration
                readBytes += Int64(size)
                #if DEBUG
                    diagnostic.sawPacket = true
                    diagnostic.stage = .readerNext
                #endif
            }
            try Task.checkCancellation()
            #if DEBUG
                diagnostic.stage = .eof
            #endif
            guard let first, reader.status == .completed,
                plan.acceptsOutput(
                    codec: "aac", container: "m4a", sampleRate: description.mSampleRate,
                    channels: Int(description.mChannelsPerFrame), assetDuration: assetDuration,
                    firstPacketTime: first, finalPacketEnd: end, reachedEOF: true)
            else { throw FoundationDownloadError.incomplete }
            return .init(
                container: "m4a", codec: "aac", sampleRate: description.mSampleRate,
                channels: Int(description.mChannelsPerFrame), duration: assetDuration)
        } catch {
            #if DEBUG
                if diagnose { FoundationJournal.shared.record(diagnostic.failure(error)) }
            #endif
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw FoundationDownloadError.incomplete
        }
    }

    #if DEBUG
        /// Fixed shape and recognized numeric errors only; never media identifiers or URLs.
        struct RenditionDiagnostic {
            enum Stage: String {
                case audioTracks, videoTracks, formats, audioDescription, codec, sampleRate,
                    channels
                case duration, readerInit, readerOutput, readerStart, readerNext, marker, packet,
                    eof
            }
            var stage = Stage.audioTracks
            var readable: Bool?
            var audioTracks = -1
            var videoTracks = -1
            var formats = -1
            var sawPacket = false
            func failure(_ error: Error) -> String {
                func count(_ value: Int) -> Int { max(-1, min(2, value)) }
                let support = readable.map { $0 ? "yes" : "no" } ?? "unknown"
                return
                    "download.native stage=rendition.inspect substage=\(stage.rawValue) outcome=failed readable=\(support) audioTracks=\(count(audioTracks)) videoTracks=\(count(videoTracks)) formats=\(count(formats)) sawPacket=\(sawPacket ? 1 : 0) "
                    + FoundationNativeDownloadErrorFields.scalars(error)
            }
        }
    #endif

}
