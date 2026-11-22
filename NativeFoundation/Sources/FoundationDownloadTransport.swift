import AVFoundation
import Foundation

/// Transient only. Authenticated requests must never be encoded into the manifest.
struct FoundationDownloadSource: Sendable {
    let request: URLRequest
    let fileExtension: String
    let expectedBytes: Int64?
}

enum FoundationDownloadError: Error, LocalizedError, Equatable {
    case unsupported, permission, response, incomplete, storage, cleanup, cancelled, network
    case nativeProtection, conversionCleanup, systemManagementUnavailable,
        originalSystemManagementUnavailable

    var errorDescription: String? {
        switch self {
        case .nativeProtection:
            "System download protection could not be verified. The asset was not saved. Use VelaCanto downloads while system management is being validated."
        case .systemManagementUnavailable:
            "System Settings downloads are not yet available on this device. Turn off Manage New Downloads in iPhone Storage to download in VelaCanto."
        case .originalSystemManagementUnavailable:
            "Original downloads stay in VelaCanto. Remove this failed request, then download again with iPhone Storage management off."
        case .unsupported: "This download quality is not available for this file or server."
        case .permission: "The server did not allow this download."
        case .response: "The download response could not be verified."
        case .incomplete: "The downloaded file is incomplete or cannot be played."
        case .storage: "The download could not be saved. Check available storage and retry."
        case .cleanup: "An incomplete download could not be removed. Retry storage cleanup."
        case .conversionCleanup:
            "The server conversion could not be closed safely. The download was not saved."
        case .cancelled: "Download cancelled."
        case .network:
            "The download could not finish on the allowed connection. Retry when connected."
        }
    }
}

enum FoundationDownloadTransport {
    typealias Progress = @Sendable (Int64, Int64?) -> Void
    typealias Load =
        @Sendable (URLRequest, Bool, FoundationDownloadByteBudget, @escaping Progress) async throws
        -> (URL, URLResponse)
    typealias Validate = @Sendable (URL) async throws -> Void

    static func supports(container: String, codec: String) -> Bool {
        switch container {
        case "mp3": codec == "mp3"
        case "aac": codec == "aac"
        case "m4a", "mp4": ["aac", "alac"].contains(codec)
        case "flac": codec == "flac"
        case "wav": ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le"].contains(codec)
        case "aiff": ["pcm_s16be", "pcm_s24be", "pcm_s32be"].contains(codec)
        default: false
        }
    }

    static func transfer(
        source: FoundationDownloadSource, to destination: URL, allowsCellular: Bool,
        progress: @escaping Progress
    ) async throws {
        try await transfer(
            source: source, to: destination, allowsCellular: allowsCellular,
            progress: progress, load: nativeLoad, validate: validateAsset)
    }

    /// The injected seams exercise the same response, size, staging and cleanup path.
    static func transfer(
        source: FoundationDownloadSource, to destination: URL, allowsCellular: Bool,
        progress: @escaping Progress, load: Load, validate: Validate
    ) async throws {
        let files = FileManager.default
        guard destination.isFileURL, !files.fileExists(atPath: destination.path),
            let url = source.request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "https", components.host != nil,
            components.user == nil, components.password == nil, components.fragment == nil,
            components.query == nil || components.query == "",
            source.request.httpMethod == "GET",
            source.expectedBytes == nil || source.expectedBytes! > 0
        else { throw FoundationDownloadError.response }
        let budget = try receiveBudget(source: source, destination: destination)
        var temporary: URL?
        var ownsDestination = false
        do {
            try Task.checkCancellation()
            var request = source.request
            request.allowsCellularAccess = allowsCellular
            request.allowsExpensiveNetworkAccess = allowsCellular
            request.allowsConstrainedNetworkAccess = false
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (location, response) = try await load(request, allowsCellular, budget, progress)
            temporary = location
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse,
                response.statusCode == 401 || response.statusCode == 403
            {
                throw FoundationDownloadError.permission
            }
            guard let response = response as? HTTPURLResponse,
                response.url == request.url, response.statusCode == 200,
                response.value(forHTTPHeaderField: "Content-Range") == nil,
                response.value(forHTTPHeaderField: "Content-Encoding") == nil
                    || response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
                        == "identity"
            else { throw FoundationDownloadError.response }
            let attributes = try files.attributesOfItem(atPath: location.path)
            if let size = (attributes[.size] as? NSNumber)?.int64Value {
                try budget.check(received: size, announced: response.expectedContentLength)
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0,
                source.expectedBytes == nil || source.expectedBytes == size,
                response.expectedContentLength < 0 || response.expectedContentLength == size
            else { throw FoundationDownloadError.incomplete }
            // Destination is a caller-owned unique staging name, never an existing ready file.
            try files.moveItem(at: location, to: destination)
            temporary = nil
            ownsDestination = true
            #if os(iOS)
                try files.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: destination.path)
            #else
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            #endif
            var protectedURL = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            try await validate(destination)
            try Task.checkCancellation()
            progress(size, source.expectedBytes ?? size)
        } catch {
            do {
                if let temporary { try files.removeItem(at: temporary) }
                if ownsDestination { try files.removeItem(at: destination) }
            } catch { throw FoundationDownloadError.cleanup }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw FoundationDownloadError.cancelled
            }
            if let downloadError = error as? FoundationDownloadError { throw downloadError }
            if error is CocoaError || (error as? URLError)?.code == .cannotWriteToFile {
                throw FoundationDownloadError.storage
            }
            throw FoundationDownloadError.network
        }
    }

    static func configuration(allowsCellular: Bool) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = false
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        return configuration
    }

    /// Keep a local free-space reserve without imposing a format or duration limit on originals.
    static func receiveBudget(source: FoundationDownloadSource, destination: URL) throws
        -> FoundationDownloadByteBudget
    {
        let reserve: Int64 = 256 * 1_024 * 1_024
        let files = FileManager.default
        let paths = [files.temporaryDirectory, destination.deletingLastPathComponent()]
        var capacity = Int64.max
        do {
            for path in paths {
                let attributes = try files.attributesOfFileSystem(forPath: path.path)
                guard let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
                    free > reserve
                else { throw FoundationDownloadError.storage }
                capacity = min(capacity, free - reserve)
            }
        } catch { throw FoundationDownloadError.storage }
        return try FoundationDownloadByteBudget(
            expectedBytes: source.expectedBytes, availableBytes: capacity)
    }

    static let nativeLoad: Load = { request, allowsCellular, budget, progress in
        let session = URLSession(configuration: configuration(allowsCellular: allowsCellular))
        defer { session.invalidateAndCancel() }
        let delegate = FoundationDownloadDelegate(budget: budget, progress: progress)
        let result: (URL, URLResponse)
        do {
            result = try await session.download(for: request, delegate: delegate)
        } catch {
            throw delegate.failure ?? error
        }
        if let failure = delegate.failure {
            do { try FileManager.default.removeItem(at: result.0) } catch {
                throw FoundationDownloadError.cleanup
            }
            throw failure
        }
        return result
    }

    static let validateAsset: Validate = { url in
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable),
                !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            else { throw FoundationDownloadError.incomplete }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw FoundationDownloadError.incomplete }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw FoundationDownloadError.incomplete
        }
    }
}

/// Both values are locally bounded; a server cannot increase the receive ceiling with headers.
struct FoundationDownloadByteBudget: Sendable {
    let maximumBytes: Int64
    let exceededError: FoundationDownloadError

    init(expectedBytes: Int64?, availableBytes: Int64) throws {
        guard availableBytes > 0 else { throw FoundationDownloadError.storage }
        if let expectedBytes {
            guard expectedBytes > 0 else { throw FoundationDownloadError.response }
            guard expectedBytes <= availableBytes else { throw FoundationDownloadError.storage }
            maximumBytes = expectedBytes
            exceededError = .incomplete
        } else {
            maximumBytes = availableBytes
            exceededError = .storage
        }
    }

