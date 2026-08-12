import Foundation
import Network

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
}

struct JellyfinPlaybackResolution: Equatable, Sendable {
    let streamURL: URL
    let playSessionID: String
    let playMethod: JellyfinPlaybackMethod
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
    let supportsDirectStream: Bool
    let supportsTranscoding: Bool
    let transcodingURL: String?

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
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
    let album: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let childCount: Int?
    let runTimeTicks: Int64?
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
        case album = "Album"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case runTimeTicks = "RunTimeTicks"
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
        album = try container.decodeIfPresent(String.self, forKey: .album)
        indexNumber = try container.decodeIfPresent(Int.self, forKey: .indexNumber)
        parentIndexNumber = try container.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        childCount = try container.decodeIfPresent(Int.self, forKey: .childCount)
        runTimeTicks = try container.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
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
        try container.encodeIfPresent(album, forKey: .album)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        try container.encodeIfPresent(childCount, forKey: .childCount)
        try container.encodeIfPresent(runTimeTicks, forKey: .runTimeTicks)
        try container.encodeIfPresent(albumID, forKey: .albumID)
        try container.encode(imageTags, forKey: .imageTags)
        try container.encodeIfPresent(
            albumPrimaryImageTag,
            forKey: .albumPrimaryImageTag
        )
        try container.encodeIfPresent(userData, forKey: .userData)
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
    case recentlyAdded
}

struct JellyfinRequestBuilder: Sendable {
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
        request.timeoutInterval = 20
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
            let maxStreamingBitrate = 320_000
            let directPlayProfiles: [DirectPlayProfile]
            let transcodingProfiles = [TranscodingProfile()]

            private enum CodingKeys: String, CodingKey {
                case maxStreamingBitrate = "MaxStreamingBitrate"
                case directPlayProfiles = "DirectPlayProfiles"
                case transcodingProfiles = "TranscodingProfiles"
            }
        }

        struct Payload: Encodable {
            let userID: String
            let maxStreamingBitrate = 320_000
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

        let containers = [
            "mp3", "aac", "m4a", "m4b", "flac", "webma", "webm", "wav", "ogg",
        ]
        let payload = Payload(
            userID: userID,
            deviceProfile: DeviceProfile(
                directPlayProfiles: containers.map(DirectPlayProfile.init)
            )
        )
        return try request(
            pathComponents: ["Items", itemID, "PlaybackInfo"],
            method: "POST",
            body: JSONEncoder().encode(payload)
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
        guard
            response.errorCode == nil,
            let playSessionID = response.playSessionID,
            !playSessionID.isEmpty,
            let source = response.mediaSources.first
        else {
            throw JellyfinAPIError.invalidResponse
        }

        // Jellyfin's UniversalAudioController uses SupportsDirectStream as its
        // "can serve the original file statically" decision for audio.
        if source.supportsDirectStream {
            return JellyfinPlaybackResolution(
                streamURL: try directPlayURL(
                    itemID: itemID,
                    mediaSourceID: source.id,
                    playSessionID: playSessionID
                ),
                playSessionID: playSessionID,
                playMethod: .directPlay
            )
        }

        guard
            source.supportsTranscoding,
            let transcodingURL = source.transcodingURL,
            !transcodingURL.isEmpty
        else {
            throw JellyfinAPIError.invalidResponse
        }
        return JellyfinPlaybackResolution(
            streamURL: try authenticatedStreamURL(
                transcodingURL,
                playSessionID: playSessionID
            ),
            playSessionID: playSessionID,
            playMethod: .transcode
        )
    }

    private func directPlayURL(
        itemID: String,
        mediaSourceID: String?,
        playSessionID: String
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
        return try request(
            pathComponents: ["Audio", itemID, "stream"],
            queryItems: queryItems
        ).url
            ?? {
                throw JellyfinAPIError.invalidResponse
            }()
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

        return try request(
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

actor JellyfinAPIClient: JellyfinAPIService {
    private let builder: JellyfinRequestBuilder
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        server: JellyfinServerURL,
        deviceID: String,
        accessToken: String? = nil,
        session: URLSession = .shared
    ) {
        builder = JellyfinRequestBuilder(
            server: server,
            deviceID: deviceID,
            accessToken: accessToken
        )
        self.session = session
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
            builder.request(pathComponents: ["Artists"], queryItems: query),
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
        case .recentlyAdded:
            query = pagedItemQuery(
                itemTypes: "MusicAlbum",
                fields: "AlbumArtist,Artists,ChildCount,ImageTags,SortName",
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
            fields: "AlbumArtist,Artists,ChildCount,ImageTags,SortName",
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
        "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks,UserData"
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

    private func executeWithoutResponse(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw JellyfinAPIError.invalidResponse
            }
            switch response.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw JellyfinAPIError.unauthorized
            default:
                throw JellyfinAPIError.httpStatus(response.statusCode)
            }
        } catch let error as JellyfinAPIError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost:
                throw JellyfinAPIError.offline
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut:
                throw JellyfinAPIError.unreachable
            case .appTransportSecurityRequiresSecureConnection:
                throw JellyfinAPIError.transportSecurity
            default:
                throw JellyfinAPIError.network(error.localizedDescription)
            }
        } catch {
            throw JellyfinAPIError.network(error.localizedDescription)
        }
    }
}

enum JellyfinAPIError: LocalizedError, Equatable {
    case unauthorized
    case unreachable
    case offline
    case transportSecurity
    case invalidResponse
    case httpStatus(Int)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "Jellyfin rejected the username, password, or saved session."
        case .unreachable:
            "Velacanto could not reach that Jellyfin server. Check the address and network."
        case .offline:
            "This device appears to be offline."
        case .transportSecurity:
            "The connection was blocked because it does not meet Apple's network security requirements."
        case .invalidResponse:
            "The server returned a response Velacanto could not understand."
        case .httpStatus(let status):
            "The Jellyfin server returned HTTP \(status)."
        case .network(let message):
            "The Jellyfin request failed: \(message)"
        }
    }
}
