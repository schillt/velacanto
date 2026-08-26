import Foundation
import Network
import os

/// Validates and normalizes a server root before any authenticated request.
///
/// HTTPS is required except for a user-selected local network server. The
/// HTTP exception is deliberately limited to `localhost`, `.local` and
/// unqualified host names; IPv4 loopback (`127.0.0.0/8`), private (`10/8`,
/// `172.16/12`, `192.168/16`), and link-local (`169.254/16`) addresses; and
/// IPv6 loopback (`::1`), unique-local (`fc00::/7`), and link-local
/// (`fe80::/10`) addresses. All other destinations require HTTPS.
///
/// This is a LAN compatibility exception, not a trust bypass: certificate
/// validation remains normal for HTTPS, and users must choose only trusted
/// local networks. Credentials in user info, query strings, and fragments are
/// rejected so configuration cannot carry or accidentally display secrets.
struct JellyfinServerURL: Equatable, Sendable {
    let url: URL

    init(_ userInput: String) throws {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            !trimmed.contains(where: \.isWhitespace),
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            scheme == "https" || scheme == "http",
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil
        else {
            throw JellyfinServerURLError.invalidAddress
        }

        if scheme == "http", !Self.isLocalHost(host) {
            throw JellyfinServerURLError.insecureRemoteAddress
        }

        components.scheme = scheme
        components.host = host.lowercased()
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let normalizedURL = components.url else {
            throw JellyfinServerURLError.invalidAddress
        }
        url = normalizedURL
    }

    private static func isLocalHost(_ rawHost: String) -> Bool {
        let host =
            rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        if host == "localhost"
            || host.hasSuffix(".local")
            || (!host.contains(".") && !host.contains(":"))
        {
            return true
        }

        if let octets = ipv4Octets(host) {
            return octets[0] == 10
                || octets[0] == 127
                || (octets[0] == 169 && octets[1] == 254)
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }

        return isLocalIPv6Address(host)
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard
            parts.count == 4,
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }

        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private static func isLocalIPv6Address(_ host: String) -> Bool {
        guard let address = IPv6Address(host) else { return false }
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 16 else { return false }

        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isUniqueLocal = bytes[0] & 0xFE == 0xFC
        let isLinkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
        return isLoopback || isUniqueLocal || isLinkLocal
    }
}

enum JellyfinServerURLError: LocalizedError, Equatable {
    case invalidAddress
    case insecureRemoteAddress

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Enter a complete Jellyfin URL, including http:// or https://."
        case .insecureRemoteAddress:
            "Plain HTTP is allowed only for local-network Jellyfin servers. Use HTTPS for remote servers."
        }
    }
}

enum JellyfinPlaybackMethod: String, Equatable, Sendable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"

    var transportKind: PlaybackTransportKind {
        switch self {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcoding
        }
    }
}

struct JellyfinPlaybackResolution: Equatable, Sendable {
    let streamURL: URL
    let playSessionID: String
    let playMethod: JellyfinPlaybackMethod
    let container: String?

    init(
        streamURL: URL,
        playSessionID: String,
        playMethod: JellyfinPlaybackMethod,
        container: String? = nil
    ) {
        self.streamURL = streamURL
        self.playSessionID = playSessionID
        self.playMethod = playMethod
        self.container = container
    }
}

struct JellyfinLyricsResponse: Decodable, Equatable, Sendable {
    let lyrics: [JellyfinLyricLine]

    private enum CodingKeys: String, CodingKey {
        case lyrics = "Lyrics"
    }
}

struct JellyfinLyricLine: Decodable, Equatable, Sendable {
    let text: String
    let start: Int64?

    private enum CodingKeys: String, CodingKey {
        case text = "Text"
        case start = "Start"
    }
}

struct JellyfinPlaybackInfoResponse: Decodable, Equatable, Sendable {
    let mediaSources: [JellyfinPlaybackMediaSource]
    let playSessionID: String?
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionID = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

struct JellyfinPlaybackMediaSource: Decodable, Equatable, Sendable {
    let id: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool
    let supportsTranscoding: Bool
    let transcodingURL: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case container = "Container"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingURL = "TranscodingUrl"
    }
}

struct JellyfinServerInfo: Decodable, Equatable, Sendable {
    let id: String
    let serverName: String
    let version: String
    let startupWizardCompleted: Bool?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}

struct JellyfinUser: Decodable, Equatable, Sendable {
    let id: String
    let name: String
    let primaryImageTag: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case primaryImageTag = "PrimaryImageTag"
    }

    init(id: String, name: String, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        primaryImageTag = try container.decodeIfPresent(
            String.self,
            forKey: .primaryImageTag
        )
    }
}

struct JellyfinAuthenticationResult: Decodable, Equatable, Sendable {
    let user: JellyfinUser
    let accessToken: String

    private enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

enum JellyfinItemKind: String, Sendable {
    case song = "audio"
    case album = "musicalbum"
    case artist = "musicartist"
    case playlist

    init?(apiValue: String?) {
        guard let apiValue else { return nil }
        self.init(rawValue: apiValue.lowercased())
    }
}

struct JellyfinItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let type: String?
    let collectionType: String?
    let albumArtist: String?
    let sortName: String?
    let artists: [String]
    let artistItems: [JellyfinArtistReference]
    let genres: [String]
    let genreItems: [JellyfinGenreReference]
    let productionYear: Int?
    let album: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let childCount: Int?
    let runTimeTicks: Int64?
    let container: String?
    let albumID: String?
    let imageTags: [String: String]
    let albumPrimaryImageTag: String?
    let userData: JellyfinUserData?

    var displayArtist: String {
        if let albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        if !artists.isEmpty {
            return artists.joined(separator: ", ")
        }
        return "Unknown artist"
    }

    var artworkItemID: String {
        albumID ?? id
    }

    var primaryImageTag: String? {
        imageTags["Primary"] ?? albumPrimaryImageTag
    }

    var duration: TimeInterval? {
        guard let runTimeTicks, runTimeTicks > 0 else { return nil }
        return TimeInterval(runTimeTicks) / 10_000_000
    }

    var kind: JellyfinItemKind? {
        JellyfinItemKind(apiValue: type)
    }

    var isFavorite: Bool { userData?.isFavorite ?? false }

    var isMusicLibrary: Bool {
        collectionType?.caseInsensitiveCompare("music") == .orderedSame
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case albumArtist = "AlbumArtist"
        case sortName = "SortName"
        case artists = "Artists"
        case artistItems = "ArtistItems"
        case genres = "Genres"
        case genreItems = "GenreItems"
        case productionYear = "ProductionYear"
        case album = "Album"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case runTimeTicks = "RunTimeTicks"
        case container = "Container"
        case albumID = "AlbumId"
        case imageTags = "ImageTags"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case userData = "UserData"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        collectionType = try container.decodeIfPresent(String.self, forKey: .collectionType)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        sortName = try container.decodeIfPresent(String.self, forKey: .sortName)
        artists = try container.decodeIfPresent([String].self, forKey: .artists) ?? []
        artistItems =
            try container.decodeIfPresent(
                [JellyfinArtistReference].self,
                forKey: .artistItems
            ) ?? []
        genres = try container.decodeIfPresent([String].self, forKey: .genres) ?? []
        genreItems =
            try container.decodeIfPresent(
                [JellyfinGenreReference].self,
                forKey: .genreItems
            ) ?? []
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        indexNumber = try container.decodeIfPresent(Int.self, forKey: .indexNumber)
        parentIndexNumber = try container.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        runTimeTicks = try container.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        albumID = try container.decodeIfPresent(String.self, forKey: .albumID)
        imageTags =
            try container.decodeIfPresent([String: String].self, forKey: .imageTags)
            ?? [:]
        albumPrimaryImageTag = try container.decodeIfPresent(
            String.self,
            forKey: .albumPrimaryImageTag
        )
        userData = try container.decodeIfPresent(JellyfinUserData.self, forKey: .userData)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(collectionType, forKey: .collectionType)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(sortName, forKey: .sortName)
        try container.encode(artists, forKey: .artists)
        try container.encode(artistItems, forKey: .artistItems)
        try container.encode(genres, forKey: .genres)
        try container.encode(genreItems, forKey: .genreItems)
        try container.encodeIfPresent(productionYear, forKey: .productionYear)
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        try container.encodeIfPresent(childCount, forKey: .childCount)
        try container.encodeIfPresent(runTimeTicks, forKey: .runTimeTicks)
        try container.encodeIfPresent(self.container, forKey: .container)
        try container.encodeIfPresent(albumID, forKey: .albumID)
        try container.encode(imageTags, forKey: .imageTags)
        try container.encodeIfPresent(
            albumPrimaryImageTag,
            forKey: .albumPrimaryImageTag
        )
        try container.encodeIfPresent(userData, forKey: .userData)
    }
}

