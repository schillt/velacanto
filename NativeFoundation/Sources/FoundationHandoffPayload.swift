import Foundation

enum FoundationHandoffError: Error, LocalizedError, Equatable {
    case unsupported, invalid, expired, differentAccount, tooLarge, unavailable, changed
    case interrupted, positionUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "This activity uses an unsupported Handoff version."
        case .invalid: "This Handoff activity could not be verified."
        case .expired: "This activity has expired. Open Handoff again on the other device."
        case .differentAccount: "Sign in to the matching music account before continuing."
        case .tooLarge: "This queue is too large to transfer safely. No partial queue was applied."
        case .unavailable: "The other device or this music is unavailable."
        case .changed: "The activity changed. Your current playback was kept."
        case .interrupted: "The Handoff transfer was interrupted. Your current playback was kept."
        case .positionUnavailable: "The playback position could not be restored."
        }
    }
}

/// Identifiers and bounded display metadata only. This is deliberately not a session,
/// library item, download record, resource URL, or persisted account-store snapshot.
struct FoundationHandoffPayload: Codable, Sendable, Equatable {
    static let protocolVersion = 2
    static let activityType = "com.chameleonenterprise.velacanto.continuation.v1"
    static let userInfoKey = "continuationHeader"
    static let maximumHeaderBytes = 2_048
    static let maximumBytes = 4_194_304
    static let maximumEntries = 10_000
    static let maximumAge: TimeInterval = 300

    enum Kind: String, Codable, Sendable { case playback, browse }
    enum SourceDevice: String, Codable, Sendable {
        case phone, tablet, mac
        var displayName: String {
            switch self {
            case .phone: "iPhone"
            case .tablet: "iPad"
            case .mac: "Mac"
            }
        }
    }
    enum RepeatMode: String, Codable, Sendable { case off, all, one }

    struct Header: Codable, Sendable, Equatable {
        let version: Int
        let id: UUID
        let scope: String
        let kind: Kind
        let createdAt: TimeInterval
        let sourceDevice: SourceDevice?

        init(
            id: UUID = UUID(), scope: String, kind: Kind,
            createdAt: TimeInterval = Date().timeIntervalSince1970,
            sourceDevice: SourceDevice? = nil
        ) {
            version = FoundationHandoffPayload.protocolVersion
            self.id = id
            self.scope = scope
            self.kind = kind
            self.createdAt = createdAt
            self.sourceDevice = sourceDevice
        }

        func validate(scope expectedScope: String?, now: TimeInterval) throws {
            guard version == FoundationHandoffPayload.protocolVersion else {
                throw FoundationHandoffError.unsupported
            }
            guard scope.utf8.count == 64,
                scope.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                createdAt.isFinite, now.isFinite, createdAt >= 0, now >= 0,
                createdAt <= now + 30
            else { throw FoundationHandoffError.invalid }
            guard now - createdAt <= FoundationHandoffPayload.maximumAge else {
                throw FoundationHandoffError.expired
            }
            guard let expectedScope, scope == expectedScope else {
                throw FoundationHandoffError.differentAccount
            }
        }

        func encoded() throws -> Data {
            try validate(scope: scope, now: createdAt)
            let result = try JSONEncoder().encode(self)
            guard result.count <= FoundationHandoffPayload.maximumHeaderBytes else {
                throw FoundationHandoffError.tooLarge
            }
            return result
        }

        static func decode(_ data: Data) throws -> Self {
            guard !data.isEmpty, data.count <= FoundationHandoffPayload.maximumHeaderBytes else {
                throw FoundationHandoffError.tooLarge
            }
            do { return try JSONDecoder().decode(Self.self, from: data) } catch {
                throw FoundationHandoffError.invalid
            }
        }
    }

    struct Reference: Codable, Sendable, Equatable {
        let id: String
        let title: String

        init(_ reference: FoundationItemReference) {
            id = reference.id
            title = reference.title
        }

        var itemReference: FoundationItemReference { .init(id: id, title: title) }

        var isValid: Bool {
            FoundationHandoffPayload.validID(id) && title.utf8.count <= 4_096
        }
    }

    struct Track: Codable, Sendable, Equatable {
        let occurrence: UUID
        let itemID: String
        let title: String
        let subtitle: String
        let duration: Double?
        let album: Reference?
        let artist: Reference?
        let trackNumber: Int?
        let discNumber: Int?

