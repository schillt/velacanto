import Combine
import Foundation
import os

struct JellyfinSession: Codable, Equatable, Sendable {
    let serverURL: URL
    let serverID: String
    let serverName: String
    let userID: String
    let username: String
    let userPrimaryImageTag: String?

    init(
        serverURL: URL,
        serverID: String,
        serverName: String,
        userID: String,
        username: String,
        userPrimaryImageTag: String? = nil
    ) {
        self.serverURL = serverURL
        self.serverID = serverID
        self.serverName = serverName
        self.userID = userID
        self.username = username
        self.userPrimaryImageTag = userPrimaryImageTag
    }
}

enum JellyfinSessionPhase: Equatable, Sendable {
    case restoring
    case signedOut
    case connecting
    case awaitingCredentials
    case authenticating
    case signedIn
}

enum JellyfinCatalogKind: String, Codable, Sendable {
    case albums
    case artists
    case songs
    case playlists
    case search
    case albumTracks
    case playlistTracks
}

struct JellyfinCatalogCursor: Sendable {
    fileprivate let identity: String
    fileprivate var offsets: [String: Int]
    fileprivate var totals: [String: Int]
    fileprivate var buffers: [String: [JellyfinItem]]
    fileprivate var exhaustedSources: Set<String>
    fileprivate var seenItemIDs: Set<String>
}

struct JellyfinCatalogPage: Sendable {
    let items: [JellyfinItem]
    let totalRecordCount: Int
    let cursor: JellyfinCatalogCursor?

    var hasMore: Bool {
        cursor != nil
    }
}

private actor JellyfinCatalogCache {
    private struct Record: Codable {
        var items: [JellyfinItem]
        var updatedAt: Date
        var lastAccessedAt: Date
        let isDetail: Bool
    }

    private struct Envelope: Codable {
        let version: Int
        var records: [String: Record]
    }

    private let directory: URL
    private let maxBytes = 10 * 1_024 * 1_024
    private let maxAge: TimeInterval = 7 * 24 * 60 * 60
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        let baseDirectory =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directory = baseDirectory.appending(
            path: "VelacantoCatalog",
            directoryHint: .isDirectory
        )
    }

    func load(
        serverID: String,
        userID: String,
        key: String
    ) -> [JellyfinItem] {
        var envelope = readEnvelope(serverID: serverID, userID: userID)
        guard var record = envelope.records[key] else { return [] }
        guard Date().timeIntervalSince(record.updatedAt) <= maxAge else {
            envelope.records.removeValue(forKey: key)
            writeEnvelope(envelope, serverID: serverID, userID: userID)
            return []
        }
        record.lastAccessedAt = Date()
        envelope.records[key] = record
        writeEnvelope(envelope, serverID: serverID, userID: userID)
        return record.items
    }

    func save(
        _ items: [JellyfinItem],
        serverID: String,
        userID: String,
        key: String,
        isDetail: Bool
    ) {
        var envelope = readEnvelope(serverID: serverID, userID: userID)
        let now = Date()
        envelope.records[key] = Record(
            items: Array(items.prefix(200)),
            updatedAt: now,
            lastAccessedAt: now,
            isDetail: isDetail
        )

        let detailKeys =
            envelope.records
            .filter(\.value.isDetail)
            .sorted { $0.value.lastAccessedAt > $1.value.lastAccessedAt }
            .dropFirst(20)
            .map(\.key)
        for detailKey in detailKeys {
            envelope.records.removeValue(forKey: detailKey)
        }

        var sortedKeys = envelope.records.keys.sorted {
            let lhs = envelope.records[$0]?.lastAccessedAt ?? .distantPast
            let rhs = envelope.records[$1]?.lastAccessedAt ?? .distantPast
            return lhs < rhs
        }
        while let data = try? encoder.encode(envelope),
            data.count > maxBytes,
            let oldestKey = sortedKeys.first
        {
            envelope.records.removeValue(forKey: oldestKey)
            sortedKeys.removeFirst()
        }
        writeEnvelope(envelope, serverID: serverID, userID: userID)
    }

    func clear(serverID: String, userID: String) {
        try? FileManager.default.removeItem(
            at: fileURL(serverID: serverID, userID: userID)
        )
    }

    private func readEnvelope(
        serverID: String,
        userID: String
    ) -> Envelope {
        guard
            let data = try? Data(
                contentsOf: fileURL(serverID: serverID, userID: userID)
            ),
            let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.version == 1
        else {
            return Envelope(version: 1, records: [:])
        }
        return envelope
    }

    private func writeEnvelope(
        _ envelope: Envelope,
        serverID: String,
        userID: String
    ) {
        guard let data = try? encoder.encode(envelope) else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try? data.write(
            to: fileURL(serverID: serverID, userID: userID),
            options: .atomic
        )
    }

    private func fileURL(serverID: String, userID: String) -> URL {
        let safeID = "\(serverID)-\(userID)".map {
            $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-"
        }
        return directory.appending(path: "\(String(safeID)).json")
    }
}