struct JellyfinArtistReference: Codable, Equatable, Sendable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinGenreReference: Codable, Equatable, Sendable {
    let id: String
    let name: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
    }
}

struct JellyfinUserData: Codable, Equatable, Sendable {
    let isFavorite: Bool

    private enum CodingKeys: String, CodingKey {
        case isFavorite = "IsFavorite"
    }
}

struct JellyfinItemsResponse: Decodable, Equatable, Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int
    let startIndex: Int

    private enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items =
            try container.decodeIfPresent(
                [JellyfinItem].self,
                forKey: .items
            ) ?? []
        totalRecordCount =
            try container.decodeIfPresent(
                Int.self,
                forKey: .totalRecordCount
            ) ?? items.count
        startIndex =
            try container.decodeIfPresent(
                Int.self,
                forKey: .startIndex
            ) ?? 0
    }
}

struct JellyfinItemPage: Equatable, Sendable {
    let items: [JellyfinItem]
    let startIndex: Int
    let totalRecordCount: Int
    let consumedItemCount: Int

    var nextStartIndex: Int {
        startIndex + consumedItemCount
    }

    var hasMore: Bool {
        nextStartIndex < totalRecordCount
    }

    init(
        items: [JellyfinItem],
        startIndex: Int,
        totalRecordCount: Int,
        consumedItemCount: Int? = nil
    ) {
        self.items = items
        self.startIndex = startIndex
        self.totalRecordCount = totalRecordCount
        self.consumedItemCount = consumedItemCount ?? items.count
    }

    init(_ response: JellyfinItemsResponse) {
        self.init(
            items: response.items,
            startIndex: response.startIndex,
            totalRecordCount: response.totalRecordCount,
            consumedItemCount: response.items.count
        )
    }
}

enum JellyfinHomeCollection: Equatable, Sendable {
    case favorites
    case mostListened
    case recentlyAdded
    case recentlyAddedTracks
}

struct JellyfinRequestBuilder: Sendable {
    private static let nativeAudioContainers = [
        "mp3", "aac", "m4a", "m4b", "flac", "wav",
    ]

    let server: JellyfinServerURL
    let deviceID: String
    let accessToken: String?