    func check(received: Int64, announced: Int64) throws {
        guard received >= 0 else { throw FoundationDownloadError.response }
        guard received <= maximumBytes, announced <= maximumBytes else { throw exceededError }
    }
}

final class FoundationDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let budget: FoundationDownloadByteBudget
    let progress: FoundationDownloadTransport.Progress
    private let lock = NSLock()
    private var budgetFailure: FoundationDownloadError?

    var failure: FoundationDownloadError? { lock.withLock { budgetFailure } }

    init(
        budget: FoundationDownloadByteBudget,
        progress: @escaping FoundationDownloadTransport.Progress
    ) {
        self.budget = budget
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) { completionHandler(nil) }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        do {
            try budget.check(received: totalBytesWritten, announced: totalBytesExpectedToWrite)
        } catch {
            lock.withLock {
                if budgetFailure == nil {
                    budgetFailure = error as? FoundationDownloadError ?? .response
                }
            }
            downloadTask.cancel()
            return
        }
        guard failure == nil else { return }
        progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

/// Native HLS remains a distinct transport. It never moves or rewrites package payload/layout,
/// substitutes an Original file, or hands an unowned location to AVFoundation.
nonisolated enum FoundationNativeDownloadTransport {
    #if DEBUG
        fileprivate static var diagnosticEnabled: Bool {
            ProcessInfo.processInfo.arguments.contains("-diagnosticNativeDownload")
        }
    #endif
    /// Reconnect only an independently fenced, unrepresented identifier. This
    /// observer never creates/cancels a task or reads/writes a native allocation.
    static func observeUnrepresentedEmptySession(
        _ identifier: String, drained: @escaping @MainActor @Sendable () -> Void
    ) async -> FoundationNativeEmptySessionOutcome {
        #if os(iOS) && !FOUNDATION_ISOLATED_TEST_HOST
            guard !Task.isCancelled,
                FoundationNativeAllocationStore.directoryScope(forSessionIdentifier: identifier)
                    != nil
            else { return .unavailable }
            let worker = FoundationNativeEmptySessionDelegate(drained: drained)
            let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
            configuration.allowsCellularAccess = false
            configuration.allowsExpensiveNetworkAccess = false
            configuration.allowsConstrainedNetworkAccess = false
            configuration.isDiscretionary = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
            let session = AVAssetDownloadURLSession(
                configuration: configuration, assetDownloadDelegate: worker,
                delegateQueue: worker.delegateQueue)
            return await worker.observe(session)
        #else
            return .unavailable
        #endif
    }

    static func transfer(
        _ proposal: FoundationNativeDownloadProposal, store: FoundationNativeAllocationStore,
        allowsCellular: Bool, progress: @escaping FoundationDownloadTransport.Progress,
        onTerminalNoAllocationFinality: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> FoundationDownloadManifest.File {
        #if !os(iOS)
            throw FoundationDownloadError.systemManagementUnavailable
        #else
            let nativeMaster: URL
            do {
                nativeMaster = try proposal.validatedNativeMasterURL()
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=authorization outcome=validated")
                    }
                #endif
            } catch {
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=authorization outcome=rejected")
                    }
                #endif
                throw error
            }
            do {
                // No OS task exists yet; cancellation/preflight can retire safely.
                try store.reserve()
            } catch {
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=reserve outcome=failed")
                    }
                #endif
                throw error
            }
            do {
                _ = try await finiteMediaURL(proposal, allowsCellular: allowsCellular)
            } catch {
                let primary =
                    (error as? FoundationDownloadError)
                    ?? (Task.isCancelled ? .cancelled : .network)
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=preflight primary=\(primary) \(FoundationNativeDownloadErrorFields.scalars(error))"
                        )
                    }
                #endif
                do {
                    try await closeConversion(
                        proposal.cleanupRequest, allowsCellular: allowsCellular)
                    #if DEBUG
                        if diagnosticEnabled {
                            FoundationJournal.shared.record(
                                "download.native stage=preflight.cleanup outcome=success")
                        }
                    #endif
                } catch {
                    #if DEBUG
                        if diagnosticEnabled {
                            FoundationJournal.shared.record(
                                "download.native stage=preflight.cleanup outcome=failed")
                        }
                    #endif
                    throw FoundationDownloadError.conversionCleanup
                }
                throw primary
            }
            let sessionIdentifier = store.sessionIdentifier
            let worker = FoundationNativeDownloadDelegate(
                progress: progress, store: store, backgroundEventsFinished: { _ in },
                deferLiveRetirementUntilFinality: true,
                acknowledgedDelivery: { identifier in
                    await MainActor.run {
                        FoundationAppRuntime.model.finishBackgroundDownloadEvents(identifier)
                    }
                })
            // The delegate queue exists and is gated before either OS factory. A
            // crash after this durable phase can never be mistaken for no allocation.
            defer { worker.activateDelegateQueue() }
            do { try store.beginCreating() } catch {
                // Finite preflight may already have started this scoped conversion.
                // A creation write can commit before reporting an error; retain its
                // authority even if cancellation-independent server cleanup also fails.
                do {
                    try await closeConversion(
                        proposal.cleanupRequest, allowsCellular: allowsCellular)
                } catch {}
                throw FoundationDownloadError.cleanup
            }
            let configuration = URLSessionConfiguration.background(
                withIdentifier: sessionIdentifier)
            configuration.allowsCellularAccess = allowsCellular
            configuration.allowsExpensiveNetworkAccess = allowsCellular
            configuration.allowsConstrainedNetworkAccess = false
            configuration.isDiscretionary = false
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.httpAdditionalHeaders = ["Accept-Encoding": "identity"]
            let session = AVAssetDownloadURLSession(
                configuration: configuration, assetDownloadDelegate: worker,
                delegateQueue: worker.delegateQueue)
            defer { worker.requestFinality(session) }
            // Use the existing official authenticated HLS master boundary. Do not put
            // reserved Authorization headers in configuration or private AVAsset options.
            // The OS may retain this credential URL in private task/package metadata.
            let asset = AVURLAsset(url: nativeMaster)
            let download = AVAssetDownloadConfiguration(asset: asset, title: proposal.title)
            if let data = proposal.artwork, FoundationCurrentArtwork.decode(data) != nil {
                download.artworkData = data
            }
            let task: AVAssetDownloadTask
            do {
                task = try worker.makeTask(session: session) {
                    session.makeAssetDownloadTask(downloadConfiguration: download)
                }
            } catch {
                _ = await worker.finishAndAwaitFinality(session)
                // Creation/binding uncertainty remains cleanup even if the independent
                // scoped server conversion cleanup fails. Pending authority must survive.
                do {
                    try await closeConversion(
                        proposal.cleanupRequest, allowsCellular: allowsCellular)
                } catch {}
                throw FoundationDownloadError.cleanup
            }
            var acquired: FoundationNativeDownloadPackage?
            #if DEBUG
                var stage = "allocation"
            #endif
            do {
                let location = try await worker.run(task)
                #if DEBUG
                    stage = "receipt"
                #endif
                // Only the callback's durable, pre-completion identity can authorize this
                // allocation. Never create a replacement snapshot after a bookmark failure.
                let package = try store.completedPackage(taskIdentifier: task.taskIdentifier)
                guard package.nativeURL == location else { throw FoundationDownloadError.cleanup }
                acquired = package
                #if DEBUG
                    stage = "ownership"
                #endif
                guard let owned = package.resolveOwnedURL() else {
                    throw FoundationDownloadError.response
                }
                let local = AVURLAsset(
                    url: owned,
                    options: [
                        AVURLAssetReferenceRestrictionsKey:
                            NSNumber(
                                value: AVAssetReferenceRestrictions.forbidLocalReferenceToRemote
                                    .rawValue),
                        AVURLAssetAllowsCellularAccessKey: false,
                        AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                        AVURLAssetAllowsConstrainedNetworkAccessKey: false,
                    ])
                #if DEBUG
                    stage = "offline"
                #endif
                guard local.assetCache?.isPlayableOffline == true else {
                    throw FoundationDownloadError.incomplete
                }
                #if DEBUG
                    stage = "duration"
                #endif
                let duration = try await local.load(.duration).seconds
                let tolerance = min(1, max(0.1, proposal.plan.duration * 0.001))
                guard duration.isFinite, abs(duration - proposal.plan.duration) <= tolerance else {
                    throw FoundationDownloadError.incomplete
                }
                #if DEBUG
                    stage = "rendition"
                #endif
                let rendition = try await FoundationConvertedDownload.inspectNativePackage(
                    owned, plan: proposal.plan)
                // Public HLS metadata loading precedes the final security pass, so any
                // OS metadata created during validation is covered by the same leaf audit.
                // Verify all regular payload files and allocated bytes; root metadata alone
                // is insufficient. Only documented security metadata may be strengthened;
                // never lower protection or rewrite package payload/layout.
                #if DEBUG
                    stage = "protection"
                #endif
                try strengthenAllocationProtection(package)
                let bytes = try protectedAllocationBytes(owned)
                try Task.checkCancellation()
                #if DEBUG
                    stage = "conversionCleanup"
                #endif
                try await closeConversion(proposal.cleanupRequest, allowsCellular: allowsCellular)
                guard await worker.finishAndAwaitFinality(session) else {
                    throw FoundationDownloadError.cleanup
                }
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=complete outcome=success")
                    }
                #endif
                return .init(
                    name: UUID().uuidString + ".movpkg", bytes: bytes, digest: "",
                    nativePackage: package, nativeRendition: rendition)
            } catch {
                task.cancel()
                guard await worker.finishAndAwaitFinality(session) else {
                    throw FoundationDownloadError.cleanup
                }
                // No raw AV/HTTP error, header, URL or server response reaches product diagnostics.
                let failure =
                    error as? FoundationDownloadError
                    ?? (Task.isCancelled ? .cancelled : .network)
                #if DEBUG
                    if diagnosticEnabled {
                        FoundationJournal.shared.record(
                            "download.native stage=\(stage) primary=\(failure)")
                    }
                #endif
                if acquired == nil, worker.failedSession {
                    // Keep an unverified failed session's authority for scoped recovery.
                    // Server cleanup has its own bounded lifetime but cannot reclassify
                    // this as conversionCleanup and discard the pending receipt.
                    do {
                        try await closeConversion(
                            proposal.cleanupRequest, allowsCellular: allowsCellular)
                    } catch {
                        #if DEBUG
                            if diagnosticEnabled {
                                FoundationJournal.shared.record(
                                    "download.native stage=conversion.cleanup outcome=failed")
                            }
                        #endif
                    }
                    throw FoundationDownloadError.cleanup
                }
                if let acquired {
                    do {
                        try acquired.removeOwnedPackage()
                        try store.retire()
                    } catch {
                        #if DEBUG
                            if diagnosticEnabled {
                                FoundationJournal.shared.record(
                                    "download.native stage=allocation.cleanup outcome=failed")
                            }
                        #endif
                        throw FoundationDownloadError.cleanup
                    }
                } else {
                    // A receipt/identity failure is never recategorized as a network error.
                    do { try store.retire() } catch {
                        #if DEBUG
                            if diagnosticEnabled {
                                FoundationJournal.shared.record(
                                    "download.native stage=allocation.cleanup outcome=failed")
                            }
                        #endif
                        throw FoundationDownloadError.cleanup
                    }
                }
                do {
                    try await closeConversion(
                        proposal.cleanupRequest, allowsCellular: allowsCellular)
                } catch {
                    #if DEBUG
                        if diagnosticEnabled {
                            FoundationJournal.shared.record(
                                "download.native stage=conversion.cleanup outcome=failed")
                        }
                    #endif
                    throw FoundationDownloadError.conversionCleanup
                }
                if acquired == nil, let receipt = try? store.load(),
                    receipt.phase == .terminalNoAllocation, receipt.creationVersion == 1,
                    receipt.taskIdentifier == task.taskIdentifier, receipt.taskIdentifier > 0,
                    receipt.nativeURL == nil, receipt.package == nil,
                    receipt.namespaceBookmark == nil,
                    receipt.hasProvenRetirement
                {
                    await onTerminalNoAllocationFinality?(store.sessionIdentifier)
                }
                throw failure
            }
        #endif
    }

    private static func finiteMediaURL(
        _ proposal: FoundationNativeDownloadProposal, allowsCellular: Bool
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(
            configuration: configuration,
            delegate: FoundationNativeDownloadRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func playlist(_ url: URL, master: Bool) async throws -> String {
            var request = proposal.request
            request.url = url
            let (bytes, response) = try await session.bytes(for: request)
            #if DEBUG
                if diagnosticEnabled {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    FoundationJournal.shared.record(
                        "download.native stage=\(master ? "master" : "media").http status=\(status) sameURL=\(response.url == url ? 1 : 0)"
                    )
                }
            #endif
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                http.url == url
            else { throw FoundationDownloadError.response }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 512 * 1_024 else {
                    #if DEBUG
                        if diagnosticEnabled {
                            FoundationJournal.shared.record(
                                "download.native stage=body outcome=budget")
                        }
                    #endif
                    throw FoundationDownloadError.response
                }
                data.append(byte)
            }
            let text = String(data: data, encoding: .utf8)
            #if DEBUG
                if diagnosticEnabled {
                    FoundationJournal.shared.record(
                        "download.native stage=\(master ? "master" : "media").body utf8=\(text != nil ? 1 : 0) prefix=\(text?.hasPrefix("#EXTM3U") == true ? 1 : 0)"
                    )
                }
            #endif
            guard let text, text.hasPrefix("#EXTM3U") else {
                throw FoundationDownloadError.response
            }
            return text
        }
        let masterURL = proposal.request.url!
        let master = try await playlist(masterURL, master: true)
        let lines = master.split(whereSeparator: \.isNewline).map(String.init)
        let candidates = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #if DEBUG
            if diagnosticEnabled {
                FoundationJournal.shared.record(
                    "download.native stage=master.shape variants=\(min(candidates.count, 1_000)) rendition=\(lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") }) ? 1 : 0)"
                )
            }
        #endif
        guard candidates.count == 1, !lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:") })
        else {
            throw FoundationDownloadError.response
        }
        let media = try safeResource(candidates[0], relativeTo: masterURL)
        let text = try await playlist(media, master: false)
        do {
            try validateFinitePlaylist(text, base: media, expectedDuration: proposal.plan.duration)
            #if DEBUG
                if diagnosticEnabled {
                    FoundationJournal.shared.record(
                        "download.native stage=media.finite outcome=success")
                }
            #endif
        } catch {
            #if DEBUG
                if diagnosticEnabled {
                    FoundationJournal.shared.record(
                        "download.native stage=media.finite outcome=failed endlist=\(text.split(whereSeparator: \.isNewline).last == "#EXT-X-ENDLIST" ? 1 : 0)"
                    )
                }
            #endif
            throw error
        }
        return media
    }

    static func safeResource(_ value: String, relativeTo base: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
            let a = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let b = URLComponents(url: base, resolvingAgainstBaseURL: false),
            a.scheme == "https", a.host == b.host, a.port == b.port,
            a.user == nil, a.password == nil, a.fragment == nil,
            !(a.queryItems ?? []).contains(where: {
                ["api_key", "apikey", "token", "access_token", "authorization"].contains(
                    $0.name.lowercased())
            })
        else { throw FoundationDownloadError.response }
        return url
    }

    static func validateFinitePlaylist(_ text: String, base: URL, expectedDuration: Double) throws {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "#EXTM3U", lines.last == "#EXT-X-ENDLIST",
            !lines.contains(where: {
                $0.hasPrefix("#EXT-X-KEY:") || $0.hasPrefix("#EXT-X-SESSION-KEY:")
            })
        else { throw FoundationDownloadError.incomplete }
        var duration: Double = 0
        var segments = 0
        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                guard
                    let value = Double(
                        line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false)[0]
                    ),
                    value.isFinite, value > 0
                else { throw FoundationDownloadError.incomplete }
                duration += value
            } else if !line.hasPrefix("#"), !line.isEmpty {
                _ = try safeResource(line, relativeTo: base)
                segments += 1
            } else if line.hasPrefix("#EXT-X-MAP:") {
                guard let marker = line.range(of: "URI=\""),
                    let end = line[marker.upperBound...].firstIndex(of: "\"")
                else {
                    throw FoundationDownloadError.response
                }
                _ = try safeResource(String(line[marker.upperBound..<end]), relativeTo: base)
            }
        }
        let tolerance = min(1, max(0.1, expectedDuration * 0.001))
        guard segments > 0, duration.isFinite, abs(duration - expectedDuration) <= tolerance else {
            throw FoundationDownloadError.incomplete
        }
    }

    /// Reconnect only to opaque sessions recorded by this account. Interrupted acquisitions
    /// are cancelled and reconciled; they never become ready from a stale callback.
    static func retireInterruptedSessions(
        _ identifiers: Set<String>, directory: URL,
        mayRetire: @escaping @MainActor @Sendable () -> Bool,
        onFinality: (@Sendable (FoundationNativeAllocationStore) async throws -> Void)? = nil
    ) async -> Set<String> {
        var retired: Set<String> = []
        #if os(iOS)
            for identifier in identifiers {
                let store = FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier)
                guard store.validSession, !Task.isCancelled, await mayRetire() else { continue }
                let worker = FoundationNativeDownloadDelegate(
                    progress: { _, _ in }, store: store, backgroundEventsFinished: { _ in },
                    deferLiveRetirementUntilFinality: true,
                    acknowledgedDelivery: { identifier in
                        await MainActor.run {
                            FoundationAppRuntime.model.finishBackgroundDownloadEvents(identifier)
                        }
                    })
                let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
                let session = AVAssetDownloadURLSession(
                    configuration: configuration,
                    assetDownloadDelegate: worker, delegateQueue: worker.delegateQueue)
                do {
                    try await worker.retire(session, mayRetire: mayRetire) {
                        try await onFinality?(store)
                    }
                    retired.insert(identifier)
                } catch {
                    // Preserve this receipt; unrelated verified downloads remain usable.
                }
            }
        #endif
        return retired
    }

    /// Security metadata only. The immutable completed proof is never refreshed.
    static func strengthenAllocationProtection(
        _ package: FoundationNativeDownloadPackage,
        resolve: (FoundationNativeDownloadPackage) -> URL? = { $0.resolveOwnedURL() },
        resources: (URL) throws -> [URLResourceKey: Any] = { url in
            let fresh = NSURL(fileURLWithPath: url.path)
            fresh.removeAllCachedResourceValues()
            return try fresh.resourceValues(
                forKeys: FoundationManagedPackageMetadata.keys
                    + [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
        },
        protection: (URL) throws -> String? = { url in
            try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? String
        },
        setProtection: (URL) throws -> Void = { url in
            #if os(iOS)
                try (url as NSURL).setResourceValue(
                    URLFileProtection.completeUntilFirstUserAuthentication,
                    forKey: .fileProtectionKey)
            #else
                throw FoundationDownloadError.nativeProtection
            #endif
        }
    ) throws {
        #if DEBUG
            enum ProtectionStage: String {
                case ownership, metadata, validation, set, readback, finalProof
            }
            var diagnosticStage = ProtectionStage.ownership
            var diagnosticClass = ProtectionClass.unavailable
            func recordFailure(_ error: Error) {
                if diagnosticEnabled {
                    FoundationJournal.shared.record(
                        "download.native stage=protection.metadata substage=\(diagnosticStage.rawValue) outcome=failed class=\(diagnosticClass.rawValue) "
                            + FoundationNativeDownloadErrorFields.scalars(error))
                }
            }
        #endif
        do {
            typealias Metadata = FoundationManagedPackageMetadata
            try Task.checkCancellation()
            guard let resolvedRoot = resolve(package), Metadata.plain(resolvedRoot) else {
                throw FoundationDownloadError.nativeProtection
            }
            #if DEBUG
                diagnosticStage = .metadata
            #endif
            let original = try resources(resolvedRoot)
            // Canonicalization chooses an address, never authority. Before using it,
            // bind BOTH addresses to the same already-proved resource, then repeat.
            let freshRoot = NSURL(fileURLWithPath: resolvedRoot.path)
            freshRoot.removeAllCachedResourceValues()
            guard
                let canonicalPath = try freshRoot.resourceValues(forKeys: [.canonicalPathKey])[
                    .canonicalPathKey] as? String, canonicalPath.hasPrefix("/")
            else { throw FoundationDownloadError.nativeProtection }
            let root = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            guard Metadata.plain(root) else { throw FoundationDownloadError.nativeProtection }
            let initial = try resources(root)
            #if DEBUG
                diagnosticStage = .validation
            #endif
            func directory(_ data: [URLResourceKey: Any]) -> Bool {
                data[.isDirectoryKey] as? Bool == true && data[.isSymbolicLinkKey] as? Bool == false
            }
            func same(_ a: [URLResourceKey: Any], _ b: [URLResourceKey: Any]) -> Bool {
                let result = Metadata.comparison(a, b)
                return result.file == .equal && result.volume == .equal
                    && result.generation == .equal
            }
            let originalRepeat = try resources(resolvedRoot)
            let addressedRepeat = try resources(root)
            guard
                [original, initial, originalRepeat, addressedRepeat].allSatisfy({
                    directory($0) && same(original, $0)
                })
            else { throw FoundationDownloadError.nativeProtection }
            func authorityMatches() throws -> Bool {
                guard let current = resolve(package), Metadata.plain(current) else { return false }
                let first = try resources(current)
                let addressed = try resources(root)
                let repeatCurrent = try resources(current)
                let repeatAddressed = try resources(root)
                return [first, addressed, repeatCurrent, repeatAddressed].allSatisfy {
                    directory($0) && same(initial, $0)
                }
            }
            let failure = FoundationNativeDownloadEnumerationFailure()
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: nil, options: [],
                    errorHandler: { _, _ in
                        failure.record()
                        return false
                    })
            else { throw FoundationDownloadError.nativeProtection }
            var visited = 0
            var directories = [root.pathComponents: initial]
            func ancestorsMatch(_ url: URL) throws -> Bool {
                var ancestor =
                    Metadata.equalPath(url, root) ? root : url.deletingLastPathComponent()
                for _ in 0...url.pathComponents.count {
                    guard let saved = directories[ancestor.pathComponents] else { return false }
                    #if DEBUG
                        diagnosticStage = .metadata
                    #endif
                    let fresh = try resources(ancestor)
                    #if DEBUG
                        diagnosticStage = .validation
                    #endif
                    guard directory(fresh), same(saved, fresh) else { return false }
                    if Metadata.equalPath(ancestor, root) { return true }
                    ancestor = ancestor.deletingLastPathComponent()
                }
                return false
            }
            func unsupported(_ kind: ProtectionClass) throws {
                #if DEBUG
                    diagnosticClass = kind
                    diagnosticStage = .validation
                #endif
                throw FoundationDownloadError.nativeProtection
            }
            func strengthen(_ url: URL, isRoot: Bool = false) throws {
                try Task.checkCancellation()
                #if DEBUG
                    diagnosticStage = .ownership
                #endif
                guard Metadata.plain(url), isRoot || Metadata.contained(url, in: root),
                    !url.pathComponents.contains(".."), try authorityMatches()
                else { throw FoundationDownloadError.nativeProtection }
                guard try ancestorsMatch(url) else {
                    throw FoundationDownloadError.nativeProtection
                }
                #if DEBUG
                    diagnosticStage = .metadata
                #endif
                let before = try resources(url)
                #if DEBUG
                    diagnosticStage = .validation
                #endif
                guard before[.isSymbolicLinkKey] as? Bool == false,
                    directory(before) || before[.isRegularFileKey] as? Bool == true,
                    same(initial, try resources(root)), try ancestorsMatch(url)
                else { throw FoundationDownloadError.nativeProtection }
                #if DEBUG
                    diagnosticStage = .metadata
                #endif
                let kind = ProtectionClass(protection: try protection(url))
                #if DEBUG
                    diagnosticClass = kind
                    diagnosticStage = .validation
                #endif
                switch kind {
                case .none:
                    // Only explicit Class D may be strengthened. B/inactive/unknown are
                    // not ordered below C and must never be converted to C.
                    try Task.checkCancellation()
                    guard same(before, try resources(url)), try ancestorsMatch(url),
                        try authorityMatches()
                    else {
                        throw FoundationDownloadError.nativeProtection
                    }
                    // Protection is metadata: identity/generation checks cannot detect
                    // another owner's intervening class change. Recheck at this gate.
                    #if DEBUG
                        diagnosticStage = .metadata
                    #endif
                    let current = ProtectionClass(protection: try protection(url))
                    #if DEBUG
                        diagnosticClass = current
                        diagnosticStage = .validation
                    #endif
                    switch current {
                    case .none:
                        #if DEBUG
                            diagnosticStage = .set
                        #endif
                        try setProtection(url)
                        #if DEBUG
                            diagnosticStage = .readback
                        #endif
                        let readback = ProtectionClass(protection: try protection(url))
                        #if DEBUG
                            diagnosticClass = readback
                        #endif
                        guard readback == .untilFirstAuthentication || readback == .complete else {
                            throw FoundationDownloadError.nativeProtection
                        }
                    case .complete, .untilFirstAuthentication: break
                    default:
                        if !directory(before) { try unsupported(current) }
                    }
                case .complete, .untilFirstAuthentication: break
                default:
                    if !directory(before) { try unsupported(kind) }
                }
                try Task.checkCancellation()
                #if DEBUG
                    diagnosticStage = .validation
                #endif
                guard same(before, try resources(url)), same(initial, try resources(root)),
                    try ancestorsMatch(url), try authorityMatches()
                else { throw FoundationDownloadError.nativeProtection }
                if directory(before) { directories[url.pathComponents] = before }
            }
            try strengthen(root, isRoot: true)
            for case let entry as URL in enumerator {
                visited += 1
                guard visited <= 100_000 else { throw FoundationDownloadError.nativeProtection }
                try strengthen(entry.absoluteURL)
            }
            #if DEBUG
                diagnosticStage = .finalProof
            #endif
            guard !failure.failed, same(initial, try resources(root)), try authorityMatches()
            else {
                throw FoundationDownloadError.nativeProtection
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            #if DEBUG
                recordFailure(CancellationError())
            #endif
            throw CancellationError()
        } catch {
            #if DEBUG
                recordFailure(error)
            #endif
            throw FoundationDownloadError.nativeProtection
        }
    }

    enum ProtectionClass: String {
        case none, complete, untilFirstAuthentication, unlessOpen, whenInactive, unavailable, other
        init(protection: String?) {
            switch protection {
            case "NSFileProtectionNone": self = .none
            case "NSFileProtectionComplete": self = .complete
            case "NSFileProtectionCompleteUntilFirstUserAuthentication":
                self = .untilFirstAuthentication
            case "NSFileProtectionCompleteUnlessOpen": self = .unlessOpen
            case "NSFileProtectionCompleteWhenUserInactive": self = .whenInactive
            case nil: self = .unavailable
            default: self = .other
            }
        }
    }

    static func protectedAllocationBytes(_ root: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        let failure = FoundationNativeDownloadEnumerationFailure()
        guard
            try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true,
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { _, _ in
                    failure.record()
                    return false
                })
        else { throw FoundationDownloadError.storage }
        var bytes: Int64 = 0
        var regularFiles = 0
        var visited = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            guard visited <= 100_000 else { throw FoundationDownloadError.storage }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw FoundationDownloadError.storage }
            if values.isRegularFile == true {
                regularFiles += 1
                #if os(iOS)
                    let protection =
                        try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                        as? String
                    guard
                        protection
                            == FileProtectionType.completeUntilFirstUserAuthentication.rawValue
                            || protection == FileProtectionType.complete.rawValue
                    else {
                        throw FoundationDownloadError.nativeProtection
                    }
                #endif
                let allocated = Int64(
                    values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                let sum = bytes.addingReportingOverflow(allocated)
                guard allocated >= 0, !sum.overflow else { throw FoundationDownloadError.storage }
                bytes = sum.partialValue
            } else if values.isDirectory != true {
                throw FoundationDownloadError.storage
            }
        }
        guard !failure.failed, regularFiles > 0, bytes > 0 else {
            throw FoundationDownloadError.storage
        }
        return bytes
    }

    private static func closeConversion(_ request: URLRequest, allowsCellular: Bool) async throws {
        // Cleanup retains the existing converted transport's cancellation-independent lifetime.
        let task = Task.detached(priority: .utility) {
            try await closeConversionNow(request, allowsCellular: allowsCellular)
        }
        try await task.value
    }

    private static func closeConversionNow(_ request: URLRequest, allowsCellular: Bool) async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = allowsCellular
        configuration.allowsExpensiveNetworkAccess = allowsCellular
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let delegate = FoundationNativeDownloadRedirectGuard()
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode)
        else {
            throw FoundationDownloadError.conversionCleanup
        }
        var count = 0
        for try await _ in bytes {
            count += 1
            guard count <= 4_096 else { throw FoundationDownloadError.conversionCleanup }
        }
    }
}

