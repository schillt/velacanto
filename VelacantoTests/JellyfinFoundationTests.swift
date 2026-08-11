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
            "http://[fc00::1]:8096",
            "http://[fd12::5]:8096",
            "http://[fe80::5]:8096",
            "http://[febf::5]:8096",
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
            "http://fc.example.com:8096",
            "http://fd.example.com:8096",
            "http://fe8.example.com:8096",
            "http://8.8.8.8:8096",
            "http://[2001:4860:4860::8888]:8096",
            "http://[fec0::1]:8096",
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

    func testJellyfinTokenStoreMigratesLegacyStorageToKeychain()
        throws
    {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoTokenStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let account = "jellyfin.access-token"
        let service = "VelacantoTests.\(UUID().uuidString)"
        let keychain = InMemoryKeychainTokenStore()
        let store = KeychainJellyfinTokenStore(
            legacyDirectory: directory,
            service: service,
            account: account,
            migratingFrom: defaults,
            keychain: keychain
        )
        defer {
            try? store.deleteToken()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let tokenFile = directory.appending(
            path: "jellyfin-access-token-v1",
            directoryHint: .notDirectory
        )
        try Data("legacy-file-token".utf8).write(to: tokenFile)

        XCTAssertEqual(try store.loadToken(), "legacy-file-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))

        try store.deleteToken()
        XCTAssertNil(try store.loadToken())
        defaults.set("legacy-token", forKey: account)

        XCTAssertEqual(try store.loadToken(), "legacy-token")
        XCTAssertNil(defaults.string(forKey: account))
        XCTAssertEqual(
            try KeychainJellyfinTokenStore(
                legacyDirectory: directory,
                service: service,
                account: account,
                keychain: keychain
            ).loadToken(),
            "legacy-token"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFile.path))

        try store.saveToken("replacement-token")
        XCTAssertEqual(try store.loadToken(), "replacement-token")

        try store.deleteToken()
        XCTAssertNil(try store.loadToken())
    }

    func testJellyfinTokenStoreDoesNotIgnoreLegacyFileDeletionFailure()
        throws
    {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoTokenStoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let account = "jellyfin.access-token"
        let service = "VelacantoTests.\(UUID().uuidString)"
        let keychain = InMemoryKeychainTokenStore()
        let tokenFile = directory.appending(
            path: "jellyfin-access-token-v1",
            directoryHint: .notDirectory
        )
        let store = KeychainJellyfinTokenStore(
            legacyDirectory: directory,
            service: service,
            account: account,
            keychain: keychain,
            removeLegacyFile: { throw LegacyFileRemovalError.failed }
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("legacy-file-token".utf8).write(to: tokenFile)

        XCTAssertThrowsError(try store.loadToken()) { error in
            XCTAssertEqual(
                error as? JellyfinCredentialStoreError,
                .storageUnavailable
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFile.path))
        XCTAssertEqual(
            try keychain.loadToken(service: service, account: account),
            "legacy-file-token"
        )

        XCTAssertThrowsError(try store.deleteToken()) { error in
            XCTAssertEqual(
                error as? JellyfinCredentialStoreError,
                .storageUnavailable
            )
        }
        XCTAssertEqual(
            try keychain.loadToken(service: service, account: account),
            "legacy-file-token"
        )
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

    func testPlaybackNegotiationRequestMatchesUniversalAudioProfile() throws {
        let server = try JellyfinServerURL("https://example.com")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )

        let request = try builder.playbackInfoRequest(
            itemID: "track-id",
            userID: "user-id"
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let profile = try XCTUnwrap(payload["DeviceProfile"] as? [String: Any])
        let directProfiles = try XCTUnwrap(
            profile["DirectPlayProfiles"] as? [[String: Any]]
        )
        let transcodeProfiles = try XCTUnwrap(
            profile["TranscodingProfiles"] as? [[String: Any]]
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/Items/track-id/PlaybackInfo")
        XCTAssertEqual(payload["UserId"] as? String, "user-id")
        XCTAssertEqual(payload["MaxStreamingBitrate"] as? Int, 320_000)
        XCTAssertEqual(directProfiles.count, 9)
        XCTAssertEqual(directProfiles.first?["Container"] as? String, "mp3")
        XCTAssertTrue(
            directProfiles.allSatisfy { $0["Type"] as? String == "Audio" }
        )
        XCTAssertEqual(transcodeProfiles.first?["Container"] as? String, "mp3")
        XCTAssertEqual(transcodeProfiles.first?["AudioCodec"] as? String, "mp3")
        XCTAssertEqual(transcodeProfiles.first?["Protocol"] as? String, "http")
    }

    func testPlaybackResolutionUsesNegotiatedDirectPlaySession() throws {
        let builder = JellyfinRequestBuilder(
            server: try JellyfinServerURL("https://example.com/jellyfin"),
            deviceID: "stable-device",
            accessToken: "access-token"
        )
        let response = JellyfinPlaybackInfoResponse(
            mediaSources: [
                JellyfinPlaybackMediaSource(
                    id: "source-id",
                    supportsDirectStream: true,
                    supportsTranscoding: true,
                    transcodingURL: "/jellyfin/Audio/track-id/stream.mp3"
                )
            ],
            playSessionID: "negotiated-session",
            errorCode: nil
        )

        let resolution = try builder.playbackResolution(
            itemID: "track-id",
            response: response
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: resolution.streamURL,
                resolvingAgainstBaseURL: false
            )
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(resolution.playMethod, .directPlay)
        XCTAssertEqual(resolution.playSessionID, "negotiated-session")
        XCTAssertEqual(components.path, "/jellyfin/Audio/track-id/stream")
        XCTAssertEqual(query["Static"], "true")
        XCTAssertEqual(query["MediaSourceId"], "source-id")
        XCTAssertEqual(query["DeviceId"], "stable-device")
        XCTAssertEqual(query["PlaySessionId"], "negotiated-session")
        XCTAssertEqual(query["api_key"], "access-token")
    }

    func testPlaybackResolutionUsesAuthenticatedServerTranscodeURL() throws {
        let builder = JellyfinRequestBuilder(
            server: try JellyfinServerURL("https://example.com/jellyfin"),
            deviceID: "stable-device",
            accessToken: "access-token"
        )
        let response = JellyfinPlaybackInfoResponse(
            mediaSources: [
                JellyfinPlaybackMediaSource(
                    id: "source-id",
                    supportsDirectStream: false,
                    supportsTranscoding: true,
                    transcodingURL:
                        "/jellyfin/Audio/track-id/stream.mp3?PlaySessionId=server-value"
                )
            ],
            playSessionID: "negotiated-session",
            errorCode: nil
        )

        let resolution = try builder.playbackResolution(
            itemID: "track-id",
            response: response
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: resolution.streamURL,
                resolvingAgainstBaseURL: false
            )
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(resolution.playMethod, .transcode)
        XCTAssertEqual(components.path, "/jellyfin/Audio/track-id/stream.mp3")
        XCTAssertEqual(query["PlaySessionId"], "negotiated-session")
        XCTAssertEqual(query["DeviceId"], "stable-device")
        XCTAssertEqual(query["api_key"], "access-token")
    }

    func testPlaybackResolutionRejectsCrossOriginTranscodeURL() throws {
        let builder = JellyfinRequestBuilder(
            server: try JellyfinServerURL("https://example.com"),
            deviceID: "stable-device",
            accessToken: "access-token"
        )
        let response = JellyfinPlaybackInfoResponse(
            mediaSources: [
                JellyfinPlaybackMediaSource(
                    id: "source-id",
                    supportsDirectStream: false,
                    supportsTranscoding: true,
                    transcodingURL: "https://attacker.example/Audio/track-id/stream.mp3"
                )
            ],
            playSessionID: "negotiated-session",
            errorCode: nil
        )

        XCTAssertThrowsError(
            try builder.playbackResolution(
                itemID: "track-id",
                response: response
            )
        ) { error in
            XCTAssertEqual(error as? JellyfinAPIError, .invalidResponse)
        }
    }

    func testPlaybackReportRequestUsesResolvedMethodAndSession() throws {
        let server = try JellyfinServerURL("https://example.com/jellyfin")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )
        let request = try builder.playbackReportRequest(
            pathComponents: ["Sessions", "Playing", "Progress"],
            itemID: "track-id",
            playSessionID: "play-session",
            positionTicks: 125_000_000,
            isPaused: true,
            playMethod: .transcode
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.path,
            "/jellyfin/Sessions/Playing/Progress"
        )
        XCTAssertEqual(payload["ItemId"] as? String, "track-id")
        XCTAssertEqual(payload["PlaySessionId"] as? String, "play-session")
        XCTAssertEqual(payload["PositionTicks"] as? Int64, 125_000_000)
        XCTAssertEqual(payload["IsPaused"] as? Bool, true)
        XCTAssertEqual(payload["CanSeek"] as? Bool, true)
        XCTAssertEqual(payload["PlayMethod"] as? String, "Transcode")
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
              "User": {
                "Id": "user-id",
                "Name": "Tyler",
                "PrimaryImageTag": "user-image-tag"
              },
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
        XCTAssertEqual(authentication.user.primaryImageTag, "user-image-tag")
        XCTAssertEqual(authentication.accessToken, "token")
        XCTAssertEqual(items.totalRecordCount, 1)
        XCTAssertEqual(items.items.first?.displayArtist, "Velacanto")
        XCTAssertEqual(items.items.first?.childCount, 9)
        XCTAssertEqual(items.items.first?.primaryImageTag, "album-image-tag")
        XCTAssertEqual(items.items.first?.kind, .album)
        XCTAssertEqual(items.items.first?.isMusicLibrary, true)
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

    func testAuthenticatedArtworkRequestKeepsTokenOutOfURL() throws {
        let server = try JellyfinServerURL("https://example.com/jellyfin")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )

        let request = try builder.artworkRequest(
            itemID: "album-id",
            imageTag: "image-tag",
            maxWidth: 512
        )
        let components = try XCTUnwrap(
            URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        let queryNames = Set((components.queryItems ?? []).map(\.name))

        XCTAssertFalse(queryNames.contains("api_key"))
        XCTAssertTrue(
            try XCTUnwrap(
                request.value(forHTTPHeaderField: "Authorization")
            ).contains("Token=\"access-token\"")
        )
    }

    func testArtworkSizeBucketingIsStable() {
        XCTAssertEqual(ArtworkKey.sizeBucket(for: 44), 128)
        XCTAssertEqual(ArtworkKey.sizeBucket(for: 129), 256)
        XCTAssertEqual(ArtworkKey.sizeBucket(for: 480), 512)
        XCTAssertEqual(ArtworkKey.sizeBucket(for: 720), 1_024)
        XCTAssertEqual(ArtworkKey.sizeBucket(for: 1_200), 1_024)
    }

    func testUserImageURLUsesJellyfinProfileImageEndpoint() throws {
        let server = try JellyfinServerURL("https://example.com/jellyfin")
        let builder = JellyfinRequestBuilder(
            server: server,
            deviceID: "stable-device",
            accessToken: "access-token"
        )

        let url = try builder.userImageURL(
            userID: "user-id",
            imageTag: "profile-tag",
            maxWidth: 128
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
            "/jellyfin/Users/user-id/Images/Primary"
        )
        XCTAssertEqual(query["tag"], "profile-tag")
        XCTAssertEqual(query["maxWidth"], "128")
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
        let albums = try await controller.musicAlbumsPage(cursor: nil).items

        XCTAssertEqual(
            albums.map(\.id),
            ["album-a", "album-shared"]
        )
    }

    func testPagedCatalogMergesLibrariesInOrderWithoutDuplicates() async throws {
        let decoder = JSONDecoder()
        let firstLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-a","Name":"Main Music"}"#.utf8)
        )
        let secondLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-b","Name":"Archive"}"#.utf8)
        )
        func album(_ id: String, _ name: String) throws -> JellyfinItem {
            try decoder.decode(
                JellyfinItem.self,
                from: Data(
                    #"{"Id":"\#(id)","Name":"\#(name)","Type":"MusicAlbum"}"#.utf8
                )
            )
        }
        let shared = try album("shared", "Delta")
        let api = FakeJellyfinAPI(
            availableLibraries: [firstLibrary, secondLibrary],
            albumsByLibrary: [
                firstLibrary.id: [
                    try album("alpha", "Alpha"),
                    shared,
                ],
                secondLibrary.id: [
                    try album("bravo", "Bravo"),
                    try album("charlie", "Charlie"),
                    shared,
                ],
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

        let first = try await controller.musicAlbumsPage(
            cursor: nil,
            limit: 2
        )
        let second = try await controller.musicAlbumsPage(
            cursor: first.cursor,
            limit: 2
        )
        let exhausted = try await controller.musicAlbumsPage(
            cursor: second.cursor,
            limit: 2
        )

        XCTAssertEqual(first.items.map(\.name), ["Alpha", "Bravo"])
        XCTAssertEqual(second.items.map(\.name), ["Charlie", "Delta"])
        XCTAssertTrue(second.hasMore)
        XCTAssertTrue(exhausted.items.isEmpty)
        XCTAssertFalse(exhausted.hasMore)
    }

    func testPagedAlbumsMergeUsingTheServerAlbumArtistAndSortName() async throws {
        let decoder = JSONDecoder()
        let firstLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-a","Name":"Main Music"}"#.utf8)
        )
        let secondLibrary = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library-b","Name":"Archive"}"#.utf8)
        )
        func album(
            id: String,
            name: String,
            artist: String,
            sortName: String
        ) throws -> JellyfinItem {
            try decoder.decode(
                JellyfinItem.self,
                from: Data(
                    #"{"Id":"\#(id)","Name":"\#(name)","Type":"MusicAlbum","AlbumArtist":"\#(artist)","SortName":"\#(sortName)"}"#
                        .utf8
                )
            )
        }
        let api = FakeJellyfinAPI(
            availableLibraries: [firstLibrary, secondLibrary],
            albumsByLibrary: [
                firstLibrary.id: [
                    try album(
                        id: "zebra",
                        name: "A display name",
                        artist: "Zulu",
                        sortName: "Alpha"
                    )
                ],
                secondLibrary.id: [
                    try album(
                        id: "alpha",
                        name: "Z display name",
                        artist: "Alpha",
                        sortName: "Zulu"
                    )
                ],
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

        let page = try await controller.musicAlbumsPage(cursor: nil, limit: 2)

        XCTAssertEqual(page.items.map(\.id), ["alpha", "zebra"])
    }

    func testCatalogPageAdvancesByRawItemsConsumedWhenFilteringAPlaylist() throws {
        let decoder = JSONDecoder()
        let song = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"song","Name":"Song","Type":"Audio"}"#.utf8)
        )
        let page = JellyfinItemPage(
            items: [song],
            startIndex: 50,
            totalRecordCount: 52,
            consumedItemCount: 2
        )

        XCTAssertEqual(page.nextStartIndex, 52)
        XCTAssertFalse(page.hasMore)
    }

    func testFastScrollPaginationSurvivesViewTaskCancellationAndRetries() async throws {
        let decoder = JSONDecoder()
        let library = try decoder.decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library","Name":"Music"}"#.utf8)
        )
        let albums = try (0..<60).map { index in
            let name = "Album \(String(format: "%03d", index))"
            return try decoder.decode(
                JellyfinItem.self,
                from: Data(
                    #"{"Id":"album-\#(index)","Name":"\#(name)","Type":"MusicAlbum"}"#.utf8
                )
            )
        }
        let api = FakeJellyfinAPI(
            availableLibraries: [library],
            albumsByLibrary: [library.id: albums],
            albumPageDelay: .milliseconds(50),
            transientAlbumPageFailures: 1
        )
        let controller = JellyfinSessionController(
            tokenStore: RecordingTokenStore(),
            sessionStore: RecordingSessionStore(),
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )
        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")
        let model = PagedJellyfinItemsModel()
        let loader: PagedJellyfinItemsModel.Loader = { cursor in
            try await controller.musicAlbumsPage(cursor: cursor)
        }

        await model.reset(loader: loader)
        XCTAssertEqual(model.items.count, 50)

        let paginationTask = try XCTUnwrap(
            model.loadMoreIfNeeded(
                itemID: try XCTUnwrap(model.items.last?.id),
                loader: loader
            )
        )
        let viewTask = Task {
            await paginationTask.value
        }
        viewTask.cancel()
        await paginationTask.value

        XCTAssertEqual(model.items.count, 60)
        XCTAssertNil(model.errorMessage)
        let requestCount = await api.albumPageRequestCount()
        XCTAssertGreaterThanOrEqual(requestCount, 3)
    }

    func testCachedCatalogSnapshotDoesNotShrinkWhenInitialPageRefreshes() async throws {
        let decoder = JSONDecoder()
        let cachedAlbums = try (0..<60).map { index in
            try decoder.decode(
                JellyfinItem.self,
                from: Data(
                    #"{"Id":"album-\#(index)","Name":"Album \#(index)","Type":"MusicAlbum"}"#.utf8
                )
            )
        }
        let refreshedFirstPage = Array(cachedAlbums.prefix(50))
        let model = PagedJellyfinItemsModel()

        await model.reset(
            cachedItems: { cachedAlbums },
            loader: { _ in
                JellyfinCatalogPage(
                    items: refreshedFirstPage,
                    totalRecordCount: cachedAlbums.count,
                    cursor: nil
                )
            }
        )

        XCTAssertEqual(model.items.map(\.id), cachedAlbums.map(\.id))
    }

    func testCatalogCacheIsClearedOnLogout() async throws {
        let api = FakeJellyfinAPI()
        let controller = JellyfinSessionController(
            tokenStore: RecordingTokenStore(),
            sessionStore: RecordingSessionStore(),
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )
        let contextID = UUID().uuidString
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(
                #"{"Id":"cached-item","Name":"Cached","Type":"Audio"}"#.utf8
            )
        )
        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")
        await controller.cacheCatalogItems(
            [item],
            kind: .albumTracks,
            contextID: contextID
        )
        let cachedItems = await controller.cachedCatalogItems(
            kind: .albumTracks,
            contextID: contextID
        )
        XCTAssertEqual(
            cachedItems.map(\.id),
            [item.id]
        )

        await controller.logout()
        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")
        let itemsAfterLogout = await controller.cachedCatalogItems(
            kind: .albumTracks,
            contextID: contextID
        )

        XCTAssertTrue(itemsAfterLogout.isEmpty)
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
        XCTAssertEqual(
            controller.session?.userPrimaryImageTag,
            "profile-image-tag"
        )
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

    func testKeychainBackedSessionRestoresAcrossControllerRelaunch() async throws {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoSessionRestoreTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = "VelacantoTests.\(UUID().uuidString)"
        let keychain = InMemoryKeychainTokenStore()
        let tokenStore = KeychainJellyfinTokenStore(
            legacyDirectory: directory,
            service: service,
            keychain: keychain
        )
        let sessionStore = UserDefaultsJellyfinSessionStore(defaults: defaults)
        let api = FakeJellyfinAPI()
        var firstController: JellyfinSessionController? =
            JellyfinSessionController(
                tokenStore: tokenStore,
                sessionStore: sessionStore,
                autoRestore: false,
                makeClient: { _, _, _ in api }
            )

        await firstController?.connect(to: "https://example.com")
        await firstController?.signIn(username: "Tyler", password: "correct")
        XCTAssertEqual(firstController?.phase, .signedIn)
        firstController = nil

        let restoredController = JellyfinSessionController(
            tokenStore: KeychainJellyfinTokenStore(
                legacyDirectory: directory,
                service: service,
                keychain: keychain
            ),
            sessionStore: UserDefaultsJellyfinSessionStore(defaults: defaults),
            makeClient: { _, _, _ in api }
        )
        for _ in 0..<100 where restoredController.phase == .restoring {
            await Task.yield()
        }

        XCTAssertEqual(restoredController.phase, .signedIn)
        XCTAssertEqual(restoredController.session?.username, "Tyler")
        XCTAssertEqual(try tokenStore.loadToken(), "access-token")
    }

    func testCorruptSavedSessionMetadataIsDiscarded() throws {
        let suiteName = "VelacantoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not JSON".utf8), forKey: "jellyfin.session")

        let store = UserDefaultsJellyfinSessionStore(defaults: defaults)

        XCTAssertNil(store.loadSession())
        XCTAssertNil(defaults.data(forKey: "jellyfin.session"))
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
        let library = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"library","Name":"Music"}"#.utf8)
        )
        let api = FakeJellyfinAPI(
            albumsError: .unauthorized,
            availableLibraries: [library]
        )
        let controller = JellyfinSessionController(
            tokenStore: tokenStore,
            sessionStore: sessionStore,
            autoRestore: false,
            makeClient: { _, _, _ in api }
        )
        await controller.connect(to: "https://example.com")
        await controller.signIn(username: "Tyler", password: "correct")

        do {
            _ = try await controller.musicAlbumsPage(cursor: nil)
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

    func testCatalogCacheTreatsCorruptDiskDataAsACacheMiss() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoCatalogCacheTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corruptFile = directory.appending(path: "server-user.json")
        try Data("not JSON".utf8).write(to: corruptFile)

        let cache = JellyfinCatalogCache(directory: directory)
        let items = await cache.load(
            serverID: "server",
            userID: "user",
            key: "albums|root"
        )

        XCTAssertTrue(items.isEmpty)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(remainingFiles.count, 1)
        XCTAssertTrue(remainingFiles[0].lastPathComponent.contains(".corrupt.json"))
    }

    func testCatalogCacheExpiresRecordsAfterSevenDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "VelacantoCatalogCacheExpiryTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(#"{"Id":"cached-item","Name":"Cached","Type":"Audio"}"#.utf8)
        )
        let savedAt = Date(timeIntervalSinceReferenceDate: 0)
        let cache = JellyfinCatalogCache(directory: directory, now: { savedAt })
        await cache.save(
            [item],
            serverID: "server",
            userID: "user",
            key: "albums|root",
            isDetail: false
        )

        let expiredCache = JellyfinCatalogCache(
            directory: directory,
            now: { savedAt.addingTimeInterval(7 * 24 * 60 * 60 + 1) }
        )
        let items = await expiredCache.load(
            serverID: "server",
            userID: "user",
            key: "albums|root"
        )

        XCTAssertTrue(items.isEmpty)
    }

    func testPlaybackResolverDoesNotRequireCatalogState() async throws {
        let track = try JSONDecoder().decode(
            JellyfinItem.self,
            from: Data(
                #"{"Id":"track-id","Name":"Night Drive","Type":"Audio"}"#.utf8
            )
        )

        let request = try await JellyfinPlaybackRequestResolver(
            api: FakeJellyfinAPI(),
            userID: "user-id"
        ).playbackRequest(for: track)

        XCTAssertEqual(request.item.id, track.id)
        XCTAssertEqual(request.item.source, .jellyfin)
        XCTAssertNotNil(request.reporter)
    }
}

