import Combine
import Foundation
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Generic platform only: never the user's personal device name or a new identity.
enum FoundationClientDeviceName: String, CaseIterable, Sendable {
    case apple = "Apple"
    case iPhone = "iPhone"
    case iPad = "iPad"
    case mac = "Mac"

    @MainActor static var current: Self {
        #if os(macOS)
            return .mac
        #else
            return UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #endif
    }

    static func activityLabel(_ reported: String?) -> String {
        switch reported {
        case Self.iPhone.rawValue: return "iPhone"
        case Self.iPad.rawValue: return "iPad"
        case Self.mac.rawValue: return "Mac"
        default: return "another device"
        }
    }
}

/// Memory-only snapshot from the signed-in account. No URLs, tokens or remote commands.
struct FoundationRemoteListeningActivity: Identifiable, Equatable, Sendable {
    let id: String
    let deviceKey: String
    let deviceLabel: String
    let checkedInAt: Date
    let item: FoundationItem
    let albumTitle: String
    let elapsed: Double?
    let sessionID: String
    let client: String
    let remoteDeviceID: String?
    let receiverScope: String?

    init(
        id: String, deviceKey: String, deviceLabel: String, checkedInAt: Date,
        item: FoundationItem, albumTitle: String, elapsed: Double?,
        sessionID: String = "", client: String = "Velacanto Native", remoteDeviceID: String? = nil,
        receiverScope: String? = nil
    ) {
        self.id = id
        self.deviceKey = deviceKey
        self.deviceLabel = deviceLabel
        self.checkedInAt = checkedInAt
        self.item = item
        self.albumTitle = albumTitle
        self.elapsed = elapsed
        self.sessionID = sessionID
        self.client = client
        self.remoteDeviceID = remoteDeviceID
        self.receiverScope = receiverScope
    }

    var usesNativeHandoff: Bool { client == "Velacanto Native" }

    var progress: FoundationListeningProgress {
        FoundationListeningProgress(elapsed: elapsed, duration: item.duration)
    }