    func request(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) throws -> URLRequest {
        var endpoint = server.url
        for component in pathComponents {
            endpoint.appendPathComponent(component)
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw JellyfinAPIError.invalidResponse
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw JellyfinAPIError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        // Metadata responses are small. Failing within a bounded interval keeps
        // navigation usable and lets a new request generation use a fresh
        // connection pool instead of waiting behind a wedged task.
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let authorization = authorizationHeader
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(authorization, forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    func playbackInfoRequest(itemID: String, userID: String) throws -> URLRequest {
        struct DirectPlayProfile: Encodable {
            let container: String
            let type = "Audio"

            private enum CodingKeys: String, CodingKey {
                case container = "Container"
                case type = "Type"
            }
        }

        struct TranscodingProfile: Encodable {
            let container = "mp3"
            let type = "Audio"
            let audioCodec = "mp3"
            let `protocol` = "http"
            let context = "Streaming"

            private enum CodingKeys: String, CodingKey {
                case container = "Container"
                case type = "Type"
                case audioCodec = "AudioCodec"
                case `protocol` = "Protocol"
                case context = "Context"
            }
        }

        struct DeviceProfile: Encodable {
            let maxStreamingBitrate: Int
            let maxStaticBitrate: Int
            let musicStreamingTranscodingBitrate: Int
            let maxStaticMusicBitrate: Int
            let directPlayProfiles: [DirectPlayProfile]
            let transcodingProfiles = [TranscodingProfile()]

            private enum CodingKeys: String, CodingKey {
                case maxStreamingBitrate = "MaxStreamingBitrate"
                case maxStaticBitrate = "MaxStaticBitrate"
                case musicStreamingTranscodingBitrate =
                    "MusicStreamingTranscodingBitrate"
                case maxStaticMusicBitrate = "MaxStaticMusicBitrate"
                case directPlayProfiles = "DirectPlayProfiles"
                case transcodingProfiles = "TranscodingProfiles"
            }
        }

        struct Payload: Encodable {
            let userID: String
            let maxStreamingBitrate: Int
            let deviceProfile: DeviceProfile
            let enableDirectPlay = true
            let enableDirectStream = true
            let enableTranscoding = true
            let allowAudioStreamCopy = true

            private enum CodingKeys: String, CodingKey {
                case userID = "UserId"
                case maxStreamingBitrate = "MaxStreamingBitrate"
                case deviceProfile = "DeviceProfile"
                case enableDirectPlay = "EnableDirectPlay"
                case enableDirectStream = "EnableDirectStream"
                case enableTranscoding = "EnableTranscoding"
                case allowAudioStreamCopy = "AllowAudioStreamCopy"
            }
        }

        // Keep direct play limited to file types AVURLAsset supports natively
        // across Velacanto's Apple targets. In particular, WebM/WebM audio are
        // not native AVPlayer asset types; Jellyfin must transcode those rather
        // than handing an unsupported URL to the player. Ogg support varies by
        // OS generation, so it remains on the safe transcoding path too.
        let maximumDirectPlayBitrate = 100_000_000
        let musicTranscodingBitrate = 320_000
        let payload = Payload(
            userID: userID,
            maxStreamingBitrate: maximumDirectPlayBitrate,
            deviceProfile: DeviceProfile(
                maxStreamingBitrate: maximumDirectPlayBitrate,
                maxStaticBitrate: maximumDirectPlayBitrate,
                musicStreamingTranscodingBitrate: musicTranscodingBitrate,
                maxStaticMusicBitrate: maximumDirectPlayBitrate,
                directPlayProfiles: Self.nativeAudioContainers.map(DirectPlayProfile.init)
            )
        )
        var request = try request(
            pathComponents: ["Items", itemID, "PlaybackInfo"],
            method: "POST",
            body: JSONEncoder().encode(payload)
        )
        // PlaybackInfo gates every skip, previous, and history replay. Give one
        // bounded negotiation the same total budget the former two-attempt
        // path consumed, without creating a second DNS/TLS/VPN flow.
        request.timeoutInterval = 8
        request.networkServiceType = .responsiveData
        return request
    }

    func directFileResolution(
        itemID: String,
        container: String
    ) throws -> JellyfinPlaybackResolution? {
        guard let nativeContainer = nativeAudioContainer(container) else {
            return nil
        }
        let playSessionID = UUID().uuidString
        let url = try request(
            pathComponents: ["Items", itemID, "File"],
            queryItems: [
                URLQueryItem(name: "DeviceId", value: deviceID),
                URLQueryItem(name: "api_key", value: accessToken),
            ]
        ).url
        guard let url else { throw JellyfinAPIError.invalidResponse }
        return JellyfinPlaybackResolution(
            streamURL: url,
            playSessionID: playSessionID,
            playMethod: .directPlay,
            container: nativeContainer
        )
    }

    func favoriteRequest(
        itemID: String,
        userID: String,
        isFavorite: Bool
    ) throws -> URLRequest {
        try request(
            pathComponents: ["Users", userID, "FavoriteItems", itemID],
            method: isFavorite ? "POST" : "DELETE"
        )
    }

    func playbackResolution(
        itemID: String,
        response: JellyfinPlaybackInfoResponse
    ) throws -> JellyfinPlaybackResolution {
        guard response.errorCode == nil else {
            throw JellyfinAPIError.unsupportedMedia
        }
        guard
            let playSessionID = response.playSessionID,
            !playSessionID.isEmpty,
            let source = response.mediaSources.first
        else {
            throw JellyfinAPIError.invalidResponse
        }

        // Current Jellyfin servers report SupportsDirectPlay explicitly.
        // Older responses used SupportsDirectStream for this decision, so keep
        // that as a compatibility fallback only when the direct-play field is
        // absent.
        let reportedContainer = source.container?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let directPlayContainer = reportedContainer.flatMap(nativeAudioContainer)
        let canDirectPlay =
            source.supportsDirectPlay ?? source.supportsDirectStream
        if canDirectPlay {
            return JellyfinPlaybackResolution(
                streamURL: try directPlayURL(
                    itemID: itemID,
                    mediaSourceID: source.id,
                    playSessionID: playSessionID,
                    container: directPlayContainer
                ),
                playSessionID: playSessionID,
                playMethod: .directPlay,
                container: directPlayContainer
            )
        }

        guard
            source.supportsTranscoding,
            let transcodingURL = source.transcodingURL,
            !transcodingURL.isEmpty
        else {
            throw JellyfinAPIError.unsupportedMedia
        }
        return JellyfinPlaybackResolution(
            streamURL: try authenticatedStreamURL(
                transcodingURL,
                playSessionID: playSessionID
            ),
            playSessionID: playSessionID,
            playMethod: .transcode,
            container: nil
        )
    }

    private func directPlayURL(
        itemID: String,
        mediaSourceID: String?,
        playSessionID: String,
        container: String?
    ) throws -> URL {
        var queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        if let mediaSourceID, !mediaSourceID.isEmpty {
            queryItems.append(
                URLQueryItem(name: "MediaSourceId", value: mediaSourceID)
            )
        }
        let streamComponent = container.map { "stream.\($0)" } ?? "stream"
        return try request(
            pathComponents: ["Audio", itemID, streamComponent],
            queryItems: queryItems
        ).url
            ?? {
                throw JellyfinAPIError.invalidResponse
            }()
    }

    private func nativeAudioContainer(_ value: String) -> String? {
        // MediaSourceInfo.Container may contain equivalent comma-separated
        // formats. Jellyfin's StreamBuilder selects the first format supported
        // by the device profile; mirror that normalization for the documented
        // stream.<container> route.
        for candidate in value.split(separator: ",") {
            let normalized = candidate.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased()
            if Self.nativeAudioContainers.contains(normalized) {
                return normalized
            }
        }
        return nil
    }

    private func authenticatedStreamURL(
        _ serverPath: String,
        playSessionID: String
    ) throws -> URL {
        guard
            let resolvedURL = URL(string: serverPath, relativeTo: server.url)?.absoluteURL,
            resolvedURL.scheme?.caseInsensitiveCompare(server.url.scheme ?? "") == .orderedSame,
            resolvedURL.host?.caseInsensitiveCompare(server.url.host ?? "") == .orderedSame,
            resolvedURL.port == server.url.port,
            var components = URLComponents(
                url: resolvedURL,
                resolvingAgainstBaseURL: false
            )
        else {
            throw JellyfinAPIError.invalidResponse
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll {
            $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame
                || $0.name.caseInsensitiveCompare("DeviceId") == .orderedSame
                || $0.name.caseInsensitiveCompare("api_key") == .orderedSame
        }
        queryItems.append(URLQueryItem(name: "PlaySessionId", value: playSessionID))
        queryItems.append(URLQueryItem(name: "DeviceId", value: deviceID))
        queryItems.append(URLQueryItem(name: "api_key", value: accessToken))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw JellyfinAPIError.invalidResponse
        }
        return url
    }

    func playbackReportRequest(
        pathComponents: [String],
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool,
        playMethod: JellyfinPlaybackMethod
    ) throws -> URLRequest {
        struct Payload: Encodable {
            let itemID: String
            let playSessionID: String
            let positionTicks: Int64
            let isPaused: Bool
            let canSeek: Bool
            let playMethod: String

            enum CodingKeys: String, CodingKey {
                case itemID = "ItemId"
                case playSessionID = "PlaySessionId"
                case positionTicks = "PositionTicks"
                case isPaused = "IsPaused"
                case canSeek = "CanSeek"
                case playMethod = "PlayMethod"
            }
        }

        var request = try request(
            pathComponents: pathComponents,
            method: "POST",
            body: JSONEncoder().encode(
                Payload(
                    itemID: itemID,
                    playSessionID: playSessionID,
                    positionTicks: positionTicks,
                    isPaused: isPaused,
                    canSeek: true,
                    playMethod: playMethod.rawValue
                )
            )
        )
        // Lifecycle telemetry is best effort. It must yield to PlaybackInfo
        // and visible user actions on a constrained connection.
        request.timeoutInterval = 4
        request.networkServiceType = .background
        return request
    }

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        return try imageRequest(
            pathComponents: ["Items", itemID, "Images", "Primary"],
            imageTag: imageTag, maxWidth: maxWidth, includesURLToken: true
        ).url
            ?? {
                throw JellyfinAPIError.invalidResponse
            }()
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URLRequest {
        try imageRequest(
            pathComponents: ["Items", itemID, "Images", "Primary"],
            imageTag: imageTag, maxWidth: maxWidth, includesURLToken: false
        )
    }

    func userImageURL(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        return try imageRequest(
            pathComponents: ["Users", userID, "Images", "Primary"],
            imageTag: imageTag, maxWidth: maxWidth, includesURLToken: true
        ).url
            ?? {
                throw JellyfinAPIError.invalidResponse
            }()
    }

    func userImageRequest(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URLRequest {
        try imageRequest(
            pathComponents: ["Users", userID, "Images", "Primary"],
            imageTag: imageTag, maxWidth: maxWidth, includesURLToken: false
        )
    }

    private func imageRequest(
        pathComponents: [String],
        imageTag: String?,
        maxWidth: Int,
        includesURLToken: Bool
    ) throws -> URLRequest {
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(max(maxWidth, 64))),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }
        if includesURLToken {
            queryItems.append(URLQueryItem(name: "api_key", value: accessToken))
        }
        return try request(pathComponents: pathComponents, queryItems: queryItems)
    }

    private var authorizationHeader: String {
        var value =
            "MediaBrowser Client=\"Velacanto\", Device=\"Apple device\", "
            + "DeviceId=\"\(headerSafe(deviceID))\", Version=\"0.1.0\""
        if let accessToken, !accessToken.isEmpty {
            value += ", Token=\"\(headerSafe(accessToken))\""
        }
        return value
    }

    private func headerSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}

/// Provider-facing, sendable Jellyfin endpoint contract for one configured
/// server and optional authenticated account.
///
/// Callers supply opaque Jellyfin IDs and receive provider response models or
/// negotiated playback/artwork requests; they must not construct endpoint URLs
/// or serialize credentials themselves. Implementations may be actors and must
/// be safe to call across concurrency domains. Failures are surfaced as
/// `JellyfinAPIError` for the session or presentation owner to classify; no
/// method logs authenticated URLs, tokens, or private media metadata. See
/// `docs/architecture.md` for the provider and session boundaries.
protocol JellyfinAPIService: Sendable {
    func publicServerInfo() async throws -> JellyfinServerInfo
    func authenticate(
        username: String,
        password: String
    ) async throws -> JellyfinAuthenticationResult
    func currentUser() async throws -> JellyfinUser
    func libraries(userID: String) async throws -> [JellyfinItem]
    func playbackResolution(
        itemID: String,
        userID: String
    ) async throws -> JellyfinPlaybackResolution
    func directPlaybackResolution(
        itemID: String,
        container: String
    ) async throws -> JellyfinPlaybackResolution?
    func lyrics(itemID: String) async throws -> JellyfinLyricsResponse?
    func setFavorite(
        _ isFavorite: Bool,
        itemID: String,
        userID: String
    ) async throws
    func albumsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage
    func artistsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage
    func songsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage
    func playlistsPage(
        userID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage
    func searchMusicPage(
        userID: String,
        query: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage
    func homeItemsPage(
        userID: String,
        collection: JellyfinHomeCollection,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage
    func musicGenres(userID: String) async throws -> [JellyfinItem]
    func genreItemsPage(
        userID: String,
        genreID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage
    func playlistItemsPage(
        userID: String,
        playlistID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage
    func tracksPage(
        userID: String,
        albumID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage
    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest
    func userImageRequest(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest
    func reportPlaybackStarted(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws
    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool,
        playMethod: JellyfinPlaybackMethod
    ) async throws
    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws
    func logout() async throws
}

extension JellyfinAPIService {
    func directPlaybackResolution(
        itemID: String,
        container: String
    ) async throws -> JellyfinPlaybackResolution? { nil }

    func lyrics(itemID: String) async throws -> JellyfinLyricsResponse? { nil }

    func musicGenres(userID: String) async throws -> [JellyfinItem] { [] }

    func genreItemsPage(
        userID: String,
        genreID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        JellyfinItemPage(items: [], startIndex: startIndex, totalRecordCount: 0)
    }

    func reportPlaybackStarted(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws {}

    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool,
        playMethod: JellyfinPlaybackMethod
    ) async throws {}

    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws {}

}

enum VelacantoNetworkPriority: Int, Sendable {
    case reporting
    case speculative
    case artwork
    case catalog
    case playback
}

enum VelacantoNetworkRequestContext {
    @TaskLocal static var priorityOverride: VelacantoNetworkPriority?
}

final class VelacantoNetworkPolicy: @unchecked Sendable {
    /// Serializes cancellation with waiter registration. Without this guard a
    /// task can be cancelled after `Task.isCancelled` is checked but before
    /// its continuation is inserted into `waiters`, leaving that continuation
    /// permanently stranded.
    private final class AdmissionCancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func registerIfActive(_ registration: () -> Void) -> Bool {
            lock.withLock {
                guard !isCancelled else { return false }
                registration()
                return true
            }
        }

        func cancel(_ cancellation: () -> Void) {
            lock.withLock {
                isCancelled = true
                cancellation()
            }
        }
    }

    private struct ActivePermit {
        let priority: VelacantoNetworkPriority
        var cancel: (@Sendable () -> Void)?
        var cancellationRequested = false
        var cancellationDelivered = false
    }

    private struct Waiter {
        let id: UUID
        let key: String?
        var priority: VelacantoNetworkPriority
        let continuation: CheckedContinuation<UUID?, Never>
    }

    private struct PlaybackQuiescenceWaiter {
        let id: UUID
        let startupToken: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    #if !DEBUG
        static let shared = VelacantoNetworkPolicy()
    #endif

    private let lock = NSLock()
    private let quarantineTransport: @Sendable () -> Void
    private let maximumActiveCount = 2
    private var startupTokens = Set<UUID>()
    private var activePermits: [UUID: ActivePermit] = [:]
    private var waiters: [Waiter] = []
    private var playbackQuiescenceWaiters: [PlaybackQuiescenceWaiter] = []
    private var terminalRemoteQuarantined = false

    init(
        quarantineTransport: @escaping @Sendable () -> Void = {
            VelacantoNetworkTransportRegistry.shared
                .enterTerminalRemoteQuarantine()
        }
    ) {
        self.quarantineTransport = quarantineTransport
    }

    var isTerminalRemoteQuarantined: Bool {
        lock.withLock { terminalRemoteQuarantined }
    }

    /// Atomically closes app-generated remote admission before the current
    /// playback startup permit is released. Existing cancellation closures
    /// remain the sole task owners; quarantine only invokes and drains them.
    func enterTerminalRemoteQuarantine() {
        let result:
            (
                didEnter: Bool,
                cancellations: [@Sendable () -> Void],
                admission: [Waiter],
                quiescence: [PlaybackQuiescenceWaiter]
            ) = lock.withLock {
                guard !terminalRemoteQuarantined else {
                    return (false, [], [], [])
                }
                terminalRemoteQuarantined = true
                var cancellations: [@Sendable () -> Void] = []
                for permit in activePermits.keys {
                    activePermits[permit]?.cancellationRequested = true
                    if let cancel = activePermits[permit]?.cancel,
                        activePermits[permit]?.cancellationDelivered == false
                    {
                        activePermits[permit]?.cancellationDelivered = true
                        cancellations.append(cancel)
                    }
                }
                let admission = waiters
                waiters.removeAll()
                let quiescence = playbackQuiescenceWaiters
                playbackQuiescenceWaiters.removeAll()
                return (true, cancellations, admission, quiescence)
            }
        guard result.didEnter else { return }

        quarantineTransport()
        for cancel in result.cancellations {
            cancel()
        }
        for waiter in result.admission {
            waiter.continuation.resume(returning: nil)
        }
        for waiter in result.quiescence {
            waiter.continuation.resume(returning: false)
        }
        PlaybackDiagnosticJournal.shared.record(
            "network-containment phase=entered active-cancelled=\(result.cancellations.count) queued-cancelled=\(result.admission.count) quiescence-cancelled=\(result.quiescence.count)"
        )
    }

    func beginPlaybackStartup(_ token: UUID) {
        let cancellations: [@Sendable () -> Void] = lock.withLock {
            guard !terminalRemoteQuarantined else { return [] }
            startupTokens.insert(token)
            var cancellations: [@Sendable () -> Void] = []
            for permit in activePermits.keys {
                guard activePermits[permit]?.priority != .playback else {
                    continue
                }
                activePermits[permit]?.cancellationRequested = true
                if let cancel = activePermits[permit]?.cancel,
                    activePermits[permit]?.cancellationDelivered == false
                {
                    activePermits[permit]?.cancellationDelivered = true
                    cancellations.append(cancel)
                }
            }
            return cancellations
        }
        for cancel in cancellations {
            cancel()
        }
    }

    func endPlaybackStartup(_ token: UUID) {
        let result:
            (
                admission: [(Waiter, UUID)],
                quiescence: [(PlaybackQuiescenceWaiter, Bool)]
            ) = lock.withLock {
                _ = startupTokens.remove(token)
                return (
                    drainWaitersLocked(),
                    drainPlaybackQuiescenceWaitersLocked()
                )
            }
        resume(result.admission)
        resumePlaybackQuiescence(result.quiescence)
    }

    /// Waits for cancellation-requested lower-priority work to release its
    /// actual permit. The startup token remains the sole admission owner; this
    /// only closes the gap between requesting cancellation and route release.
    func waitUntilPlaybackStartupQuiescent(_ token: UUID) async throws {
        let waiterID = UUID()
        let cancellationState = AdmissionCancellationState()
        let isAuthoritative = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediateResult: Bool?
                let registered = cancellationState.registerIfActive {
                    immediateResult = lock.withLock {
                        guard !terminalRemoteQuarantined else {
                            return false
                        }
                        guard startupTokens.contains(token) else {
                            return false
                        }
                        guard hasActiveNonPlaybackPermitLocked else {
                            return true
                        }
                        playbackQuiescenceWaiters.append(
                            PlaybackQuiescenceWaiter(
                                id: waiterID,
                                startupToken: token,
                                continuation: continuation
                            )
                        )
                        return nil
                    }
                }
                guard registered else {
                    continuation.resume(returning: false)
                    return
                }
                if let immediateResult {
                    continuation.resume(returning: immediateResult)
                }
            }
        } onCancel: {
            cancellationState.cancel {
                self.cancelPlaybackQuiescenceWaiter(waiterID)
            }
        }
        guard isAuthoritative else { throw CancellationError() }
        try Task.checkCancellation()
    }

    var playbackStartupCount: Int {
        lock.withLock { startupTokens.count }
    }

    func perform<Value: Sendable>(
        priority: VelacantoNetworkPriority,
        key: String? = nil,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let permit = await acquire(priority: priority, key: key) else {
            throw CancellationError()
        }
        defer { release(permit) }
        try Task.checkCancellation()
        let operationTask = Task {
            try await operation()
        }
        let shouldCancel = registerCancellation(
            { operationTask.cancel() },
            for: permit
        )
        if shouldCancel {
            operationTask.cancel()
        }
        return try await withTaskCancellationHandler {
            try await operationTask.value
        } onCancel: {
            operationTask.cancel()
        }
    }

    func promote(key: String, to priority: VelacantoNetworkPriority) {
        let resumptions: [(Waiter, UUID)] = lock.withLock {
            for index in waiters.indices where waiters[index].key == key {
                if priority.rawValue > waiters[index].priority.rawValue {
                    waiters[index].priority = priority
                }
            }
            sortWaitersLocked()
            return drainWaitersLocked()
        }
        resume(resumptions)
    }

    func hasQueuedRequest(key: String) -> Bool {
        lock.withLock {
            waiters.contains { $0.key == key }
        }
    }

    func hasPlaybackQuiescenceWaiter(for startupToken: UUID) -> Bool {
        lock.withLock {
            playbackQuiescenceWaiters.contains {
                $0.startupToken == startupToken
            }
        }
    }

    private func acquire(
        priority: VelacantoNetworkPriority,
        key: String?
    ) async -> UUID? {
        let waiterID = UUID()
        let cancellationState = AdmissionCancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediatePermit: UUID?
                var rejected = false
                let registered = cancellationState.registerIfActive {
                    immediatePermit = lock.withLock {
                        guard !terminalRemoteQuarantined else {
                            rejected = true
                            return nil
                        }
                        if canAdmitLocked(priority) {
                            let permit = UUID()
                            activePermits[permit] = ActivePermit(priority: priority)
                            return permit
                        }
                        waiters.append(
                            Waiter(
                                id: waiterID,
                                key: key,
                                priority: priority,
                                continuation: continuation
                            ))
                        sortWaitersLocked()
                        return nil
                    }
                }
                guard registered else {
                    continuation.resume(returning: nil)
                    return
                }
                if let immediatePermit {
                    continuation.resume(returning: immediatePermit)
                } else if rejected {
                    continuation.resume(returning: nil)
                }
            }
        } onCancel: {
            cancellationState.cancel {
                self.cancelWaiter(waiterID)
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        let waiter: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == waiterID })
            else {
                return nil
            }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: nil)
    }

    private func cancelPlaybackQuiescenceWaiter(_ waiterID: UUID) {
        let waiter: PlaybackQuiescenceWaiter? = lock.withLock {
            guard
                let index = playbackQuiescenceWaiters.firstIndex(where: {
                    $0.id == waiterID
                })
            else {
                return nil
            }
            return playbackQuiescenceWaiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }

    private func release(_ permit: UUID) {
        let result:
            (
                admission: [(Waiter, UUID)],
                quiescence: [(PlaybackQuiescenceWaiter, Bool)]
            ) = lock.withLock {
                activePermits[permit] = nil
                return (
                    drainWaitersLocked(),
                    drainPlaybackQuiescenceWaitersLocked()
                )
            }
        resume(result.admission)
        resumePlaybackQuiescence(result.quiescence)
    }

    private func registerCancellation(
        _ cancellation: @escaping @Sendable () -> Void,
        for permit: UUID
    ) -> Bool {
        lock.withLock {
            guard var activePermit = activePermits[permit] else { return true }
            activePermit.cancel = cancellation
            let shouldCancel =
                activePermit.cancellationRequested
                && !activePermit.cancellationDelivered
            if shouldCancel {
                activePermit.cancellationDelivered = true
            }
            activePermits[permit] = activePermit
            return shouldCancel
        }
    }

    private func canAdmitLocked(_ priority: VelacantoNetworkPriority) -> Bool {
        guard !terminalRemoteQuarantined else { return false }
        guard activePermits.count < maximumActiveCount else { return false }
        let hasActivePlayback = activePermits.values.contains {
            $0.priority == .playback
        }
        if priority == .playback {
            return !hasActivePlayback
        }
        guard startupTokens.isEmpty, !hasActivePlayback else { return false }
        return activePermits.isEmpty
    }

    private var hasActiveNonPlaybackPermitLocked: Bool {
        activePermits.values.contains { $0.priority != .playback }
    }

    private func drainWaitersLocked() -> [(Waiter, UUID)] {
        var resumptions: [(Waiter, UUID)] = []
        while let index = waiters.firstIndex(where: {
            canAdmitLocked($0.priority)
        }) {
            let waiter = waiters.remove(at: index)
            let permit = UUID()
            activePermits[permit] = ActivePermit(priority: waiter.priority)
            resumptions.append((waiter, permit))
        }
        return resumptions
    }

    private func sortWaitersLocked() {
        waiters.sort { lhs, rhs in
            lhs.priority.rawValue > rhs.priority.rawValue
        }
    }

    private func drainPlaybackQuiescenceWaitersLocked() -> [(PlaybackQuiescenceWaiter, Bool)] {
        var resumptions: [(PlaybackQuiescenceWaiter, Bool)] = []
        var retained: [PlaybackQuiescenceWaiter] = []
        for waiter in playbackQuiescenceWaiters {
            if !startupTokens.contains(waiter.startupToken) {
                resumptions.append((waiter, false))
            } else if !hasActiveNonPlaybackPermitLocked {
                resumptions.append((waiter, true))
            } else {
                retained.append(waiter)
            }
        }
        playbackQuiescenceWaiters = retained
        return resumptions
    }

    private func resume(_ resumptions: [(Waiter, UUID)]) {
        for (waiter, permit) in resumptions {
            waiter.continuation.resume(returning: permit)
        }
    }

    private func resumePlaybackQuiescence(
        _ resumptions: [(PlaybackQuiescenceWaiter, Bool)]
    ) {
        for (waiter, result) in resumptions {
            waiter.continuation.resume(returning: result)
        }
    }
}

/// Owns one reusable connection pool and one degraded-route circuit breaker
/// for a Jellyfin origin. A transport failure briefly rejects every new
/// app-generated request at admission instead of creating fresh DNS/TLS/VPN
/// flows from independent features.
final class VelacantoNetworkTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let makeSession: @Sendable () -> URLSession
    private var session: URLSession?
    private var latestSessionGeneration = 0
    private var degradedUntil: Date?
    private let degradedRouteCooldown: TimeInterval

    init(
        makeSession: @escaping @Sendable () -> URLSession =
            VelacantoNetworkTransport.makeDefaultSession,
        degradedRouteCooldown: TimeInterval = 5,
        startsQuarantined: Bool = false
    ) {
        self.makeSession = makeSession
        self.degradedRouteCooldown = degradedRouteCooldown
        if startsQuarantined {
            session = nil
        } else {
            latestSessionGeneration = 1
            session = makeSession()
        }
    }

    var hasLiveSession: Bool {
        lock.withLock { session != nil }
    }

    var activeSessionGeneration: Int? {
        lock.withLock {
            session == nil ? nil : latestSessionGeneration
        }
    }

    func enterTerminalRemoteQuarantine() {
        let invalidated: (session: URLSession, generation: Int)? =
            lock.withLock {
                guard let session else { return nil }
                let result = (session, latestSessionGeneration)
                self.session = nil
                degradedUntil = nil
                return result
            }
        guard let invalidated else { return }
        invalidated.session.invalidateAndCancel()
        PlaybackDiagnosticJournal.shared.record(
            "network-transport phase=invalidated generation=\(invalidated.generation)"
        )
    }

    func data(
        for request: URLRequest,
        monitorsRouteHealth: Bool = true
    ) async throws -> (Data, URLResponse) {
        let attempt: (session: URLSession, generation: Int)? = lock.withLock {
            if let degradedUntil, degradedUntil > Date() {
                return nil
            }
            degradedUntil = nil
            guard let session else { return nil }
            return (session, latestSessionGeneration)
        }
        guard let attempt else {
            throw VelacantoNetworkTransportSuppressed()
        }
        do {
            let response = try await attempt.session.data(for: request)
            if monitorsRouteHealth {
                lock.withLock {
                    if latestSessionGeneration == attempt.generation,
                        session != nil
                    {
                        degradedUntil = nil
                    }
                }
            }
            return response
        } catch {
            if monitorsRouteHealth, Self.degradesRoute(error) {
                lock.withLock {
                    if latestSessionGeneration == attempt.generation,
                        session != nil
                    {
                        degradedUntil = Date().addingTimeInterval(
                            degradedRouteCooldown
                        )
                    }
                }
            }
            throw VelacantoNetworkTransportFailure(underlying: error)
        }
    }

    private static func degradesRoute(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost,
            .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
            .appTransportSecurityRequiresSecureConnection,
            .secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A VPN-required route can be temporarily unavailable while its
        // Network Extension reconnects. Let the single admitted task wait for
        // that route; the resource deadline still bounds the wait.
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        return URLSession(
            configuration: configuration,
            delegate: VelacantoNetworkMetricsDelegate.shared,
            delegateQueue: nil
        )
    }
}

final class VelacantoNetworkTransportRegistry: @unchecked Sendable {
    static let shared = VelacantoNetworkTransportRegistry()

    private let lock = NSLock()
    private var transports: [String: VelacantoNetworkTransport] = [:]
    private var terminalRemoteQuarantined = false

    func transport(for url: URL) -> VelacantoNetworkTransport {
        let key = Self.originKey(for: url)
        return lock.withLock {
            if let transport = transports[key] {
                return transport
            }
            let transport = VelacantoNetworkTransport(
                startsQuarantined: terminalRemoteQuarantined
            )
            transports[key] = transport
            return transport
        }
    }

    func enterTerminalRemoteQuarantine() {
        let retained: [VelacantoNetworkTransport] = lock.withLock {
            guard !terminalRemoteQuarantined else { return [] }
            terminalRemoteQuarantined = true
            return Array(transports.values)
        }
        for transport in retained {
            transport.enterTerminalRemoteQuarantine()
        }
        PlaybackDiagnosticJournal.shared.record(
            "network-transport-registry phase=quarantined retained=\(retained.count)"
        )
    }

    private static func originKey(for url: URL) -> String {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        else {
            return "invalid-origin"
        }
        let scheme = components.scheme?.lowercased() ?? "unknown"
        let host = components.host?.lowercased() ?? "unknown"
        let port = components.port.map(String.init) ?? "default"
        return "\(scheme)|\(host)|\(port)"
    }
}

actor JellyfinAPIClient: JellyfinAPIService {
    private enum SessionLane: String, Sendable {
        case playback
        case interactive
        case background
    }

    private static let networkLogger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Network"
    )

    private let builder: JellyfinRequestBuilder
    private let fixedSession: URLSession?
    private let transport: VelacantoNetworkTransport
    private var interactiveSuppressedUntil: Date?
    private var backgroundSuppressedUntil: Date?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        server: JellyfinServerURL,
        deviceID: String,
        accessToken: String? = nil,
        session: URLSession? = nil,
        transport: VelacantoNetworkTransport? = nil
    ) {
        builder = JellyfinRequestBuilder(
            server: server,
            deviceID: deviceID,
            accessToken: accessToken
        )
        fixedSession = session
        self.transport =
            transport
            ?? VelacantoNetworkTransportRegistry.shared.transport(for: server.url)
    }

    func publicServerInfo() async throws -> JellyfinServerInfo {
        try await execute(
            builder.request(pathComponents: ["System", "Info", "Public"]),
            as: JellyfinServerInfo.self
        )
    }

    func authenticate(
        username: String,
        password: String
    ) async throws -> JellyfinAuthenticationResult {
        struct Body: Encodable {
            let username: String
            let password: String

            private enum CodingKeys: String, CodingKey {
                case username = "Username"
                case password = "Pw"
            }
        }

        let body = try encoder.encode(Body(username: username, password: password))
        let request = try builder.request(
            pathComponents: ["Users", "AuthenticateByName"],
            method: "POST",
            body: body
        )
        return try await execute(request, as: JellyfinAuthenticationResult.self)
    }

    func currentUser() async throws -> JellyfinUser {
        try await execute(
            builder.request(pathComponents: ["Users", "Me"]),
            as: JellyfinUser.self
        )
    }

    func lyrics(itemID: String) async throws -> JellyfinLyricsResponse? {
        do {
            return try await execute(
                builder.request(pathComponents: ["Audio", itemID, "Lyrics"]),
                as: JellyfinLyricsResponse.self
            )
        } catch JellyfinAPIError.httpStatus(404) {
            return nil
        }
    }

    func libraries(userID: String) async throws -> [JellyfinItem] {
        let query = [URLQueryItem(name: "UserId", value: userID)]
        do {
            let response = try await execute(
                builder.request(pathComponents: ["UserViews"], queryItems: query),
                as: JellyfinItemsResponse.self
            )
            return response.items.filter(\.isMusicLibrary)
        } catch JellyfinAPIError.httpStatus(404) {
            let response = try await execute(
                builder.request(pathComponents: ["Users", userID, "Views"]),
                as: JellyfinItemsResponse.self
            )
            return response.items.filter(\.isMusicLibrary)
        }
    }

    func artistsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            parentID: libraryID,
            fields: "ChildCount,ImageTags",
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm,
            additional: [URLQueryItem(name: "UserId", value: userID)]
        )
        let response = try await execute(
            builder.request(pathComponents: ["Artists", "AlbumArtists"], queryItems: query),
            as: JellyfinItemsResponse.self
        )
        return JellyfinItemPage(response)
    }

