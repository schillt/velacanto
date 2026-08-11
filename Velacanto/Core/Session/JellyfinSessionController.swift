import Combine
import Foundation
import Security

/// The UI-visible lifecycle of a Jellyfin connection attempt.
enum JellyfinSessionPhase: Equatable, Sendable {
    case restoring
    case signedOut
    case connecting
    case awaitingCredentials
    case authenticating
    case signedIn
}

@MainActor
/// Coordinates published session state for SwiftUI.
///
/// It is deliberately a thin façade: catalog reads and stream negotiation use
/// focused collaborators, while this type owns only state transitions that
/// affect presentation. Each asynchronous operation snapshots the active
/// session before awaiting so stale responses cannot repopulate the UI.
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
    private let catalogCache = JellyfinCatalogCache()
    private let deviceID: String
    private var candidateServer: JellyfinServerURL?
    private var client: (any JellyfinAPIService)?

    convenience init(autoRestore: Bool = true) {
        self.init(
            tokenStore: KeychainJellyfinTokenStore(
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

    // MARK: - Connection lifecycle

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
        guard let activeSession = session, client != nil else { return }
        isRefreshingLibraries = true
        defer {
            if session == activeSession {
                isRefreshingLibraries = false
            }
        }

        do {
            let refreshedLibraries = try await catalogRepository().libraries()
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

    // MARK: - Catalog façade

    func musicAlbumsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil,
        artist: JellyfinItem? = nil
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: .albums, contextID: artist?.id, cursor: cursor,
            limit: limit, searchTerm: searchTerm
        )
    }

    func musicArtistsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: .artists, cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
    }

    func musicSongsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil,
        artist: JellyfinItem? = nil
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: artist == nil ? .songs : .artistTracks,
            contextID: artist?.id,
            cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
    }

    func musicPlaylistsPage(
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: .playlists, cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
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
        return try await catalogPage(
            kind: .search, contextID: trimmedQuery, cursor: cursor,
            limit: limit, searchTerm: trimmedQuery
        )
    }

    func tracksPage(
        in album: JellyfinItem,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: .albumTracks, contextID: album.id, cursor: cursor,
            limit: limit
        )
    }

    func tracksPage(
        inPlaylist playlist: JellyfinItem,
        cursor: JellyfinCatalogCursor?,
        limit: Int = 50
    ) async throws -> JellyfinCatalogPage {
        try await catalogPage(
            kind: .playlistTracks, contextID: playlist.id, cursor: cursor,
            limit: limit
        )
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

    // MARK: - Playback façade

    func playbackRequest(for track: JellyfinItem) async throws -> PlaybackRequest {
        do {
            return try await playbackResolver().playbackRequest(for: track)
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func playbackRequest(for item: PlaybackItem) async throws -> PlaybackRequest {
        guard item.source == .jellyfin else {
            throw JellyfinSessionError.unsupportedHistoryItem
        }
        do {
            return try await playbackResolver().playbackRequest(for: item)
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    // MARK: - Artwork façade

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async -> URLRequest? {
        return try? await catalogRepository().artworkRequest(
            itemID: itemID,
            imageTag: imageTag,
            maxWidth: maxWidth
        )
    }

    func userImageRequest(maxWidth: Int) async -> URLRequest? {
        guard let session else { return nil }
        return try? await catalogRepository().userImageRequest(
            imageTag: session.userPrimaryImageTag,
            maxWidth: maxWidth
        )
    }

    // MARK: - Session management

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

    // MARK: - Collaborator factories

    /// Converts the main-actor session snapshot into a focused catalog service.
    /// The repository does not retain UI state, so in-flight browsing cannot
    /// mutate published session state after logout or a new sign-in.
    private func catalogRepository() throws -> JellyfinCatalogRepository {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return JellyfinCatalogRepository(
            api: client,
            userID: session.userID,
            libraryIDs: libraries.map(\.id)
        )
    }

    private func catalogPage(
        kind: JellyfinCatalogKind,
        contextID: String? = nil,
        cursor: JellyfinCatalogCursor?,
        limit: Int,
        searchTerm: String? = nil
    ) async throws -> JellyfinCatalogPage {
        do {
            return try await catalogRepository().page(
                kind: kind,
                contextID: contextID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
        } catch {
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    private func playbackResolver() throws -> JellyfinPlaybackRequestResolver {
        guard let session, let client else {
            throw JellyfinSessionError.notSignedIn
        }
        return JellyfinPlaybackRequestResolver(api: client, userID: session.userID)
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
