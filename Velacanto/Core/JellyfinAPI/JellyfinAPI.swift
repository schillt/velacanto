import Foundation

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

        return host == "::1"
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
            || Self.isIPv6LinkLocal(host)
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

    private static func isIPv6LinkLocal(_ host: String) -> Bool {
        guard host.hasPrefix("fe"), host.count >= 3 else { return false }
        switch host[host.index(host.startIndex, offsetBy: 2)] {
        case "8", "9", "a", "b":
            return true
        default:
            return false
        }
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
    let artists: [String]
    let album: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let childCount: Int?
    let runTimeTicks: Int64?
    let albumID: String?
    let imageTags: [String: String]
    let albumPrimaryImageTag: String?

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

    var isMusicLibrary: Bool {
        collectionType?.caseInsensitiveCompare("music") == .orderedSame
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case collectionType = "CollectionType"
        case albumArtist = "AlbumArtist"
        case artists = "Artists"
        case album = "Album"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case childCount = "ChildCount"
        case runTimeTicks = "RunTimeTicks"
        case albumID = "AlbumId"
        case imageTags = "ImageTags"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        collectionType = try container.decodeIfPresent(String.self, forKey: .collectionType)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
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
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(collectionType, forKey: .collectionType)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
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

    var nextStartIndex: Int {
        startIndex + items.count
    }

    var hasMore: Bool {
        nextStartIndex < totalRecordCount
    }

    init(
        items: [JellyfinItem],
        startIndex: Int,
        totalRecordCount: Int
    ) {
        self.items = items
        self.startIndex = startIndex
        self.totalRecordCount = totalRecordCount
    }

    init(_ response: JellyfinItemsResponse) {
        self.init(
            items: response.items,
            startIndex: response.startIndex,
            totalRecordCount: response.totalRecordCount
        )
    }
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

    func streamURL(itemID: String, userID: String) throws -> URL {
        let playSessionID = UUID().uuidString
        let queryItems = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "DeviceId", value: deviceID),
            URLQueryItem(name: "PlaySessionId", value: playSessionID),
            URLQueryItem(name: "MaxStreamingBitrate", value: "320000"),
            URLQueryItem(
                name: "Container",
                value: "mp3,aac,m4a,m4b,flac,webma,webm,wav,ogg"
            ),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "EnableRedirection", value: "true"),
            URLQueryItem(name: "EnableRemoteMedia", value: "true"),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        return try request(
            pathComponents: ["Audio", itemID, "universal"],
            queryItems: queryItems
        ).url
            ?? {
                throw JellyfinAPIError.invalidResponse
            }()
    }

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(max(maxWidth, 64))),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }
        return try request(
            pathComponents: ["Items", itemID, "Images", "Primary"],
            queryItems: queryItems
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
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(max(maxWidth, 64))),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }
        return try request(
            pathComponents: ["Items", itemID, "Images", "Primary"],
            queryItems: queryItems
        )
    }

    func userImageURL(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) throws -> URL {
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(max(maxWidth, 64))),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: accessToken),
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }
        return try request(
            pathComponents: ["Users", userID, "Images", "Primary"],
            queryItems: queryItems
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
        var queryItems = [
            URLQueryItem(name: "maxWidth", value: String(max(maxWidth, 64))),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let imageTag, !imageTag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: imageTag))
        }
        return try request(
            pathComponents: ["Users", userID, "Images", "Primary"],
            queryItems: queryItems
        )
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

protocol JellyfinAPIService: Sendable {
    func publicServerInfo() async throws -> JellyfinServerInfo
    func authenticate(
        username: String,
        password: String
    ) async throws -> JellyfinAuthenticationResult
    func currentUser() async throws -> JellyfinUser
    func libraries(userID: String) async throws -> [JellyfinItem]
    func albums(userID: String, libraryID: String) async throws -> [JellyfinItem]
    func albums(
        userID: String,
        libraryID: String,
        artistID: String
    ) async throws -> [JellyfinItem]
    func artists(userID: String, libraryID: String) async throws -> [JellyfinItem]
    func songs(userID: String, libraryID: String) async throws -> [JellyfinItem]
    func playlists(userID: String) async throws -> [JellyfinItem]
    func searchMusic(
        userID: String,
        query: String,
        limit: Int
    ) async throws -> [JellyfinItem]
    func playlistItems(
        userID: String,
        playlistID: String
    ) async throws -> [JellyfinItem]
    func tracks(userID: String, albumID: String) async throws -> [JellyfinItem]
    func streamURL(itemID: String, userID: String) async throws -> URL
    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URL
    func userImageURL(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URL
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
        positionTicks: Int64
    ) async throws
    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool
    ) async throws
    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64
    ) async throws
    func logout() async throws
}