    /// Display-only estimate between playing reports. Continuation still uses the source snapshot.
    func presentationProgress(at date: Date) -> FoundationListeningProgress {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return progress }
        let age = date.timeIntervalSince(checkedInAt)
        // Match the decoder's tolerated future skew; never extrapolate beyond freshness.
        guard age.isFinite, age >= -5 else { return progress }
        let estimate = elapsed + min(90, max(0, age))
        let bounded: Double
        if let duration = item.duration, duration.isFinite, duration > 0 {
            bounded = min(duration, estimate)
        } else {
            bounded = estimate
        }
        return FoundationListeningProgress(elapsed: bounded, duration: item.duration)
    }

    static func decode(
        _ data: Data, userID: String, ownDeviceID: String, now: Date,
        catalogSource: FoundationCatalogSource? = nil
    ) throws -> [Self] {
        // This is a post-buffer decode budget, not a network transfer/allocation limit.
        guard data.count <= 1_048_576, let owner = canonicalUserID(userID),
            !ownDeviceID.isEmpty, ownDeviceID.utf8.count <= 128
        else { throw FoundationLibraryError.invalidResponse }
        let sessions = try JSONDecoder().decode([ActivitySession].self, from: data)
        guard sessions.count <= 512 else { throw FoundationLibraryError.invalidResponse }
        let formatter = ISO8601DateFormatter()
        func date(_ text: String?) -> Date? {
            guard let text, text.utf8.count <= 64 else { return nil }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let result = formatter.date(from: text) { return result }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }
        let candidates: [Self] = sessions.compactMap { session in
            guard canonicalUserID(session.userID) == owner,
                session.isActive == true,
                let device = remoteDeviceID(session.deviceID),
                device.caseInsensitiveCompare(ownDeviceID) != .orderedSame,
                let sessionID = occurrenceID(session.id), let media = session.nowPlayingItem,
                media.type == "Audio", let itemID = catalogID(media.id),
                session.playState?.isPaused == false,
                let checkIn = date(session.lastPlaybackCheckIn),
                now.timeIntervalSince(checkIn) >= -5, now.timeIntervalSince(checkIn) <= 90
            else { return nil }
            let item = canonicalItem(media, catalogSource: catalogSource)
            let occurrence = [
                catalogSource?.identity ?? owner, sessionID, device.lowercased(),
                itemID, occurrenceID(session.playlistItemID) ?? "",
            ].joined(separator: "\0")
            return Self(
                id: FoundationMusicLibraryStore.digest(occurrence),
                deviceKey: FoundationMusicLibraryStore.digest(device.lowercased()),
                deviceLabel: session.client == "Velacanto Native"
                    ? FoundationClientDeviceName.activityLabel(session.deviceName)
                    : text(session.client) ?? "another player",
                checkedInAt: checkIn, item: item, albumTitle: text(media.album) ?? "Unknown Album",
                elapsed: seconds(session.playState?.positionTicks), sessionID: sessionID,
                client: text(session.client) ?? "Unknown player", remoteDeviceID: device,
                receiverScope: catalogSource.map {
                    FoundationMusicLibraryStore.digest($0.identity + "\0" + ownDeviceID)
                })
        }
        var seen: Set<String> = []
        return Array(
            candidates.sorted {
                $0.checkedInAt == $1.checkedInAt ? $0.id < $1.id : $0.checkedInAt > $1.checkedInAt
            }.filter { seen.insert($0.deviceKey).inserted }.prefix(3))
    }

    fileprivate static func canonicalItem(
        _ media: ActivitySession.Item, catalogSource: FoundationCatalogSource?
    ) -> FoundationItem {
        let artistName =
            text(media.albumArtist)
            ?? text((media.artists ?? []).prefix(4).joined(separator: ", ")) ?? "Unknown Artist"
        let album = catalogID(media.albumID).map {
            FoundationItemReference(
                id: $0, title: text(media.album) ?? "Unknown Album",
                primaryImageTag: token(media.albumPrimaryImageTag), catalogSource: catalogSource)
        }
        let artist = (media.albumArtists ?? media.artistItems ?? []).prefix(16).compactMap {
            reference -> FoundationItemReference? in
            guard let id = catalogID(reference.id) else { return nil }
            return FoundationItemReference(
                id: id, title: text(reference.name) ?? artistName,
                catalogSource: catalogSource)
        }.first
        return FoundationItem(
            id: catalogID(media.id) ?? "", title: text(media.name) ?? "Untitled",
            subtitle: artistName, kind: .track, duration: seconds(media.runTimeTicks),
            primaryImageTag: token(media.imageTags?["Primary"]), album: album,
            artist: artist, catalogSource: catalogSource)
    }

    fileprivate static func seconds(_ ticks: Int64?) -> Double? {
        guard let ticks, ticks >= 0 else { return nil }
        return Double(ticks) / 10_000_000
    }

    fileprivate static func text(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 2048 else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(256))
    }

    /// Remote clients own these opaque values. Jellyfin Web encodes its user agent and
    /// timestamp, so its valid device IDs can exceed the native client's 128-byte limit.
    /// Preserve the entire value; never decode, trim, truncate or substitute an identity.
    static func remoteDeviceID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 2048,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    /// Session/queue occurrence IDs are opaque strings, never catalog URL components.
    fileprivate static func occurrenceID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    /// Catalog GUIDs have N/D/case variants. Queue occurrence and device/session
    /// identifiers stay opaque and are never passed through this canonicalizer.
    static func catalogID(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.utf8.count == 32,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        {
            return value.lowercased()
        }
        guard let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    fileprivate static func token(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
            FoundationJellyfinLibrary.validID(value)
        else { return nil }
        return value
    }

    fileprivate static func canonicalUserID(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }),
            compact != String(repeating: "0", count: 32),
            text.count == 32 || (text.count == 36 && UUID(uuidString: text) != nil)
        else { return nil }
        return compact
    }

    fileprivate struct ActivitySession: Decodable {
        let id: String?
        let userID: String?
        let client: String?
        let isActive: Bool?
        let deviceID: String?
        let deviceName: String?
        let lastPlaybackCheckIn: String?
        let playlistItemID: String?
        let nowPlayingItem: Item?
        let playState: State?
        let nowPlayingQueue: [QueueItem]?
        let nowPlayingQueueFullItems: [Item]?
        let supportsRemoteControl: Bool?
        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case userID = "UserId"
            case client = "Client"
            case isActive = "IsActive"
            case deviceID = "DeviceId"
            case deviceName = "DeviceName"
            case lastPlaybackCheckIn = "LastPlaybackCheckIn"
            case playlistItemID = "PlaylistItemId"
            case nowPlayingItem = "NowPlayingItem"
            case playState = "PlayState"
            case nowPlayingQueue = "NowPlayingQueue"
            case nowPlayingQueueFullItems = "NowPlayingQueueFullItems"
            case supportsRemoteControl = "SupportsRemoteControl"
        }
        struct QueueItem: Decodable {
            let id: String?
            let playlistItemID: String?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case playlistItemID = "PlaylistItemId"
            }
        }
        struct Item: Decodable {
            let id: String?
            let type: String?
            let name: String?
            let album: String?
            let albumID: String?
            let albumArtist: String?
            let artists: [String]?
            let albumArtists: [Reference]?
            let artistItems: [Reference]?
            let runTimeTicks: Int64?
            let albumPrimaryImageTag: String?
            let imageTags: [String: String]?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case type = "Type"
                case name = "Name"
                case album = "Album"
                case albumID = "AlbumId"
                case albumArtist = "AlbumArtist"
                case artists = "Artists"
                case albumArtists = "AlbumArtists"
                case artistItems = "ArtistItems"
                case runTimeTicks = "RunTimeTicks"
                case albumPrimaryImageTag = "AlbumPrimaryImageTag"
                case imageTags = "ImageTags"
            }
        }
        struct Reference: Decodable {
            let id: String?
            let name: String?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
            }
        }
        struct State: Decodable {
            let isPaused: Bool?
            let positionTicks: Int64?
            let repeatMode: String?
            let playbackOrder: String?
            enum CodingKeys: String, CodingKey {
                case isPaused = "IsPaused"
                case positionTicks = "PositionTicks"
                case repeatMode = "RepeatMode"
                case playbackOrder = "PlaybackOrder"
            }
        }
    }
}