/// Decline redirects rather than forwarding a private-library header to another origin.
nonisolated class FoundationNativeDownloadRedirectGuard: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

nonisolated final class FoundationNativeDownloadDelegate: FoundationNativeDownloadRedirectGuard,
    AVAssetDownloadDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var location: URL?
    private var cancelled = false
    private var retirement: CheckedContinuation<Void, Error>?
    private var cleanupFailed = false
    private var liveTaskIdentifier: Int?
    private var observedAllocation = false
    private var terminalResult: Result<URL, Error>?
    // nil = no final callback; true = systemic failure; false = explicit invalidation.
    private var invalidationFailed: Bool?
    var failedSession: Bool { lock.withLock { invalidationFailed == true } }
    private let progress: FoundationDownloadTransport.Progress
    private let store: FoundationNativeAllocationStore
    private let backgroundEventsFinished: @Sendable (String) -> Void
    private let acknowledgedDelivery: (@Sendable (String) async -> Void)?
    private let acknowledgedFinality: @Sendable (String) async -> Void
    private let deferLiveRetirementUntilFinality: Bool
    private let retireAllocation: @Sendable () throws -> Void
    private var deliveryTail: Task<Void, Never>?
    private var finality: Bool?
    private var finalityRequested = false
    private var finalityWaiters: [CheckedContinuation<Bool, Never>] = []
    #if FOUNDATION_ISOLATED_TEST_HOST
        var isolatedFinalityWaitStarted: (() -> Void)?
        var isolatedRetirementWaitStarted: (() -> Void)?
        var isolatedTerminalFailure: FoundationDownloadError? {
            lock.withLock {
                guard case .failure(let error)? = terminalResult else { return nil }
                return error as? FoundationDownloadError
            }
        }
    #endif
    let delegateQueue: OperationQueue
    private var boundTask: URLSessionTask?
    private var ownedSession: URLSession?
    private var completionClaimed = false
    private let announceAllocation:
        @Sendable (FoundationNativeAllocationStore, URL, Int) throws -> Void
    private let sealAllocation: @Sendable (FoundationNativeAllocationStore, URL, Int) throws -> Void

    init(
        progress: @escaping FoundationDownloadTransport.Progress,
        store: FoundationNativeAllocationStore,
        announceAllocation:
            @escaping @Sendable (FoundationNativeAllocationStore, URL, Int) throws -> Void = {
                try $0.announce($1, taskIdentifier: $2)
            },
        sealAllocation:
            @escaping @Sendable (FoundationNativeAllocationStore, URL, Int) throws -> Void = {
                try $0.sealAnnouncement($1, taskIdentifier: $2)
            },
        backgroundEventsFinished: @escaping @Sendable (String) -> Void = { identifier in
            Task { @MainActor in
                FoundationAppRuntime.model.finishBackgroundDownloadEvents(identifier)
            }
        },
        deferLiveRetirementUntilFinality: Bool = false,
        acknowledgedDelivery: (@Sendable (String) async -> Void)? = nil,
        acknowledgedFinality: @escaping @Sendable (String) async -> Void = { _ in
            await MainActor.run {}
        },
        retireAllocation: (@Sendable () throws -> Void)? = nil
    ) {
        self.progress = progress
        self.store = store
        self.backgroundEventsFinished = backgroundEventsFinished
        self.acknowledgedDelivery = acknowledgedDelivery
        self.acknowledgedFinality = acknowledgedFinality
        self.deferLiveRetirementUntilFinality = deferLiveRetirementUntilFinality
        self.retireAllocation = retireAllocation ?? { @Sendable in try store.retire() }
        self.announceAllocation = announceAllocation
        self.sealAllocation = sealAllocation
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        self.delegateQueue = queue
    }

    func activateDelegateQueue() { delegateQueue.isSuspended = false }

    /// The factory returns the sole task whose ID may become this delegate's binding.
    /// No delegate event may run before binding and continuation/resume preparation.
    func makeTask<T: URLSessionTask>(session: URLSession, _ factory: () -> T) throws -> T {
        var made: T?
        do {
            guard delegateQueue.isSuspended, !failedSession else {
                throw FoundationDownloadError.cleanup
            }
            let receipt = try store.load()
            guard receipt.phase == .creating, receipt.creationVersion == 1,
                receipt.taskIdentifier == 0, receipt.nativeURL == nil,
                receipt.package == nil, receipt.retired != true
            else { throw FoundationDownloadError.cleanup }
            lock.withLock { ownedSession = session }
            let task = factory()
            made = task
            try store.bindCreatedTask(taskIdentifier: task.taskIdentifier)
            lock.withLock {
                boundTask = task
                liveTaskIdentifier = task.taskIdentifier
            }
            return task
        } catch {
            made?.cancel()
            activateDelegateQueue()
            throw FoundationDownloadError.cleanup
        }
    }

    private func deliverBackgroundEvents() -> Task<Void, Never>? {
        backgroundEventsFinished(store.sessionIdentifier)
        guard let acknowledgedDelivery else { return nil }
        let identifier = store.sessionIdentifier
        return lock.withLock {
            let previous = deliveryTail
            let next = Task {
                await previous?.value
                await acknowledgedDelivery(identifier)
            }
            deliveryTail = next
            return next
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        _ = deliverBackgroundEvents()
    }

    /// Final invalidation is an owner-lifetime boundary, not the OS event-drain signal.
    /// Join any earlier drain delivery and a separate main-actor barrier in order.
    private func acknowledgeFinalInvalidation() -> Task<Void, Never> {
        let identifier = store.sessionIdentifier
        let acknowledge = acknowledgedFinality
        return lock.withLock {
            let previous = deliveryTail
            let next = Task {
                await previous?.value
                await acknowledge(identifier)
            }
            deliveryTail = next
            return next
        }
    }

    func requestFinality(_ session: URLSession) {
        activateDelegateQueue()
        let request = lock.withLock { () -> Bool in
            guard !finalityRequested, invalidationFailed == nil else { return false }
            finalityRequested = true
            return true
        }
        if request { session.finishTasksAndInvalidate() }
    }

    /// A cancelled waiter cannot turn an unfinished native session into cleanup authority.
    func finishAndAwaitFinality(_ session: URLSession) async -> Bool {
        requestFinality(session)
        return await withCheckedContinuation { continuation in
            let completed = lock.withLock { () -> Bool? in
                if let finality { return finality }
                finalityWaiters.append(continuation)
                #if FOUNDATION_ISOLATED_TEST_HOST
                    isolatedFinalityWaitStarted?()
                #endif
                return nil
            }
            if let completed { continuation.resume(returning: completed) }
        }
    }

    private func completeFinality(_ succeeded: Bool) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            guard finality == nil else { return [] }
            finality = succeeded
            let waiters = finalityWaiters
            finalityWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: succeeded) }
    }

    func retire(
        _ session: URLSession, mayRetire: @escaping @MainActor @Sendable () -> Bool,
        onFinality: (@Sendable () async throws -> Void)? = nil
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            // Cold reconnection must attach retirement before delivering its events.
            defer { activateDelegateQueue() }
            let invalidated = lock.withLock { () -> Bool? in
                if let invalidationFailed { return invalidationFailed }
                ownedSession = session
                retirement = continuation
                #if FOUNDATION_ISOLATED_TEST_HOST
                    isolatedRetirementWaitStarted?()
                #endif
                return nil
            }
            if let invalidated {
                if invalidated {
                    continuation.resume(throwing: FoundationDownloadError.cleanup)
                } else {
                    continuation.resume()
                }
                return
            }
            session.getAllTasks { tasks in
                for task in tasks { task.cancel() }
                session.finishTasksAndInvalidate()
            }
        }
        // The final delegate callback alone does not join its model delivery. Retain
        // the session and receipt until both finality and the scoped owner check hold.
        guard await finishAndAwaitFinality(session), !Task.isCancelled,
            await mayRetire(), !Task.isCancelled
        else { throw FoundationDownloadError.cleanup }
        try await onFinality?()
        guard !Task.isCancelled, await mayRetire(), !Task.isCancelled else {
            throw FoundationDownloadError.cleanup
        }
        try retireAllocation()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        // Public NSURLSession.h declares this the final session message, including
        // systemic errors. Terminal delivery is not proof of a successful task,
        // allocation absence, package eligibility, deletion or retirement.
        let result = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
            guard invalidationFailed == nil else { return (false, nil) }
            invalidationFailed = error != nil
            let pending = retirement
            retirement = nil
            return (true, pending)
        }
        guard result.0 else { return }
        defer {
            let acknowledgement = acknowledgeFinalInvalidation()
            let succeeded = error == nil
            Task {
                await acknowledgement.value
                completeFinality(succeeded)
            }
        }
        if error != nil {
            // Retain the exact receipt. A final session error does not provide the
            // original live task's no-allocation callback history or cleanup proof.
            result.1?.resume(throwing: FoundationDownloadError.cleanup)
            complete(.failure(FoundationDownloadError.cleanup))
            return
        }
        result.1?.resume()
    }

    func run(_ task: URLSessionTask) async throws -> URL {
        guard !failedSession, lock.withLock({ boundTask === task }) else {
            // Cancel only the task returned by our factory, never adopt the argument.
            lock.withLock { boundTask }?.cancel()
            activateDelegateQueue()
            throw FoundationDownloadError.cleanup
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // This scope does not await delegate delivery. Every setup, cancel,
                // write-failure and early-result exit releases the queue before waiting.
                defer { activateDelegateQueue() }
                let state = lock.withLock { () -> (Result<URL, Error>?, Bool) in
                    if let result = terminalResult { return (result, cancelled) }
                    self.continuation = continuation
                    return (nil, cancelled)
                }
                if let result = state.0 {
                    continuation.resume(with: result)
                    return
                }
                if state.1 {
                    task.cancel()
                    return
                }
                do {
                    // A process lost after this phase cannot infer "no allocation".
                    let shouldResume = try lock.withLock {
                        guard !cancelled, terminalResult == nil else { return false }
                        // Serialize this write with the terminal callback's state read;
                        // cancellation cannot overwrite a terminal tombstone with resuming.
                        try store.beginResuming(taskIdentifier: task.taskIdentifier)
                        return true
                    }
                    if shouldResume { task.resume() } else { task.cancel() }
                } catch {
                    #if DEBUG
                        if FoundationNativeDownloadTransport.diagnosticEnabled {
                            FoundationJournal.shared.record(
                                FoundationNativeDownloadErrorFields.persistence(
                                    stage: .beginResuming, error: error))
                        }
                    #endif
                    lock.withLock { cleanupFailed = true }
                    task.cancel()
                }
            }
        } onCancel: {
            self.lock.withLock { self.cancelled = true }
            // Await the actual terminal callback, including cancellation before resume.
            task.cancel()
        }
    }

    private func complete(_ result: Result<URL, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard terminalResult == nil else { return nil }
            terminalResult = result
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }

    /// Accept Foundation's supplied local-file base representation, without inventing
    /// a base or reconstructing/canonicalizing a path. Stored URLs remain strict.
    static func validatedCallbackURL(_ location: URL) throws -> URL {
        var entry: URL? = location
        var count = 0
        while let current = entry {
            guard count < 8, current.isFileURL,
                current.scheme?.lowercased() == "file", current.path.hasPrefix("/"),
                current.host == nil || current.host == ""
                    || current.host?.lowercased() == "localhost",
                current.user == nil, current.password == nil,
                current.query == nil, current.fragment == nil
            else { throw FoundationDownloadError.cleanup }
            count += 1
            entry = current.baseURL
        }
        let absolute = location.absoluteURL
        guard FoundationManagedPackageMetadata.plain(absolute) else {
            throw FoundationDownloadError.cleanup
        }
        return absolute
    }

    /// Announcement seam shared with native-free lifecycle tests. It never accesses
    /// the destination resource; only the exact issued URL and owned parent are pinned.
    func recordAnnouncement(_ location: URL, session: URLSession, task: URLSessionTask) throws {
        let matched = lock.withLock { () -> Bool in
            guard ownedSession === session, liveTaskIdentifier == task.taskIdentifier,
                boundTask != nil, retirement == nil
            else { return false }
            observedAllocation = true
            return true
        }
        guard matched else { throw FoundationDownloadError.cleanup }
        let absolute: URL
        do { absolute = try Self.validatedCallbackURL(location) } catch {
            #if DEBUG
                if FoundationNativeDownloadTransport.diagnosticEnabled {
                    FoundationJournal.shared.record(
                        FoundationNativeDownloadErrorFields.capture(
                            stage: .initialURL, location: location))
                }
            #endif
            throw error
        }
        try announceAllocation(store, absolute, task.taskIdentifier)
        lock.withLock { self.location = absolute }
    }

    func urlSession(
        _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard
            lock.withLock({
                ownedSession === session && liveTaskIdentifier == assetDownloadTask.taskIdentifier
            })
        else { return }
        do { try recordAnnouncement(location, session: session, task: assetDownloadTask) } catch {
            lock.withLock { cleanupFailed = true }
            assetDownloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        #if DEBUG
            if FoundationNativeDownloadTransport.diagnosticEnabled, let error {
                FoundationJournal.shared.record(
                    "download.native stage=allocation.callback \(FoundationNativeDownloadErrorFields.scalars(error))"
                )
            }
        #endif
        // The public task ID is scoped to its one owned session. Do not require the
        // callback's Swift task wrapper to be identical to our factory wrapper.
        guard
            lock.withLock({
                ownedSession === session && liveTaskIdentifier == task.taskIdentifier
                    && terminalResult == nil && !completionClaimed
            })
        else { return }
        // Do not let a duplicate/stale task callback manufacture terminal proof after
        // the session has already failed. The original authority stays untouched.
        if failedSession {
            complete(.failure(FoundationDownloadError.cleanup))
            return
        }
        // Cold retirement deliberately cannot manufacture terminal-no-allocation proof.
        if lock.withLock({ retirement != nil }) { return }
        #if DEBUG
            var diagnosticCleanupFailed = false
        #endif
        let state = lock.withLock {
            #if DEBUG
                diagnosticCleanupFailed = cleanupFailed
            #endif
            return (liveTaskIdentifier, observedAllocation, location, cancelled, cleanupFailed)
        }
        #if DEBUG
            if FoundationNativeDownloadTransport.diagnosticEnabled {
                FoundationJournal.shared.record(
                    FoundationNativeDownloadErrorFields.terminal(
                        taskMatches: state.0 == task.taskIdentifier,
                        observedAllocation: state.1, cleanupFailed: diagnosticCleanupFailed))
            }
        #endif
        do {
            if state.0 == task.taskIdentifier && !state.1 {
                try store.recordTerminalNoAllocation(taskIdentifier: task.taskIdentifier)
            }
            if error != nil || state.3 || state.4 {
                if !deferLiveRetirementUntilFinality { try store.retire() }
                let nativeError = error as NSError?
                let failure: FoundationDownloadError
                if state.4 {
                    failure = .cleanup
                } else if state.3
                    || (nativeError?.domain == NSURLErrorDomain
                        && nativeError?.code == NSURLErrorCancelled)
                {
                    failure = .cancelled
                } else {
                    failure = .network
                }
                complete(.failure(failure))
            } else if state.2 != nil {
                var pending: CheckedContinuation<URL, Error>?
                let sealed = try lock.withLock { () throws -> URL in
                    guard ownedSession === session, liveTaskIdentifier == task.taskIdentifier,
                        boundTask != nil, observedAllocation, !cancelled, !cleanupFailed,
                        invalidationFailed != true, retirement == nil,
                        terminalResult == nil, !completionClaimed, let location
                    else { throw FoundationDownloadError.cleanup }
                    completionClaimed = true
                    // One synchronous proof/publication linearizes with cancellation.
                    // No other task, cold owner or duplicate callback can create it.
                    try sealAllocation(store, location, task.taskIdentifier)
                    terminalResult = .success(location)
                    pending = continuation
                    continuation = nil
                    return location
                }
                pending?.resume(returning: sealed)
            } else {
                if !deferLiveRetirementUntilFinality { try store.retire() }
                complete(.failure(FoundationDownloadError.incomplete))
            }
        } catch { complete(.failure(FoundationDownloadError.cleanup)) }
    }
}

