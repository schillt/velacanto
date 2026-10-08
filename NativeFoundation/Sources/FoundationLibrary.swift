import Foundation
import Get
import JellyfinAPI

struct FoundationItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case album, artist, track, playlist, genre }
    let id: String
    var title: String
    let subtitle: String
    let kind: Kind
    let duration: Double?
    var primaryImageTag: String? = nil
    var isFavorite: Bool? = nil
    var album: FoundationItemReference? = nil
    var artist: FoundationItemReference? = nil
    var genres: [FoundationItemReference] = []
    var playCount: Int = 0
    var sortName: String? = nil
}

extension FoundationItem {
    /// Related routes use the same catalog identity and metadata in every entry point.
    var relatedAlbum: FoundationItem? {
        guard let album, !album.id.isEmpty else { return nil }
        return FoundationItem(
            id: album.id, title: album.title.isEmpty ? "Album" : album.title,
            subtitle: artist.flatMap { $0.title.isEmpty ? nil : $0.title } ?? subtitle,
            kind: .album, duration: nil,
            primaryImageTag: album.primaryImageTag, artist: artist)
    }

    var relatedArtist: FoundationItem? {
        guard let artist, !artist.id.isEmpty else { return nil }
        return FoundationItem(
            id: artist.id, title: artist.title.isEmpty ? "Artist" : artist.title,
            subtitle: "", kind: .artist, duration: nil, primaryImageTag: artist.primaryImageTag)
    }
}

struct FoundationItemReference: Equatable, Codable, Sendable {
    let id: String
    let title: String
    var primaryImageTag: String? = nil
}

struct FoundationPage: Codable, Sendable {
    let items: [FoundationItem]
    let nextStartIndex: Int?
}

struct FoundationSession: Codable, Sendable {
    let serverURL: URL
    let accessToken: String
    let userID: String
    let deviceID: String
}

/// A bounded account-owned probe verifies SortName filtering independently of release versions.
enum FoundationAlphabetCapability: Sendable, Equatable {
    case verified, unavailable
}

/// Share resolved capability across account-scoped copies; failed probes remain retryable.
private actor FoundationAlphabetCapabilityMemo {
    private struct Pending {
        let id: UUID
        let task: Task<FoundationAlphabetCapability?, Never>
    }
    private var pending: Pending?
    private var result: FoundationAlphabetCapability?
    private var retired = false

    func value(using load: @escaping @Sendable () async throws -> FoundationAlphabetCapability)
        async
        -> FoundationAlphabetCapability
    {
        guard !retired else { return .unavailable }
        if let result { return result }
        let work: Pending
        if let pending {
            work = pending
        } else {
            let task: Task<FoundationAlphabetCapability?, Never> = Task {
                do {
                    let capability = try await load()
                    try Task.checkCancellation()
                    return capability
                } catch { return nil }
            }
            work = Pending(id: UUID(), task: task)
            pending = work
        }
        let value = await work.task.value
        guard !retired else { return .unavailable }
        // Late waiters from a failed probe must not clear a newer retry owner.
        if pending?.id == work.id {
            result = value
            pending = nil
        }
        // A resolved unsupported filter is cached; transport failures remain retryable.
        return value ?? .unavailable
    }

    func retire() {
        retired = true
        pending?.task.cancel()
        pending = nil
        result = nil
    }
}

protocol FoundationLibrary: Sendable {
    func retireAlphabetCapability() async
    func alphabetCapability() async -> FoundationAlphabetCapability
    /// A relative cursor into the bounded SortName >= letter tail, never an absolute rank.
    func alphabetPage(kind: FoundationItem.Kind, letter: String, startIndex: Int) async throws
        -> FoundationPage
    var catalogPageCache: FoundationCatalogPageCache? { get }
    var catalogScopeID: String { get }
    func catalogCacheKey(_ key: String) -> String
    func cachedArtworkResult(for item: FoundationItem, size: Int) async throws
        -> FoundationCurrentArtwork.Result?
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource
    var supportsPlaylistManagement: Bool { get }
    var supportsRepeatedPlaylistTracks: Bool { get }
    func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions
    func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage
    func createPlaylist(name: String) async throws -> FoundationItem
    func renamePlaylist(id: String, name: String) async throws
    func deletePlaylist(id: String) async throws
    func addTracks(to playlistID: String, tracks: [FoundationItem]) async throws
    func removeEntry(from playlistID: String, entryID: String) async throws

    func lyrics(for item: FoundationItem) async throws -> FoundationLyrics?
    func overview(for item: FoundationItem) async throws -> String?
    func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage
    func similarItems(for item: FoundationItem) async throws -> FoundationPage
    func mostPlayedAlbums() async throws -> FoundationPage
    func mostPlayed(artistID: String) async throws -> FoundationPage
    func homeGenres() async throws -> FoundationPage
    func searchGenres() async throws -> FoundationPage
    func profile() async throws -> (name: String, image: Data?)
    func recentlyPlayed(startIndex: Int) async throws -> FoundationPage
    func favoriteAlbums(startIndex: Int) async throws -> FoundationPage
    func search(
        query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int
    ) async throws -> FoundationPage
    func recentAlbums(startIndex: Int) async throws -> FoundationPage
    func recentTracks(startIndex: Int) async throws -> FoundationPage
    func albums(startIndex: Int) async throws -> FoundationPage
    func artists(startIndex: Int) async throws -> FoundationPage
    func albums(artistID: String, startIndex: Int) async throws -> FoundationPage
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage
    func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage
    func songs(startIndex: Int) async throws -> FoundationPage
    func playlists(startIndex: Int) async throws -> FoundationPage
    func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage
    func favorites(startIndex: Int) async throws -> FoundationPage
    func genres(startIndex: Int) async throws -> FoundationPage
    func albums(genreID: String, startIndex: Int) async throws -> FoundationPage
    func setFavorite(for item: FoundationItem, isFavorite: Bool) async throws
    func playbackURL(for item: FoundationItem) async throws -> URL
    func artwork(for item: FoundationItem) async throws -> Data?
    func artwork(for item: FoundationItem, size: Int) async throws -> Data?
    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    func artworkResult(for item: FoundationItem, size: Int, allowsNetwork: Bool) async throws
        -> FoundationCurrentArtwork.Result?
}

