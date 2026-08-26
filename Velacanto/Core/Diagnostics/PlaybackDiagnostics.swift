import Foundation

enum PlaybackMediaMetricRole: String, Equatable, Sendable {
    case current
    case staged
}

struct PlaybackMediaMetricClaim: Equatable, Sendable {
    let generation: Int
    let role: PlaybackMediaMetricRole
    let requestOrdinal: Int
    let itemStartedAt: Date
}

/// Thread-safe ownership for one AVPlayerItem's metric events.
///
/// Native metric callbacks may arrive after the main-actor player has promoted
/// or removed an item. Claiming an event atomically snapshots its current role
/// and generation, while deactivation rejects callbacks after removal.
final class PlaybackMediaMetricContextOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: Int
    private var role: PlaybackMediaMetricRole
    private var nextRequestOrdinal = 1
    private var isActive = true
    private let itemStartedAt: Date

    init(
        generation: Int,
        role: PlaybackMediaMetricRole,
        itemStartedAt: Date = Date()
    ) {
        self.generation = generation
        self.role = role
        self.itemStartedAt = itemStartedAt
    }

    func update(generation: Int, role: PlaybackMediaMetricRole) {
        lock.withLock {
            guard isActive else { return }
            self.generation = generation
            self.role = role
        }
    }

    func claimNextRequest() -> PlaybackMediaMetricClaim? {
        lock.withLock {
            guard isActive else { return nil }
            let claim = PlaybackMediaMetricClaim(
                generation: generation,
                role: role,
                requestOrdinal: nextRequestOrdinal,
                itemStartedAt: itemStartedAt
            )
            nextRequestOrdinal += 1
            return claim
        }
    }

    func deactivate() {
        lock.withLock {
            isActive = false
        }
    }
}

enum PlaybackNetworkMetricProtocol: String, Equatable, Sendable {
    case unavailable
    case http1 = "http1"
    case http2 = "h2"
    case http3 = "h3"
    case quic
    case other

    init(nativeValue: String?) {
        switch nativeValue?.lowercased() {
        case nil, "": self = .unavailable
        case "http/1.0", "http/1.1": self = .http1
        case "h2": self = .http2
        case "h3": self = .http3
        case "quic": self = .quic
        default: self = .other
        }
    }
}

enum PlaybackNetworkMetricFetchType: String, Equatable, Sendable {
    case unavailable
    case unknown
    case network
    case cache
    case serverPush = "server-push"
    case future

    init(nativeValue: URLSessionTaskMetrics.ResourceFetchType?) {
        guard let nativeValue else {
            self = .unavailable
            return
        }
        switch nativeValue {
        case .unknown: self = .unknown
        case .networkLoad: self = .network
        case .localCache: self = .cache
        case .serverPush: self = .serverPush
        @unknown default: self = .future
        }
    }
}

struct PlaybackNetworkMetricSnapshot: Equatable, Sendable {
    let totalMilliseconds: Int64
    let fetchMilliseconds: Int64
    let dnsMilliseconds: Int64
    let connectMilliseconds: Int64
    let tlsMilliseconds: Int64
    let requestMilliseconds: Int64
    let timeToFirstByteMilliseconds: Int64
    let responseMilliseconds: Int64
    let transactionCount: Int
    let statusCode: Int
    let networkProtocol: PlaybackNetworkMetricProtocol
    let fetchType: PlaybackNetworkMetricFetchType
    let reusedConnection: Bool?
    let proxyConnection: Bool?
    let cellular: Bool?
    let constrained: Bool?
    let expensive: Bool?

    init(
        totalMilliseconds: Int64,
        fetchMilliseconds: Int64,
        dnsMilliseconds: Int64,
        connectMilliseconds: Int64,
        tlsMilliseconds: Int64,
        requestMilliseconds: Int64,
        timeToFirstByteMilliseconds: Int64,
        responseMilliseconds: Int64,
        transactionCount: Int,
        statusCode: Int,
        networkProtocol: PlaybackNetworkMetricProtocol,
        fetchType: PlaybackNetworkMetricFetchType,
        reusedConnection: Bool?,
        proxyConnection: Bool?,
        cellular: Bool?,
        constrained: Bool?,
        expensive: Bool?
    ) {
        self.totalMilliseconds = totalMilliseconds
        self.fetchMilliseconds = fetchMilliseconds
        self.dnsMilliseconds = dnsMilliseconds
        self.connectMilliseconds = connectMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.requestMilliseconds = requestMilliseconds
        self.timeToFirstByteMilliseconds = timeToFirstByteMilliseconds
        self.responseMilliseconds = responseMilliseconds
        self.transactionCount = transactionCount
        self.statusCode = statusCode
        self.networkProtocol = networkProtocol
        self.fetchType = fetchType
        self.reusedConnection = reusedConnection
        self.proxyConnection = proxyConnection
        self.cellular = cellular
        self.constrained = constrained
        self.expensive = expensive
    }

    static let unavailable = PlaybackNetworkMetricSnapshot(
        totalMilliseconds: -1,
        fetchMilliseconds: -1,
        dnsMilliseconds: -1,
        connectMilliseconds: -1,
        tlsMilliseconds: -1,
        requestMilliseconds: -1,
        timeToFirstByteMilliseconds: -1,
        responseMilliseconds: -1,
        transactionCount: 0,
        statusCode: 0,
        networkProtocol: .unavailable,
        fetchType: .unavailable,
        reusedConnection: nil,
        proxyConnection: nil,
        cellular: nil,
        constrained: nil,
        expensive: nil
    )

