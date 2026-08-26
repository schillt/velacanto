import Foundation

#if DEBUG
    extension VelacantoNetworkPolicy {
        private static let sharedLock = NSLock()
        nonisolated(unsafe) private static var sharedInstance =
            VelacantoNetworkPolicy()

        static var shared: VelacantoNetworkPolicy {
            sharedLock.withLock { sharedInstance }
        }

        static func resetSharedForTesting() {
            sharedLock.withLock {
                sharedInstance = VelacantoNetworkPolicy()
            }
        }
    }
#endif

final class VelacantoNetworkMetricsDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    static let shared = VelacantoNetworkMetricsDelegate()
    private override init() {}

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let duration = metrics.taskInterval.duration
        guard duration >= 0.75 else { return }
        let snapshot = PlaybackNetworkMetricSnapshot(metrics: metrics)
        let event = PlaybackMetricJournalFormatter.appNetwork(
            kind: Self.diagnosticRequestKind(
                for: task.originalRequest ?? task.currentRequest
            ),
            ordinal: task.taskIdentifier,
            snapshot: snapshot
        )
        PlaybackDiagnosticJournal.shared.record(event)
    }

    nonisolated static func diagnosticRequestKind(
        for request: URLRequest?
    ) -> PlaybackNetworkRequestMetricKind {
        let components = request?.url?.pathComponents ?? []
        if components.last?.caseInsensitiveCompare("PlaybackInfo")
            == .orderedSame
        {
            return .playbackInfo
        }
        if components.suffix(2).map({ $0.lowercased() }) == ["users", "me"] {
            return .sessionValidation
        }
        if components.contains(where: {
            $0.caseInsensitiveCompare("Images") == .orderedSame
        }) {
            return .artwork
        }
        if components.contains(where: {
            $0.caseInsensitiveCompare("Playing") == .orderedSame
                || $0.caseInsensitiveCompare("PlayingProgress") == .orderedSame
                || $0.caseInsensitiveCompare("PlayingStopped") == .orderedSame
        }) {
            return .playbackReport
        }
        return .app
    }
}

struct VelacantoNetworkTransportFailure: Error {
    let underlying: any Error
}

struct VelacantoNetworkTransportSuppressed: Error {}