extension FoundationLibrary {
    func retireAlphabetCapability() async {}
    func alphabetCapability() async -> FoundationAlphabetCapability { .unavailable }
    func alphabetPage(kind: FoundationItem.Kind, letter: String, startIndex: Int) async throws
        -> FoundationPage
    { throw FoundationLibraryError.unavailable }
    var catalogPageCache: FoundationCatalogPageCache? { nil }
    var catalogScopeID: String { "all" }
    func catalogCacheKey(_ key: String) -> String { key }
    func cachedArtworkResult(for item: FoundationItem, size: Int) async throws
        -> FoundationCurrentArtwork.Result?
    { nil }
    func artworkResult(for item: FoundationItem, size: Int, allowsNetwork: Bool) async throws
        -> FoundationCurrentArtwork.Result?
    {
        guard allowsNetwork else { return nil }
        let data = try await artwork(for: item.catalogArtworkItem, size: size)
        try Task.checkCancellation()
        return await Task.detached(priority: .utility) {
            data.flatMap { FoundationCurrentArtwork.decode($0, maximumPixels: size) }
        }.value
    }

    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        throw FoundationDownloadError.unsupported
    }
    var supportsPlaylistManagement: Bool { false }
    var supportsRepeatedPlaylistTracks: Bool { false }
    func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
        throw FoundationLibraryError.unavailable
    }
    func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
        throw FoundationLibraryError.unavailable
    }
    func createPlaylist(name: String) async throws -> FoundationItem {
        throw FoundationLibraryError.unavailable
    }
    func renamePlaylist(id: String, name: String) async throws {
        throw FoundationLibraryError.unavailable
    }
    func deletePlaylist(id: String) async throws { throw FoundationLibraryError.unavailable }
    func addTracks(to playlistID: String, tracks: [FoundationItem]) async throws {
        throw FoundationLibraryError.unavailable
    }
    func removeEntry(from playlistID: String, entryID: String) async throws {
        throw FoundationLibraryError.unavailable
    }

    func lyrics(for item: FoundationItem) async throws -> FoundationLyrics? {
        throw FoundationLibraryError.unavailable
    }
    func mostPlayedAlbums() async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func mostPlayed(artistID: String) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func similarItems(for item: FoundationItem) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func overview(for item: FoundationItem) async throws -> String? { nil }
    func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func homeGenres() async throws -> FoundationPage { throw FoundationLibraryError.unavailable }
    func searchGenres() async throws -> FoundationPage { throw FoundationLibraryError.unavailable }
    func profile() async throws -> (name: String, image: Data?) {
        throw FoundationLibraryError.unavailable
    }

    func recentlyPlayed(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func favoriteAlbums(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func search(
        query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int
    ) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func recentAlbums(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func recentTracks(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func genres(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func albums(genreID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func setFavorite(for item: FoundationItem, isFavorite: Bool) async throws {
        throw FoundationLibraryError.unavailable
    }

    func songs(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func playlists(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func favorites(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func artists(startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func albums(artistID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }

    func artwork(for item: FoundationItem) async throws -> Data? { nil }
    func artwork(for item: FoundationItem, size: Int) async throws -> Data? {
        try await artwork(for: item)
    }
    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    {
        try await artwork(for: item, size: size)
    }

}

enum FoundationLibraryError: String, Error, LocalizedError, Sendable {
    case invalidServer, invalidResponse, authentication, unavailable, network, cancelled,
        secureConnection, credentials

    var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a valid HTTPS server address."
        case .invalidResponse: "The server returned an unsupported response."
        case .authentication: "Sign in again or check your account permissions."
        case .unavailable: "The requested operation is unavailable."
        case .network: "The network request failed. Try again explicitly."
        case .cancelled: "The request was cancelled."
        case .secureConnection: "A secure connection could not be established."
        case .credentials: "The saved sign-in could not be accessed."
        }
    }

    static func category(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                .clientCertificateRejected, .clientCertificateRequired:
                return .secureConnection
            default: return .network
            }
        }
        if error is DecodingError { return .invalidResponse }
        return .unavailable
    }
}

/// A generated-request adapter, with no retry, admission, cache or recovery state.
struct FoundationJellyfinLibrary: FoundationLibrary {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let session: FoundationSession
    private let load: Load
    private let alphabetMemo = FoundationAlphabetCapabilityMemo()
    let artworkCache: FoundationArtworkCache?
    let catalogPageCache: FoundationCatalogPageCache?
    private(set) var musicLibraryID: String?
    private(set) var catalogAvailable = true

    var catalogScopeID: String {
        (musicLibraryID.map { FoundationMusicLibraryStore.digest($0) } ?? "all")
            + (catalogAvailable ? "" : ".unavailable")
    }

    func catalogCacheKey(_ key: String) -> String {
        if let musicLibraryID {
            return "library." + FoundationMusicLibraryStore.digest(musicLibraryID) + "." + key
        }
        return catalogAvailable ? key : "unavailable." + key
    }

    func scoped(to id: String?, available: Bool = true) -> Self {
        var scoped = self
        scoped.musicLibraryID = id
        scoped.catalogAvailable = available
        return scoped
    }

    func musicLibraries() async throws -> [FoundationMusicLibraryChoice] {
        let result = try await send(
            Paths.getUserViews(
                parameters: .init(
                    userID: session.userID, isIncludeExternalContent: false, isIncludeHidden: false)
            ))
        guard let entries = result.items, entries.count <= 128 else {
            throw FoundationLibraryError.invalidResponse
        }
        var seen: Set<String> = []
        return try entries.filter { $0.collectionType == .music }.map { entry in
            guard let id = entry.id, Self.validID(id), seen.insert(id).inserted,
                let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty, name.utf8.count <= 512
            else { throw FoundationLibraryError.invalidResponse }
            return FoundationMusicLibraryChoice(id: id, name: name)
        }
    }

    init(
        session: FoundationSession, load: @escaping Load = nativeLoad,
        artworkCache: FoundationArtworkCache? = nil,
        catalogPageCache: FoundationCatalogPageCache? = nil
    ) {
        self.session = session
        self.load = load
        self.artworkCache = artworkCache
        self.catalogPageCache = catalogPageCache
        self.musicLibraryID = nil
    }

    var supportsPlaylistManagement: Bool { true }

    func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
        guard Self.validID(id) else { throw FoundationLibraryError.invalidResponse }
        let permission = try await send(
            Paths.getPlaylistUser(playlistID: id, userID: session.userID))
        let item = try await send(Paths.getItem(itemID: id, userID: session.userID))
        guard item.id == id, item.type == .playlist, permission.userID == session.userID else {
            throw FoundationLibraryError.invalidResponse
        }
        return FoundationPlaylistPermissions(
            name: item.name ?? "Untitled", canEdit: permission.canEdit == true,
            canDelete: item.canDelete == true)
    }

    func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
        guard Self.validID(id), startIndex >= 0 else {
            throw FoundationLibraryError.invalidResponse
        }
        let result = try await send(
            Paths.getPlaylistItems(
                playlistID: id,
                parameters: .init(userID: session.userID, startIndex: startIndex, limit: 100)))
        let page = try mappedPage(result, kinds: [.track], startIndex: startIndex, limit: 100)
        let entries = try zip(page.items, result.items ?? []).enumerated().map { index, pair in
            let (item, source) = pair
            guard let entryID = source.playlistItemID, !entryID.isEmpty,
                entryID.utf8.count <= 128,
                entryID.unicodeScalars.allSatisfy({
                    CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
                })
            else { throw FoundationLibraryError.invalidResponse }
            return FoundationPlaylistEntry(
                id: "\(startIndex + index):\(entryID)", mutationID: entryID, item: item)
        }
        return FoundationPlaylistPage(entries: entries, nextStartIndex: page.nextStartIndex)
    }

    func createPlaylist(name: String) async throws -> FoundationItem {
        let name = try FoundationPlaylistName.validated(name)
        let result = try await send(
            Paths.createPlaylist(
                CreatePlaylistDto(
                    isPublic: false, mediaType: .audio, name: name, userID: session.userID)))
        guard let id = result.id, Self.validID(id) else {
            throw FoundationLibraryError.invalidResponse
        }
        return FoundationItem(id: id, title: name, subtitle: "", kind: .playlist, duration: nil)
    }

    func renamePlaylist(id: String, name: String) async throws {
        guard Self.validID(id) else { throw FoundationLibraryError.invalidResponse }
        let name = try FoundationPlaylistName.validated(name)
        _ = try await responseData(
            Paths.updatePlaylist(playlistID: id, UpdatePlaylistDto(name: name)))
    }

    func deletePlaylist(id: String) async throws {
        guard Self.validID(id) else { throw FoundationLibraryError.invalidResponse }
        _ = try await responseData(Paths.deleteItem(itemID: id))
    }

    func addTracks(to playlistID: String, tracks: [FoundationItem]) async throws {
        guard Self.validID(playlistID), !tracks.isEmpty, tracks.count <= 100,
            tracks.allSatisfy({ $0.kind == .track && Self.validID($0.id) })
        else {
            throw FoundationLibraryError.invalidResponse
        }
        _ = try await responseData(
            Paths.addItemToPlaylist(
                playlistID: playlistID,
                parameters: .init(ids: tracks.map(\.id), userID: session.userID)))
    }

    func removeEntry(from playlistID: String, entryID: String) async throws {
        guard Self.validID(playlistID), !entryID.isEmpty, entryID.utf8.count <= 128,
            entryID.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
            })
        else { throw FoundationLibraryError.invalidResponse }
        _ = try await responseData(
            Paths.removeItemFromPlaylist(playlistID: playlistID, entryIDs: [entryID]))
    }

    static func signIn(
        serverURL: URL, username: String, password: String,
        load: @escaping Load = nativeLoad
    ) async throws -> FoundationSession {
        let base = try validatedServerURL(serverURL)
        let deviceID = UUID().uuidString
        let unsigned = FoundationSession(
            serverURL: base, accessToken: "", userID: "", deviceID: deviceID)
        let adapter = Self(session: unsigned, load: load)
        let result: AuthenticationResult = try await adapter.send(
            Paths.authenticateUserByName(AuthenticateUserByName(pw: password, username: username)))
        guard let token = result.accessToken, !token.isEmpty,
            let userID = result.user?.id, Self.validID(userID)
        else {
            throw FoundationLibraryError.invalidResponse
        }
        return FoundationSession(
            serverURL: base, accessToken: token, userID: userID, deviceID: deviceID)
    }

    /// Jellyfin's session logout route reads the token from the Authorization header.
    /// Do not use SDK signOut(): SDK 3.1.0 puts the token in the request path.
    func endSession() async throws {
        await retireAlphabetCapability()
        _ = try await responseData(Paths.reportSessionEnded)
    }

    func retireAlphabetCapability() async { await alphabetMemo.retire() }

    func alphabetCapability() async -> FoundationAlphabetCapability {
        await alphabetMemo.value { try await probeAlphabetCapability() }
    }

    /// Two one-row queries establish that a boundary excludes known lower SortName membership.
    /// Probe account-wide so an empty selected library does not disable another library's rail.
    private func probeAlphabetCapability() async throws -> FoundationAlphabetCapability {
        var parameters = Paths.GetItemsParameters()
        parameters.userID = session.userID
        parameters.includeItemTypes = [.audio]
        parameters.isRecursive = true
        parameters.startIndex = 0
        parameters.limit = 1
        parameters.fields = [.sortName]
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = false
        parameters.enableUserData = false
        let initial: BaseItemDtoQueryResult = try await send(Paths.getItems(parameters: parameters))
        guard let initialItems = initial.items, initialItems.count == 1,
            initial.startIndex == 0, let initialCount = initial.totalRecordCount,
            initialCount >= 1, let first = initialItems.first,
            first.type == .audio, let firstID = first.id, Self.validID(firstID),
            let sortName = first.sortName?.lowercased(), !sortName.isEmpty,
            let scalar = sortName.unicodeScalars.first
        else { throw FoundationLibraryError.unavailable }
        // A next ASCII boundary gives a known exclusion, rather than trusting an accepted query.
        let boundary: String
        if scalar.value < 97 {
            boundary = "a"
        } else if (97..<122).contains(scalar.value),
            let next = UnicodeScalar(scalar.value + 1)
        {
            boundary = String(next)
        } else {
            // No stronger A-Z boundary can prove exclusion for a Z/non-ASCII first sort name.
            throw FoundationLibraryError.unavailable
        }
        try Task.checkCancellation()
        parameters.nameStartsWithOrGreater = boundary
        let filtered: BaseItemDtoQueryResult = try await send(
            Paths.getItems(parameters: parameters))
        guard let filteredItems = filtered.items, filteredItems.count <= 1,
            filtered.startIndex == 0, let filteredCount = filtered.totalRecordCount,
            filteredCount >= filteredItems.count
        else { throw FoundationLibraryError.invalidResponse }
        if filteredItems.isEmpty {
            guard filteredCount == 0 else { throw FoundationLibraryError.invalidResponse }
            return .verified
        }
        guard let item = filteredItems.first, item.type == .audio,
            let id = item.id, Self.validID(id),
            let filteredSortName = item.sortName?.lowercased(), !filteredSortName.isEmpty
        else { throw FoundationLibraryError.invalidResponse }
        // A repeated lower item proves the boundary was ignored. Counts can race catalog edits.
        guard id != firstID, filteredSortName >= boundary else { return .unavailable }
        guard filteredCount < initialCount else { throw FoundationLibraryError.invalidResponse }
        return .verified
    }

    func alphabetPage(kind: FoundationItem.Kind, letter: String, startIndex: Int) async throws
        -> FoundationPage
    {
        guard startIndex >= 0, letter.utf8.count == 1,
            let scalar = letter.unicodeScalars.first, (65...90).contains(scalar.value)
        else { throw FoundationLibraryError.invalidResponse }
        guard await alphabetCapability() == .verified else {
            throw FoundationLibraryError.unavailable
        }
        try Task.checkCancellation()
        let boundary = letter.lowercased()
        switch kind {
        case .artist:
            return try await albumArtists(
                startIndex: startIndex, limit: 50, sortNameBoundary: boundary)
        case .genre:
            return try await genrePage(
                startIndex: startIndex, limit: 50, sortNameBoundary: boundary)
        case .album, .track, .playlist:
            return try await page(
                kinds: [kind], parent: nil, startIndex: startIndex, limit: 50,
                sortNameBoundary: boundary)
        }
    }

    func search(
        query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int
    ) async throws -> FoundationPage {
        guard startIndex >= 0, (1...50).contains(limit) else {
            throw FoundationLibraryError.invalidResponse
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return FoundationPage(items: [], nextStartIndex: nil) }
        if kind == .artist {
            return try await albumArtists(startIndex: startIndex, limit: limit, query: term)
        }
        if kind == .genre {
            return try await genrePage(startIndex: startIndex, limit: limit, query: term)
        }
        return try await page(
            kinds: [kind], parent: nil, startIndex: startIndex,
            limit: limit, query: term)
    }

    /// Reads server history; this does not add playback reporting to Foundation.
    func recentlyPlayed(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track], parent: nil, startIndex: startIndex, limit: 24,
            isPlayed: true, sortBy: [.datePlayed], sortOrder: .descending)
    }

    func favoriteAlbums(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.album], parent: nil, startIndex: startIndex, limit: 24, isFavorite: true)
    }

    func recentAlbums(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.album], parent: nil, startIndex: startIndex, limit: 24,
            sortBy: [.dateCreated], sortOrder: .descending, fields: [.genres])
    }

    func recentTracks(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track], parent: nil, startIndex: startIndex, limit: 24,
            sortBy: [.dateCreated], sortOrder: .descending)
    }

    func albums(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(kinds: [.album], parent: nil, startIndex: startIndex, limit: 50)
    }

    /// One bounded sample, not an exhaustive album-history scan.
    func mostPlayedAlbums() async throws -> FoundationPage {
        let tracks = try await page(
            kinds: [.track], parent: nil, startIndex: 0, limit: 100,
            isPlayed: true, sortBy: [.playCount], sortOrder: .descending)
        var albums: [String: FoundationItem] = [:]
        for track in tracks.items where track.playCount > 0 {
            guard let reference = track.album else { continue }
            if var album = albums[reference.id] {
                album.playCount += track.playCount
                albums[reference.id] = album
            } else {
                albums[reference.id] = FoundationItem(
                    id: reference.id, title: reference.title, subtitle: track.subtitle,
                    kind: .album, duration: nil, primaryImageTag: reference.primaryImageTag,
                    artist: track.artist, playCount: track.playCount)
            }
        }
        let ranked = albums.values.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.id < $1.id
        }
        return FoundationPage(items: Array(ranked.prefix(12)), nextStartIndex: nil)
    }

    func mostPlayed(artistID: String) async throws -> FoundationPage {
        guard Self.validID(artistID) else { throw FoundationLibraryError.invalidResponse }
        let result = try await page(
            kinds: [.track], parent: nil, artistID: artistID, startIndex: 0, limit: 12,
            isPlayed: true, sortBy: [.playCount], sortOrder: .descending)
        return FoundationPage(items: result.items, nextStartIndex: nil)
    }

    func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage {
        guard Self.validID(artistID) else { throw FoundationLibraryError.invalidResponse }
        return try await page(
            kinds: [.album], parent: nil, contributingArtistID: artistID,
            startIndex: startIndex, limit: 12,
            sortBy: [.premiereDate, .productionYear, .sortName], sortOrder: .descending)
    }

    func similarItems(for item: FoundationItem) async throws -> FoundationPage {
        guard Self.validID(item.id) else { throw FoundationLibraryError.invalidResponse }
        // Similar endpoints cannot honestly constrain results to a music folder.
        guard musicLibraryID == nil, catalogAvailable else {
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        let endpoint: Request<BaseItemDtoQueryResult>
        switch item.kind {
        case .artist:
            endpoint = Paths.getSimilarArtists(
                itemID: item.id, parameters: .init(userID: session.userID, limit: 12))
        case .album:
            endpoint = Paths.getSimilarAlbums(
                itemID: item.id,
                parameters: .init(
                    excludeArtistIDs: item.artist.map { [$0.id] },
                    userID: session.userID, limit: 12))
        default:
            throw FoundationLibraryError.unavailable
        }
        let result: BaseItemDtoQueryResult = try await send(endpoint)
        guard let entries = result.items, entries.count <= 12 else {
            throw FoundationLibraryError.invalidResponse
        }
        return FoundationPage(
            items: try mappedItems(entries, kinds: [item.kind]), nextStartIndex: nil)
    }

    func overview(for item: FoundationItem) async throws -> String? {
        guard Self.validID(item.id), item.kind == .artist || item.kind == .album else {
            throw FoundationLibraryError.invalidResponse
        }
        let detail: BaseItemDto = try await send(
            Paths.getItem(itemID: item.id, userID: session.userID))
        guard detail.id == item.id else { throw FoundationLibraryError.invalidResponse }
        return detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func artists(startIndex: Int = 0) async throws -> FoundationPage {
        try await albumArtists(startIndex: startIndex, limit: 50)
    }

    /// Keep Library and Search on the provider's album-artist identity set.
    private func albumArtists(
        startIndex: Int, limit: Int, query: String? = nil,
        sortNameBoundary: String? = nil
    ) async throws
        -> FoundationPage
    {
        guard startIndex >= 0, (1...50).contains(limit) else {
            throw FoundationLibraryError.invalidResponse
        }
        guard catalogAvailable else { throw FoundationLibraryError.unavailable }
        var parameters = Paths.GetAlbumArtistsParameters()
        parameters.userID = session.userID
        parameters.parentID = musicLibraryID
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.searchTerm = query
        parameters.nameStartsWithOrGreater = sortNameBoundary
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = true
        parameters.enableImageTypes = [.primary]
        parameters.imageTypeLimit = 1
        parameters.enableUserData = true
        // Jellyfin retains this documented compatibility endpoint. SDK 3.1 marks
        // its helper deprecated in favor of Persons, whose older-server semantics
        // differ. Keep generated query encoding without suppressing warnings.
        let endpoint = Request<BaseItemDtoQueryResult>(
            path: "/Artists/AlbumArtists", method: "GET", query: parameters.asQuery,
            id: "GetAlbumArtists")
        let result = try await send(endpoint)
        return try mappedPage(result, kinds: [.artist], startIndex: startIndex, limit: limit)
    }

    func tracks(artistID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(artistID) else { throw FoundationLibraryError.invalidResponse }
        return try await page(
            kinds: [.track], parent: nil, artistID: artistID, startIndex: startIndex, limit: 100)
    }

    func albums(artistID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(artistID) else { throw FoundationLibraryError.invalidResponse }
        return try await page(
            kinds: [.album], parent: nil, artistID: artistID, startIndex: startIndex, limit: 50)
    }

    func tracks(albumID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(albumID) else { throw FoundationLibraryError.invalidResponse }
        return try await page(kinds: [.track], parent: albumID, startIndex: startIndex, limit: 100)
    }

    func songs(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track], parent: nil, startIndex: startIndex, limit: 100, fields: [.sortName])
    }

    func playlists(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(kinds: [.playlist], parent: nil, startIndex: startIndex, limit: 50)
    }

    func favorites(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track, .album, .artist, .playlist], parent: nil,
            startIndex: startIndex, limit: 50, isFavorite: true)
    }

    func playlistTracks(playlistID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(playlistID), startIndex >= 0 else {
            throw FoundationLibraryError.invalidResponse
        }
        let result = try await send(
            Paths.getPlaylistItems(
                playlistID: playlistID,
                parameters: .init(
                    userID: session.userID, startIndex: startIndex, limit: 100,
                    enableImages: true, enableUserData: true, imageTypeLimit: 1,
                    enableImageTypes: [.primary])))
        // The playlist endpoint supplies occurrence order. Do not sort or deduplicate.
        return try mappedPage(result, kinds: [.track], startIndex: startIndex, limit: 100)
    }

    func homeGenres() async throws -> FoundationPage {
        let page = try await rankedGenres(albumOnly: true)
        return FoundationPage(items: Array(page.items.prefix(5)), nextStartIndex: nil)
    }

    func searchGenres() async throws -> FoundationPage {
        try await rankedGenres(albumOnly: false)
    }

    /// Rank one complete, bounded summary response without scanning genre contents.
    private func rankedGenres(albumOnly: Bool) async throws -> FoundationPage {
        let limit = 1000
        guard catalogAvailable else { throw FoundationLibraryError.unavailable }
        var parameters = Paths.GetGenresParameters()
        parameters.userID = session.userID
        parameters.parentID = musicLibraryID
        parameters.startIndex = 0
        parameters.limit = limit
        parameters.includeItemTypes =
            albumOnly ? [.musicAlbum] : [.musicAlbum, .audio, .musicArtist]
        parameters.fields = [.itemCounts]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = !albumOnly
        parameters.enableImageTypes = [.primary]
        parameters.imageTypeLimit = 1
        let endpoint = Request<BaseItemDtoQueryResult>(
            path: "/MusicGenres", method: "GET", query: parameters.asQuery, id: "GetMusicGenres")
        let result = try await send(endpoint)
        guard let entries = result.items, result.totalRecordCount == entries.count else {
            throw FoundationLibraryError.unavailable
        }
        let page = try mappedPage(result, kinds: [.genre], startIndex: 0, limit: limit)
        let ranked = try zip(page.items, entries).map {
            item, entry -> (item: FoundationItem, count: Int?) in
            let counts =
                albumOnly
                ? [entry.albumCount] : [entry.albumCount, entry.songCount, entry.artistCount]
            guard counts.allSatisfy({ $0 != nil }) else { return (item, nil) }
            let count = try counts.reduce(0) { total, value in
                guard let value, value >= 0 else { throw FoundationLibraryError.unavailable }
                let (sum, overflow) = total.addingReportingOverflow(value)
                guard !overflow else { throw FoundationLibraryError.invalidResponse }
                return sum
            }
            return (item: item, count: count)
        }.filter { !albumOnly || ($0.count ?? 0) > 0 }.sorted {
            if let left = $0.count, let right = $1.count {
                if left != right { return left > right }
            } else if ($0.count != nil) != ($1.count != nil) {
                return $0.count != nil
            }
            let order = $0.item.title.localizedStandardCompare($1.item.title)
            return order == .orderedSame ? $0.item.id < $1.item.id : order == .orderedAscending
        }
        return FoundationPage(items: ranked.map(\.item), nextStartIndex: nil)
    }

    func profile() async throws -> (name: String, image: Data?) {
        let user = try await send(Paths.getCurrentUser)
        var image: Data?
        if let tag = user.primaryImageTag, !tag.isEmpty {
            let loadImage: @Sendable (FoundationItem, Int) async throws -> Data? = { _, _ in
                try await responseData(
                    Paths.getUserImage(
                        parameters: .init(userID: session.userID, tag: tag, format: .jpg)),
                    accept: "image/jpeg")
            }
            if let artworkCache {
                let avatar = FoundationItem(
                    id: "account-avatar:", title: "", subtitle: "", kind: .artist,
                    duration: nil, primaryImageTag: tag)
                image = try? await artworkCache.result(
                    for: avatar, pixels: 160, allowsNetwork: true, load: loadImage)?.data
            } else {
                image = try? await loadImage(
                    FoundationItem(
                        id: "", title: "", subtitle: "", kind: .artist, duration: nil), 160)
            }
        }
        try Task.checkCancellation()
        return (user.name ?? "", image)
    }

    func genres(startIndex: Int = 0) async throws -> FoundationPage {
        try await genrePage(startIndex: startIndex, limit: 50)
    }

    private func genrePage(
        startIndex: Int, limit: Int, query: String? = nil,
        sortNameBoundary: String? = nil
    ) async throws
        -> FoundationPage
    {
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
        guard catalogAvailable else { throw FoundationLibraryError.unavailable }
        var parameters = Paths.GetGenresParameters()
        parameters.userID = session.userID
        parameters.parentID = musicLibraryID
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.searchTerm = query
        parameters.nameStartsWithOrGreater = sortNameBoundary
        parameters.includeItemTypes = [.musicAlbum, .audio]
        parameters.sortBy = [.sortName]
        parameters.sortOrder = [.ascending]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = true
        parameters.enableImageTypes = [.primary]
        parameters.imageTypeLimit = 1
        // The music-specific endpoint is retained for deployed server compatibility;
        // its query schema matches the SDK's generated genre parameters.
        let endpoint = Request<BaseItemDtoQueryResult>(
            path: "/MusicGenres", method: "GET", query: parameters.asQuery, id: "GetMusicGenres")
        return try mappedPage(
            try await send(endpoint), kinds: [.genre], startIndex: startIndex, limit: limit)
    }

    func albums(genreID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(genreID) else { throw FoundationLibraryError.invalidResponse }
        return try await page(
            kinds: [.album], parent: nil, genreID: genreID, startIndex: startIndex, limit: 50)
    }

    func setFavorite(for item: FoundationItem, isFavorite: Bool) async throws {
        guard item.kind != .genre else { throw FoundationLibraryError.unavailable }
        guard Self.validID(item.id), Self.validID(session.userID) else {
            throw FoundationLibraryError.invalidResponse
        }
        let endpoint =
            isFavorite
            ? Paths.markFavoriteItem(itemID: item.id, userID: session.userID)
            : Paths.unmarkFavoriteItem(itemID: item.id, userID: session.userID)
        let result = try await send(endpoint)
        guard result.isFavorite == isFavorite else { throw FoundationLibraryError.invalidResponse }
    }

    /// Only the lyrics endpoint treats a missing resource as optional metadata.
    func lyrics(for item: FoundationItem) async throws -> FoundationLyrics? {
        guard item.kind == .track, Self.validID(item.id) else {
            throw FoundationLibraryError.invalidResponse
        }
        let data = try await responseData(Paths.getLyrics(itemID: item.id), notFoundIsEmpty: true)
        guard !data.isEmpty else { return nil }
        guard data.count <= 262_144 else { throw FoundationLibraryError.invalidResponse }
        do {
            let result = try JSONDecoder().decode(LyricDto.self, from: data)
            // Jellyfin's parser and client use Start directly; applying Metadata.Offset again
            // could shift already-normalized timestamps. One second is 10,000,000 ticks.
            let lines = (result.lyrics ?? []).enumerated().map { index, line in
                let start = line.start.flatMap { ticks -> Double? in
                    guard ticks >= 0 else { return nil }
                    let seconds = Double(ticks) / 10_000_000
                    if let duration = item.duration, duration > 0, seconds >= duration {
                        return nil
                    }
                    return seconds
                }
                return FoundationLyrics.Line(
                    id: index,
                    text: (line.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    start: start)
            }
            let lyrics = FoundationLyrics(lines: lines)
            try Task.checkCancellation()
            return lyrics.text.isEmpty ? nil : lyrics
        } catch {
            throw FoundationLibraryError.category(error)
        }
    }

    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
        guard item.kind == .track, Self.validID(item.id) else {
            throw FoundationDownloadError.unsupported
        }
        let metadata = try await send(Paths.getItem(itemID: item.id, userID: session.userID))
        try Task.checkCancellation()
        guard metadata.id == item.id, metadata.type == .audio, metadata.canDownload == true,
            let sources = metadata.mediaSources, sources.count == 1, let source = sources.first,
            source.protocol == .file, source.isRemote != true, source.isInfiniteStream != true,
            source.requiresOpening != true,
            let container = source.container?.lowercased(),
            let streams = source.mediaStreams ?? metadata.mediaStreams,
            let audio = streams.first(where: { $0.type == .audio }),
            let codec = audio.codec?.lowercased(),
            FoundationDownloadTransport.supports(container: container, codec: codec),
            let size = source.size, size > 0
        else { throw FoundationDownloadError.unsupported }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !session.accessToken.isEmpty,
            session.accessToken.unicodeScalars.allSatisfy({ safe.contains($0) }),
            session.deviceID.unicodeScalars.allSatisfy({ safe.contains($0) })
        else { throw FoundationDownloadError.permission }
        var request = URLRequest(
            url: try Self.url(Paths.getDownload(itemID: item.id), base: session.serverURL))
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(
            "MediaBrowser Client=\"Velacanto Native\", Device=\"Apple\", DeviceId=\"\(session.deviceID)\", Version=\"1\", Token=\"\(session.accessToken)\"",
            forHTTPHeaderField: "Authorization")
        return FoundationDownloadSource(
            request: request, fileExtension: container == "mp4" ? "m4a" : container,
            expectedBytes: Int64(size))
    }

    func playbackURL(for item: FoundationItem) async throws -> URL {
        try Task.checkCancellation()
        guard item.kind == .track, Self.validID(item.id),
            !session.accessToken.isEmpty
        else { throw FoundationLibraryError.unavailable }
        // Jellyfin selects direct delivery for these native audio formats, or AAC/HLS
        // for incompatible media. AVPlayer owns loading, buffering and seeking.
        let endpoint = Paths.getUniversalAudioStream(
            itemID: item.id,
            parameters: .init(
                container: [
                    "mp3", "aac", "mp4|aac|alac", "m4a|aac|alac", "flac",
                    "wav|pcm_s16le|pcm_s24le", "aiff|pcm_s16be|pcm_s24be",
                ],
                deviceID: session.deviceID, userID: session.userID,
                audioCodec: "aac", audioBitRate: 320_000,
                transcodingContainer: "ts", transcodingProtocol: .hls,
                enableRedirection: false))
        return try Self.url(
            endpoint, base: session.serverURL,
            additionalQuery: [("ApiKey", session.accessToken)])
    }

    func cachedArtworkResult(for item: FoundationItem, size: Int) async throws
        -> FoundationCurrentArtwork.Result?
    {
        try await artworkCache?.cachedResult(for: item, pixels: size)
    }

    func artwork(for item: FoundationItem) async throws -> Data? {
        try await artwork(for: item, size: 160)
    }

    func artwork(for item: FoundationItem, size: Int) async throws -> Data? {
        if artworkCache != nil {
            return try await artworkResult(for: item, size: size, allowsNetwork: true)?.data
        }
        return try await readArtwork(for: item, size: size, allowsCellular: nil)
    }

    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    {
        try await readArtwork(for: item, size: size, allowsCellular: allowsCellular)
    }

    func artworkResult(for item: FoundationItem, size: Int, allowsNetwork: Bool) async throws
        -> FoundationCurrentArtwork.Result?
    {
        guard let artworkCache else {
            guard allowsNetwork else { return nil }
            let data = try await readArtwork(
                for: item.catalogArtworkItem, size: size, allowsCellular: nil)
            return await Task.detached(priority: .utility) {
                data.flatMap {
                    FoundationCurrentArtwork.decode($0, maximumPixels: min(640, max(1, size)))
                }
            }.value
        }
        return try await artworkCache.result(
            for: item, pixels: size, allowsNetwork: allowsNetwork
        ) { item, pixels in
            try await readArtwork(for: item, size: pixels, allowsCellular: nil)
        }
    }

    private func readArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool?)
        async throws -> Data?
    {
        try Task.checkCancellation()
        let tag = item.primaryImageTag.flatMap { $0.isEmpty ? nil : $0 }
        // Artist and album references may omit image tags. Jellyfin accepts
        // an untagged Primary request; missing version metadata is not missing artwork.
        guard item.kind != .track, tag != nil || item.kind == .artist || item.kind == .album
        else { return nil }
        guard Self.validID(item.id) else { throw FoundationLibraryError.invalidResponse }
        let pixels = min(1024, max(1, size))
        return try await responseData(
            Paths.getItemImage(
                itemID: item.id, imageType: "Primary",
                parameters: .init(maxWidth: pixels, maxHeight: pixels, tag: tag, format: .jpg)),
            accept: "image/jpeg", allowsCellular: allowsCellular)
    }

    private func page(
        kinds: [FoundationItem.Kind], parent: String?, artistID: String? = nil,
        contributingArtistID: String? = nil,
        genreID: String? = nil, startIndex: Int,
        limit: Int, isFavorite: Bool? = nil, isPlayed: Bool? = nil, sortBy: [ItemSortBy]? = nil,
        sortOrder: JellyfinAPI.SortOrder = .ascending, query: String? = nil,
        fields: [ItemFields]? = nil, sortNameBoundary: String? = nil
    ) async throws -> FoundationPage {
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
        let accountWide = kinds == [.playlist]
        guard catalogAvailable || parent != nil || accountWide else {
            throw FoundationLibraryError.unavailable
        }
        var parameters = Paths.GetItemsParameters()
        parameters.userID = session.userID
        parameters.startIndex = startIndex
        parameters.limit = limit
        parameters.isRecursive = parent == nil
        parameters.parentID = parent ?? (accountWide ? nil : musicLibraryID)
        parameters.albumArtistIDs = artistID.map { [$0] }
        parameters.contributingArtistIDs = contributingArtistID.map { [$0] }
        parameters.genreIDs = genreID.map { [$0] }
        parameters.fields = fields
        parameters.includeItemTypes = kinds.map(Self.itemType)
        parameters.isFavorite = isFavorite
        parameters.isPlayed = isPlayed
        parameters.searchTerm = query
        parameters.nameStartsWithOrGreater = sortNameBoundary
        parameters.sortBy =
            sortBy ?? (parent == nil ? [.sortName] : [.parentIndexNumber, .indexNumber, .sortName])
        parameters.sortOrder = [sortOrder]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = true
        parameters.enableImageTypes = [.primary]
        parameters.imageTypeLimit = 1
        parameters.enableUserData = true
        let result: BaseItemDtoQueryResult = try await send(Paths.getItems(parameters: parameters))
        return try mappedPage(result, kinds: kinds, startIndex: startIndex, limit: limit)
    }

    private static func itemType(_ kind: FoundationItem.Kind) -> BaseItemKind {
        switch kind {
        case .album: .musicAlbum
        case .artist: .musicArtist
        case .track: .audio
        case .playlist: .playlist
        case .genre: .musicGenre
        }
    }

    private func mappedPage(
        _ result: BaseItemDtoQueryResult, kinds: [FoundationItem.Kind], startIndex: Int, limit: Int
    ) throws -> FoundationPage {
        guard let entries = result.items, entries.count <= limit,
            let total = result.totalRecordCount, total >= 0,
            result.startIndex == startIndex
        else { throw FoundationLibraryError.invalidResponse }
        let items = try mappedItems(entries, kinds: kinds)
        let (next, overflow) = startIndex.addingReportingOverflow(entries.count)
        guard !overflow, !entries.isEmpty || total <= startIndex else {
            throw FoundationLibraryError.invalidResponse
        }
        return FoundationPage(items: items, nextStartIndex: next < total ? next : nil)
    }

    private func mappedItems(_ entries: [BaseItemDto], kinds: [FoundationItem.Kind]) throws
        -> [FoundationItem]
    {
        try entries.map { entry -> FoundationItem in
            guard let id = entry.id, Self.validID(id),
                let kind = kinds.first(where: { Self.itemType($0) == entry.type })
            else {
                throw FoundationLibraryError.invalidResponse
            }
            let album = entry.albumID.flatMap { albumID -> FoundationItemReference? in
                guard Self.validID(albumID) else { return nil }
                return FoundationItemReference(
                    id: albumID, title: entry.album ?? "Album",
                    primaryImageTag: entry.albumPrimaryImageTag)
            }
            let artist = (entry.albumArtists ?? []).lazy.compactMap {
                reference -> FoundationItemReference? in
                guard let id = reference.id, Self.validID(id) else { return nil }
                return FoundationItemReference(id: id, title: reference.name ?? "Artist")
            }.first
            return FoundationItem(
                id: id, title: entry.name ?? "Untitled",
                subtitle: entry.albumArtist ?? entry.artists?.joined(separator: ", ") ?? "",
                kind: kind,
                duration: entry.runTimeTicks.map { Double($0) / 10_000_000 },
                primaryImageTag: kind == .track
                    ? nil : entry.imageTags?["Primary"],
                isFavorite: kind == .genre ? nil : entry.userData?.isFavorite,
                album: album, artist: artist,
                genres: (entry.genreItems ?? []).compactMap { reference in
                    guard let id = reference.id, Self.validID(id), let title = reference.name,
                        !title.isEmpty
                    else { return nil }
                    return FoundationItemReference(id: id, title: title)
                }, playCount: max(0, entry.userData?.playCount ?? 0), sortName: entry.sortName)
        }
    }

    private func send<Response: Decodable>(_ endpoint: Request<Response>) async throws -> Response {
        let data = try await responseData(endpoint)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else {
                throw FoundationLibraryError.invalidResponse
            }
            return date
        }
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw FoundationLibraryError.category(error)
        }
    }

    #if DEBUG
        /// Only finite categories leave this function; request values never enter the journal.
        private static func tracePurpose<Response>(_ endpoint: Request<Response>) -> String {
            switch endpoint.id {
            case "GetItemImage": return "artwork"
            case "GetLyrics": return "lyrics"
            case "GetAlbumArtists": return "artists"
            case "GetMusicGenres": return "genres"
            case "GetPlaylistItems": return "playlistTracks"
            case "GetItems": break
            default: return "other"
            }
            let query = endpoint.query ?? []
            func has(_ key: String) -> Bool { query.contains { $0.0 == key } }
            func matches(_ key: String, _ value: String) -> Bool {
                query.contains { $0.0 == key && $0.1 == value }
            }
            if has("searchTerm") { return "search" }
            if has("albumArtistIds") { return "artistAlbums" }
            if has("genreIds") { return "genreAlbums" }
            if matches("isPlayed", "true") { return "homeHistory" }
            let types = query.filter { $0.0 == "includeItemTypes" }.compactMap { $0.1 }
            if types == ["MusicAlbum"] {
                if matches("isFavorite", "true") { return "homeFavorites" }
                if matches("sortBy", "DateCreated") { return "recentAlbums" }
                return "albums"
            }
            if types == ["Audio"] {
                if has("parentId") { return "albumTracks" }
                if matches("sortBy", "DateCreated") { return "recentTracks" }
                return "songs"
            }
            return "other"
        }
    #endif

    private func responseData<Response>(
        _ endpoint: Request<Response>, accept: String = "application/json",
        notFoundIsEmpty: Bool = false, allowsCellular: Bool? = nil
    ) async throws -> Data {
        #if DEBUG
            let operationID = UUID().uuidString
            let traceFields = FoundationTrace.fields
            let purpose = Self.tracePurpose(endpoint)
            let family =
                endpoint.id == "AuthenticateUserByName"
                ? "auth" : endpoint.id == "GetItemImage" ? "artwork" : "catalog"
            FoundationJournal.shared.record(
                "api family=\(family) operation=\(operationID) purpose=\(purpose) \(traceFields) outcome=started"
            )
        #endif
        do {
            try Task.checkCancellation()
            var request = URLRequest(url: try Self.url(endpoint, base: session.serverURL))
            request.httpMethod = endpoint.method.rawValue
            if let allowsCellular {
                request.allowsCellularAccess = allowsCellular
                request.allowsExpensiveNetworkAccess = allowsCellular
                request.allowsConstrainedNetworkAccess = false
            }
            request.setValue(accept, forHTTPHeaderField: "Accept")
            // Reject header syntax instead of altering account authentication values.
            let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            guard session.accessToken.unicodeScalars.allSatisfy({ safe.contains($0) }),
                session.deviceID.unicodeScalars.allSatisfy({ safe.contains($0) })
            else { throw FoundationLibraryError.authentication }
            let token = session.accessToken
            let device = session.deviceID
            request.setValue(
                "MediaBrowser Client=\"Velacanto Native\", Device=\"Apple\", DeviceId=\"\(device)\", Version=\"1\", Token=\"\(token)\"",
                forHTTPHeaderField: "Authorization")
            if let body = endpoint.body {
                request.httpBody = try JSONEncoder().encode(body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            #if DEBUG
                let (data, response) = try await withTaskCancellationHandler {
                    FoundationJournal.shared.record(
                        "api operation=\(operationID) purpose=\(purpose) \(traceFields) event=loadInvoked"
                    )
                    defer {
                        FoundationJournal.shared.record(
                            "api operation=\(operationID) purpose=\(purpose) \(traceFields) event=loadReturned"
                        )
                    }
                    return try await load(request)
                } onCancel: {
                    FoundationJournal.shared.record(
                        "api operation=\(operationID) purpose=\(purpose) \(traceFields) event=cancellationRequested"
                    )
                }
            #else
                let (data, response) = try await load(request)
            #endif
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw FoundationLibraryError.invalidResponse
            }
            guard response.url == request.url else { throw FoundationLibraryError.secureConnection }
            switch response.statusCode {
            case 200..<300: break
            case 404 where notFoundIsEmpty: break
            case 401, 403: throw FoundationLibraryError.authentication
            case 300..<400: throw FoundationLibraryError.secureConnection
            default: throw FoundationLibraryError.unavailable
            }
            #if DEBUG
                FoundationJournal.shared.record(
                    "api family=\(family) operation=\(operationID) purpose=\(purpose) \(traceFields) outcome=success"
                )
            #endif
            return response.statusCode == 404 && notFoundIsEmpty ? Data() : data
        } catch {
            let category = FoundationLibraryError.category(error)
            #if DEBUG
                let outcome = category == .cancelled ? "cancelled" : "failed"
                FoundationJournal.shared.record(
                    "api family=\(family) operation=\(operationID) purpose=\(purpose) \(traceFields) outcome=\(outcome) category=\(category.rawValue)"
                )
            #endif
            throw category
        }
    }

    static func validID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
            || (value.utf8.count == 32
                && value.utf8.allSatisfy {
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                })
    }

    static func validatedServerURL(_ url: URL) throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { throw FoundationLibraryError.invalidServer }
        return url
    }

    static func url<Response>(
        _ endpoint: Request<Response>, base: URL,
        additionalQuery: [(String, String?)] = []
    ) throws -> URL {
        let base = try validatedServerURL(base)
        guard let path = endpoint.url, path.scheme == nil, path.host == nil,
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else {
            throw FoundationLibraryError.invalidResponse
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + path.path
        components.queryItems = ((endpoint.query ?? []) + additionalQuery).map {
            URLQueryItem(name: $0.0, value: $0.1)
        }
        guard let url = components.url else { throw FoundationLibraryError.invalidResponse }
        return url
    }

    private static let nativeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let nativeLoad: Load = { request in
        try await nativeSession.data(for: request, delegate: RejectRedirects())
    }

    private static let signOutSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let signOutLoad: Load = { request in
        try await signOutSession.data(for: request, delegate: RejectRedirects())
    }
}

/// Even same-origin redirects are rejected: sign-in POST bodies must not be replayed.
private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Offline-only # and unsupported/unknown server windows always restore All on reconnect.
enum FoundationAlphabetSelectionPolicy {
    static func onlineSelection(_ letter: String?, capability: FoundationAlphabetCapability)
        -> String?
    {
        guard capability == .verified, let letter, letter.utf8.count == 1,
            let scalar = letter.unicodeScalars.first, (65...90).contains(scalar.value)
        else { return nil }
        return letter
    }
}

/// Retire the actual departing account adapter, independently of logout's transport adapter.
enum FoundationAlphabetAccountLifecycle {
    @discardableResult
    static func retire(_ library: (any FoundationLibrary)?) -> Task<Void, Never>? {
        guard let library else { return nil }
        return Task { await library.retireAlphabetCapability() }
    }
}