protocol JellyfinTokenStoring {
    func loadToken() throws -> String?
    func saveToken(_ token: String) throws
    func deleteToken() throws
}

protocol JellyfinSessionPersisting {
    func loadSession() -> JellyfinSession?
    func saveSession(_ session: JellyfinSession)
    func deleteSession()
    func loadDeviceID() -> String?
    func saveDeviceID(_ deviceID: String)
}

struct FileJellyfinTokenStore: JellyfinTokenStoring {
    private static let defaultAccount = "jellyfin.access-token"

    private let fileManager: FileManager
    private let directory: URL
    private let fileURL: URL
    private let account: String
    private let legacyDefaults: UserDefaults?

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        account: String = defaultAccount,
        migratingFrom legacyDefaults: UserDefaults? = nil
    ) {
        let applicationSupport =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
        let resolvedDirectory =
            directory
            ?? applicationSupport.appending(
                path: "Velacanto/Session",
                directoryHint: .isDirectory
            )
        self.fileManager = fileManager
        self.directory = resolvedDirectory
        fileURL = resolvedDirectory.appending(
            path: "jellyfin-access-token-v1",
            directoryHint: .notDirectory
        )
        self.account = account
        self.legacyDefaults = legacyDefaults
    }

    func loadToken() throws -> String? {
        if fileManager.fileExists(atPath: fileURL.path) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                throw JellyfinCredentialStoreError.storageUnavailable
            }
            guard
                let token = String(data: data, encoding: .utf8),
                !token.isEmpty
            else {
                throw JellyfinCredentialStoreError.invalidToken
            }
            return token
        }

        guard
            let legacyDefaults,
            let legacyToken = legacyDefaults.string(forKey: account),
            !legacyToken.isEmpty
        else {
            return nil
        }

        try saveToken(legacyToken)
        legacyDefaults.removeObject(forKey: account)
        return legacyToken
    }

    func saveToken(_ token: String) throws {
        guard !token.isEmpty else {
            throw JellyfinCredentialStoreError.invalidToken
        }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try Data(token.utf8).write(to: fileURL, options: .atomic)
            var attributes: [FileAttributeKey: Any] = [
                .posixPermissions: 0o600
            ]
            #if os(iOS)
                attributes[.protectionKey] =
                    FileProtectionType.completeUntilFirstUserAuthentication
            #endif
            try fileManager.setAttributes(
                attributes,
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw JellyfinCredentialStoreError.storageUnavailable
        }

        legacyDefaults?.removeObject(forKey: account)
    }

    func deleteToken() throws {
        defer {
            legacyDefaults?.removeObject(forKey: account)
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            throw JellyfinCredentialStoreError.storageUnavailable
        }
    }
}

struct UserDefaultsJellyfinSessionStore: JellyfinSessionPersisting {
    private let defaults: UserDefaults
    private let sessionKey = "jellyfin.session"
    private let deviceIDKey = "jellyfin.device-id"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSession() -> JellyfinSession? {
        guard let data = defaults.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(JellyfinSession.self, from: data)
    }

    func saveSession(_ session: JellyfinSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: sessionKey)
    }

    func deleteSession() {
        defaults.removeObject(forKey: sessionKey)
    }

    func loadDeviceID() -> String? {
        defaults.string(forKey: deviceIDKey)
    }

    func saveDeviceID(_ deviceID: String) {
        defaults.set(deviceID, forKey: deviceIDKey)
    }
}