extension JellyfinAPIService {
    func reportPlaybackStarted(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64
    ) async throws {}

    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool
    ) async throws {}

    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64
    ) async throws {}

    func albumsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let allItems: [JellyfinItem]
        if let artistID {
            allItems = try await albums(
                userID: userID,
                libraryID: libraryID,
                artistID: artistID
            )
        } else {
            allItems = try await albums(userID: userID, libraryID: libraryID)
        }
        return Self.localPage(
            allItems,
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
    }

    func artistsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        Self.localPage(
            try await artists(userID: userID, libraryID: libraryID),
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
    }

    func songsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        Self.localPage(
            try await songs(userID: userID, libraryID: libraryID),
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
    }

    func playlistsPage(
        userID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        Self.localPage(
            try await playlists(userID: userID),
            startIndex: startIndex,
            limit: limit,
            searchTerm: searchTerm
        )
    }

    func searchMusicPage(
        userID: String,
        query: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let items = try await searchMusic(
            userID: userID,
            query: query,
            limit: startIndex + limit
        )
        return Self.localPage(
            items,
            startIndex: startIndex,
            limit: limit,
            searchTerm: nil
        )
    }

    func playlistItemsPage(
        userID: String,
        playlistID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        Self.localPage(
            try await playlistItems(userID: userID, playlistID: playlistID),
            startIndex: startIndex,
            limit: limit,
            searchTerm: nil
        )
    }

    func tracksPage(
        userID: String,
        albumID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        Self.localPage(
            try await tracks(userID: userID, albumID: albumID),
            startIndex: startIndex,
            limit: limit,
            searchTerm: nil
        )
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
        URLRequest(
            url: try await artworkURL(
                itemID: itemID,
                imageTag: imageTag,
                maxWidth: maxWidth
            )
        )
    }

    func userImageRequest(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
        URLRequest(
            url: try await userImageURL(
                userID: userID,
                imageTag: imageTag,
                maxWidth: maxWidth
            )
        )
    }

    private static func localPage(
        _ items: [JellyfinItem],
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) -> JellyfinItemPage {
        let filtered: [JellyfinItem]
        if let searchTerm, !searchTerm.isEmpty {
            filtered = items.filter {
                $0.name.localizedCaseInsensitiveContains(searchTerm)
                    || $0.displayArtist.localizedCaseInsensitiveContains(searchTerm)
                    || ($0.album?.localizedCaseInsensitiveContains(searchTerm) ?? false)
            }
        } else {
            filtered = items
        }
        let safeStart = min(max(startIndex, 0), filtered.count)
        let safeEnd = min(safeStart + max(limit, 1), filtered.count)
        return JellyfinItemPage(
            items: Array(filtered[safeStart..<safeEnd]),
            startIndex: safeStart,
            totalRecordCount: filtered.count
        )
    }
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

    func albums(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        try await albums(
            userID: userID,
            libraryID: libraryID,
            additionalQueryItems: []
        )
    }

    func albums(
        userID: String,
        libraryID: String,
        artistID: String
    ) async throws -> [JellyfinItem] {
        try await albums(
            userID: userID,
            libraryID: libraryID,
            additionalQueryItems: [
                URLQueryItem(name: "AlbumArtistIds", value: artistID)
            ]
        )
    }

    func artists(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "ParentId", value: libraryID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "ChildCount,ImageTags"),
        ]
        let response = try await execute(
            builder.request(pathComponents: ["Artists"], queryItems: query),
            as: JellyfinItemsResponse.self
        )
        return response.items
    }

    func artistsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query =
            [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "ChildCount,ImageTags"),
            ]
            + pageQueryItems(
                startIndex: startIndex,
                limit: limit,
                searchTerm: searchTerm
            )
        let response = try await execute(
            builder.request(pathComponents: ["Artists"], queryItems: query),
            as: JellyfinItemsResponse.self
        )
        return JellyfinItemPage(response)
    }

    func songs(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: libraryID),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
            ),
        ]
        return try await items(userID: userID, query: query)
    }

    func songsPage(
        userID: String,
        libraryID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query =
            [
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(
                    name: "Fields",
                    value:
                        "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
                ),
            ]
            + pageQueryItems(
                startIndex: startIndex,
                limit: limit,
                searchTerm: searchTerm
            )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func playlists(userID: String) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value: "ChildCount,ImageTags,RunTimeTicks"
            ),
        ]
        return try await items(userID: userID, query: query)
    }

    func playlistsPage(
        userID: String,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        let query =
            [
                URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(
                    name: "Fields",
                    value: "ChildCount,ImageTags,RunTimeTicks"
                ),
            ]
            + pageQueryItems(
                startIndex: startIndex,
                limit: limit,
                searchTerm: searchTerm
            )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func searchMusic(
        userID: String,
        query: String,
        limit: Int
    ) async throws -> [JellyfinItem] {
        let queryItems = [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(
                name: "IncludeItemTypes",
                value: "Audio,MusicAlbum,MusicArtist,Playlist"
            ),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ChildCount,ImageTags,RunTimeTicks"
            ),
        ]
        return try await items(userID: userID, query: queryItems)
    }

    func searchMusicPage(
        userID: String,
        query: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let queryItems = [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(
                name: "IncludeItemTypes",
                value: "Audio,MusicAlbum,MusicArtist,Playlist"
            ),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "StartIndex", value: String(max(startIndex, 0))),
            URLQueryItem(name: "Limit", value: String(max(limit, 1))),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ChildCount,ImageTags,RunTimeTicks"
            ),
        ]
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: queryItems)
        )
    }

    func playlistItems(
        userID: String,
        playlistID: String
    ) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
            ),
        ]
        let response = try await execute(
            builder.request(
                pathComponents: ["Playlists", playlistID, "Items"],
                queryItems: query
            ),
            as: JellyfinItemsResponse.self
        )
        return response.items.filter { $0.kind == .song }
    }

    func playlistItemsPage(
        userID: String,
        playlistID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query = [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "StartIndex", value: String(max(startIndex, 0))),
            URLQueryItem(name: "Limit", value: String(max(limit, 1))),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
            ),
        ]
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
            totalRecordCount: response.totalRecordCount
        )
    }

    private func albums(
        userID: String,
        libraryID: String,
        additionalQueryItems: [URLQueryItem]
    ) async throws -> [JellyfinItem] {
        let query =
            [
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "AlbumArtist,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(
                    name: "Fields",
                    value: "AlbumArtist,Artists,ChildCount,ImageTags"
                ),
            ] + additionalQueryItems
        return try await items(userID: userID, query: query)
    }

    func albumsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        var additionalQueryItems: [URLQueryItem] = []
        if let artistID {
            additionalQueryItems.append(
                URLQueryItem(name: "AlbumArtistIds", value: artistID)
            )
        }
        let query =
            [
                URLQueryItem(name: "ParentId", value: libraryID),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "AlbumArtist,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(
                    name: "Fields",
                    value: "AlbumArtist,Artists,ChildCount,ImageTags"
                ),
            ] + additionalQueryItems
            + pageQueryItems(
                startIndex: startIndex,
                limit: limit,
                searchTerm: searchTerm
            )
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func tracks(userID: String, albumID: String) async throws -> [JellyfinItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: albumID),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
            ),
        ]
        return try await items(userID: userID, query: query)
    }

    func tracksPage(
        userID: String,
        albumID: String,
        startIndex: Int,
        limit: Int
    ) async throws -> JellyfinItemPage {
        let query = [
            URLQueryItem(name: "ParentId", value: albumID),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "StartIndex", value: String(max(startIndex, 0))),
            URLQueryItem(name: "Limit", value: String(max(limit, 1))),
            URLQueryItem(
                name: "Fields",
                value:
                    "Album,AlbumArtist,Artists,AlbumId,AlbumPrimaryImageTag,ImageTags,RunTimeTicks"
            ),
        ]
        return JellyfinItemPage(
            try await itemsResponse(userID: userID, query: query)
        )
    }

    func streamURL(itemID: String, userID: String) throws -> URL {
        try builder.streamURL(itemID: itemID, userID: userID)
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
        positionTicks: Int64
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: false
        )
    }

    func reportPlaybackProgress(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64,
        isPaused: Bool
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing", "Progress"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: isPaused
        )
    }

    func reportPlaybackStopped(
        itemID: String,
        playSessionID: String,
        positionTicks: Int64
    ) async throws {
        try await sendPlaybackReport(
            path: ["Sessions", "Playing", "Stopped"],
            itemID: itemID,
            playSessionID: playSessionID,
            positionTicks: positionTicks,
            isPaused: true
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

    private func items(
        userID: String,
        query: [URLQueryItem]
    ) async throws -> [JellyfinItem] {
        try await itemsResponse(userID: userID, query: query).items
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
        isPaused: Bool
    ) async throws {
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

        var request = try builder.request(
            pathComponents: path,
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            Payload(
                itemID: itemID,
                playSessionID: playSessionID,
                positionTicks: positionTicks,
                isPaused: isPaused,
                canSeek: true,
                playMethod: "DirectStream"
            )
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
