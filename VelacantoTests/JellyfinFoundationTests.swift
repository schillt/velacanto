import XCTest

@testable import Velacanto

@MainActor
final class JellyfinFoundationTests: XCTestCase {
    func testServerURLNormalizesHTTPSAndKeepsReverseProxyPath() throws {
        let server = try JellyfinServerURL("  HTTPS://Music.Example.com/jellyfin/  ")

        XCTAssertEqual(
            server.url.absoluteString,
            "https://music.example.com/jellyfin"
        )
    }

    func testServerURLAllowsExplicitLocalHTTPDestinations() throws {
        let allowedAddresses = [
            "http://localhost:8096",
            "http://127.0.0.1:8096",
            "http://10.0.0.5:8096",
            "http://172.16.0.5:8096",
            "http://172.31.255.255:8096",
            "http://192.168.1.20:8096",
            "http://169.254.10.2:8096",
            "http://jellyfin:8096",
            "http://media.local:8096",
            "http://[::1]:8096",
            "http://[fd12::5]:8096",
            "http://[fe80::5]:8096",
        ]

        for address in allowedAddresses {
            XCTAssertNoThrow(
                try JellyfinServerURL(address),
                "Expected local address to be accepted: \(address)"
            )
        }
    }

    func testServerURLRejectsInsecureRemoteAndMalformedAddresses() {
        let rejectedAddresses = [
            "http://example.com",
            "http://8.8.8.8:8096",
            "http://[2001:4860:4860::8888]:8096",
            "ftp://192.168.1.20/music",
            "jellyfin.example.com",
            "https://user:password@example.com",
            "https://example.com?token=secret",
            "https://example.com/#fragment",
        ]

        for address in rejectedAddresses {
            XCTAssertThrowsError(
                try JellyfinServerURL(address),
                "Expected address to be rejected: \(address)"
            )
        }
    }

    func testJellyfinTokenStoreUsesAppPreferences() throws {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsJellyfinTokenStore(defaults: defaults)

        XCTAssertNil(try store.loadToken())
        try store.saveToken("access-token")
        XCTAssertEqual(try store.loadToken(), "access-token")

        try store.deleteToken()
        XCTAssertNil(try store.loadToken())
    }

    func testRequestBuilderPreservesBasePathAndBuildsClientAuthorization() throws {
        let server = try JellyfinServerURL("https://example.com/jellyfin")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "device-id",
            accessToken: nil
        )