        init(_ entry: FoundationQueueEntry) {
            occurrence = entry.id
            itemID = entry.item.id
            title = entry.item.title
            subtitle = entry.item.subtitle
            duration = entry.item.duration
            album = entry.item.album.map(Reference.init)
            artist = entry.item.artist.map(Reference.init)
            trackNumber = entry.item.trackNumber
            discNumber = entry.item.discNumber
        }

        var entry: FoundationQueueEntry {
            .init(
                id: occurrence,
                item: .init(
                    id: itemID, title: title, subtitle: subtitle, kind: .track, duration: duration,
                    album: album?.itemReference, artist: artist?.itemReference,
                    trackNumber: trackNumber, discNumber: discNumber))
        }

        var isValid: Bool {
            FoundationHandoffPayload.validID(itemID) && title.utf8.count <= 4_096
                && subtitle.utf8.count <= 4_096
                && duration.map { $0.isFinite && $0 >= 0 } != false
                && album?.isValid != false && artist?.isValid != false
                && trackNumber.map { (0...1_000_000).contains($0) } != false
                && discNumber.map { (0...1_000_000).contains($0) } != false
        }
    }

    struct Session: Codable, Sendable, Equatable {
        let entries: [Track]
        let selected: UUID
        let position: Double
        let shuffle: Bool
        let repeatMode: RepeatMode
        let wasPlaying: Bool
        let visibleOccurrences: [UUID]

        init(
            entries: [Track], selected: UUID, position: Double, shuffle: Bool,
            repeatMode: RepeatMode, wasPlaying: Bool, visibleOccurrences: [UUID]? = nil
        ) {
            self.entries = entries
            self.selected = selected
            self.position = position
            self.shuffle = shuffle
            self.repeatMode = repeatMode
            self.wasPlaying = wasPlaying
            self.visibleOccurrences = visibleOccurrences ?? entries.map(\.occurrence)
        }

        var isValid: Bool {
            !entries.isEmpty && entries.count <= FoundationHandoffPayload.maximumEntries
                && entries.allSatisfy(\.isValid)
                && Set(entries.map(\.occurrence)).count == entries.count
                && entries.contains { $0.occurrence == selected }
                && validVisibility
                && position.isFinite && position >= 0
                && position <= Double(Int64.max / 600) - 1
        }

        private var validVisibility: Bool {
            let visible = Set(visibleOccurrences)
            return visible.count == visibleOccurrences.count && visible.contains(selected)
                && entries.filter { visible.contains($0.occurrence) }.map(\.occurrence)
                    == visibleOccurrences
        }
    }

    struct Destination: Codable, Sendable, Equatable {
        let id: String
        let kind: FoundationItem.Kind

        var isValid: Bool {
            FoundationHandoffPayload.validID(id)
                && [.album, .artist, .playlist].contains(kind)
        }
    }

    let header: Header
    let session: Session?
    let destination: Destination?

    func validate(scope: String?, now: TimeInterval, expected: Header? = nil) throws {
        try header.validate(scope: scope, now: now)
        if let expected {
            guard header.id == expected.id, header.scope == expected.scope,
                header.kind == expected.kind, header.version == expected.version,
                header.sourceDevice == expected.sourceDevice
            else { throw FoundationHandoffError.changed }
        }
        switch header.kind {
        case .playback:
            guard session?.isValid == true, destination == nil else {
                throw FoundationHandoffError.invalid
            }
        case .browse:
            guard destination?.isValid == true, session == nil else {
                throw FoundationHandoffError.invalid
            }
        }
    }

    func encoded() throws -> Data {
        guard (session?.entries.count ?? 0) <= Self.maximumEntries else {
            throw FoundationHandoffError.tooLarge
        }
        try validate(scope: header.scope, now: header.createdAt)
        // Reject a huge source queue before asking an encoder to allocate its complete
        // representation. This bound includes JSON escaping and conservative field overhead.
        guard estimatedEncodedBytes <= Self.maximumBytes else {
            throw FoundationHandoffError.tooLarge
        }
        let result = try JSONEncoder().encode(self)
        guard result.count <= Self.maximumBytes else { throw FoundationHandoffError.tooLarge }
        return result
    }

    private var estimatedEncodedBytes: Int {
        1_024 + (session?.visibleOccurrences.count ?? 0) * 39
            + (session?.entries.reduce(0) { count, entry in
                var size =
                    197 + Self.stringBytes(entry.itemID) + Self.stringBytes(entry.title)
                    + Self.stringBytes(entry.subtitle)
                for reference in [entry.album, entry.artist].compactMap({ $0 }) {
                    size += 12 + Self.stringBytes(reference.id) + Self.stringBytes(reference.title)
                }
                return count + size
            } ?? 0)
    }

