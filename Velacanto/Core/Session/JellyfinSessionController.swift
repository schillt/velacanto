import Combine
import Foundation

struct JellyfinSession: Codable, Equatable, Sendable {
    let serverURL: URL
    let serverID: String
    let serverName: String
    let userID: String
    let username: String
}

enum JellyfinSessionPhase: Equatable, Sendable {
    case restoring
    case signedOut
    case connecting
    case awaitingCredentials
    case authenticating
    case signedIn
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

struct UserDefaultsJellyfinTokenStore: JellyfinTokenStoring {
    private let defaults: UserDefaults
    private let tokenKey = "jellyfin.access-token"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadToken() throws -> String? {
        defaults.string(forKey: tokenKey)
    }

    func saveToken(_ token: String) throws {
        guard !token.isEmpty else {
            throw JellyfinCredentialStoreError.invalidToken
        }
        defaults.set(token, forKey: tokenKey)
    }

    func deleteToken() throws {
        defaults.removeObject(forKey: tokenKey)
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

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            "Jellyfin returned an invalid access token."
        }
    }
}

@MainActor
final class JellyfinSessionController: ObservableObject {
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
    private let deviceID: String
    private var candidateServer: JellyfinServerURL?
    private var client: (any JellyfinAPIService)?

    convenience init(autoRestore: Bool = true) {
        self.init(
            tokenStore: UserDefaultsJellyfinTokenStore(),
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
                username: result.user.name
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
            let streamURL = try await client.streamURL(
                itemID: track.id,
                userID: session.userID
            )
            return try await playbackAdapter.playbackRequest(
                for: JellyfinTrackSelection(
                    track: track,
                    streamURL: streamURL
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
            let streamURL = try await client.streamURL(
                itemID: item.id,
                userID: session.userID
            )
            return PlaybackRequest(
                item: item,
                asset: PlaybackAsset(url: streamURL)
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
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

    func editServer() {
        guard session == nil else { return }
        candidateServer = nil
        serverInfo = nil
        client = nil
        errorMessage = nil
        phase = .signedOut
    }

    func logout() async {
        let oldClient = client
        do {
            try tokenStore.deleteToken()
            sessionStore.deleteSession()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        clearSession()
        try? await oldClient?.logout()
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
                    username: user.name
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