private final class InMemoryKeychainTokenStore: JellyfinKeychainTokenPersisting {
    private var tokens: [String: String] = [:]

    func loadToken(service: String, account: String) throws -> String? {
        tokens[key(service: service, account: account)]
    }

    func saveToken(
        _ token: String,
        service: String,
        account: String
    ) throws {
        tokens[key(service: service, account: account)] = token
    }

    func deleteToken(service: String, account: String) throws {
        tokens.removeValue(forKey: key(service: service, account: account))
    }

    private func key(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}

private enum LegacyFileRemovalError: Error {
    case failed
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
    private let albumPageDelay: Duration?
    private var transientAlbumPageFailures: Int
    private var albumPageRequests = 0

    init(
        publicServerInfoError: JellyfinAPIError? = nil,
        authenticationError: JellyfinAPIError? = nil,
        currentUserError: JellyfinAPIError? = nil,
        albumsError: JellyfinAPIError? = nil,
        availableLibraries: [JellyfinItem] = [],
        albumsByLibrary: [String: [JellyfinItem]] = [:],
        albumPageDelay: Duration? = nil,
        transientAlbumPageFailures: Int = 0
    ) {
        self.publicServerInfoError = publicServerInfoError
        self.authenticationError = authenticationError
        self.currentUserError = currentUserError
        self.albumsError = albumsError
        self.availableLibraries = availableLibraries
        self.albumsByLibrary = albumsByLibrary
        self.albumPageDelay = albumPageDelay
        self.transientAlbumPageFailures = transientAlbumPageFailures
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
            user: JellyfinUser(
                id: "user-id",
                name: username,
                primaryImageTag: "profile-image-tag"
            ),
            accessToken: "access-token"
        )
    }