struct FoundationListeningProgress: Equatable, Sendable {
    let elapsed: Double?
    let duration: Double?

    var fraction: Double {
        guard let elapsed, elapsed.isFinite, let duration, duration.isFinite, duration > 0 else {
            return 0
        }
        return min(1, max(0, elapsed / duration))
    }

    private func time(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= Double(Int.max / 2) else {
            return "Unavailable"
        }
        let seconds = Int(value)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    var label: String { "\(time(elapsed)) / \(time(duration))" }
    var accessibilityValue: String { "Elapsed \(time(elapsed)), duration \(time(duration))" }
}

/// Only the progress content redraws each second, with no model writes or remote requests.
struct FoundationRemoteListeningProgressView<Content: View>: View {
    let activity: FoundationRemoteListeningActivity
    let isActive: Bool
    @ViewBuilder let content: (FoundationListeningProgress) -> Content
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false

    var body: some View {
        Group {
            if isActive && isVisible && scenePhase == .active {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(activity.presentationProgress(at: context.date))
                }
            } else {
                content(activity.progress)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}

/// Choose first, then hide: dismissing the freshest activity must not reveal a fallback.
enum FoundationContinueListeningSelection {
    static func select(
        _ activities: [FoundationRemoteListeningActivity], dismissed: Set<String>
    ) -> FoundationRemoteListeningActivity? {
        guard
            let selected = activities.sorted(by: {
                $0.checkedInAt == $1.checkedInAt ? $0.id < $1.id : $0.checkedInAt > $1.checkedInAt
            }).first, !dismissed.contains(selected.id)
        else { return nil }
        return selected
    }
}

/// Account-lifetime UI memory only. This never owns playback or changes a remote session.
@MainActor
final class FoundationContinueListeningDismissals: ObservableObject {
    @Published private(set) var keys: Set<String> = []
    private var scope: String?

    func configure(scope: String?) {
        guard self.scope != scope else { return }
        self.scope = scope
        keys = []
    }

    func dismiss(_ id: String, scope: String) {
        guard self.scope == scope else { return }
        keys.insert(id)
    }
}

enum FoundationRemoteListeningDeadline {
    /// Includes ordinary admission and connectivity waiting. The supplied load must cooperate
    /// with cancellation, as URLSession.data does. This introduces no timer or polling loop.
    static func run<Value: Sendable>(
        timeout: Duration = .seconds(8),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw FoundationLibraryError.unavailable
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            try Task.checkCancellation()
            return value
        }
    }
}

@MainActor
final class FoundationRemoteListeningModel: ObservableObject {
    @Published private(set) var activities: [FoundationRemoteListeningActivity] = []
    @Published private(set) var unavailable = false
    @Published private(set) var snapshotRevision = UUID()
    private var generation = UUID()

