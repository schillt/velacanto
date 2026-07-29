import Foundation

enum MusicSourceKind: String, CaseIterable, Identifiable {
    case localFiles
    case jellyfin
    case navidrome

    var id: Self { self }

    var displayName: String {
        switch self {
        case .localFiles:
            "Local Files"
        case .jellyfin:
            "Jellyfin"
        case .navidrome:
            "Navidrome"
        }
    }

    var symbolName: String {
        switch self {
        case .localFiles:
            "folder.fill"
        case .jellyfin:
            "server.rack"
        case .navidrome:
            "music.note.list"
        }
    }

    var summary: String {
        switch self {
        case .localFiles:
            "Open one audio file in place. Velacanto never copies it into an app library."
        case .jellyfin:
            "Connect to and stream from a personal Jellyfin music library."
        case .navidrome:
            "Use the same player with a Navidrome/Subsonic-compatible library."
        }
    }

    var availabilityText: String {
        switch self {
        case .localFiles:
            "AVAILABLE NOW"
        case .jellyfin:
            "NEXT ADAPTER"
        case .navidrome:
            "PLANNED"
        }
    }
}

struct PlaybackItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let source: MusicSourceKind

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        source: MusicSourceKind
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.source = source
    }
}

struct PlaybackRequest {
    let item: PlaybackItem
    let mediaURL: URL
    let resourceAccess: SecurityScopedResourceAccess?
}

protocol PlaybackSourceAdapter {
    associatedtype Selection

    var source: MusicSourceKind { get }
    func playbackRequest(for selection: Selection) throws -> PlaybackRequest
}