    init(metrics: URLSessionTaskMetrics?) {
        guard let metrics else {
            self = .unavailable
            return
        }
        let transaction = metrics.transactionMetrics.last
        totalMilliseconds = Self.milliseconds(metrics.taskInterval.duration)
        fetchMilliseconds = Self.milliseconds(
            from: transaction?.fetchStartDate,
            to: transaction?.responseEndDate
        )
        dnsMilliseconds = Self.milliseconds(
            from: transaction?.domainLookupStartDate,
            to: transaction?.domainLookupEndDate
        )
        connectMilliseconds = Self.milliseconds(
            from: transaction?.connectStartDate,
            to: transaction?.connectEndDate
        )
        tlsMilliseconds = Self.milliseconds(
            from: transaction?.secureConnectionStartDate,
            to: transaction?.secureConnectionEndDate
        )
        requestMilliseconds = Self.milliseconds(
            from: transaction?.requestStartDate,
            to: transaction?.requestEndDate
        )
        timeToFirstByteMilliseconds = Self.milliseconds(
            from: transaction?.requestEndDate,
            to: transaction?.responseStartDate
        )
        responseMilliseconds = Self.milliseconds(
            from: transaction?.responseStartDate,
            to: transaction?.responseEndDate
        )
        transactionCount = metrics.transactionMetrics.count
        statusCode =
            (transaction?.response as? HTTPURLResponse)?.statusCode ?? 0
        networkProtocol = PlaybackNetworkMetricProtocol(
            nativeValue: transaction?.networkProtocolName
        )
        fetchType = PlaybackNetworkMetricFetchType(
            nativeValue: transaction?.resourceFetchType
        )
        reusedConnection = transaction?.isReusedConnection
        proxyConnection = transaction?.isProxyConnection
        cellular = transaction?.isCellular
        constrained = transaction?.isConstrained
        expensive = transaction?.isExpensive
    }

    static func milliseconds(from start: Date?, to end: Date?) -> Int64 {
        guard let start, let end else { return -1 }
        return milliseconds(end.timeIntervalSince(start))
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        let milliseconds = seconds * 1_000
        guard
            milliseconds.isFinite,
            milliseconds >= 0,
            milliseconds <= Double(Int32.max)
        else {
            return -1
        }
        return Int64(milliseconds.rounded())
    }

    static func relativeMilliseconds(_ date: Date, from origin: Date) -> Int64 {
        milliseconds(date.timeIntervalSince(origin))
    }
}

enum PlaybackMediaResourceMetricResult: String, Equatable, Sendable {
    case succeeded
    case failed
}

struct PlaybackMediaResourceMetricSnapshot: Equatable, Sendable {
    let eventMilliseconds: Int64
    let requestStartMilliseconds: Int64
    let requestEndMilliseconds: Int64
    let responseStartMilliseconds: Int64
    let responseEndMilliseconds: Int64
    let byteRangeLocation: Int64
    let byteRangeLength: Int64
    let readFromCache: Bool
    let result: PlaybackMediaResourceMetricResult
    let network: PlaybackNetworkMetricSnapshot
}

enum PlaybackNetworkRequestMetricKind: String, Equatable, Sendable {
    case playbackInfo = "playback-info"
    case sessionValidation = "session-validation"
    case artwork
    case playbackReport = "playback-report"
    case app
}

enum PlaybackMetricJournalFormatter {
    static func mediaResource(
        claim: PlaybackMediaMetricClaim,
        snapshot: PlaybackMediaResourceMetricSnapshot
    ) -> String {
        "av-resource generation=\(claim.generation) role=\(claim.role.rawValue) request=\(claim.requestOrdinal) event-ms=\(snapshot.eventMilliseconds) request-start-ms=\(snapshot.requestStartMilliseconds) request-end-ms=\(snapshot.requestEndMilliseconds) response-start-ms=\(snapshot.responseStartMilliseconds) response-end-ms=\(snapshot.responseEndMilliseconds) byte-range-location=\(snapshot.byteRangeLocation) byte-range-length=\(snapshot.byteRangeLength) result=\(snapshot.result.rawValue) read-from-cache=\(snapshot.readFromCache) \(networkFields(snapshot.network))"
    }

    static func appNetwork(
        kind: PlaybackNetworkRequestMetricKind,
        ordinal: Int,
        snapshot: PlaybackNetworkMetricSnapshot
    ) -> String {
        "network-metric kind=\(kind.rawValue) ordinal=\(ordinal) \(networkFields(snapshot))"
    }

    private static func networkFields(
        _ snapshot: PlaybackNetworkMetricSnapshot
    ) -> String {
        "total-ms=\(snapshot.totalMilliseconds) fetch-ms=\(snapshot.fetchMilliseconds) dns-ms=\(snapshot.dnsMilliseconds) connect-ms=\(snapshot.connectMilliseconds) tls-ms=\(snapshot.tlsMilliseconds) request-ms=\(snapshot.requestMilliseconds) ttfb-ms=\(snapshot.timeToFirstByteMilliseconds) response-ms=\(snapshot.responseMilliseconds) transactions=\(snapshot.transactionCount) status=\(snapshot.statusCode) protocol=\(snapshot.networkProtocol.rawValue) fetch=\(snapshot.fetchType.rawValue) reused=\(flag(snapshot.reusedConnection)) proxy=\(flag(snapshot.proxyConnection)) cellular=\(flag(snapshot.cellular)) constrained=\(flag(snapshot.constrained)) expensive=\(flag(snapshot.expensive))"
    }

    private static func flag(_ value: Bool?) -> String {
        switch value {
        case true: "true"
        case false: "false"
        case nil: "unavailable"
        }
    }
}