    /// Retire in-flight work without blanking a still-fresh remote snapshot.
    /// Scene transitions and ordinary refreshes are not authoritative playback changes.
    func suspend() {
        generation = UUID()
        unavailable = false
    }

    func cancel() {
        suspend()
        snapshotRevision = UUID()
        activities = []
    }

    func removeExpiredActivities(now: Date = Date()) {
        let fresh = activities.filter { $0.checkedInAt.addingTimeInterval(90) > now }
        guard fresh != activities else { return }
        snapshotRevision = UUID()
        activities = fresh
    }

    /// Remove stale hints without rereading the server. The view's foreground task owns
    /// these at-most-three sleeps; Home departure/background cancellation ends them.
    func expireVisibleActivity(
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        guard !Task.isCancelled else { return }
        let expected = snapshotRevision
        let deadlines = Set(activities.map { $0.checkedInAt.addingTimeInterval(90) }).sorted()
        do {
            for deadline in deadlines {
                try await sleep(.seconds(max(0, deadline.timeIntervalSince(now()))))
                try Task.checkCancellation()
                // A later snapshot owns its own deadlines. An old expiry cannot remove it.
                guard snapshotRevision == expected else { return }
                activities.removeAll { $0.checkedInAt.addingTimeInterval(90) <= deadline }
            }
        } catch {
            // Cancellation (including a scene transition) is not an empty server response.
        }
    }

    func refresh(
        using load: @Sendable () async throws -> [FoundationRemoteListeningActivity]
    ) async {
        guard !Task.isCancelled else { return }
        suspend()
        let expected = generation
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard generation == expected else { return }
            snapshotRevision = UUID()
            activities = result
        } catch {
            guard generation == expected, !Task.isCancelled else { return }
            unavailable = !(error is CancellationError)
        }
    }
}

@MainActor
struct FoundationHandoffGuidePreference {
    static let key = "foundation.handoff.guide.suppressed.v1"
    let defaults: UserDefaults
    var suppressed: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

enum FoundationContinueListeningInstructionAction: Equatable {
    case fullGuide, inlineInstructions
    static func onTap(guideSuppressed: Bool) -> Self {
        guideSuppressed ? .inlineInstructions : .fullGuide
    }
}

struct FoundationHandoffListeningGuide: View {
    let instruction: String
    @Binding var suppressed: Bool
    let done: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Continue listening here").font(.title2).bold()
                Text(instruction)
                Text(
                    "Keep VelaCanto open on the device playing music. Both devices need the same Apple Account, Bluetooth, Wi-Fi, and Handoff enabled."
                )
                Text(
                    "If no Handoff offer appears, check those settings. This card cannot start a transfer by itself."
                )
                .foregroundStyle(.secondary)
                Toggle("Don’t show this guide again", isOn: $suppressed)
                Text(
                    "Tapping the card will show short instructions. Handoff Help remains available."
                )
                .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 520, alignment: .leading)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
            }
        }
    }
}