enum JellyfinCredentialStoreError: LocalizedError, Equatable {
    case invalidToken
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Jellyfin returned an invalid access token."
        case .storageUnavailable:
            "The Jellyfin session could not be saved in Velacanto’s private app storage."
        }
    }
}

@MainActor
final class JellyfinSessionController: ObservableObject {
    private static let performanceLog = OSLog(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Performance"
    )
    typealias ClientFactory =
        @Sendable (JellyfinServerURL, String, String?) -> any JellyfinAPIService

    @Published private(set) var phase: JellyfinSessionPhase
    @Published private(set) var serverInfo: JellyfinServerInfo?
    @Published private(set) var session: JellyfinSession?
    @Published private(set) var libraries: [JellyfinItem] = []
    @Published private(set) var isRefreshingLibraries = false
    @Published private(set) var errorMessage: String?

    private let tokenStore: any JellyfinTokenStoring
    private let sessionStore: any JellyfinSessionPersisting
    private let makeClient: ClientFactory
    private let playbackAdapter = JellyfinPlaybackAdapter()
    private let catalogCache = JellyfinCatalogCache()
    private let deviceID: String
    private var candidateServer: JellyfinServerURL?
    private var client: (any JellyfinAPIService)?

    convenience init(autoRestore: Bool = true) {
        self.init(
            tokenStore: FileJellyfinTokenStore(
                migratingFrom: .standard
            ),
            sessionStore: UserDefaultsJellyfinSessionStore(),
            autoRestore: autoRestore
        )
    }

    init(
        tokenStore: any JellyfinTokenStoring,
        sessionStore: any JellyfinSessionPersisting,
        autoRestore: Bool = true,
        makeClient: @escaping ClientFactory = { server, deviceID, token in
            JellyfinAPIClient(
                server: server,
                deviceID: deviceID,
                accessToken: token
            )
        }
    ) {
        self.tokenStore = tokenStore
        self.sessionStore = sessionStore
        self.makeClient = makeClient

        if let savedDeviceID = sessionStore.loadDeviceID(), !savedDeviceID.isEmpty {
            deviceID = savedDeviceID
        } else {
            let newDeviceID = UUID().uuidString
            deviceID = newDeviceID
            sessionStore.saveDeviceID(newDeviceID)
        }

        phase = autoRestore ? .restoring : .signedOut
        if autoRestore {
            Task { [weak self] in
                await self?.restore()
            }
        }
    }

    var isSignedIn: Bool {
        session != nil
    }

    var isWorking: Bool {
        switch phase {
        case .restoring, .connecting, .authenticating:
            true
        case .signedOut, .awaitingCredentials, .signedIn:
            false
        }
    }

    var usesInsecureLocalHTTP: Bool {
        (candidateServer?.url ?? session?.serverURL)?.scheme?.lowercased() == "http"
    }

    var playbackAccount: PlaybackAccount? {
        guard let session else { return nil }
        return PlaybackAccount(
            serverID: session.serverID,
            userID: session.userID
        )
    }

