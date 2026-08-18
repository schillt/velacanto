import Combine
import Foundation
import Security
import os

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
    private enum CachedLyrics {
        case available(MusicLyrics)
        case unavailable
    }

    private struct ActiveLyricsRequest {
        let id: UUID
        let itemID: MusicCatalogItemID
        let task: Task<MusicLyrics?, Error>
    }

    private static let logger = Logger(
        subsystem: "com.chameleonenterprise.velacanto",
        category: "Session"
    )
    typealias ClientFactory =
        @Sendable (JellyfinServerURL, String, String?) -> any JellyfinAPIService

    @Published private(set) var phase: JellyfinSessionPhase
    @Published private(set) var serverInfo: JellyfinServerInfo?
    @Published private(set) var session: JellyfinSession?
    @Published private(set) var libraries: [JellyfinItem] = []
    @Published private(set) var isRefreshingLibraries = false
    @Published private(set) var errorMessage: String?

    let itemActions = MusicItemActionStateOwner()

    private let tokenStore: any JellyfinTokenStoring
    private let sessionStore: any JellyfinSessionPersisting
    private let makeClient: ClientFactory
    private let catalogCache = JellyfinCatalogCache()
    private let genreCache = JellyfinGenreCache()
    private let deviceID: String
    private var candidateServer: JellyfinServerURL?
    private var client: (any JellyfinAPIService)?
    private var lyricsCache: [MusicCatalogItemID: CachedLyrics] = [:]
    private var activeLyricsRequest: ActiveLyricsRequest?
    private var genreCacheAccount: PlaybackAccount?
    private var cachedGenres: [MusicGenre] = []
    private var genreLoadTask: Task<[MusicGenre], Error>?
    private var homeGenreLoadTask: Task<[MusicGenre], Error>?

    convenience init(autoRestore: Bool = true) {
        self.init(
            tokenStore: KeychainJellyfinTokenStore(
                migratingFrom: .standard
            ),
            sessionStore: UserDefaultsJellyfinSessionStore(),
            autoRestore: autoRestore
        )
    }

    /// A process-local, argument-gated fixture for UI automation. It deliberately
    /// has no persistent credentials, network endpoint, or private media data.
    convenience init(uiTestingSignedIn: Bool) {
        self.init(
            tokenStore: UITestTokenStore(),
            sessionStore: UITestSessionStore(),
            autoRestore: false,
            makeClient: { _, _, _ in UITestJellyfinAPI() }
        )
        guard uiTestingSignedIn else { return }
        let fixture = UITestJellyfinAPI()
        client = fixture
        session = JellyfinSession(
            serverURL: URL(fileURLWithPath: "/"),
            serverID: "ui-test-server",
            serverName: "UI Test Library",
            userID: "ui-test-user",
            username: "UI Test User",
            userPrimaryImageTag: nil
        )
        phase = .signedIn
        configureItemActions()
        Task { [weak self] in
            await self?.refreshLibraries()
        }
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
        resetLyricsState()
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
            configureItemActions()
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
            configureItemActions()
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
        cursor: MusicCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil,
        artist: MusicCatalogItem? = nil
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .albums, contextID: artist?.id, cursor: cursor,
            limit: limit, searchTerm: searchTerm
        )
    }

    func musicArtistsPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .artists, cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
    }

    func musicSongsPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil,
        artist: MusicCatalogItem? = nil
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: artist == nil ? .songs : .artistTracks,
            contextID: artist?.id,
            cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
    }

    func musicPlaylistsPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 50,
        searchTerm: String? = nil
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .playlists, cursor: cursor, limit: limit,
            searchTerm: searchTerm
        )
    }

    func searchMusicPage(
        query: String,
        cursor: MusicCatalogCursor?,
        limit: Int = 50
    ) async throws -> MusicCatalogPage {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return MusicCatalogPage(
                items: [],
                totalRecordCount: 0,
                cursor: nil
            )
        }
        return try await catalogPage(
            kind: .search, cursor: cursor,
            limit: limit, searchTerm: trimmedQuery
        )
    }

    func homeFavoritesPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 12
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .favorites, cursor: cursor, limit: limit
        )
    }

    func homeMostListenedPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 12
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .mostListened, cursor: cursor, limit: limit
        )
    }

    func homeRecentlyAddedPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 12
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .recentlyAdded, cursor: cursor, limit: limit
        )
    }

    func homeRecentlyAddedTracksPage(
        cursor: MusicCatalogCursor?,
        limit: Int = 24
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .recentlyAddedTracks, cursor: cursor, limit: limit
        )
    }

    func cachedMusicGenres() async -> [MusicGenre] {
        guard let session else { return [] }
        return await genreCache.load(
            serverID: session.serverID,
            userID: session.userID,
            key: "all"
        )
    }

    func cachedHomeMusicGenres(limit: Int) async -> [MusicGenre] {
        guard let session else { return [] }
        return Array(
            await genreCache.load(
                serverID: session.serverID,
                userID: session.userID,
                key: "home"
            )
            .prefix(limit)
        )
    }

    func musicGenres(forceRefresh: Bool = false) async throws -> [MusicGenre] {
        guard let account = playbackAccount else {
            throw JellyfinSessionError.notSignedIn
        }
        if !forceRefresh, genreCacheAccount == account, !cachedGenres.isEmpty {
            return cachedGenres
        }
        if genreCacheAccount != account {
            genreLoadTask?.cancel()
            cachedGenres = []
            genreCacheAccount = account
        }
        if let genreLoadTask {
            return try await genreLoadTask.value
        }
        let repository = try catalogRepository()
        let task = Task { try await repository.musicGenres() }
        genreLoadTask = task
        do {
            let genres = try await task.value
            guard playbackAccount == account else { return [] }
            cachedGenres = genres
            genreLoadTask = nil
            if let session {
                await genreCache.save(
                    genres,
                    serverID: session.serverID,
                    userID: session.userID,
                    key: "all"
                )
            }
            return genres
        } catch {
            genreLoadTask = nil
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func homeMusicGenres(limit: Int = 5) async throws -> [MusicGenre] {
        guard let account = playbackAccount else {
            throw JellyfinSessionError.notSignedIn
        }
        if let homeGenreLoadTask {
            return try await homeGenreLoadTask.value
        }
        let repository = try catalogRepository()
        let task = Task { try await repository.homeMusicGenres(limit: limit) }
        homeGenreLoadTask = task
        do {
            let genres = try await task.value
            guard playbackAccount == account else { return [] }
            homeGenreLoadTask = nil
            if let session {
                await genreCache.save(
                    genres,
                    serverID: session.serverID,
                    userID: session.userID,
                    key: "home"
                )
            }
            return genres
        } catch {
            homeGenreLoadTask = nil
            handleExpiredSessionIfNeeded(error)
            throw error
        }
    }

    func preloadGenreAlbums(for genres: [MusicGenre], limit: Int = 50) async {
        for genre in genres {
            guard !Task.isCancelled else { return }
            let cached = await cachedCatalogItems(kind: .genreItems, contextID: genre.id)
            guard cached.isEmpty else { continue }
            guard let page = try? await genreItemsPage(in: genre, cursor: nil, limit: limit)
            else {
                continue
            }
            await cacheCatalogItems(page.items, kind: .genreItems, contextID: genre.id)
        }
    }

    func genreItemsPage(
        in genre: MusicGenre,
        cursor: MusicCatalogCursor?,
        limit: Int = 50
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .genreItems,
            contextID: genre.id,
            cursor: cursor,
            limit: limit
        )
    }

    func tracksPage(
        in album: MusicCatalogItem,
        cursor: MusicCatalogCursor?,
        limit: Int = 50
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .albumTracks, contextID: album.id, cursor: cursor,
            limit: limit
        )
    }

    func tracksPage(
        inPlaylist playlist: MusicCatalogItem,
        cursor: MusicCatalogCursor?,
        limit: Int = 50
    ) async throws -> MusicCatalogPage {
        try await catalogPage(
            kind: .playlistTracks, contextID: playlist.id, cursor: cursor,
            limit: limit
        )
    }

    func cachedCatalogItems(
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID? = nil
    ) async -> [MusicCatalogItem] {
        guard kind != .search, let session else { return [] }
        let items = await catalogCache.load(
            serverID: session.serverID,
            userID: session.userID,
            key: catalogCacheKey(kind: kind, contextID: contextID)
        )
        itemActions.reconcile(items)
        return items
    }

    func cacheCatalogItems(
        _ items: [MusicCatalogItem],
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID? = nil
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

    func playbackRequest(for track: MusicCatalogItem) async throws -> PlaybackRequest {
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

    func lyrics(for item: PlaybackItem) async throws -> MusicLyrics? {
        guard item.source == .jellyfin, let account = playbackAccount else {
            resetLyricsState()
            return nil
        }
        let itemID = MusicCatalogItemID(
            source: .jellyfin,
            accountScope: "\(account.serverID)|\(account.userID)",
            opaqueID: item.id
        )

        if let cached = lyricsCache[itemID] {
            switch cached {
            case .available(let lyrics):
                return lyrics
            case .unavailable:
                return nil
            }
        }

        activeLyricsRequest?.task.cancel()
        let repository = try catalogRepository()
        let requestID = UUID()
        let task = Task {
            try await repository.lyrics(for: itemID)
        }
        activeLyricsRequest = ActiveLyricsRequest(
            id: requestID,
            itemID: itemID,
            task: task
        )

        do {
            let lyrics = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            guard
                activeLyricsRequest?.id == requestID,
                activeLyricsRequest?.itemID == itemID,
                playbackAccount == account
            else {
                return nil
            }
            activeLyricsRequest = nil
            lyricsCache[itemID] = lyrics.map(CachedLyrics.available) ?? .unavailable
            return lyrics
        } catch {
            if activeLyricsRequest?.id == requestID {
                activeLyricsRequest = nil
            }
            handleExpiredSessionIfNeeded(error)
            if error is CancellationError {
                throw error
            }
            throw MusicLyricsError.unavailable
        }
    }

    // MARK: - Artwork façade

    func artworkRequest(
        itemID: String,
        imageTag: String?,
        maxWidth: Int
    ) async -> URLRequest? {
        do {
            return try await catalogRepository().artworkRequest(
                itemID: itemID,
                imageTag: imageTag,
                maxWidth: maxWidth
            )
        } catch {
            // Artwork is optional presentation. A failed request must not
            // change signed-in or browse state, and diagnostics omit media IDs.
            Self.logger.notice("Could not build artwork request; using placeholder")
            return nil
        }
    }

    func userImageRequest(maxWidth: Int) async -> URLRequest? {
        guard let session else { return nil }
        do {
            return try await catalogRepository().userImageRequest(
                imageTag: session.userPrimaryImageTag,
                maxWidth: maxWidth
            )
        } catch {
            // A profile image is optional presentation and never changes the
            // session or library state. Do not include user or image data here.
            Self.logger.notice("Could not build user image request; using placeholder")
            return nil
        }
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
            await genreCache.clear(
                serverID: oldSession.serverID,
                userID: oldSession.userID
            )
        }
        do {
            try await oldClient?.logout()
        } catch {
            // Local credential and cache removal is the authoritative logout.
            // The remote call is best-effort and must not expose account data.
            Self.logger.notice("Remote logout did not complete after local sign-out")
        }
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
            accountScope: "\(session.serverID)|\(session.userID)",
            libraryIDs: libraries.map(\.id)
        )
    }

    private func catalogPage(
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID? = nil,
        cursor: MusicCatalogCursor?,
        limit: Int,
        searchTerm: String? = nil
    ) async throws -> MusicCatalogPage {
        do {
            let page = try await catalogRepository().page(
                kind: kind,
                contextID: contextID,
                cursor: cursor,
                limit: limit,
                searchTerm: searchTerm
            )
            itemActions.reconcile(page.items)
            return page
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
        kind: MusicCatalogKind,
        contextID: MusicCatalogItemID?
    ) -> String {
        "\(kind.rawValue)|\(contextID?.opaqueID ?? "root")"
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
                    discardExpiredCredentials()
                    return
                }
                clearSession()
                return
            }

            let server = try JellyfinServerURL(savedSession.serverURL.absoluteString)
            let authenticatedClient = makeClient(server, deviceID, token)
            session = savedSession
            candidateServer = server
            client = authenticatedClient
            configureItemActions()

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
                configureItemActions()
                await refreshLibraries()
            } catch JellyfinAPIError.unauthorized {
                discardExpiredCredentials()
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
        discardExpiredCredentials()
    }

    /// Removes locally stored expired credentials. If Keychain access fails,
    /// the visible signed-out state owns that failure rather than leaving an
    /// unusable credential silently available for a later restore attempt.
    private func discardExpiredCredentials() {
        sessionStore.deleteSession()
        clearSession()
        do {
            try tokenStore.deleteToken()
            errorMessage = JellyfinSessionError.expiredSession.localizedDescription
        } catch {
            Self.logger.error("Could not remove expired Keychain credential")
            errorMessage =
                JellyfinSessionError.expiredCredentialRemovalFailed
                .localizedDescription
        }
    }

    private func clearSession() {
        itemActions.clear()
        resetLyricsState()
        genreLoadTask?.cancel()
        genreLoadTask = nil
        homeGenreLoadTask?.cancel()
        homeGenreLoadTask = nil
        cachedGenres = []
        genreCacheAccount = nil
        session = nil
        candidateServer = nil
        serverInfo = nil
        client = nil
        libraries = []
        isRefreshingLibraries = false
        phase = .signedOut
    }

    private func resetLyricsState() {
        activeLyricsRequest?.task.cancel()
        activeLyricsRequest = nil
        lyricsCache.removeAll(keepingCapacity: false)
    }

    private func configureItemActions() {
        guard let session, let repository = try? catalogRepository() else {
            itemActions.clear()
            return
        }
        itemActions.configure(
            accountScope: "\(session.serverID)|\(session.userID)",
            provider: repository
        )
    }
}

