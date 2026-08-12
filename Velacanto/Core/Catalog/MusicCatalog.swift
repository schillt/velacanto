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
    let trackNumber: Int?
    let discNumber: Int?
    let childCount: Int?
    let duration: TimeInterval?
    let artwork: MusicArtworkReference?
    let isFavorite: Bool
    let capabilities: MusicItemCapabilities

    var artworkItemID: String { artwork?.opaqueItemID ?? id.opaqueID }
    var primaryImageTag: String? { artwork?.imageTag }
    var indexNumber: Int? { trackNumber }
    var parentIndexNumber: Int? { discNumber }

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
