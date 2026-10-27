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

    var progress: FoundationListeningProgress {
        FoundationListeningProgress(elapsed: elapsed, duration: item.duration)
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
                session.client == "Velacanto Native", session.isActive == true,
                let device = session.deviceID, !device.isEmpty, device.utf8.count <= 128,
                device.caseInsensitiveCompare(ownDeviceID) != .orderedSame,
                let sessionID = occurrenceID(session.id), let media = session.nowPlayingItem,
                media.type == "Audio", let itemID = token(media.id),
                session.playState?.isPaused == false,
                let checkIn = date(session.lastPlaybackCheckIn),
                now.timeIntervalSince(checkIn) >= -5, now.timeIntervalSince(checkIn) <= 90
            else { return nil }
            let artistName =
                text(media.albumArtist)
                ?? text((media.artists ?? []).prefix(4).joined(separator: ", ")) ?? "Unknown Artist"
            let album = token(media.albumID).map {
                FoundationItemReference(
                    id: $0, title: text(media.album) ?? "Unknown Album",
                    primaryImageTag: token(media.albumPrimaryImageTag), catalogSource: catalogSource
                )
            }
            let artist = (media.albumArtists ?? media.artistItems ?? []).prefix(16).compactMap {
                reference -> FoundationItemReference? in
                guard let id = token(reference.id) else { return nil }
                return FoundationItemReference(
                    id: id, title: text(reference.name) ?? artistName, catalogSource: catalogSource)
            }.first
            let item = FoundationItem(
                id: itemID, title: text(media.name) ?? "Untitled", subtitle: artistName,
                kind: .track, duration: seconds(media.runTimeTicks),
                primaryImageTag: token(media.imageTags?["Primary"]), album: album,
                artist: artist, catalogSource: catalogSource)
            let occurrence = [
                catalogSource?.identity ?? owner, sessionID, device.lowercased(),
                itemID, occurrenceID(session.playlistItemID) ?? "",
            ].joined(separator: "\0")
            return Self(
                id: FoundationMusicLibraryStore.digest(occurrence),
                deviceKey: FoundationMusicLibraryStore.digest(device.lowercased()),
                deviceLabel: FoundationClientDeviceName.activityLabel(session.deviceName),
                checkedInAt: checkIn, item: item, albumTitle: text(media.album) ?? "Unknown Album",
                elapsed: seconds(session.playState?.positionTicks))
        }
        var seen: Set<String> = []
        return Array(
            candidates.sorted {
                $0.checkedInAt == $1.checkedInAt ? $0.id < $1.id : $0.checkedInAt > $1.checkedInAt
            }.filter { seen.insert($0.deviceKey).inserted }.prefix(3))
    }

    private static func seconds(_ ticks: Int64?) -> Double? {
        guard let ticks, ticks >= 0 else { return nil }
        return Double(ticks) / 10_000_000
    }

    private static func text(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 2048 else { return nil }
        let cleaned = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let result = String(String.UnicodeScalarView(cleaned))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(256))
    }

    /// Session/queue occurrence IDs are opaque strings, never catalog URL components.
    private static func occurrenceID(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    private static func token(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 128,
            FoundationJellyfinLibrary.validID(value)
        else { return nil }
        return value
    }

    private static func canonicalUserID(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(of: "-", with: "").lowercased()
        guard compact.count == 32, compact.allSatisfy({ $0.isASCII && $0.isHexDigit }),
            compact != String(repeating: "0", count: 32),
            text.count == 32 || (text.count == 36 && UUID(uuidString: text) != nil)
        else { return nil }
        return compact
    }

    private struct ActivitySession: Decodable {
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
            enum CodingKeys: String, CodingKey {
                case isPaused = "IsPaused"
                case positionTicks = "PositionTicks"
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
    private var generation = UUID()

    func cancel() {
        generation = UUID()
        activities = []
        unavailable = false
    }

    /// Remove stale hints without rereading the server. The view's foreground task owns
    /// these at-most-three sleeps; Home departure/background cancellation ends them.
    func expireVisibleActivity(
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        guard !Task.isCancelled else { return }
        let expected = generation
        let deadlines = Set(activities.map { $0.checkedInAt.addingTimeInterval(90) }).sorted()
        do {
            for deadline in deadlines {
                try await sleep(.seconds(max(0, deadline.timeIntervalSince(now()))))
                try Task.checkCancellation()
                guard generation == expected else { return }
                activities.removeAll { $0.checkedInAt.addingTimeInterval(90) <= deadline }
            }
        } catch {
            if generation == expected { activities = [] }
        }
    }

    func refresh(
        using load: @Sendable () async throws -> [FoundationRemoteListeningActivity]
    ) async {
        guard !Task.isCancelled else { return }
        cancel()
        let expected = generation
        do {
            let result = try await load()
            try Task.checkCancellation()
            guard generation == expected else { return }
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