#if DEBUG
    /// Fixed scalar formatting only, not a logger. Unknown domains/codes become other/0.
    /// Inspect exactly one underlying error; descriptions and all other userInfo stay private.
    nonisolated enum FoundationNativeDownloadErrorFields {
        private static func recognized(_ error: NSError?) -> (domain: String, code: Int) {
            guard let error else { return ("other", 0) }
            switch error.domain {
            case NSURLErrorDomain: return ("URL", error.code)
            case AVFoundationErrorDomain: return ("AVFoundation", error.code)
            case NSOSStatusErrorDomain: return ("OSStatus", error.code)
            case NSCocoaErrorDomain: return ("Cocoa", error.code)
            case NSPOSIXErrorDomain: return ("POSIX", error.code)
            default: return ("other", 0)
            }
        }

        enum CaptureStage: String, CaseIterable {
            case initialURL, session, task, existingReceipt, binding, allocatedWrite
            case namespace, parentBookmark, completionClaim, packageBookmark, ownershipProof,
                packageWrite
        }

        struct Binding {
            let taskZero: Bool
            let taskMatches: Bool
            let urlPresent: Bool
            let urlMatches: Bool
            let retired: Bool
            let phase: FoundationNativeAllocationStore.Receipt.Phase?
            var fields: String {
                "taskZero=\(taskZero ? 1 : 0) taskMatches=\(taskMatches ? 1 : 0) urlPresent=\(urlPresent ? 1 : 0) urlMatches=\(urlMatches ? 1 : 0) retired=\(retired ? 1 : 0) phase=\(phase?.rawValue ?? "missing")"
            }
        }

        enum PersistenceStage: String {
            case allocatedWrite, parentBookmark, packageWrite, beginResuming
        }

        static func capture(
            stage: CaptureStage, location: URL, writeError: Error? = nil, binding: Binding? = nil
        ) -> String {
            // Project booleans only. Never interpolate the URL or any component text.
            let shape =
                "download.native stage=allocation.capture substage=\(stage.rawValue) outcome=failed fileURL=\(location.isFileURL ? 1 : 0) basePresent=\(location.baseURL != nil ? 1 : 0) plain=\(FoundationManagedPackageMetadata.plain(location) ? 1 : 0)"
            let fields = binding.map { shape + " " + $0.fields } ?? shape
            return writeError.map { fields + " " + scalars($0) } ?? fields
        }

        static func persistence(stage: PersistenceStage, error: Error) -> String {
            "download.native stage=allocation.persistence substage=\(stage.rawValue) "
                + scalars(error)
        }

        static func terminal(taskMatches: Bool, observedAllocation: Bool, cleanupFailed: Bool)
            -> String
        {
            "download.native stage=allocation.terminal taskMatches=\(taskMatches ? 1 : 0) observedAllocation=\(observedAllocation ? 1 : 0) cleanupFailed=\(cleanupFailed ? 1 : 0)"
        }

        static func scalars(_ error: Error) -> String {
            let native = error as NSError
            let primary = recognized(native)
            let underlying = recognized(native.userInfo[NSUnderlyingErrorKey] as? NSError)
            return
                "domain=\(primary.domain) code=\(primary.code) underlyingDomain=\(underlying.domain) underlyingCode=\(underlying.code)"
        }
    }