enum JellyfinSessionError: LocalizedError, Equatable {
    case missingCredentials
    case notSignedIn
    case expiredSession
    case expiredCredentialRemovalFailed
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
        case .expiredCredentialRemovalFailed:
            "The saved Jellyfin session expired, but its stored credential could not be removed. Resolve Keychain access, then sign in again."
        case .serverSetupIncomplete:
            "That Jellyfin server has not completed its initial setup."
        case .unsupportedHistoryItem:
            "This recent item must be opened again from its original source."
        }
    }
}

private final class UITestTokenStore: JellyfinTokenStoring {
    func loadToken() throws -> String? { nil }
    func saveToken(_: String) throws {}
    func deleteToken() throws {}
}

private final class UITestSessionStore: JellyfinSessionPersisting {
    func loadSession() -> JellyfinSession? { nil }
    func saveSession(_: JellyfinSession) {}
    func deleteSession() {}
    func loadDeviceID() -> String? { "ui-test-device" }
    func saveDeviceID(_: String) {}
}

/// Synthetic catalog responses used exclusively by the UI-test launch fixture.
/// The values are generic and never leave the process.
private actor UITestJellyfinAPI: JellyfinAPIService {
    private let album = UITestJellyfinAPI.item(
        #"{"Id":"ui-test-album","Name":"Test Album","Type":"MusicAlbum","AlbumArtist":"Test Artist","UserData":{"IsFavorite":false}}"#
    )

    func publicServerInfo() async throws -> JellyfinServerInfo {
        throw JellyfinAPIError.invalidResponse
    }
    func authenticate(username: String, password: String) async throws
        -> JellyfinAuthenticationResult
    { throw JellyfinAPIError.invalidResponse }
    func currentUser() async throws -> JellyfinUser {
        JellyfinUser(id: "ui-test-user", name: "UI Test User")
    }
    func libraries(userID: String) async throws -> [JellyfinItem] { [] }
    func playbackResolution(itemID: String, userID: String) async throws
        -> JellyfinPlaybackResolution
    { throw JellyfinAPIError.invalidResponse }
    func setFavorite(_: Bool, itemID: String, userID: String) async throws {}
    func albumsPage(
        userID: String, libraryID: String, artistID: String?, startIndex: Int, limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage { page([album], startIndex: startIndex) }
    func artistsPage(
        userID: String, libraryID: String, startIndex: Int, limit: Int, searchTerm: String?
    ) async throws -> JellyfinItemPage { page([], startIndex: startIndex) }
    func songsPage(
        userID: String, libraryID: String, artistID: String?, startIndex: Int, limit: Int,
        searchTerm: String?
    ) async throws -> JellyfinItemPage { page([], startIndex: startIndex) }
    func playlistsPage(userID: String, startIndex: Int, limit: Int, searchTerm: String?)
        async throws -> JellyfinItemPage
    { page([], startIndex: startIndex) }
    func searchMusicPage(userID: String, query: String, startIndex: Int, limit: Int) async throws
        -> JellyfinItemPage
    { page([album], startIndex: startIndex) }
    func homeItemsPage(
        userID: String, collection: JellyfinHomeCollection, startIndex: Int, limit: Int
    ) async throws -> JellyfinItemPage { page([album], startIndex: startIndex) }
    func playlistItemsPage(userID: String, playlistID: String, startIndex: Int, limit: Int)
        async throws -> JellyfinItemPage
    { page([], startIndex: startIndex) }
    func tracksPage(userID: String, albumID: String, startIndex: Int, limit: Int) async throws
        -> JellyfinItemPage
    { page([], startIndex: startIndex) }
    func artworkRequest(itemID: String, imageTag: String?, maxWidth: Int) async throws -> URLRequest
    { throw JellyfinAPIError.invalidResponse }
    func userImageRequest(userID: String, imageTag: String?, maxWidth: Int) async throws
        -> URLRequest
    { throw JellyfinAPIError.invalidResponse }
    func logout() async throws {}

    func lyrics(itemID: String) async throws -> JellyfinLyricsResponse? {
        JellyfinLyricsResponse(lyrics: [JellyfinLyricLine(text: "Test lyric", start: 0)])
    }

    private func page(_ items: [JellyfinItem], startIndex: Int) -> JellyfinItemPage {
        JellyfinItemPage(
            items: startIndex == 0 ? items : [], startIndex: startIndex,
            totalRecordCount: items.count)
    }

    private static func item(_ json: String) -> JellyfinItem {
        // The literal is authored alongside the fixture and guaranteed valid at launch.
        try! JSONDecoder().decode(JellyfinItem.self, from: Data(json.utf8))
    }
}