    func connect(to userInput: String) async {
        phase = .connecting
        errorMessage = nil
        serverInfo = nil
        candidateServer = nil

        do {
            let server = try JellyfinServerURL(userInput)
            let newClient = makeClient(server, deviceID, nil)
            let info = try await newClient.publicServerInfo()
            if info.startupWizardCompleted == false {
                throw JellyfinSessionError.serverSetupIncomplete
            }

            candidateServer = server
            serverInfo = info
            client = newClient
            phase = .awaitingCredentials
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func signIn(username: String, password: String) async {
        guard
            let server = candidateServer,
            let info = serverInfo,
            !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !password.isEmpty
        else {
            errorMessage = JellyfinSessionError.missingCredentials.localizedDescription
            return
        }

        phase = .authenticating
        errorMessage = nil

        do {
            let unauthenticatedClient = makeClient(server, deviceID, nil)
            let result = try await unauthenticatedClient.authenticate(
                username: username,
                password: password
            )
            try tokenStore.saveToken(result.accessToken)

            let newSession = JellyfinSession(
                serverURL: server.url,
                serverID: info.id,
                serverName: info.serverName,
                userID: result.user.id,
                username: result.user.name,
                userPrimaryImageTag: result.user.primaryImageTag
            )
            sessionStore.saveSession(newSession)

            let authenticatedClient = makeClient(
                server,
                deviceID,
                result.accessToken
            )
            session = newSession
            client = authenticatedClient
            phase = .signedIn
            await refreshLibraries()
        } catch {
            phase = .awaitingCredentials
            errorMessage = error.localizedDescription
        }
    }

    func refreshLibraries() async {
        guard let activeSession = session, let client else { return }
        isRefreshingLibraries = true
        defer {
            if session == activeSession {
                isRefreshingLibraries = false
            }
        }

        do {
            let refreshedLibraries = try await client.libraries(
                userID: activeSession.userID
            )
            guard session == activeSession else { return }
            libraries = refreshedLibraries
            errorMessage = nil
        } catch {
            guard session == activeSession else { return }
            libraries = []
            errorMessage = error.localizedDescription
            handleExpiredSessionIfNeeded(error)
        }
    }

    func albums(in library: JellyfinItem) async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            return try await client.albums(
                userID: session.userID,
                libraryID: library.id
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func musicAlbums(for artist: JellyfinItem? = nil) async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            var results: [JellyfinItem] = []
            for library in libraries {
                if let artist {
                    results += try await client.albums(
                        userID: session.userID,
                        libraryID: library.id,
                        artistID: artist.id
                    )
                } else {
                    results += try await client.albums(
                        userID: session.userID,
                        libraryID: library.id
                    )
                }
            }
            return uniqueItems(results)
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func musicArtists() async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            var results: [JellyfinItem] = []
            for library in libraries {
                results += try await client.artists(
                    userID: session.userID,
                    libraryID: library.id
                )
            }
            return uniqueItems(results)
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func musicSongs() async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            var results: [JellyfinItem] = []
            for library in libraries {
                results += try await client.songs(
                    userID: session.userID,
                    libraryID: library.id
                )
            }
            return uniqueItems(results)
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func musicPlaylists() async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            return uniqueItems(
                try await client.playlists(userID: session.userID)
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func musicAlbumsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil,
        artist: JellyfinItem? = nil
    ) async throws -> JellyfinCatalogPage {
        try await multiLibraryPage(
            kind: .albums,
            contextID: artist?.id,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { client, userID, libraryID, offset, pageLimit, term in
            try await client.albumsPage(
                userID: userID,
                libraryID: libraryID,
                artistID: artist?.id,
                startIndex: offset,
                limit: pageLimit,
                searchTerm: term
            )
        }
    }

    func musicArtistsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        try await multiLibraryPage(
            kind: .artists,
            contextID: nil,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { client, userID, libraryID, offset, pageLimit, term in
            try await client.artistsPage(
                userID: userID,
                libraryID: libraryID,
                startIndex: offset,
                limit: pageLimit,
                searchTerm: term
            )
        }
    }

    func musicSongsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        try await multiLibraryPage(
            kind: .songs,
            contextID: nil,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { client, userID, libraryID, offset, pageLimit, term in
            try await client.songsPage(
                userID: userID,
                libraryID: libraryID,
                startIndex: offset,
                limit: pageLimit,
                searchTerm: term
            )
        }
    }

    func musicPlaylistsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return try await singleSourcePage(
            kind: .playlists,
            contextID: nil,
            cursor: cursor,
            limit: limit,
            searchTerm: searchTerm
        ) { offset, pageLimit in
            try await client.playlistsPage(
                userID: session.userID,
                startIndex: offset,
                limit: pageLimit,
                searchTerm: searchTerm
            )
        }
    }

    func searchMusicPage(
        query: String,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50
    ) async throws -> JellyfinCatalogPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return JellyfinCatalogPage(
                items: [],
                totalRecordCount: 0,
                cursor: nil
            )
        }
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return try await singleSourcePage(
            kind: .search,
            contextID: trimmedQuery,
            cursor: cursor,
            limit: limit,
            searchTerm: trimmedQuery
        ) { offset, pageLimit in
            try await client.searchMusicPage(
                userID: session.userID,
                query: trimmedQuery,
                startIndex: offset,
                limit: pageLimit
            )
        }
    }

    func tracksPage(
        in album: JellyfinItem,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50
    ) async throws -> JellyfinCatalogPage {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return try await singleSourcePage(
            kind: .albumTracks,
            contextID: album.id,
            cursor: cursor,
            limit: limit,
            searchTerm: nil
        ) { offset, pageLimit in
            try await client.tracksPage(
                userID: session.userID,
                albumID: album.id,
                startIndex: offset,
                limit: pageLimit
            )
        }
    }

    func tracksPage(
        inPlaylist playlist: JellyfinItem,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50
    ) async throws -> JellyfinCatalogPage {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return try await singleSourcePage(
            kind: .playlistTracks,
            contextID: playlist.id,
            cursor: cursor,
            limit: limit,
            searchTerm: nil
        ) { offset, pageLimit in
            try await client.playlistItemsPage(
                userID: session.userID,
                playlistID: playlist.id,
                startIndex: offset,
                limit: pageLimit
            )
        }
    }

    func cachedCatalogItems(
        kind: JellyfinCatalogKind,
        contextID: String? = nil
    ) async -> [JellyfinItem] {
        guard kind != .search, let session else { return [] }
        let items = await catalogCache.load(
            serverID: session.serverID,
            userID: session.userID,
            key: catalogCacheKey(kind: kind, contextID: contextID)
        )
        if !items.isEmpty {
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "Catalog Cache Hit"
            )
        }
        return items
    }