#if DEBUG
    /// Explicit preparation only. Fixed categories/counts, never source or account identifiers.
    enum FoundationRemotePreparationDiagnostic: String {
        case receiverScopeRejected
        case readingSessions
        case decodingOffer
        case matchingActivity
        case authorizingQueue
        case resolvingMetadata
        case providerPrepared
        case preparingProvider
        case encodingPayload
        case selectingOccurrence
        case confirmationPrepared
        case sourceSessionMismatch
        case sourcePrerequisites
        case missingCurrentOccurrence
        case sourceExpired
        case missingSourceQueue
        case invalidQueueItem
        case invalidQueueOccurrence
        case duplicateQueueOccurrence
        case currentOccurrenceMismatch
        case missingRepeat
        case unsupportedRepeat
        case invalidFullItem
        case duplicateFullItem
        case invalidAuthorizationItemID
        case authorizationShape
        case authorizationIDs

        static func recordAuthorizationShape(
            requestedCount: Int, startIndex: Int?, totalCount: Int?, rowsCount: Int?
        ) {
            FoundationJournal.shared.record(
                "remote-preparation reason=\(Self.authorizationShape.rawValue) requestedCount=\(requestedCount)"
                    + " startIndex=\(startIndex ?? -1) totalCount=\(totalCount ?? -1)"
                    + " rowsCount=\(rowsCount ?? -1) hasStartIndex=\(startIndex != nil)"
                    + " hasTotalCount=\(totalCount != nil) hasRows=\(rowsCount != nil)")
        }

        static func recordAuthorizationIDs(
            requestedCount: Int, mappedCount: Int, uniqueCount: Int, matchedCount: Int
        ) {
            FoundationJournal.shared.record(
                "remote-preparation reason=\(Self.authorizationIDs.rawValue) requestedCount=\(requestedCount)"
                    + " mappedCount=\(mappedCount) uniqueCount=\(uniqueCount) matchedCount=\(matchedCount)"
            )
        }

        func recordQueueIdentity(queueCount: Int, uniqueOccurrences: Bool, currentMatches: Bool) {
            FoundationJournal.shared.record(
                "remote-preparation reason=\(rawValue) queueCount=\(queueCount)"
                    + " uniqueOccurrences=\(uniqueOccurrences) currentMatches=\(currentMatches)")
        }

        func record(queueCount: Int = -1, metadataCount: Int = -1, completed: Bool = false) {
            let outcome = completed ? "prepared" : Task.isCancelled ? "cancelled" : "incomplete"
            FoundationJournal.shared.record(
                "remote-preparation stage=\(rawValue) outcome=\(outcome)"
                    + " queueCount=\(queueCount) metadataCount=\(metadataCount)")
        }
    }
#endif

/// A complete, memory-only source-reported queue. No delivery locations or source credentials.
/// Server RPC has no compare-and-stop precondition: source completion is explicitly best effort.
struct FoundationRemoteContinuationOffer: Sendable {
    struct Occurrence: Equatable, Sendable {
        let itemID: String
        let sourceID: String
        let localID: UUID
    }
    let scope: String
    let sessionID: String
    let deviceID: String
    let client: String
    let sourceOccurrence: String
    let queue: [Occurrence]
    let repeatMode: FoundationHandoffPayload.RepeatMode
    let position: Double
    let checkedInAt: Date
    let supportsRemoteControl: Bool
    let items: [String: FoundationItem]

    var activityID: String {
        guard let current = queue.first(where: { $0.sourceID == sourceOccurrence }),
            let account = items[current.itemID]?.catalogSource?.identity
        else { return "" }
        return FoundationMusicLibraryStore.digest(
            [
                account, sessionID, deviceID.lowercased(),
                current.itemID, sourceOccurrence,
            ].joined(separator: "\0"))
    }

