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

    var errorDescription: String? {
        switch self {
        case .unsupported: "This original file cannot be downloaded for native playback."
        case .permission: "The server did not allow this download."
        case .response: "The download response could not be verified."
        case .incomplete: "The downloaded file is incomplete or cannot be played."
        case .storage: "The download could not be saved. Check available storage and retry."
        case .cleanup: "An incomplete download could not be removed. Retry storage cleanup."
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