#endif
nonisolated private final class FoundationNativeDownloadEnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var failed: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

nonisolated enum FoundationNativeEmptySessionOutcome: Sendable, Equatable {
    case quiescent
    case observedNativeWork
    case unavailable
}

/// Evidence reducer for the proposed nonmutating empty-session reconciliation.
/// It does not create a session, query account data, own a native task, or authorize
/// any storage mutation. A caller must independently fence account/storage identity.
nonisolated final class FoundationNativeEmptySessionEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var inventoryRecorded = false
    private var emptyInventory = false
    private var drainDelivered: Bool
    private var drainAcknowledged: Bool
    private var invalidationRecorded = false
    private var successfulInvalidation = false
    private var finalityAcknowledged = false
    private var disqualified = false
    private var observedNativeWork = false

    /// Prior acknowledgement is admissible only for this exact pending event in
    /// the current model, from a real native delivery already joined on MainActor.
    /// No persisted marker, empty inventory, or previous process can supply it.
    init(priorDrainAcknowledged: Bool = false) {
        drainDelivered = priorDrainAcknowledged
        drainAcknowledged = priorDrainAcknowledged
    }

    func recordInventory(count: Int) {
        lock.lock()
        defer { lock.unlock() }
        if inventoryRecorded || invalidationRecorded { disqualified = true }
        inventoryRecorded = true
        emptyInventory = count == 0
        if count != 0 {
            disqualified = true
            observedNativeWork = true
        }
    }

    func observeTaskAllocationOrChallenge() {
        lock.lock()
        disqualified = true
        observedNativeWork = true
        lock.unlock()
    }

    func recordDrainDelivery() {
        lock.lock()
        if invalidationRecorded { disqualified = true }
        drainDelivered = true
        lock.unlock()
    }

    func acknowledgeDrainDelivery() {
        lock.lock()
        if !drainDelivered { disqualified = true }
        drainAcknowledged = drainDelivered
        lock.unlock()
    }

    func recordInvalidation(succeeded: Bool) {
        lock.lock()
        if invalidationRecorded || !inventoryRecorded { disqualified = true }
        invalidationRecorded = true
        successfulInvalidation = succeeded
        if !succeeded { disqualified = true }
        lock.unlock()
    }

    func acknowledgeFinality() {
        lock.lock()
        if !invalidationRecorded { disqualified = true }
        finalityAcknowledged = invalidationRecorded
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        disqualified = true
        lock.unlock()
    }

    var outcome: FoundationNativeEmptySessionOutcome {
        lock.lock()
        defer { lock.unlock() }
        if observedNativeWork { return .observedNativeWork }
        return inventoryRecorded && emptyInventory && invalidationRecorded
            && successfulInvalidation && finalityAcknowledged && !disqualified
            ? .quiescent : .unavailable
    }

    /// Contract-derived quiescence of an observed empty native session. This is
    /// separate from the actual URLSessionDidFinishEvents delivery signal.
    var isQuiescentEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inventoryRecorded && emptyInventory && invalidationRecorded
            && successfulInvalidation && finalityAcknowledged && !disqualified
    }

    var isSuccessful: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inventoryRecorded && emptyInventory && drainDelivered && drainAcknowledged
            && invalidationRecorded && successfulInvalidation && finalityAcknowledged
            && !disqualified
    }
}