    var fingerprint: String {
        let parts =
            [
                scope, sessionID, deviceID.lowercased(), client, sourceOccurrence,
                repeatMode.rawValue,
            ] + queue.flatMap { [$0.itemID, $0.sourceID] }
        let framed = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return FoundationMusicLibraryStore.digest(framed)
    }
    var missingItemIDs: [String] {
        Array(Set(queue.map(\.itemID))).filter { items[$0] == nil }.sorted()
    }
    func matching(_ previous: Self) throws -> Self {
        guard FoundationRemoteListeningActivity.remoteDeviceID(deviceID) != nil,
            deviceID == previous.deviceID, fingerprint == previous.fingerprint
        else { throw FoundationHandoffError.changed }
        return self
    }
    func resolving(_ additional: [FoundationItem], authoritative: Bool = false) throws -> Self {
        var metadata = items
        let wanted = Set(queue.map(\.itemID))
        for item in additional {
            guard item.kind == .track, wanted.contains(item.id) else {
                throw FoundationHandoffError.unavailable
            }
            if authoritative || metadata[item.id] == nil { metadata[item.id] = item }
        }
        return Self(
            scope: scope, sessionID: sessionID, deviceID: deviceID, client: client,
            sourceOccurrence: sourceOccurrence, queue: queue, repeatMode: repeatMode,
            position: position, checkedInAt: checkedInAt,
            supportsRemoteControl: supportsRemoteControl, items: metadata)
    }
    private static func occurrenceID(_ value: String, scope: String, sessionID: String) -> UUID {
        let hash = FoundationMusicLibraryStore.digest(scope + "\0" + sessionID + "\0" + value)
        let text = String(hash.prefix(32))
        let formatted = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(
                text[
                    text.index(
                        text.startIndex, offsetBy: range.lowerBound)..<text.index(
                            text.startIndex, offsetBy: range.upperBound)])
        }.joined(separator: "-")
        // digest always yields64 hexadecimal characters; this is not untrusted parsing.
        return UUID(uuidString: formatted)!
    }
    var entries: [FoundationQueueEntry] {
        queue.compactMap { entry in
            items[entry.itemID].map {
                FoundationQueueEntry(id: entry.localID, item: $0)
            }
        }
    }
    var selected: UUID { Self.occurrenceID(sourceOccurrence, scope: scope, sessionID: sessionID) }
    func payload(scope contextScope: String, id: UUID) throws -> FoundationHandoffPayload {
        guard missingItemIDs.isEmpty, entries.count == queue.count else {
            throw FoundationHandoffError.unavailable
        }
        let result = FoundationHandoffPayload(
            header: .init(id: id, scope: contextScope, kind: .playback),
            session: .init(
                entries: entries.map(FoundationHandoffPayload.Track.init), selected: selected,
                position: position, shuffle: false, repeatMode: repeatMode, wasPlaying: true),
            destination: nil)
        _ = try result.encoded()
        return result
    }

    static func decode(
        _ data: Data, sessionID: String, userID: String,
        ownDeviceID: String, scope: String, catalogSource: FoundationCatalogSource, now: Date
    ) throws -> Self {
        typealias Activity = FoundationRemoteListeningActivity
        guard data.count <= FoundationHandoffPayload.maximumBytes,
            FoundationJellyfinLibrary.validID(sessionID),
            !ownDeviceID.isEmpty, ownDeviceID.utf8.count <= 128,
            let owner = Activity.canonicalUserID(userID)
        else {
            throw FoundationHandoffError.invalid
        }
        let sessions = try JSONDecoder().decode([Activity.ActivitySession].self, from: data)
        guard sessions.count <= 512 else { throw FoundationHandoffError.tooLarge }
        let matches = sessions.filter { $0.id == sessionID }
        guard matches.count == 1, let session = matches.first,
            Activity.canonicalUserID(session.userID) == owner,
            let device = Activity.remoteDeviceID(session.deviceID),
            device.caseInsensitiveCompare(ownDeviceID) != .orderedSame,
            session.isActive == true, session.playState?.isPaused == false,
            let current = session.nowPlayingItem, current.type == "Audio",
            let currentID = Activity.catalogID(current.id),
            let selected = Activity.occurrenceID(session.playlistItemID),
            let position = Activity.seconds(session.playState?.positionTicks), position.isFinite,
            position <= Double(Int64.max / 600) - 1
        else {
            #if DEBUG
                let reason: FoundationRemotePreparationDiagnostic
                if matches.count != 1 {
                    reason = .sourceSessionMismatch
                } else if Activity.occurrenceID(matches.first?.playlistItemID) == nil {
                    reason = .missingCurrentOccurrence
                } else {
                    reason = .sourcePrerequisites
                }
                let candidate = matches.first
                FoundationJournal.shared.record(
                    "remote-preparation reason=\(reason.rawValue) matchesCount=\(matches.count)"
                        + " hasCurrentOccurrence=\(Activity.occurrenceID(candidate?.playlistItemID) != nil)"
                        + " hasQueue=\(candidate?.nowPlayingQueue != nil)"
                        + " hasRepeat=\(candidate?.playState?.repeatMode != nil)"
                        + " active=\(candidate?.isActive == true) playing=\(candidate?.playState?.isPaused == false)"
                )
            #endif
            throw FoundationHandoffError.unavailable
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var checkIn = session.lastPlaybackCheckIn.flatMap { formatter.date(from: $0) }
        if checkIn == nil {
            formatter.formatOptions = [.withInternetDateTime]
            checkIn = session.lastPlaybackCheckIn.flatMap { formatter.date(from: $0) }
        }
        guard let checkIn, (-5...90).contains(now.timeIntervalSince(checkIn)) else {
            #if DEBUG
                FoundationRemotePreparationDiagnostic.sourceExpired.record()
            #endif
            throw FoundationHandoffError.expired
        }
        guard let source = session.nowPlayingQueue, !source.isEmpty else {
            #if DEBUG
                FoundationRemotePreparationDiagnostic.missingSourceQueue.record(
                    queueCount: session.nowPlayingQueue?.count ?? -1)
            #endif
            throw FoundationHandoffError.unavailable
        }
        guard source.count <= FoundationHandoffPayload.maximumEntries else {
            throw FoundationHandoffError.tooLarge
        }
        let queue = try source.map { row -> Occurrence in
            guard let id = Activity.catalogID(row.id),
                let occurrence = Activity.occurrenceID(row.playlistItemID)
            else {
                #if DEBUG
                    let reason: FoundationRemotePreparationDiagnostic =
                        Activity.catalogID(row.id) == nil
                        ? .invalidQueueItem : .invalidQueueOccurrence
                    reason.record(queueCount: source.count)
                #endif
                throw FoundationHandoffError.invalid
            }
            return .init(
                itemID: id, sourceID: occurrence,
                localID: Self.occurrenceID(occurrence, scope: scope, sessionID: sessionID))
        }
        guard Set(queue.map(\.sourceID)).count == queue.count,
            queue.first(where: { $0.sourceID == selected })?.itemID == currentID
        else {
            #if DEBUG
                let reason: FoundationRemotePreparationDiagnostic =
                    Set(queue.map(\.sourceID)).count != queue.count
                    ? .duplicateQueueOccurrence : .currentOccurrenceMismatch
                reason.recordQueueIdentity(
                    queueCount: queue.count,
                    uniqueOccurrences: Set(queue.map(\.sourceID)).count == queue.count,
                    currentMatches: queue.first(where: { $0.sourceID == selected })?.itemID
                        == currentID)
            #endif
            throw FoundationHandoffError.invalid
        }
        let repeatMode: FoundationHandoffPayload.RepeatMode
        switch session.playState?.repeatMode {
        case "RepeatNone": repeatMode = .off
        case "RepeatAll": repeatMode = .all
        case "RepeatOne": repeatMode = .one
        default:
            #if DEBUG
                let reason: FoundationRemotePreparationDiagnostic =
                    session.playState?.repeatMode == nil ? .missingRepeat : .unsupportedRepeat
                reason.record(queueCount: queue.count)
            #endif
            throw FoundationHandoffError.unavailable
        }
        var items: [String: FoundationItem] = [:]
        let wanted = Set(queue.map(\.itemID))
        for media in (session.nowPlayingQueueFullItems ?? []) {
            guard media.type == "Audio", let id = Activity.catalogID(media.id),
                wanted.contains(id), items[id] == nil
            else {
                #if DEBUG
                    let id = Activity.catalogID(media.id)
                    let duplicate = id.map { items[$0] != nil } ?? false
                    let reason: FoundationRemotePreparationDiagnostic =
                        duplicate ? .duplicateFullItem : .invalidFullItem
                    reason.record(
                        queueCount: queue.count,
                        metadataCount: session.nowPlayingQueueFullItems?.count ?? -1)
                #endif
                throw FoundationHandoffError.invalid
            }
            items[id] = Activity.canonicalItem(media, catalogSource: catalogSource)
        }
        items[currentID] = Activity.canonicalItem(current, catalogSource: catalogSource)
        return Self(
            scope: scope, sessionID: sessionID, deviceID: device,
            client: Activity.text(session.client) ?? "Unknown player", sourceOccurrence: selected,
            queue: queue, repeatMode: repeatMode, position: position, checkedInAt: checkIn,
            supportsRemoteControl: session.supportsRemoteControl == true, items: items)
    }

    /// One confirmation read; absence/ambiguity is not reported as a verified stop.
    static func stopped(_ data: Data, expected: Self, userID: String) throws -> Bool {
        typealias Activity = FoundationRemoteListeningActivity
        guard data.count <= FoundationHandoffPayload.maximumBytes else {
            throw FoundationHandoffError.tooLarge
        }
        let sessions = try JSONDecoder().decode([Activity.ActivitySession].self, from: data)
        guard sessions.count <= 512 else { throw FoundationHandoffError.tooLarge }
        let matches = sessions.filter { $0.id == expected.sessionID }
        guard matches.count == 1, let session = matches.first,
            let owner = Activity.canonicalUserID(userID),
            Activity.canonicalUserID(session.userID) == owner,
            let device = Activity.remoteDeviceID(session.deviceID),
            device == expected.deviceID
        else { return false }
        return session.nowPlayingItem == nil
    }
}