        let request = try builder.request(
            pathComponents: ["System", "Info", "Public"]
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.com/jellyfin/System/Info/Public"
        )
        let authorization = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Authorization")
        )
        XCTAssertTrue(authorization.contains("Client=\"Velacanto\""))
        XCTAssertTrue(authorization.contains("DeviceId=\"device-id\""))
        XCTAssertFalse(authorization.contains("Token="))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Emby-Authorization"),
            authorization
        )
    }

    func testAuthenticatedStreamURLContainsPlaybackParameters() throws {
        let server = try JellyfinServerURL("https://example.com")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )

        let url = try builder.streamURL(itemID: "track-id", userID: "user-id")
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(components.path, "/Audio/track-id/universal")
        XCTAssertEqual(query["UserId"], "user-id")
        XCTAssertEqual(query["DeviceId"], "stable-device")
        XCTAssertEqual(query["api_key"], "access-token")
        XCTAssertEqual(query["TranscodingContainer"], "mp3")
        XCTAssertNotNil(query["PlaySessionId"])
    }

    func testJellyfinModelsDecodeCurrentServerShapes() throws {
        let serverData = Data(
            """
            {
              "Id": "server-id",
              "ServerName": "Home",
              "Version": "10.11.0",
              "StartupWizardCompleted": true
            }
            """.utf8
        )
        let authenticationData = Data(
            """
            {
              "User": {"Id": "user-id", "Name": "Tyler"},
              "AccessToken": "token"
            }
            """.utf8
        )
        let itemsData = Data(
            """
            {
              "Items": [{
                "Id": "album-id",
                "Name": "Open Roads",
                "Type": "MusicAlbum",
                "CollectionType": "music",
                "AlbumArtist": "Velacanto",
                "Artists": ["Velacanto"],
                "ImageTags": {"Primary": "album-image-tag"},
                "ChildCount": 9
              }],
              "TotalRecordCount": 1
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        let server = try decoder.decode(JellyfinServerInfo.self, from: serverData)
        let authentication = try decoder.decode(
            JellyfinAuthenticationResult.self,
            from: authenticationData
        )
        let items = try decoder.decode(JellyfinItemsResponse.self, from: itemsData)

        XCTAssertEqual(server.serverName, "Home")
        XCTAssertEqual(server.startupWizardCompleted, true)
        XCTAssertEqual(authentication.user.name, "Tyler")
        XCTAssertEqual(authentication.accessToken, "token")
        XCTAssertEqual(items.totalRecordCount, 1)
        XCTAssertEqual(items.items.first?.displayArtist, "Velacanto")
        XCTAssertEqual(items.items.first?.childCount, 9)
        XCTAssertEqual(items.items.first?.primaryImageTag, "album-image-tag")
    }

    func testArtworkURLUsesAuthenticatedJellyfinImageEndpoint() throws {
        let server = try JellyfinServerURL("https://example.com/jellyfin")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )

        let url = try builder.artworkURL(
            itemID: "album-id",
            imageTag: "image-tag",
            maxWidth: 720
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(
            components.path,
            "/jellyfin/Items/album-id/Images/Primary"
        )
        XCTAssertEqual(query["tag"], "image-tag")
        XCTAssertEqual(query["maxWidth"], "720")
        XCTAssertEqual(query["quality"], "90")
        XCTAssertEqual(query["api_key"], "access-token")
    }

    func testPlaybackAdapterCreatesSourceNeutralJellyfinRequest() async throws {
        let data = Data(
            """
            {
              "Id": "track-id",
              "Name": "Night Drive",
              "Type": "Audio",
              "AlbumArtist": "Velacanto",
              "Artists": ["Velacanto"],
              "Album": "Open Roads",
              "IndexNumber": 2,
              "RunTimeTicks": 1800000000
            }
            """.utf8
        )
        let track = try JSONDecoder().decode(JellyfinItem.self, from: data)
        let streamURL = try XCTUnwrap(
            URL(string: "https://example.com/Audio/track-id/universal")
        )

        let request = try await JellyfinPlaybackAdapter().playbackRequest(
            for: JellyfinTrackSelection(
                track: track,
                streamURL: streamURL
            )
        )

        XCTAssertEqual(request.item.id, "track-id")
        XCTAssertEqual(request.item.title, "Night Drive")
        XCTAssertEqual(request.item.artist, "Velacanto")
        XCTAssertEqual(request.item.albumTitle, "Open Roads")
        XCTAssertEqual(request.item.source, .jellyfin)
        XCTAssertEqual(track.duration, 180)
    }

    func testMusicCatalogCombinesLibrariesAndRemovesDuplicateAlbums() async throws {
        let decoder = JSONDecoder()
        let firstLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-a","Name":"Main Music"}"#.utf8)
        )
        let secondLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-b","Name":"Archive"}"#.utf8)
        )
        let alphaAlbum = try decoder.decode(
            JellyfinItem.self,
            from: Data(
                #"{"Id":"album-a","Name":"Alpha","Type":"MusicAlbum"}"#.utf8
            )
        )
        let sharedAlbum = try decoder.decode(
            JellyfinItem.self,
            from: Data(
                #"{"Id":"album-shared","Name":"Zebra","Type":"MusicAlbum"}"#.utf8
            )
        )
        let api = FakeJellyfinAPI(
            availableLibraries: [firstLibrary, secondLibrary],
            albumsByLibrary: [
                firstLibrary.id: [sharedAlbum],
                secondLibrary.id: [alphaAlbum, sharedAlbum],
            ]
        )
        let controller = JellyfinSessionController(
            tokenStore: RecordingTokenStore(),
            sessionStore: RecordingSessionStore(),
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )

        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")
        let albums = try await controller.musicAlbums()

        XCTAssertEqual(
            albums.map(\.id),
            ["album-a", "album-shared"]
        )
    }

    func testSessionSignInPersistsTokenButNeverPasswordThenLogoutDeletesIt() async throws {
        let tokenStore = RecordingTokenStore()
        let sessionStore = RecordingSessionStore()
        let api = FakeJellyfinAPI()
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: sessionStore,
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )

        await controller.connect(to: "https://example.com")
        await controller.signIn(
            username: "Tyler",
            password: "never-persist-this"
        )

        XCTAssertEqual(controller.phase, .signedIn)
        XCTAssertEqual(controller.session?.username, "Tyler")
        XCTAssertEqual(tokenStore.token, "access-token")
        let persistedData = try JSONEncoder().encode(
            XCTUnwrap(sessionStore.session)
        )
        let persistedText = try XCTUnwrap(
            String(data: persistedData, encoding: .utf8)
        )
        XCTAssertFalse(persistedText.contains("never-persist-this"))
        XCTAssertFalse(persistedText.lowercased().contains("password"))

        await controller.logout()

        XCTAssertEqual(controller.phase, .signedOut)
        XCTAssertNil(controller.session)
        XCTAssertNil(tokenStore.token)
        XCTAssertNil(sessionStore.session)
        XCTAssertEqual(tokenStore.deleteCount, 1)
    }

    func testExpiredRestoredSessionDeletesSavedToken() async throws {
        let tokenStore = RecordingTokenStore(token: "expired-token")
        let serverURL = try XCTUnwrap(URL(string: "https://example.com"))
        let sessionStore = RecordingSessionStore(
            session: JellyfinSession(
                serverURL: serverURL,
                serverID: "server-id",
                serverName: "Home",
                userID: "user-id",
                username: "Tyler"
            ),
            deviceID: "stable-device"
        )
        let api = FakeJellyfinAPI(currentUserError: .unauthorized)
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: sessionStore,
            makeClient: { _, _, _ in api }
        )

        for _ in 0..<100 where controller.phase == .restoring {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .signedOut)
        XCTAssertNil(controller.session)
        XCTAssertNil(tokenStore.token)
        XCTAssertNil(sessionStore.session)
        XCTAssertEqual(
            controller.errorMessage,
            JellyfinSessionError.expiredSession.localizedDescription
        )
    }

    func testUnreachableServerReturnsToSignedOutWithRetryableError() async {
        let controller = JellyfinSessionController(
            tokenStore: RecordingTokenStore(),
            sessionStore: RecordingSessionStore(),
            autoRestore: false,
            makeClient: { _, _, _ in
                FakeJellyfinAPI(publicServerInfoError: .unreachable)
            }
        )

        await controller.connect(to: "https://unreachable.example.com")

        XCTAssertEqual(controller.phase, .signedOut)
        XCTAssertNil(controller.serverInfo)
        XCTAssertEqual(
            controller.errorMessage,
            JellyfinAPIError.unreachable.localizedDescription
        )
    }

    func testBadCredentialsKeepConnectedServerAvailableForRetry() async {
        let tokenStore = RecordingTokenStore()
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: RecordingSessionStore(),
            autoRestore: false,
            makeClient: { _, _, token in
                FakeJellyfinAPI(
                    authenticationError: token == nil ? .unauthorized : nil
                )
            }
        )

        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "incorrect")

        XCTAssertEqual(controller.phase, .awaitingCredentials)
        XCTAssertNotNil(controller.serverInfo)
        XCTAssertNil(controller.session)
        XCTAssertNil(tokenStore.token)
        XCTAssertEqual(
            controller.errorMessage,
            JellyfinAPIError.unauthorized.localizedDescription
        )
    }

    func testIncompletePersistedSessionIsRemovedDuringRestore() async {
        let tokenStore = RecordingTokenStore(token: "orphaned-token")
        let sessionStore = RecordingSessionStore()
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: sessionStore,
            makeClient: { _, _, _ in FakeJellyfinAPI() }
        )

        for _ in 0..<100 where controller.phase == .restoring {
            await Task.yield()
        }

        XCTAssertEqual(controller.phase, .signedOut)
        XCTAssertNil(tokenStore.token)
        XCTAssertEqual(tokenStore.deleteCount, 1)
    }

    func testExpiredSessionDuringBrowsingDeletesSavedCredentials() async throws {
        let tokenStore = RecordingTokenStore()
        let sessionStore = RecordingSessionStore()
        let api = FakeJellyfinAPI(albumsError: .unauthorized)
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: sessionStore,
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )
        let library = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-id","Name":"Music"}"#.utf8)
        )

        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")

        do {
            _ = try await controller.albums(in: library)
            XCTFail("Expected the expired session to reject browsing.")
        } catch {
            XCTAssertEqual(error as? JellyfinAPIError, .unauthorized)
        }

        XCTAssertEqual(controller.phase, .signedOut)
        XCTAssertNil(controller.session)
        XCTAssertNil(tokenStore.token)
        XCTAssertNil(sessionStore.session)
        XCTAssertEqual(
            controller.errorMessage,
            JellyfinSessionError.expiredSession.localizedDescription
        )
    }
}

private final class RecordingTokenStore: JellyfinTokenStoring {
    var token: String?
    private(set) var deleteCount = 0

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() throws -> String? {
        token
    }

    func saveToken(_ token: String) throws {
        self.token = token
    }

    func deleteToken() throws {
        token = nil
        deleteCount += 1
    }
}

private final class RecordingSessionStore: JellyfinSessionPersisting {
    var session: JellyfinSession?
    var deviceID: String?

    init(
        session: JellyfinSession? = nil,
        deviceID: String? = nil
    ) {
        self.session = session
        self.deviceID = deviceID
    }

    func loadSession() -> JellyfinSession? {
        session
    }

    func saveSession(_ session: JellyfinSession) {
        self.session = session
    }

    func deleteSession() {
        session = nil
    }

    func loadDeviceID() -> String? {
        deviceID
    }

    func saveDeviceID(_ deviceID: String) {
        self.deviceID = deviceID
    }
}

private actor FakeJellyfinAPI: JellyfinAPIService {
    private let publicServerInfoError: JellyfinAPIError?
    private let authenticationError: JellyfinAPIError?
    private let currentUserError: JellyfinAPIError?
    private let albumsError: JellyfinAPIError?
    private let availableLibraries: [JellyfinItem]
    private let albumsByLibrary: [String: [JellyfinItem]]

    init(
        publicServerInfoError: JellyfinAPIError? = nil,
        authenticationError: JellyfinAPIError? = nil,
        currentUserError: JellyfinAPIError? = nil,
        albumsError: JellyfinAPIError? = nil,
        availableLibraries: [JellyfinItem] = [],
        albumsByLibrary: [String: [JellyfinItem]] = [:]
    ) {
        self.publicServerInfoError = publicServerInfoError
        self.authenticationError = authenticationError
        self.currentUserError = currentUserError
        self.albumsError = albumsError
        self.availableLibraries = availableLibraries
        self.albumsByLibrary = albumsByLibrary
    }

    func publicServerInfo() async throws -> JellyfinServerInfo {
        if let publicServerInfoError {
            throw publicServerInfoError
        }
        return JellyfinServerInfo(
            id: "server-id",
            serverName: "Home",
            version: "10.11.0",
            startupWizardCompleted: true
        )
    }

    func authenticate(
        username: String,
        password: String
    ) async throws -> JellyfinAuthenticationResult {
        if let authenticationError {
            throw authenticationError
        }
        return JellyfinAuthenticationResult(
            user: JellyfinUser(id: "user-id", name: username),
            accessToken: "access-token"
        )
    }

    func currentUser() async throws -> JellyfinUser {
        if let currentUserError {
            throw currentUserError
        }
        return JellyfinUser(id: "user-id", name: "Tyler")
    }

    func libraries(userID: String) async throws -> [JellyfinItem] {
        availableLibraries
    }

    func albums(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        if let albumsError {
            throw albumsError
        }
        return albumsByLibrary[libraryID] ?? []
    }

    func albums(
        userID: String,
        libraryID: String,
        artistID: String
    ) async throws -> [JellyfinItem] {
        if let albumsError {
            throw albumsError
        }
        return []
    }

    func artists(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        []
    }

    func songs(userID: String, libraryID: String) async throws -> [JellyfinItem] {
        []
    }

    func playlists(userID: String) async throws -> [JellyfinItem] {
        []
    }

    func searchMusic(
        userID: String,
        query: String,
        limit: Int
    ) async throws -> [JellyfinItem] {
        []
    }

    func playlistItems(
        userID: String,
        playlistID: String
    ) async throws -> [JellyfinItem] {
        []
    }

    func tracks(userID: String, albumID: String) async throws -> [JellyfinItem] {
        []
    }

    func streamURL(itemID: String, userID: String) async throws -> URL {
        guard let url = URL(string: "https://example.com/Audio/\(itemID)/universal") else {
            throw JellyfinAPIError.invalidResponse
        }
        return url
    }

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URL {
        guard
            var components = URLComponents(
                string: "https://example.com/Items/\(itemID)/Images/Primary"
            )
        else {
            throw JellyfinAPIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "tag", value: imageTag),
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
        ]
        guard let url = components.url else {
            throw JellyfinAPIError.invalidResponse
        }
        return url
    }

    func logout() async throws {}
}