/// One owned nonmutating observation. Even a failed/nonempty observation retains
/// its exact session through final invalidation; cancellation never cancels tasks.
nonisolated private final class FoundationNativeEmptySessionDelegate: NSObject,
    AVAssetDownloadDelegate, @unchecked Sendable
{
    let delegateQueue: OperationQueue
    private let lock = NSLock()
    private let evidence = FoundationNativeEmptySessionEvidence()
    private let drained: @MainActor @Sendable () -> Void
    private var session: AVAssetDownloadURLSession?
    private var continuation: CheckedContinuation<FoundationNativeEmptySessionOutcome, Never>?
    private var deliveryTail: Task<Void, Never>?
    private var invalidationClaimed = false

    init(drained: @escaping @MainActor @Sendable () -> Void) {
        self.drained = drained
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        delegateQueue = queue
    }

    func observe(_ session: AVAssetDownloadURLSession) async -> FoundationNativeEmptySessionOutcome
    {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.session = session
                    self.continuation = continuation
                }
                delegateQueue.isSuspended = false
                session.getAllTasks { [self] tasks in
                    evidence.recordInventory(count: tasks.count)
                    // Graceful invalidation does not cancel unexpected existing
                    // tasks. The owner stays alive until their final callback.
                    session.finishTasksAndInvalidate()
                }
            }
        } onCancel: {
            self.evidence.cancel()
        }
    }

    private func owns(_ value: URLSession) -> Bool {
        let matched = lock.withLock { session === value }
        if !matched { evidence.observeTaskAllocationOrChallenge() }
        return matched
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard owns(session) else { return }
        evidence.recordDrainDelivery()
        let delivered = drained
        lock.withLock {
            let previous = deliveryTail
            deliveryTail = Task { [self] in
                await previous?.value
                await delivered()
                evidence.acknowledgeDrainDelivery()
            }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        guard owns(session) else { return }
        let claimed = lock.withLock { () -> Bool in
            guard !invalidationClaimed else { return false }
            invalidationClaimed = true
            return true
        }
        guard claimed else { return }
        evidence.recordInvalidation(succeeded: error == nil)
        lock.withLock {
            let previous = deliveryTail
            deliveryTail = Task { [self] in
                await previous?.value
                await MainActor.run {}
                evidence.acknowledgeFinality()
                let result = evidence.outcome
                let pending = lock.withLock {
                    () -> CheckedContinuation<FoundationNativeEmptySessionOutcome, Never>? in
                    let value = continuation
                    continuation = nil
                    self.session = nil
                    deliveryTail = nil
                    return value
                }
                pending?.resume(returning: result)
            }
        }
    }

    func urlSession(
        _ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
        willDownloadTo location: URL
    ) {
        guard owns(session) else { return }
        evidence.observeTaskAllocationOrChallenge()
        // The supplied location is deliberately never inspected or persisted.
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard owns(session) else { return }
        evidence.observeTaskAllocationOrChallenge()
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        _ = owns(session)
        evidence.observeTaskAllocationOrChallenge()
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        _ = owns(session)
        evidence.observeTaskAllocationOrChallenge()
        completionHandler(.performDefaultHandling, nil)
    }
}
