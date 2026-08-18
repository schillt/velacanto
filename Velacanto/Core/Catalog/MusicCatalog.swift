import Foundation

struct MusicCatalogItemID: Hashable, Codable, Sendable {
    let source: MusicSourceID
    let accountScope: String
    let opaqueID: String
}

struct MusicArtworkReference: Equatable, Codable, Sendable {
    let opaqueItemID: String
    let imageTag: String?
}

/// Provider-neutral lyrics for one playable catalog item.
struct MusicLyrics: Equatable, Sendable {
    let lines: [MusicLyricLine]

    var hasTimedLines: Bool {
        lines.contains { $0.startTime != nil }
    }

    var isFullyTimed: Bool {
        !lines.isEmpty && lines.allSatisfy { $0.startTime != nil }
    }

    func activeLine(at playbackTime: TimeInterval) -> MusicLyricLine? {
        lines.reduce(nil) { activeLine, line in
            guard let startTime = line.startTime, startTime <= playbackTime else {
                return activeLine
            }
            guard let activeStartTime = activeLine?.startTime else {
                return line
            }
            return startTime >= activeStartTime ? line : activeLine
        }
    }
}

struct MusicLyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let text: String
    let startTime: TimeInterval?
}

enum MusicLyricsError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        "Lyrics could not be loaded. Try again."
    }
}

struct MusicItemCapabilities: OptionSet, Codable, Sendable {
    let rawValue: UInt16

    static let navigate = Self(rawValue: 1 << 0)
    static let play = Self(rawValue: 1 << 1)
    static let shuffle = Self(rawValue: 1 << 2)
    static let favorite = Self(rawValue: 1 << 3)
    static let playNext = Self(rawValue: 1 << 4)
    static let playLast = Self(rawValue: 1 << 5)
}

struct MusicCatalogItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case song
        case album
        case artist
        case playlist
    }

    let id: MusicCatalogItemID
    let name: String
    let kind: Kind
    let sortName: String?
    let artists: [String]
    let albumArtist: String?
    let album: String?
    let albumID: String?
    let artistIDs: [String]
    let trackNumber: Int?
    let discNumber: Int?
    let childCount: Int?
    let duration: TimeInterval?
    let artwork: MusicArtworkReference?
    let isFavorite: Bool
    let capabilities: MusicItemCapabilities

    init(
        id: MusicCatalogItemID,
        name: String,
        kind: Kind,
        sortName: String?,
        artists: [String],
        albumArtist: String?,
        album: String?,
        albumID: String? = nil,
        artistIDs: [String] = [],
        trackNumber: Int?,
        discNumber: Int?,
        childCount: Int?,
        duration: TimeInterval?,
        artwork: MusicArtworkReference?,
        isFavorite: Bool,
        capabilities: MusicItemCapabilities
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sortName = sortName
        self.artists = artists
        self.albumArtist = albumArtist
        self.album = album
        self.albumID = albumID
        self.artistIDs = artistIDs
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.childCount = childCount
        self.duration = duration
        self.artwork = artwork
        self.isFavorite = isFavorite
        self.capabilities = capabilities
    }

    var artworkItemID: String { artwork?.opaqueItemID ?? id.opaqueID }
    var primaryImageTag: String? { artwork?.imageTag }
    var indexNumber: Int? { trackNumber }
    var parentIndexNumber: Int? { discNumber }

    var albumNavigationItem: MusicCatalogItem? {
        guard let album, let albumID else { return nil }
        return MusicCatalogItem(
            id: MusicCatalogItemID(
                source: id.source,
                accountScope: id.accountScope,
                opaqueID: albumID
            ),
            name: album,
            kind: .album,
            sortName: nil,
            artists: artists,
            albumArtist: albumArtist,
            album: nil,
            albumID: nil,
            trackNumber: nil,
            discNumber: nil,
            childCount: nil,
            duration: nil,
            artwork: artwork,
            isFavorite: false,
            capabilities: [.navigate, .play, .shuffle, .favorite]
        )
    }

    var artistNavigationItem: MusicCatalogItem? {
        guard let artistID = artistIDs.first else { return nil }
        return MusicCatalogItem(
            id: MusicCatalogItemID(
                source: id.source,
                accountScope: id.accountScope,
                opaqueID: artistID
            ),
            name: artists.first ?? albumArtist ?? "Artist",
            kind: .artist,
            sortName: nil,
            artists: [],
            albumArtist: nil,
            album: nil,
            albumID: nil,
            artistIDs: [],
            trackNumber: nil,
            discNumber: nil,
            childCount: nil,
            duration: nil,
            artwork: nil,
            isFavorite: false,
            capabilities: [.navigate, .play, .shuffle, .favorite]
        )
    }

    var displayArtist: String {
        if let albumArtist, !albumArtist.isEmpty { return albumArtist }
        if !artists.isEmpty { return artists.joined(separator: ", ") }
        return "Unknown artist"
    }
}

enum MusicCatalogKind: String, Codable, Sendable {
    case albums
    case artists
    case songs
    case playlists
    case search
    case albumTracks
    case artistTracks
    case playlistTracks
    case favorites
    case recentlyAdded
}

struct MusicCatalogCursor: Sendable {
    let identity: String
    var offsets: [String: Int]
    var totals: [String: Int]
    var buffers: [String: [MusicCatalogItem]]
    var exhaustedSources: Set<String>
    var seenItemIDs: Set<MusicCatalogItemID>
}

struct MusicCatalogPage: Sendable {
    let items: [MusicCatalogItem]
    let totalRecordCount: Int
    let cursor: MusicCatalogCursor?

    var hasMore: Bool { cursor != nil }
}

protocol MusicLibraryProviding: Sendable {
    func page(
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID?,
        cursor: MusicCatalogCursor?,
        limit: Int,
        searchTerm: String?
    ) async throws -> MusicCatalogPage
}

protocol MusicItemActionProviding: Sendable {
    func setFavorite(
        _ isFavorite: Bool,
        for itemID: MusicCatalogItemID
    ) async throws
}

protocol MusicLyricsProviding: Sendable {
    func lyrics(for itemID: MusicCatalogItemID) async throws -> MusicLyrics?
}