    private static func stringBytes(_ string: String) -> Int {
        2
            + string.unicodeScalars.reduce(0) { count, scalar in
                switch scalar.value {
                case 0...31, 0x2028, 0x2029: count + 6
                case 34, 47, 92: count + 2
                case 0...0x7F: count + 1
                case 0...0x7FF: count + 2
                case 0...0xFFFF: count + 3
                default: count + 4
                }
            }
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw FoundationHandoffError.tooLarge
        }
        do { return try JSONDecoder().decode(Self.self, from: data) } catch {
            throw FoundationHandoffError.invalid
        }
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128
            && id.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95
            }
    }
}

/// One bounded length-prefixed message. Partial delivery is never a partial queue.
struct FoundationHandoffFrame {
    private let maximumBytes: Int
    private var data = Data()
    private var expectedCount: Int?
    private(set) var complete = false

    init(maximumBytes: Int = FoundationHandoffPayload.maximumBytes) {
        self.maximumBytes = maximumBytes
    }

    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= FoundationHandoffPayload.maximumBytes else {
            throw FoundationHandoffError.tooLarge
        }
        let count = UInt32(payload.count)
        return Data([
            UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
            UInt8((count >> 8) & 255), UInt8(count & 255),
        ]) + payload
    }

    mutating func append(_ chunk: Data) throws -> Data? {
        guard !complete else { throw FoundationHandoffError.invalid }
        guard maximumBytes > 0, maximumBytes <= FoundationHandoffPayload.maximumBytes,
            chunk.count <= maximumBytes + 4 - data.count
        else {
            throw FoundationHandoffError.tooLarge
        }
        data.append(chunk)
        if expectedCount == nil, data.count >= 4 {
            let count = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= maximumBytes else {
                throw FoundationHandoffError.tooLarge
            }
            expectedCount = Int(count)
        }
        guard let expectedCount else { return nil }
        guard data.count <= expectedCount + 4 else { throw FoundationHandoffError.invalid }
        guard data.count == expectedCount + 4 else { return nil }
        complete = true
        return data.dropFirst(4)
    }
}

/// Sent only after the expected receiver occurrence has actually begun native playback.
/// It is not an invitation to execute arbitrary commands on the source device.
struct FoundationHandoffAcknowledgement: Codable, Sendable, Equatable {
    let version: Int
    let kind: String
    let transfer: UUID
    let occurrence: UUID
    let nonce: UUID

    init(transfer: UUID, occurrence: UUID, nonce: UUID = UUID()) {
        version = FoundationHandoffPayload.protocolVersion
        kind = "started"
        self.transfer = transfer
        self.occurrence = occurrence
        self.nonce = nonce
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 512 else { throw FoundationHandoffError.tooLarge }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.version == FoundationHandoffPayload.protocolVersion else {
                throw FoundationHandoffError.unsupported
            }
            guard value.kind == "started" else { throw FoundationHandoffError.invalid }
            return value
        } catch let error as FoundationHandoffError { throw error } catch {
            throw FoundationHandoffError.invalid
        }
    }
}

/// Small, phase-bound messages on the existing native continuation streams.
/// Authorization proves the offered source session is still current before replacing
/// the receiver queue. One later clock response is requested only at native readiness.
struct FoundationHandoffControl: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable { case authorize, authorized, position, positionValue }
    let version: Int
    let kind: Kind
    let transfer: UUID
    let occurrence: UUID
    let nonce: UUID
    let seconds: Double?

    init(kind: Kind, transfer: UUID, occurrence: UUID, nonce: UUID, seconds: Double? = nil) {
        version = FoundationHandoffPayload.protocolVersion
        self.kind = kind
        self.transfer = transfer
        self.occurrence = occurrence
        self.nonce = nonce
        self.seconds = seconds
    }

    func validate() throws {
        guard version == FoundationHandoffPayload.protocolVersion else {
            throw FoundationHandoffError.unsupported
        }
        if kind == .positionValue {
            guard let seconds, seconds.isFinite, seconds >= 0,
                seconds <= Double(Int64.max / 600) - 1
            else { throw FoundationHandoffError.invalid }
        } else if seconds != nil {
            throw FoundationHandoffError.invalid
        }
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 512 else { throw FoundationHandoffError.tooLarge }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 512 else { throw FoundationHandoffError.tooLarge }
        do {
            let value = try JSONDecoder().decode(Self.self, from: data)
            try value.validate()
            return value
        } catch let error as FoundationHandoffError { throw error } catch {
            throw FoundationHandoffError.invalid
        }
    }
}