    func cacheCatalogItems(
        _ items: [JellyfinItem],
        kind: JellyfinCatalogKind,
        contextID: String? = nil
    ) async {
        guard kind != .search, let session else { return }
        await catalogCache.save(
            items,
            serverID: session.serverID,
            userID: session.userID,
            key: catalogCacheKey(kind: kind, contextID: contextID),
            isDetail: kind == .albumTracks || kind == .playlistTracks
                || contextID != nil
        )
    }

    func searchMusic(query: String) async throws -> [JellyfinItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }

        do {
            return try await client.searchMusic(
                userID: session.userID,
                query: trimmedQuery,
                limit: 60
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func tracks(inPlaylist playlist: JellyfinItem) async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            return try await client.playlistItems(
                userID: session.userID,
                playlistID: playlist.id
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func tracks(in album: JellyfinItem) async throws -> [JellyfinItem] {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            return try await client.tracks(
                userID: session.userID,
                albumID: album.id
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func playbackRequest(for track: JellyfinItem) async throws -> PlaybackRequest {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            let resolution = try await client.playbackResolution(
                itemID: track.id,
                userID: session.userID
            )
            let reporter = playbackReporter(
                itemID: track.id,
                resolution: resolution,
                client: client
            )
            return try await playbackAdapter.playbackRequest(
                for: JellyfinTrackSelection(
                    track: track,
                    streamURL: resolution.streamURL,
                    reporter: reporter
                )
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func playbackRequest(for item: PlaybackItem) async throws -> PlaybackRequest {
        guard item.source == .jellyfin else {
            throw JellyfinSessionError.unsupportedHistoryItem
        }
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        do {
            let resolution = try await client.playbackResolution(
                itemID: item.id,
                userID: session.userID
            )
            return PlaybackRequest(
                item: item,
                asset: PlaybackAsset(url: resolution.streamURL),
                reporter: playbackReporter(
                    itemID: item.id,
                    resolution: resolution,
                    client: client
                )
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    private func playbackReporter(
        itemID: String,
        resolution: JellyfinPlaybackResolution,
        client: any JellyfinAPIService
    ) -> (any PlaybackLifecycleReporting)? {
        return JellyfinPlaybackReporter(
            api: client,
            itemID: itemID,
            playSessionID: resolution.playSessionID,
            playMethod: resolution.playMethod
        )
    }

    func artworkURL(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async -> URL? {
        guard let client else { return nil }
        return try? await client.artworkURL(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async -> URLRequest? {
        guard let client else { return nil }
        return try? await client.artworkRequest(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func userImageURL(maxWidth: Int) async -> URL? {
        guard let session, let client else { return nil }
        return try? await client.userImageURL(
            userID: session.userID,
            imageTag: session.userPrimaryImageTag,
            maxWidth: maxWidth
        )
    }

    func userImageRequest(maxWidth: Int) async -> URLRequest? {
        guard let session, let client else { return nil }
        return try? await client.userImageRequest(
            userID: session.userID,
            imageTag: session.userPrimaryImageTag,
            maxWidth: maxWidth
        )
    }

    func editServer() {
        guard session == nil else { return }
        candidateServer = nil
        serverInfo = nil
        client = nil
        errorMessage = nil
        phase = .signedOut
    }

    func logout() async {
        let oldSession = session
        let oldClient = client
        do {
            try tokenStore.deleteToken()
            sessionStore.deleteSession()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        clearSession()
        if let oldSession {
            await catalogCache.clear(
                serverID: oldSession.serverID,
                userID: oldSession.userID
            )
        }
        try? await oldClient?.logout()
    }

    private typealias PageLoader =
        @Sendable (
            any JellyfinAPIService,
            String,
            String,
            Int,
            Int,
            String?
        ) async throws -> JellyfinItemPage

    private func multiLibraryPage(
        kind: JellyfinCatalogKind,
        contextID: String?,
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?,
        loader: @escaping PageLoader
    ) async throws -> JellyfinCatalogPage {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        let sourceIDs = libraries.map(\.id)
        do {
            return try await pageFromSources(
                kind: kind,
                contextID: contextID,
                sourceIDs: sourceIDs,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            ) { sourceID, offset, pageLimit in
                try await loader(
                    client,
                    session.userID,
                    sourceID,
                    offset,
                    pageLimit,
                    searchTerm
                )
            }
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    private func singleSourcePage(
        kind: JellyfinCatalogKind,
        contextID: String?,
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?,
        loader: @escaping @Sendable (Int, Int) async throws -> JellyfinItemPage
    ) async throws -> JellyfinCatalogPage {
        do {
            return try await pageFromSources(
                kind: kind,
                contextID: contextID,
                sourceIDs: ["global"],
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            ) { _, offset, pageLimit in
                try await loader(offset, pageLimit)
            }
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    private func pageFromSources(
        kind: JellyfinCatalogKind,
        contextID: String?,
        sourceIDs: [String],
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String?,
        loader:
            @escaping @Sendable (
                String,
                Int,
                Int
            ) async throws -> JellyfinItemPage
    ) async throws -> JellyfinCatalogPage {
        let signpostID = OSSignpostID(log: Self.performanceLog)
        os_signpost(
            .begin,
            log: Self.performanceLog,
            name: "Catalog Page",
            signpostID: signpostID
        )
        defer {
            os_signpost(
                .end,
                log: Self.performanceLog,
                name: "Catalog Page",
                signpostID: signpostID
            )
        }
        let safeLimit = max(limit, 1)
        let identity = [
            kind.rawValue,
            contextID ?? "",
            searchTerm ?? "",
            sourceIDs.sorted().joined(separator: ","),
        ].joined(separator: "|")

        var state: JellyfinCatalogCursor
        if let cursor, cursor.identity == identity {
            state = cursor
        } else {
            state = JellyfinCatalogCursor(
                identity: identity,
                offsets: Dictionary(
                    uniqueKeysWithValues: sourceIDs.map { ($0, 0) }
                ),
                totals: [:],
                buffers: Dictionary(
                    uniqueKeysWithValues: sourceIDs.map { ($0, []) }
                ),
                exhaustedSources: [],
                seenItemIDs: []
            )
        }

        var output: [JellyfinItem] = []
        while output.count < safeLimit {
            let sourcesToFill = sourceIDs.filter {
                state.buffers[$0, default: []].isEmpty
                    && !state.exhaustedSources.contains($0)
            }

            if !sourcesToFill.isEmpty {
                let offsets = state.offsets
                let responses = try await withThrowingTaskGroup(
                    of: (String, JellyfinItemPage).self
                ) { group in
                    for sourceID in sourcesToFill {
                        let offset = offsets[sourceID, default: 0]
                        group.addTask {
                            (
                                sourceID,
                                try await loader(
                                    sourceID,
                                    offset,
                                    safeLimit
                                )
                            )
                        }
                    }

                    var values: [(String, JellyfinItemPage)] = []
                    for try await value in group {
                        values.append(value)
                    }
                    return values
                }

                for (sourceID, page) in responses {
                    state.buffers[sourceID, default: []].append(
                        contentsOf: page.items
                    )
                    state.offsets[sourceID] = page.nextStartIndex
                    state.totals[sourceID] = page.totalRecordCount
                    if page.items.isEmpty
                        || (page.totalRecordCount > 0
                            && page.nextStartIndex >= page.totalRecordCount)
                    {
                        state.exhaustedSources.insert(sourceID)
                    }
                }
            }

            let nextSourceID =
                sourceIDs
                .filter { !state.buffers[$0, default: []].isEmpty }
                .min { lhs, rhs in
                    guard
                        let left = state.buffers[lhs]?.first,
                        let right = state.buffers[rhs]?.first
                    else {
                        return lhs < rhs
                    }
                    let comparison = left.name.localizedStandardCompare(
                        right.name
                    )
                    if comparison == .orderedSame {
                        return left.id < right.id
                    }
                    return comparison == .orderedAscending
                }

            guard let nextSourceID else { break }
            let candidate = state.buffers[nextSourceID, default: []].removeFirst()
            if state.seenItemIDs.insert(candidate.id).inserted {
                output.append(candidate)
            }
        }

        let hasMore =
            sourceIDs.contains {
                !state.exhaustedSources.contains($0)
                    || !state.buffers[$0, default: []].isEmpty
            }
        return JellyfinCatalogPage(
            items: output,
            totalRecordCount: state.totals.values.reduce(0, +),
            cursor: hasMore ? state : nil
        )
    }

    private func catalogCacheKey(
        kind: JellyfinCatalogKind,
        contextID: String?
    ) -> String {
        "\(kind.rawValue)|\(contextID ?? "root")"
    }

    private func restore() async {
        do {
            let savedSession = sessionStore.loadSession()
            let token = try tokenStore.loadToken()
            guard let savedSession, let token else {
                if savedSession != nil {
                    sessionStore.deleteSession()
                }
                if token != nil {
                    try tokenStore.deleteToken()
                }
                clearSession()
                return
            }

            let server = try JellyfinServerURL(savedSession.serverURL.absoluteString)
            let authenticatedClient = makeClient(server, deviceID, token)
            session = savedSession
            candidateServer = server
            client = authenticatedClient

            do {
                let user = try await authenticatedClient.currentUser()
                let restored = JellyfinSession(
                    serverURL: savedSession.serverURL,
                    serverID: savedSession.serverID,
                    serverName: savedSession.serverName,
                    userID: user.id,
                    username: user.name,
                    userPrimaryImageTag: user.primaryImageTag
                )
                session = restored
                sessionStore.saveSession(restored)
                phase = .signedIn
                await refreshLibraries()
            } catch JellyfinAPIError.unauthorized {
                try tokenStore.deleteToken()
                sessionStore.deleteSession()
                clearSession()
                errorMessage = JellyfinSessionError.expiredSession.localizedDescription
            } catch {
                phase = .signedIn
                errorMessage =
                    "The saved session is available, but Velacanto could not verify it: "
                    + error.localizedDescription
            }
        } catch {
            clearSession()
            errorMessage = error.localizedDescription
        }
    }

    private func handleExpiredSessionIfNeeded(_ error: Error) {
        guard error as? JellyfinAPIError == .unauthorized else { return }
        try? tokenStore.deleteToken()
        sessionStore.deleteSession()
        clearSession()
        errorMessage = JellyfinSessionError.expiredSession.localizedDescription
    }

    private func uniqueItems(_ items: [JellyfinItem]) -> [JellyfinItem] {
        var seen = Set<String>()
        return
            items
            .filter { seen.insert($0.id).inserted }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private func clearSession() {
        session = nil
        candidateServer = nil
        serverInfo = nil
        client = nil
        libraries = []
        isRefreshingLibraries = false
        phase = .signedOut
    }
}

enum JellyfinSessionError: LocalizedError, Equatable {
    case missingCredentials
    case notSignedIn
    case expiredSession
    case serverSetupIncomplete
    case unsupportedHistoryItem

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Enter both a Jellyfin username and password."
        case .notSignedIn:
            "Sign in to Jellyfin before browsing or playing music."
        case .expiredSession:
            "The saved Jellyfin session expired. Please sign in again."
        case .serverSetupIncomplete:
            "That Jellyfin server has not completed its initial setup."
        case .unsupportedHistoryItem:
            "This recent item must be opened again from its original source."
        }
    }
}