    func songsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            parentID: libraryID,
            itemTypes: "Audio",
            fields: Self.trackFields,
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm,
            additional: artistID.map { [URLQueryItem(name: "ArtistIds", value: $0)] } ?? []
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func playlistsPage(
        userID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            itemTypes: "Playlist",
            fields: "ChildCount,ImageTags,RunTimeTicks",
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func searchMusicPage(
        userID: String,
        query: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let queryItems = pagedItemQuery(
            itemTypes: "Audio,MusicAlbum,MusicArtist,Playlist",
            fields: Self.searchFields,
            startIndex: startIndex,
            limit: limit,
            searchTerm: query
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: queryItems)
        )
    }

    func homeItemsPage(
        userID: String,
        collection: JellyfinHomeCollection,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query: [URLQueryItem]
        switch collection {
        case .favorites:
            query = pagedItemQuery(
                itemTypes: "Audio,MusicAlbum,MusicArtist,Playlist",
                fields: Self.searchFields,
                startIndex: startIndex,
                limit: limit,
                additional: [URLQueryItem(name: "Filters", value: "IsFavorite")]
            )
        case .mostListened:
            query = pagedItemQuery(
                itemTypes: "MusicAlbum",
                fields: "AlbumArtist,Artists,ChildCount,Genres,GenreItems,ImageTags,SortName",
                sortBy: "PlayCount",
                sortOrder: "Descending",
                startIndex: startIndex,
                limit: limit
            )
        case .recentlyAdded:
            query = pagedItemQuery(
                itemTypes: "MusicAlbum",
                fields: "AlbumArtist,Artists,ChildCount,Genres,GenreItems,ImageTags,SortName",
                sortBy: "DateCreated",
                sortOrder: "Descending",
                startIndex: startIndex,
                limit: limit
            )
        case .recentlyAddedTracks:
            query = pagedItemQuery(
                itemTypes: "Audio",
                fields: Self.searchFields,
                sortBy: "DateCreated",
                sortOrder: "Descending",
                startIndex: startIndex,
                limit: limit
            )
        }
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func musicGenres(userID: String) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Fields", value: "ChildCount"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "false"),
        ]
        let response = try await execute(
            builder.request(pathComponents: ["MusicGenres"], queryItems: query),
            as: JellyfinItemsResponse.self
        )
        return response.items
    }

    func genreItemsPage(
        userID: String,
        genreID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            itemTypes: "MusicAlbum",
            fields: "AlbumArtist,Artists,ChildCount,ImageTags,SortName",
            sortBy: "AlbumArtist,SortName",
            startIndex: startIndex,
            limit: limit,
            additional: [
                URLQueryItem(name: "GenreIds", value: genreID),
                URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
            ]
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func playlistItemsPage(
        userID: String,
        playlistID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            fields: Self.trackFields,
            sortBy: nil,
            startIndex: startIndex,
            limit: limit,
            recursively: false,
            additional: [URLQueryItem(name: "UserId", value: userID)]
        )
        let response = try await execute(
            builder.request(
                pathComponents: ["Playlists", playlistID, "Items"],
                queryItems: query
            ),
            as: JellyfinItemsResponse.self
        )
        let songs = response.items.filter { $0.kind == .song }
        return JellyfinItemPage(
            items: songs,
            startIndex: response.startIndex,
            totalRecordCount: response.totalRecordCount,
            consumedItemCount: response.items.count
        )
    }

    func albumsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            parentID: libraryID,
            itemTypes: "MusicAlbum",
            fields: "AlbumArtist,Artists,ArtistItems,ChildCount,ImageTags,SortName",
            sortBy: "AlbumArtist,SortName",
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm,
            additional: artistID.map { [URLQueryItem(name: "AlbumArtistIds", value: $0)] } ?? []
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func tracksPage(
        userID: String,
        albumID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query = pagedItemQuery(
            parentID: albumID,
            itemTypes: "Audio",
            fields: Self.trackFields,
            sortBy: "ParentIndexNumber,IndexNumber,SortName",
            startIndex: startIndex,
            limit: limit
        )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func playbackResolution(
        itemID: String,
        userID: String
    ) async throws -> JellyfinPlaybackResolution {
        let response = try await execute(
            builder.playbackInfoRequest(itemID: itemID, userID: userID),
            as: JellyfinPlaybackInfoResponse.self
        )
        return try builder.playbackResolution(
            itemID: itemID,
            response: response
        )
    }

    func directPlaybackResolution(
        itemID: String,
        container: String
    ) async throws -> JellyfinPlaybackResolution? {
        try builder.directFileResolution(
            itemID: itemID,
            container: container
        )
    }

    func setFavorite(
        _ isFavorite: Bool,
        itemID: String,
        userID: String
    ) async throws {
        let request = try builder.favoriteRequest(
            itemID: itemID,
            userID: userID,
            isFavorite: isFavorite
        )
        _ = try await executeWithoutResponse(request)
    }

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        try builder.artworkURL(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URLRequest {
        try builder.artworkRequest(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func reportPlaybackStarted(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: false,
            playMethod: playMethod
        )
    }

    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool,
        playMethod: JellyfinPlaybackMethod
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing", "Progress"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: isPaused,
            playMethod: playMethod
        )
    }

    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        playMethod: JellyfinPlaybackMethod
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing", "Stopped"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: true,
            playMethod: playMethod
        )
    }

    func userImageURL(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        try builder.userImageURL(
            userID: userID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func userImageRequest(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URLRequest {
        try builder.userImageRequest(
            userID: userID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func logout() async throws {
        let request = try builder.request(
            pathComponents: ["Sessions", "Logout"],
            method: "POST"
        )
        _ = try await executeWithoutResponse(request)
    }

    private func itemsResponse(
        userID: String,
        query: [URLQueryItem]
    ) async throws -> JellyfinItemsResponse {
        do {
            return try await execute(
                builder.request(
                    pathComponents: ["Users", userID, "Items"],
                    queryItems: query
                ),
                as: JellyfinItemsResponse.self
            )
        } catch JellyfinAPIError.httpStatus(404) {
            var currentQuery = query
            currentQuery.append(URLQueryItem(name: "UserId", value: userID))
            return try await execute(
                builder.request(pathComponents: ["Items"], queryItems: currentQuery),
                as: JellyfinItemsResponse.self
            )
        }
    }

    private static let trackFields =
        "Album,AlbumArtist,Artists,ArtistItems,AlbumId,AlbumPrimaryImageTag,Container,Genres,GenreItems,ImageTags,RunTimeTicks,UserData"
    private static let searchFields = trackFields + ",ChildCount"

    private func pagedItemQuery(
        parentID: String? = nil,
        itemTypes: String? = nil,
        fields: String,
        sortBy: String? = "SortName",
        sortOrder: String = "Ascending",
        startIndex: Int,
        limit: Int,
        searchTerm: String? = nil,
        recursively: Bool = true,
        additional: [URLQueryItem] = []
    ) -> [URLQueryItem] {
        var items = additional
        if let parentID { items.append(URLQueryItem(name: "ParentId", value: parentID)) }
        if let itemTypes { items.append(URLQueryItem(name: "IncludeItemTypes", value: itemTypes)) }
        if recursively { items.append(URLQueryItem(name: "Recursive", value: "true")) }
        if let sortBy {
            items.append(URLQueryItem(name: "SortBy", value: sortBy))
            items.append(URLQueryItem(name: "SortOrder", value: sortOrder))
        }
        items.append(URLQueryItem(name: "Fields", value: fields))
        items += pageQueryItems(
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
        return items
    }

    private func pageQueryItems(
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "StartIndex", value: String(max(startIndex, 0))),
            URLQueryItem(name: "Limit", value: String(max(limit, 1))),
        ]
        if let searchTerm, !searchTerm.isEmpty {
            items.append(URLQueryItem(name: "SearchTerm", value: searchTerm))
        }
        return items
    }

    private func sendPlaybackReport(
        path: [String],
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool,
        playMethod: JellyfinPlaybackMethod
    ) async throws {
        let request = try builder.playbackReportRequest(
            pathComponents: path,
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: isPaused,
            playMethod: playMethod
        )
        _ = try await executeWithoutResponse(request)
    }

    private func execute<Response: Decodable & Sendable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let data = try await executeWithoutResponse(request)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw JellyfinAPIError.invalidResponse
        }
    }

    private func executeWithoutResponse(
        _ request: URLRequest
    ) async throws -> Data {
        let lane = sessionLane(for: request)
        let requestKind = diagnosticRequestKind(for: request, lane: lane)
        if lane == .interactive, isInteractiveRequestSuppressed {
            PlaybackDiagnosticJournal.shared.record(
                "network-request kind=\(requestKind) lane=interactive phase=suppressed"
            )
            throw JellyfinAPIError.unreachable
        }
        if lane == .background, isBackgroundRequestSuppressed {
            PlaybackDiagnosticJournal.shared.record(
                "network-request kind=\(requestKind) lane=background phase=dropped"
            )
            throw JellyfinAPIError.unreachable
        }
        try Task.checkCancellation()
        let priority =
            VelacantoNetworkRequestContext.priorityOverride
            ?? networkPriority(for: lane)
        let attempt = 1
        let startedAt = Date()
        PlaybackDiagnosticJournal.shared.record(
            "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=started attempt=\(attempt) priority=\(priority.rawValue)"
        )
        do {
            let (data, response) = try await VelacantoNetworkPolicy.shared.perform(
                priority: priority
            ) { @Sendable () async throws -> (Data, URLResponse) in
                PlaybackDiagnosticJournal.shared.record(
                    "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=admitted attempt=\(attempt) priority=\(priority.rawValue)"
                )
                guard await self.canStartAdmittedRequest(in: lane) else {
                    throw JellyfinAPIError.unreachable
                }
                if let fixedSession = self.fixedSession {
                    return try await fixedSession.data(for: request)
                }
                return try await self.transport.data(
                    for: request,
                    monitorsRouteHealth: lane != .background
                )
            }
            if lane == .background {
                backgroundSuppressedUntil = nil
            } else if lane == .interactive {
                interactiveSuppressedUntil = nil
            }
            guard let response = response as? HTTPURLResponse else {
                throw JellyfinAPIError.invalidResponse
            }
            switch response.statusCode {
            case 200..<300:
                PlaybackDiagnosticJournal.shared.record(
                    "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=succeeded attempt=\(attempt) elapsed-ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
                return data
            case 401, 403:
                PlaybackDiagnosticJournal.shared.record(
                    "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=failed category=authentication attempt=\(attempt)"
                )
                throw JellyfinAPIError.unauthorized
            default:
                PlaybackDiagnosticJournal.shared.record(
                    "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=failed category=http status=\(response.statusCode) attempt=\(attempt)"
                )
                throw JellyfinAPIError.httpStatus(response.statusCode)
            }
        } catch let error as JellyfinAPIError {
            throw error
        } catch is CancellationError {
            PlaybackDiagnosticJournal.shared.record(
                "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=cancelled attempt=\(attempt)"
            )
            throw CancellationError()
        } catch is VelacantoNetworkTransportSuppressed {
            PlaybackDiagnosticJournal.shared.record(
                "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=suppressed category=degraded-route"
            )
            throw JellyfinAPIError.unreachable
        } catch let failure as VelacantoNetworkTransportFailure {
            if failure.underlying is CancellationError {
                throw CancellationError()
            }
            guard let error = failure.underlying as? URLError else {
                throw JellyfinAPIError.network(
                    failure.underlying.localizedDescription
                )
            }
            if error.code == .cancelled {
                throw CancellationError()
            }
            recordTransportFailure(
                error,
                lane: lane,
                startedAt: startedAt,
                requestKind: requestKind,
                attempt: attempt
            )
            throw Self.apiError(for: error)
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            recordTransportFailure(
                error,
                lane: lane,
                startedAt: startedAt,
                requestKind: requestKind,
                attempt: attempt
            )
            throw Self.apiError(for: error)
        } catch {
            throw JellyfinAPIError.network(error.localizedDescription)
        }
    }

    private func recordTransportFailure(
        _ error: URLError,
        lane: SessionLane,
        startedAt: Date,
        requestKind: String,
        attempt: Int
    ) {
        guard
            Self.isTransientTransportError(error)
                || Self.isTransportSecurityError(error)
        else {
            return
        }
        if lane == .background {
            backgroundSuppressedUntil = Date().addingTimeInterval(5)
        } else if lane == .interactive {
            interactiveSuppressedUntil = Date().addingTimeInterval(5)
        }
        Self.networkLogger.error(
            "Request lane=\(lane.rawValue, privacy: .public) phase=transport-failed code=\(error.code.rawValue, privacy: .public) elapsed_ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000), privacy: .public)"
        )
        PlaybackDiagnosticJournal.shared.record(
            "network-request kind=\(requestKind) lane=\(lane.rawValue) phase=failed category=\(Self.diagnosticCategory(for: error)) attempt=\(attempt) elapsed-ms=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
    }

    private func diagnosticRequestKind(
        for request: URLRequest,
        lane: SessionLane
    ) -> String {
        let components = request.url?.pathComponents ?? []
        if components.last?.caseInsensitiveCompare("PlaybackInfo") == .orderedSame {
            return "playback-info"
        }
        if components.suffix(2).map({ $0.lowercased() }) == ["users", "me"] {
            return "session-validation"
        }
        if components.contains(where: {
            $0.caseInsensitiveCompare("Images") == .orderedSame
        }) {
            return "artwork"
        }
        if components.contains(where: {
            $0.caseInsensitiveCompare("Playing") == .orderedSame
                || $0.caseInsensitiveCompare("PlayingProgress") == .orderedSame
                || $0.caseInsensitiveCompare("PlayingStopped") == .orderedSame
        }) {
            return "playback-report"
        }
        return lane == .interactive ? "catalog-or-session" : lane.rawValue
    }

    private static func diagnosticCategory(for error: URLError) -> String {
        switch error.code {
        case .timedOut: return "timeout"
        case .notConnectedToInternet: return "offline"
        case .cannotFindHost, .dnsLookupFailed: return "dns"
        case .cannotConnectToHost, .networkConnectionLost: return "unreachable"
        case .secureConnectionFailed, .serverCertificateUntrusted,
            .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            return "tls"
        default: return "transport"
        }
    }

    private func sessionLane(for request: URLRequest) -> SessionLane {
        switch request.networkServiceType {
        case .responsiveData, .responsiveAV:
            .playback
        case .background:
            .background
        default:
            .interactive
        }
    }

    private var isInteractiveRequestSuppressed: Bool {
        guard let interactiveSuppressedUntil else { return false }
        return interactiveSuppressedUntil > Date()
    }

    private var isBackgroundRequestSuppressed: Bool {
        guard let backgroundSuppressedUntil else { return false }
        return backgroundSuppressedUntil > Date()
    }

    private func canStartAdmittedRequest(in lane: SessionLane) -> Bool {
        switch lane {
        case .playback:
            true
        case .interactive:
            !isInteractiveRequestSuppressed
        case .background:
            !isBackgroundRequestSuppressed
        }
    }

    private func networkPriority(
        for lane: SessionLane
    ) -> VelacantoNetworkPriority {
        switch lane {
        case .playback:
            .playback
        case .interactive:
            .catalog
        case .background:
            .reporting
        }
    }

    private static func isTransientTransportError(_ error: URLError) -> Bool {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .timedOut:
            true
        default:
            false
        }
    }

    private static func isTransportSecurityError(_ error: URLError) -> Bool {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            true
        default:
            false
        }
    }

    private static func apiError(for error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            CancellationError()
        case .notConnectedToInternet, .networkConnectionLost:
            JellyfinAPIError.offline
        case .timedOut:
            JellyfinAPIError.timeout
        case .cannotFindHost, .dnsLookupFailed:
            JellyfinAPIError.dns
        case .cannotConnectToHost:
            JellyfinAPIError.unreachable
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
            .serverCertificateHasBadDate, .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
            .clientCertificateRejected, .clientCertificateRequired:
            JellyfinAPIError.transportSecurity
        default:
            JellyfinAPIError.network(error.localizedDescription)
        }
    }

}

enum JellyfinAPIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case unreachable
    case timeout
    case dns
    case offline
    case transportSecurity
    case unsupportedMedia
    case invalidResponse
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Jellyfin rejected the username, password, or saved session."
        case .unreachable:
            "Velacanto could not reach that Jellyfin server. Check the address and network."
        case .timeout:
            "The Jellyfin server did not respond in time."
        case .dns:
            "Velacanto could not resolve the Jellyfin server address."
        case .offline:
            "This device appears to be offline."
        case .transportSecurity:
            "The connection was blocked because it does not meet Apple's network security requirements."
        case .unsupportedMedia:
            "Jellyfin could not provide a supported audio stream for this item."
        case .invalidResponse:
            "The server returned a response Velacanto could not understand."
        case .httpStatus(let status):
            "The Jellyfin server returned HTTP \(status)."
        case .network(let message):
            "The Jellyfin request failed: \(message)"
        }
    }
}