    func currentUser() async throws -> JellyfinUser {
        if let currentUserError {
            throw currentUserError
        }
        return JellyfinUser(
            id: "user-id",
            name: "Tyler",
            primaryImageTag: "profile-image-tag"
        )
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

    func albumsPage(
        userID: String,
        libraryID: String,
        artistID: String?,
        startIndex: Int,
        limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage {
        albumPageRequests += 1
        if startIndex > 0, let albumPageDelay {
            try await Task.sleep(for: albumPageDelay)
        }
        if startIndex > 0, transientAlbumPageFailures > 0 {
            transientAlbumPageFailures -= 1
            throw JellyfinAPIError.unreachable
        }
        if let albumsError {
            throw albumsError
        }
        var albums = albumsByLibrary[libraryID] ?? []
        if let searchTerm, !searchTerm.isEmpty {
            albums = albums.filter {
                $0.name.localizedCaseInsensitiveContains(searchTerm)
            }
        }
        let safeStart = min(max(startIndex, 0), albums.count)
        let safeEnd = min(safeStart + max(limit, 1), albums.count)
        return JellyfinItemPage(
            items: Array(albums[safeStart..<safeEnd]),
            startIndex: safeStart,
            totalRecordCount: albums.count
        )
    }

    func albumPageRequestCount() -> Int {
        albumPageRequests
    }

    func artistsPage(
        userID: String, libraryID: String, startIndex: Int, limit: Int, searchTerm: String?
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func songsPage(
        userID: String, libraryID: String, artistID: String?, startIndex: Int, limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func playlistsPage(
        userID: String, startIndex: Int, limit: Int, searchTerm: String?
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func searchMusicPage(
        userID: String, query: String, startIndex: Int, limit: Int
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func playlistItemsPage(
        userID: String, playlistID: String, startIndex: Int, limit: Int
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func tracksPage(
        userID: String, albumID: String, startIndex: Int, limit: Int
    ) async throws -> JellyfinItemPage { emptyPage(startIndex) }

    func playbackResolution(
        itemID: String,
        userID: String
    ) async throws -> JellyfinPlaybackResolution {
        guard let url = URL(string: "https://example.com/Audio/\(itemID)/stream") else {
            throw JellyfinAPIError.invalidResponse
        }
        return JellyfinPlaybackResolution(
            streamURL: url,
            playSessionID: "fake-session",
            playMethod: .directPlay
        )
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
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
        return URLRequest(url: url)
    }

    func userImageRequest(
        userID: String,
        imageTag: String?,
        maxWidth: Int
    ) async throws -> URLRequest {
        guard
            var components = URLComponents(
                string: "https://example.com/Users/\(userID)/Images/Primary"
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
        return URLRequest(url: url)
    }

    private func emptyPage(_ startIndex: Int) -> JellyfinItemPage {
        JellyfinItemPage(items: [], startIndex: max(startIndex, 0), totalRecordCount: 0)
    }

    func logout() async throws {}
}
