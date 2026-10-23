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
    var logoImageTag: String? = nil
    var backdropImageTag: String? = nil
    /// Non-primary projections stay within the existing account-owned artwork pipeline.
    var artworkRole: ArtworkRole? = nil
    enum ArtworkRole: String, Codable, Sendable { case primary, logo, backdrop }
    var isFavorite: Bool? = nil
    var album: FoundationItemReference? = nil
    var artist: FoundationItemReference? = nil
    var genres: [FoundationItemReference] = []
    var playCount: Int = 0
    var sortName: String? = nil
    /// Membership identity for editing this occurrence, separate from the song identity.
    var playlistEntryID: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
}

extension FoundationItem {
    var resolvedArtworkRole: ArtworkRole { artworkRole ?? .primary }

    /// No role silently substitutes a portrait for a wordmark or backdrop.
    func artworkItem(for role: ArtworkRole) -> FoundationItem? {
        guard role != .primary else { return catalogArtworkItem }
        guard kind == .artist else { return nil }
        let tag = role == .logo ? logoImageTag : backdropImageTag
        guard let tag, !tag.isEmpty else { return nil }
        var projection = self
        projection.primaryImageTag = tag
        projection.artworkRole = role
        return projection
    }

    /// Preserve the existing primary cache namespace and isolate optional roles.
    var artworkCacheBase: String {
        let base = "\(kind)\0\(id)"
        return resolvedArtworkRole == .primary ? base : "\(base)\0\(resolvedArtworkRole.rawValue)"
    }

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

/// A bounded discovery policy over one provider sample, independent of listening history.
enum FoundationArtistSongSuggestions {
    static let sampleLimit = 32
    static let shelfLimit = 12

    static func select(from sample: [FoundationItem]) -> [FoundationItem] {
        var seen: Set<String> = []
        let candidates = sample.prefix(sampleLimit).enumerated().filter {
            $0.element.kind == .track && seen.insert($0.element.id).inserted
        }.sorted {
            // A favorite advances only two sample positions; discovery still dominates.
            let left = $0.offset - ($0.element.isFavorite == true ? 2 : 0)
            let right = $1.offset - ($1.element.isFavorite == true ? 2 : 0)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        var albumCounts: [String: Int] = [:]
        var selected: [FoundationItem] = []
        var deferred: [FoundationItem] = []
        for track in candidates {
            let albumKey = track.album.map { "album:" + $0.id } ?? "track:" + track.id
            if albumCounts[albumKey, default: 0] < 2 {
                selected.append(track)
                albumCounts[albumKey, default: 0] += 1
            } else {
                deferred.append(track)
            }
        }
        // A one-album artist still gets a useful shelf instead of only two songs.
        return Array((selected + deferred).prefix(shelfLimit))
    }
}

/// Query-selected identities only; song matches must not expand to every song by its artist.
struct FoundationMusicSearchContext: Sendable {
    var trackIDs: Set<String> = []
    var albumIDs: Set<String> = []
    var artistIDs: Set<String> = []
    var genreIDs: Set<String> = []

    var identities: Set<String> { trackIDs.union(albumIDs).union(artistIDs).union(genreIDs) }
    var isEmpty: Bool { identities.isEmpty }

    func matches(track: FoundationItem) -> Bool {
        guard track.kind == .track else { return false }
        return trackIDs.contains(track.id)
            || track.album.map { albumIDs.contains($0.id) } == true
            || track.artist.map { artistIDs.contains($0.id) } == true
            || track.genres.contains { genreIDs.contains($0.id) }
    }

    func validate() throws {
        guard trackIDs.count + albumIDs.count + artistIDs.count + genreIDs.count <= 200,
            identities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else { throw FoundationLibraryError.invalidResponse }
    }
}

/// The cursor advances through inspected playlist candidates, not through matching results.
struct FoundationPlaylistContentPage: Sendable {
    let items: [FoundationItem]
    let nextStartIndex: Int?
    let hasIncompleteCoverage: Bool
    let partialFailureCount: Int
}

/// One bounded batch: six playlist candidates and at most their first 100 tracks each.
enum FoundationPlaylistContentSearch {
    static let candidateLimit = 6
    static let trackLimit = 100

    static func resolve(
        context: FoundationMusicSearchContext, startIndex: Int,
        playlists: @Sendable (Int, Int) async throws -> FoundationPage,
        tracks: @Sendable (String) async throws -> FoundationPage
    ) async throws -> FoundationPlaylistContentPage {
        try Task.checkCancellation()
        try context.validate()
        guard startIndex >= 0 else { throw FoundationLibraryError.invalidResponse }
        guard !context.isEmpty else {
            return .init(
                items: [], nextStartIndex: nil, hasIncompleteCoverage: false,
                partialFailureCount: 0)
        }
        let candidates: FoundationPage
        do {
            candidates = try await playlists(startIndex, candidateLimit)
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            let category = FoundationLibraryError.category(error)
            if category == .cancelled { throw CancellationError() }
            throw category
        }
        guard candidates.items.count <= candidateLimit,
            candidates.items.allSatisfy({ $0.kind == .playlist && !$0.id.isEmpty }),
            candidates.nextStartIndex.map({ $0 > startIndex && !candidates.items.isEmpty }) ?? true
        else { throw FoundationLibraryError.invalidResponse }
        var matches: [FoundationItem] = []
        var inspected: Set<String> = []
        var incomplete = candidates.nextStartIndex != nil
        var failureCount = 0
        for playlist in candidates.items where inspected.insert(playlist.id).inserted {
            try Task.checkCancellation()
            do {
                let contents = try await tracks(playlist.id)
                try Task.checkCancellation()
                guard contents.items.count <= trackLimit,
                    contents.items.allSatisfy({ $0.kind == .track }),
                    contents.nextStartIndex.map({ $0 > 0 && !contents.items.isEmpty }) ?? true
                else { throw FoundationLibraryError.invalidResponse }
                incomplete = incomplete || contents.nextStartIndex != nil
                if contents.items.contains(where: context.matches(track:)) {
                    matches.append(playlist)
                }
            } catch {
                try Task.checkCancellation()
                let category = FoundationLibraryError.category(error)
                if category == .cancelled { throw CancellationError() }
                // A missing optional playlist or transport failure is partial; authentication stays actionable.
                guard category == .network || category == .unavailable else { throw category }
                failureCount += 1
                incomplete = true
            }
        }
        try Task.checkCancellation()
        return .init(
            items: matches, nextStartIndex: candidates.nextStartIndex,
            hasIncompleteCoverage: incomplete, partialFailureCount: failureCount)
    }
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

/// One account-owned artist detail read serves branding, overview and favorite observation.
/// Failures are never retained; leaving the last visible consumer cancels its work.
/// Account-owned metadata shared by independent hero consumers.
struct FoundationArtistDetails: Sendable {
    let item: FoundationItem
    let overview: String?
}

actor FoundationArtistDetailMemo {
    typealias Value = FoundationArtistDetails
    private struct Entry {
        let value: Value
        let revision: String
        let expiry: Date
        let access: UInt
    }
    private struct Job {
        let key: String
        let revision: String
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<Value, Error>]
    }
    private var entries: [String: Entry] = [:]
    private var jobs: [UUID: Job] = [:]
    private var activeByKey: [String: UUID] = [:]
    private var clock: UInt = 0
    private var live = true
    private let limit: Int
    private let now: @Sendable () -> Date

    init(limit: Int = 32, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = max(1, limit)
        self.now = now
    }

    /// A cache-only read never joins or starts transport work.
    func cachedValue(key: String, revision: String = "") -> Value? {
        guard live, let entry = entries[key], entry.revision == revision,
            entry.expiry > now()
        else { return nil }
        clock &+= 1
        entries[key] = Entry(
            value: entry.value, revision: revision, expiry: entry.expiry, access: clock)
        return entry.value
    }

    func value(
        key: String, revision: String = "", load: @escaping @Sendable () async throws -> Value
    ) async throws
        -> Value
    {
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        clock &+= 1
        if let entry = entries[key], entry.revision == revision, entry.expiry > now() {
            entries[key] = Entry(
                value: entry.value, revision: revision, expiry: entry.expiry, access: clock)
            return entry.value
        }
        entries.removeValue(forKey: key)
        if let active = activeByKey[key], jobs[active]?.revision != revision {
            activeByKey.removeValue(forKey: key)
        }
        guard activeByKey[key] != nil || jobs.count < limit else {
            throw FoundationLibraryError.unavailable
        }
        let jobID = activeByKey[key] ?? UUID()
        let waiter = UUID()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[jobID] {
                    job.waiters[waiter] = continuation
                    jobs[jobID] = job
                } else {
                    let task = Task { [weak self] in
                        let outcome: Result<Value, Error>
                        do {
                            let value = try await load()
                            try Task.checkCancellation()
                            outcome = .success(value)
                        } catch { outcome = .failure(error) }
                        await self?.finish(id: jobID, outcome: outcome)
                    }
                    jobs[jobID] = Job(
                        key: key, revision: revision, task: task, waiters: [waiter: continuation])
                    activeByKey[key] = jobID
                }
            }
        } onCancel: {
            Task { await self.cancel(id: jobID, waiter: waiter) }
        }
        try Task.checkCancellation()
        return result
    }

    private func finish(id: UUID, outcome: Result<Value, Error>) {
        guard let job = jobs.removeValue(forKey: id) else { return }
        let mayPublish = activeByKey[job.key] == id
        if mayPublish { activeByKey.removeValue(forKey: job.key) }
        if live, mayPublish, case .success(let value) = outcome {
            clock &+= 1
            entries[job.key] = Entry(
                value: value, revision: job.revision, expiry: now().addingTimeInterval(60),
                access: clock)
            if entries.count > limit,
                let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key
            {
                entries.removeValue(forKey: oldest)
            }
        }
        for continuation in job.waiters.values { continuation.resume(with: outcome) }
    }

    private func cancel(id: UUID, waiter: UUID) {
        guard var job = jobs[id], let continuation = job.waiters.removeValue(forKey: waiter) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            job.task.cancel()
            jobs.removeValue(forKey: id)
            if activeByKey[job.key] == id { activeByKey.removeValue(forKey: job.key) }
        } else {
            jobs[id] = job
        }
    }

    func invalidate(key: String) {
        entries.removeValue(forKey: key)
        // Existing branding/overview consumers finish normally. New consumers get a new
        // generation, and the pre-mutation read can never republish stale favorite state.
        activeByKey.removeValue(forKey: key)
    }

    func retire() {
        live = false
        entries.removeAll()
        activeByKey.removeAll()
        let pending = jobs.values
        jobs.removeAll()
        for job in pending {
            job.task.cancel()
            for continuation in job.waiters.values {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

}

protocol FoundationLibrary: Sendable {
    func reportPlayback(_ event: FoundationPlaybackReport) async throws
    func retireAlphabetCapability() async
    func alphabetCapability() async -> FoundationAlphabetCapability
    /// A relative cursor into the bounded SortName >= letter tail, never an absolute rank.
    func alphabetPage(kind: FoundationItem.Kind, letter: String, startIndex: Int) async throws
        -> FoundationPage
    var catalogPageCache: FoundationCatalogPageCache? { get }
    var catalogScopeID: String { get }
    func catalogCacheKey(_ key: String) -> String
    func retryArtwork(for item: FoundationItem) async
    func cachedArtworkResult(for item: FoundationItem, size: Int) async throws
        -> FoundationCurrentArtwork.Result?
    func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource
    func downloadPreparation(for item: FoundationItem, quality: FoundationDownloadQuality)
        async throws -> FoundationDownloadPreparation
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
    func cachedArtistDetails(for item: FoundationItem) async -> FoundationArtistDetails?
    func overview(for item: FoundationItem) async throws -> String?
    func itemDetails(for item: FoundationItem) async throws -> FoundationItem?
    func invalidateItemDetails(for item: FoundationItem) async
    func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage
    func similarItems(for item: FoundationItem) async throws -> FoundationPage
    func mostPlayedAlbums() async throws -> FoundationPage
    func mostPlayed(artistID: String) async throws -> FoundationPage
    func suggestedSongs(artistID: String) async throws -> FoundationPage
    func homeGenres() async throws -> FoundationPage
    func searchGenres() async throws -> FoundationPage
    func profile() async throws -> (name: String, image: Data?)
    func recentlyPlayed(startIndex: Int) async throws -> FoundationPage
    func favoriteAlbums(startIndex: Int) async throws -> FoundationPage
    func favoriteCollectionsPreview() async throws -> FoundationPage
    func search(
        query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int
    ) async throws -> FoundationPage
    func recentAlbums(startIndex: Int) async throws -> FoundationPage
    func recentTracks(startIndex: Int) async throws -> FoundationPage
    /// A bounded, server-ordered snapshot of recent music groups (albums or singles).
    func recentMusicSuggestions() async throws -> FoundationPage
    func albums(startIndex: Int) async throws -> FoundationPage
    func artists(startIndex: Int) async throws -> FoundationPage
    func albums(artistID: String, startIndex: Int) async throws -> FoundationPage
    func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage
    func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage
    func songs(startIndex: Int) async throws -> FoundationPage
    func playlists(startIndex: Int) async throws -> FoundationPage
    func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage
    func playlistsContainingMusic(context: FoundationMusicSearchContext, startIndex: Int)
        async throws -> FoundationPlaylistContentPage
    func favorites(startIndex: Int) async throws -> FoundationPage
    func favorites(kind: FoundationItem.Kind, startIndex: Int) async throws -> FoundationPage
    func genres(startIndex: Int) async throws -> FoundationPage
    func albums(genreID: String, startIndex: Int) async throws -> FoundationPage
    func setFavorite(for item: FoundationItem, isFavorite: Bool) async throws
    func playbackURL(for item: FoundationItem) async throws -> URL
    func playbackResource(for item: FoundationItem) async throws -> FoundationPlaybackResource
    func artwork(for item: FoundationItem) async throws -> Data?
    func artwork(for item: FoundationItem, size: Int) async throws -> Data?
    func downloadArtwork(for item: FoundationItem, size: Int, allowsCellular: Bool) async throws
        -> Data?
    func artworkResult(for item: FoundationItem, size: Int, allowsNetwork: Bool) async throws
        -> FoundationCurrentArtwork.Result?
}

extension FoundationLibrary {
    func playbackResource(for item: FoundationItem) async throws -> FoundationPlaybackResource {
        FoundationPlaybackResource(url: try await playbackURL(for: item))
    }

    func retryArtwork(for item: FoundationItem) async {}
    func invalidateItemDetails(for item: FoundationItem) async {}
    func reportPlayback(_ event: FoundationPlaybackReport) async throws {}
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
    func downloadPreparation(for item: FoundationItem, quality: FoundationDownloadQuality)
        async throws -> FoundationDownloadPreparation
    {
        guard quality == .original else { throw FoundationDownloadError.unsupported }
        return .original(try await downloadSource(for: item))
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
    func suggestedSongs(artistID: String) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func similarItems(for item: FoundationItem) async throws -> FoundationPage {
        throw FoundationLibraryError.unavailable
    }
    func cachedArtistDetails(for item: FoundationItem) async -> FoundationArtistDetails? { nil }
    func overview(for item: FoundationItem) async throws -> String? { nil }
    func itemDetails(for item: FoundationItem) async throws -> FoundationItem? { nil }
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

    func favoriteCollectionsPreview() async throws -> FoundationPage {
        let albums = try await favorites(kind: .album, startIndex: 0)
        try Task.checkCancellation()
        let playlists = try await favorites(kind: .playlist, startIndex: 0)
        try Task.checkCancellation()
        return foundationFavoriteCollectionsPreview(albums: albums, playlists: playlists)
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

    func recentMusicSuggestions() async throws -> FoundationPage {
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
    func playlistsContainingMusic(context: FoundationMusicSearchContext, startIndex: Int)
        async throws -> FoundationPlaylistContentPage
    { throw FoundationLibraryError.unavailable }
    func favorites(kind: FoundationItem.Kind, startIndex: Int) async throws -> FoundationPage {
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

/// A generated-request adapter with account-owned bounded artist metadata reuse.
struct FoundationJellyfinLibrary: FoundationLibrary {
    typealias Load = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    let session: FoundationSession
    private let load: Load
    private let streamingQuality: @Sendable () async -> FoundationStreamingQuality
    private let hlsCleanup = FoundationHLSCleanup()
    #if DEBUG
        @TaskLocal static var hlsCleanupLoad: Load?
        // Internal fixture seam only; persisted comparison preferences have no authority.
        @TaskLocal static var hlsOriginalPreferred = true
    #endif
    private let alphabetMemo = FoundationAlphabetCapabilityMemo()
    private let artistDetailMemo = FoundationArtistDetailMemo()
    let artworkCache: FoundationArtworkCache?
    let networkAdmission: FoundationNetworkAdmission
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
        catalogPageCache: FoundationCatalogPageCache? = nil,
        networkAdmission: FoundationNetworkAdmission = FoundationNetworkAdmission()
    ) {
        self.init(
            session: session, streamingQuality: { .original }, load: load,
            artworkCache: artworkCache, catalogPageCache: catalogPageCache,
            networkAdmission: networkAdmission)
    }

    init(
        session: FoundationSession,
        streamingQuality: @escaping @Sendable () async -> FoundationStreamingQuality,
        load: @escaping Load = nativeLoad,
        artworkCache: FoundationArtworkCache? = nil,
        catalogPageCache: FoundationCatalogPageCache? = nil,
        networkAdmission: FoundationNetworkAdmission = FoundationNetworkAdmission()
    ) {
        self.session = session
        self.load = load
        self.streamingQuality = streamingQuality
        self.artworkCache = artworkCache
        self.networkAdmission = networkAdmission
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

    func retireAlphabetCapability() async {
        await networkAdmission.retire()
        await alphabetMemo.retire()
        await artistDetailMemo.retire()
    }

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
            let scalar = letter.unicodeScalars.first,
            (65...90).contains(scalar.value) || (kind == .track && letter == "#")
        else { throw FoundationLibraryError.invalidResponse }
        if kind == .track {
            guard catalogAvailable else { throw FoundationLibraryError.unavailable }
            let offset =
                startIndex == 0
                ? try await FoundationSongAlphabetSeek.lowerBound(
                    letter: letter, read: songAlphabetProbe)
                : startIndex
            let result = try await page(
                kinds: [.track], parent: nil, startIndex: offset, limit: 50, sortBy: [.name])
            let keys = result.items.map(FoundationSongAlphabetSeek.key)
            guard zip(keys, keys.dropFirst()).allSatisfy({ $0 <= $1 }),
                letter == "#" || keys.allSatisfy({ $0 >= letter.lowercased() })
            else { throw FoundationLibraryError.invalidResponse }
            return result
        }
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

    private func songAlphabetProbe(_ offset: Int) async throws -> FoundationSongAlphabetSeek.Probe {
        try Task.checkCancellation()
        var parameters = Paths.GetItemsParameters()
        parameters.userID = session.userID
        parameters.parentID = musicLibraryID
        parameters.includeItemTypes = [.audio]
        parameters.isRecursive = true
        parameters.startIndex = offset
        parameters.limit = 1
        parameters.sortBy = [.name]
        parameters.sortOrder = [.ascending]
        parameters.enableTotalRecordCount = true
        parameters.enableImages = false
        parameters.enableUserData = false
        let result: BaseItemDtoQueryResult = try await send(Paths.getItems(parameters: parameters))
        guard let entries = result.items, entries.count <= 1,
            let total = result.totalRecordCount, result.startIndex == offset,
            entries.allSatisfy({ $0.name?.isEmpty == false })
        else { throw FoundationLibraryError.invalidResponse }
        return .init(
            startIndex: offset, totalCount: total,
            items: try mappedItems(entries, kinds: [.track]))
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

    func favoriteCollectionsPreview() async throws -> FoundationPage {
        let albums: FoundationPage
        if catalogAvailable {
            albums = try await page(
                kinds: [.album], parent: nil, startIndex: 0, limit: 5, isFavorite: true)
        } else {
            albums = .init(items: [], nextStartIndex: nil)
        }
        try Task.checkCancellation()
        let playlists = try await page(
            kinds: [.playlist], parent: nil, startIndex: 0, limit: 5, isFavorite: true)
        try Task.checkCancellation()
        return foundationFavoriteCollectionsPreview(albums: albums, playlists: playlists)
    }

    func recentAlbums(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.album], parent: nil, startIndex: startIndex, limit: 24,
            sortBy: [.dateCreated], sortOrder: .descending, fields: [.genres])
    }

    /// Owner-selected Jellyfin Date Added ascending order, including the native name tie-breaker.
    func recentTracks(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track], parent: nil, startIndex: startIndex, limit: 24,
            sortBy: [.dateCreated, .sortName], sortOrder: .ascending)
    }

    func recentMusicSuggestions() async throws -> FoundationPage {
        guard catalogAvailable else { throw FoundationLibraryError.unavailable }
        // Preserve the server's grouping and user preferences, as its music Suggestions do.
        let entries: [BaseItemDto] = try await send(
            Paths.getLatestMedia(
                parameters: .init(
                    userID: session.userID, parentID: musicLibraryID, fields: [.genres],
                    includeItemTypes: [.audio], enableImages: true, imageTypeLimit: 1,
                    enableImageTypes: [.primary], enableUserData: true, limit: 24)))
        guard entries.count <= 24 else { throw FoundationLibraryError.invalidResponse }
        return .init(items: try mappedItems(entries, kinds: [.album, .track]), nextStartIndex: nil)
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

    func suggestedSongs(artistID: String) async throws -> FoundationPage {
        guard Self.validID(artistID) else { throw FoundationLibraryError.invalidResponse }
        let sample = try await page(
            kinds: [.track], parent: nil, artistID: artistID, startIndex: 0,
            limit: FoundationArtistSongSuggestions.sampleLimit, sortBy: [.random])
        return FoundationPage(
            items: FoundationArtistSongSuggestions.select(from: sample.items), nextStartIndex: nil)
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

    func cachedArtistDetails(for item: FoundationItem) async -> FoundationArtistDetails? {
        guard item.kind == .artist, Self.validID(item.id), !Task.isCancelled else { return nil }
        return await artistDetailMemo.cachedValue(
            key: item.id, revision: item.artistBrandingRevision)
    }

    func overview(for item: FoundationItem) async throws -> String? {
        guard Self.validID(item.id), item.kind == .artist || item.kind == .album else {
            throw FoundationLibraryError.invalidResponse
        }
        if item.kind == .artist { return try await artistDetails(for: item).overview }
        let detail: BaseItemDto = try await send(
            Paths.getItem(itemID: item.id, userID: session.userID))
        guard detail.id == item.id else { throw FoundationLibraryError.invalidResponse }
        return detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func itemDetails(for item: FoundationItem) async throws -> FoundationItem? {
        guard Self.validID(item.id), item.kind == .album || item.kind == .artist else {
            throw FoundationLibraryError.invalidResponse
        }
        if item.kind == .artist { return try await artistDetails(for: item).item }
        let detail: BaseItemDto = try await send(
            Paths.getItem(itemID: item.id, userID: session.userID))
        guard detail.id == item.id else { throw FoundationLibraryError.invalidResponse }
        return try mappedItems([detail], kinds: [item.kind]).first
    }

    private func artistDetails(for item: FoundationItem) async throws
        -> FoundationArtistDetailMemo.Value
    {
        try await artistDetailMemo.value(key: item.id, revision: item.artistBrandingRevision) {
            let detail: BaseItemDto = try await send(
                Paths.getItem(itemID: item.id, userID: session.userID))
            guard detail.id == item.id,
                let mapped = try mappedItems([detail], kinds: [.artist]).first
            else { throw FoundationLibraryError.invalidResponse }
            return .init(
                item: mapped,
                overview: detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func invalidateItemDetails(for item: FoundationItem) async {
        if item.kind == .artist { await artistDetailMemo.invalidate(key: item.id) }
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
            kinds: [.track], parent: nil, startIndex: startIndex, limit: 100,
            sortBy: [.name], fields: [.sortName])
    }

    func playlists(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(kinds: [.playlist], parent: nil, startIndex: startIndex, limit: 50)
    }

    func favorites(kind: FoundationItem.Kind, startIndex: Int) async throws -> FoundationPage {
        guard [.album, .artist, .track, .playlist].contains(kind) else {
            throw FoundationLibraryError.unavailable
        }
        return try await page(
            kinds: [kind], parent: nil, startIndex: startIndex, limit: 50, isFavorite: true)
    }

    func favorites(startIndex: Int = 0) async throws -> FoundationPage {
        try await page(
            kinds: [.track, .album, .artist, .playlist], parent: nil,
            startIndex: startIndex, limit: 50, isFavorite: true)
    }

    func playlistsContainingMusic(context: FoundationMusicSearchContext, startIndex: Int)
        async throws -> FoundationPlaylistContentPage
    {
        try Task.checkCancellation()
        try context.validate()
        guard startIndex >= 0, context.identities.allSatisfy(Self.validID) else {
            throw FoundationLibraryError.invalidResponse
        }
        let omitsSharedIdentities =
            musicLibraryID != nil
            && (!context.artistIDs.isEmpty || !context.genreIDs.isEmpty)
        let effectiveContext =
            musicLibraryID == nil
            ? context
            : FoundationMusicSearchContext(trackIDs: context.trackIDs, albumIDs: context.albumIDs)
        guard !effectiveContext.isEmpty else {
            return .init(
                items: [], nextStartIndex: nil, hasIncompleteCoverage: omitsSharedIdentities,
                partialFailureCount: 0)
        }
        guard catalogAvailable else { throw FoundationLibraryError.unavailable }
        // Artist and genre identities may span libraries. A selected library uses only its
        // resolved track/album identities; omitted relationships remain explicitly incomplete.
        let result = try await FoundationPlaylistContentSearch.resolve(
            context: effectiveContext, startIndex: startIndex,
            playlists: { offset, limit in
                try await page(kinds: [.playlist], parent: nil, startIndex: offset, limit: limit)
            },
            tracks: { id in try await playlistTracks(playlistID: id, startIndex: 0) })
        try Task.checkCancellation()
        return .init(
            items: result.items, nextStartIndex: result.nextStartIndex,
            hasIncompleteCoverage: result.hasIncompleteCoverage || omitsSharedIdentities,
            partialFailureCount: result.partialFailureCount)
    }

    func playlistTracks(playlistID: String, startIndex: Int = 0) async throws -> FoundationPage {
        guard Self.validID(playlistID), startIndex >= 0 else {
            throw FoundationLibraryError.invalidResponse
        }
        let result = try await send(
            Paths.getPlaylistItems(
                playlistID: playlistID,
                parameters: .init(
                    userID: session.userID, startIndex: startIndex, limit: 100, fields: [.genres],
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
        await invalidateItemDetails(for: item)
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

    func downloadPreparation(for item: FoundationItem, quality: FoundationDownloadQuality)
        async throws -> FoundationDownloadPreparation
    {
        if quality == .original { return .original(try await downloadSource(for: item)) }
        return .converted(try await convertedDownloadProposal(for: item, quality: quality))
    }

    /// Fresh authorization and source checks, before starting this transfer's conversion.
    func convertedDownloadProposal(for item: FoundationItem, quality: FoundationDownloadQuality)
        async throws -> FoundationDownloadConversionProposal
    {
        guard item.kind == .track, Self.validID(item.id), quality.aacBitrate != nil else {
            throw FoundationDownloadError.unsupported
        }
        // Fresh account and item reads, not saved catalog or session policy snapshots.
        // There is still a check-to-transfer revocation window: the progressive route
        // does not atomically enforce the Download policy at its own request boundary.
        let user = try await send(Paths.getUserByID(userID: session.userID))
        try Task.checkCancellation()
        guard user.id == session.userID, let policy = user.policy,
            policy.isDisabled == false, policy.enableMediaPlayback == true,
            policy.enableContentDownloading == true, policy.enableAudioPlaybackTranscoding == true
        else { throw FoundationDownloadError.permission }
        let metadata = try await send(Paths.getItem(itemID: item.id, userID: session.userID))
        try Task.checkCancellation()
        guard metadata.id == item.id, metadata.type == .audio, metadata.canDownload == true else {
            throw FoundationDownloadError.permission
        }
        guard let sources = metadata.mediaSources, sources.count == 1, let source = sources.first,
            source.protocol == .file, source.isRemote != true, source.isInfiniteStream != true,
            source.requiresOpening != true, source.requiresClosing != true,
            (source.requiredHTTPHeaders ?? [:]).isEmpty,
            let sourceID = source.id,
            let streams = source.mediaStreams ?? metadata.mediaStreams,
            streams.filter({ $0.type == .audio }).count == 1,
            let audio = streams.first(where: { $0.type == .audio }), let index = audio.index,
            let ticks = source.runTimeTicks ?? metadata.runTimeTicks, ticks > 0
        else { throw FoundationDownloadError.unsupported }
        if let sourceTicks = source.runTimeTicks, let itemTicks = metadata.runTimeTicks,
            abs(Double(sourceTicks) - Double(itemTicks)) > 10_000_000
        {
            throw FoundationDownloadError.unsupported
        }
        let plan = try FoundationDownloadConversionPlan(
            quality: quality, duration: Double(ticks) / 10_000_000,
            sourceID: sourceID, audioStreamIndex: index)
        let query = try plan.queryItems(deviceID: session.deviceID).map { ($0.name, $0.value) }
        let endpoint = Request<Data>(
            path: "/Audio/\(item.id)/stream.m4a", method: "GET", query: query)
        var request = URLRequest(url: try Self.url(endpoint, base: session.serverURL))
        request.httpMethod = "GET"
        guard
            plan.accepts(
                request, base: session.serverURL, itemID: item.id, deviceID: session.deviceID)
        else { throw FoundationDownloadError.response }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard !session.accessToken.isEmpty,
            session.accessToken.unicodeScalars.allSatisfy({ safe.contains($0) })
        else { throw FoundationDownloadError.permission }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(
            "MediaBrowser Client=\"Velacanto Native\", Device=\"Apple\", DeviceId=\"\(session.deviceID)\", Version=\"1\", Token=\"\(session.accessToken)\"",
            forHTTPHeaderField: "Authorization")
        var cleanupRequest = request
        cleanupRequest.url = try Self.url(
            Request<Data>(
                path: "/Videos/ActiveEncodings", method: "DELETE",
                query: [
                    ("deviceId", session.deviceID), ("playSessionId", plan.sessionID.uuidString),
                ]), base: session.serverURL)
        cleanupRequest.httpMethod = "DELETE"
        return FoundationDownloadConversionProposal(
            request: request, cleanupRequest: cleanupRequest, plan: plan,
            base: session.serverURL, itemID: item.id, deviceID: session.deviceID)
    }

    func reportPlayback(_ event: FoundationPlaybackReport) async throws {
        try Task.checkCancellation()
        guard Self.validID(event.itemID), event.position.isFinite, event.position >= 0,
            event.position < Double(Int.max) / 10_000_000
        else { throw FoundationLibraryError.invalidResponse }
        let scaledPosition = event.position * 10_000_000
        guard scaledPosition < Double(Int.max) else {
            throw FoundationLibraryError.invalidResponse
        }
        let ticks = Int(scaledPosition)
        if event.kind == .stop {
            _ = try await responseData(
                Paths.reportPlaybackStopped(
                    .init(
                        itemID: event.itemID, mediaSourceID: event.source?.mediaSourceID,
                        playSessionID: event.source?.serverSessionID
                            ?? event.occurrenceID.uuidString,
                        positionTicks: ticks)))
        } else {
            let body = PlaybackStateInfo(
                isPaused: event.paused, itemID: event.itemID,
                mediaSourceID: event.source?.mediaSourceID,
                playMethod: event.source?.delivery == .hlsAAC
                    ? .transcode : (event.source?.delivery == .hlsCopy ? .directStream : nil),
                playSessionID: event.source?.serverSessionID ?? event.occurrenceID.uuidString,
                positionTicks: ticks)
            if event.kind == .start {
                _ = try await responseData(Paths.reportPlaybackStart(body))
            } else {
                _ = try await responseData(Paths.reportPlaybackProgress(body))
            }
        }
    }

    func playbackResource(for item: FoundationItem) async throws -> FoundationPlaybackResource {
        let quality = await streamingQuality().resolved(for: FoundationStreamingPath())
        #if DEBUG
            return try await hlsResource(
                for: item, quality: quality, resolveMetadata: Self.hlsOriginalPreferred)
        #else
            return try await hlsResource(for: item, quality: quality)
        #endif
    }

    private func hlsResource(
        for item: FoundationItem, quality: FoundationStreamingQuality, resolveMetadata: Bool = true
    ) async throws -> FoundationPlaybackResource {
        try Task.checkCancellation()
        guard item.kind == .track, Self.validID(item.id) else {
            throw FoundationLibraryError.unavailable
        }
        var selectedSource: MediaSourceInfo?
        var selectedAudio: MediaStream?
        var copyCodec: String?
        var container = "ts"
        if resolveMetadata {
            let metadataData = try await responseData(
                Paths.getItem(itemID: item.id, userID: session.userID), loadOverride: load)
            try Task.checkCancellation()
            let metadata = try Self.decodePlaybackMetadata(metadataData)
            guard metadata.id == item.id, metadata.type == .audio,
                let sources = metadata.mediaSources, sources.count == 1,
                let source = sources.first, let identity = source.id, !identity.isEmpty,
                source.protocol == .file, source.isRemote != true,
                source.isInfiniteStream != true, source.requiresOpening != true,
                source.requiresClosing != true, (source.requiredHTTPHeaders ?? [:]).isEmpty,
                let streams = source.mediaStreams ?? metadata.mediaStreams
            else { throw FoundationLibraryError.unavailable }
            let audio = streams.filter { $0.type == .audio }
            guard audio.count == 1, audio[0].isExternal != true,
                let index = audio[0].index, index >= 0
            else { throw FoundationLibraryError.unavailable }
            selectedSource = source
            selectedAudio = audio[0]
            copyCodec = quality == .original ? Self.hlsCopyCodec(audio[0]) : nil
            if let copyCodec { container = copyCodec == "mp3" ? "ts" : "mp4" }
            #if DEBUG
                FoundationJournal.shared.record(
                    "player.hls.selection delivery=\(copyCodec == nil ? "aac" : "copy") "
                        + "reason=\(quality == .original ? Self.hlsCopyReason(audio[0]) : "fixedQuality")"
                )
            #endif
        }
        let copyOnly = copyCodec != nil
        let bitrate = copyOnly ? 50_000_000 : (quality.aacBitrate ?? 320_000)
        let profile = DeviceProfile(
            directPlayProfiles: [], maxStreamingBitrate: bitrate,
            musicStreamingTranscodingBitrate: bitrate,
            transcodingProfiles: [
                TranscodingProfile(
                    protocol: .hls, audioCodec: copyCodec ?? "aac",
                    container: container,
                    context: .streaming, type: .audio)
            ])
        let info: PlaybackInfoResponse
        do {
            info = try await send(
                Paths.getPostedPlaybackInfo(
                    itemID: item.id,
                    PlaybackInfoDto(
                        allowAudioStreamCopy: copyOnly, audioStreamIndex: selectedAudio?.index,
                        deviceProfile: profile,
                        enableDirectPlay: false, enableDirectStream: false,
                        enableTranscoding: true,
                        isAutoOpenLiveStream: false, maxStreamingBitrate: bitrate,
                        mediaSourceID: selectedSource?.id, userID: session.userID)))
        } catch {
            #if DEBUG
                FoundationJournal.shared.record(
                    "player.hls.negotiation outcome=failed stage=response decode=\(error is DecodingError ? 1 : 0)"
                )
            #endif
            throw error
        }
        #if DEBUG
            FoundationJournal.shared.record(
                "player.hls.negotiation outcome=decoded error=\(info.errorCode == nil ? 0 : 1) "
                    + "session=\(info.playSessionID?.isEmpty == false ? 1 : 0) sources=\(info.mediaSources?.count ?? 0)"
            )
        #endif
        #if DEBUG
            for source in (info.mediaSources ?? []).prefix(4) {
                FoundationJournal.shared.record(
                    "player.hls.source transcode=\(source.isSupportsTranscoding == true ? 1 : 0) "
                        + "hls=\(source.transcodingSubProtocol == .hls ? 1 : 0) "
                        + "opening=\(source.requiresOpening == true ? 1 : 0) closing=\(source.requiresClosing == true ? 1 : 0) "
                        + "headers=\((source.requiredHTTPHeaders ?? [:]).count) "
                        + "identity=\(source.id?.isEmpty == false ? 1 : 0) url=\(source.transcodingURL == nil ? 0 : 1)"
                )
            }
        #endif
        guard info.errorCode == nil,
            let serverSession = info.playSessionID, !serverSession.isEmpty,
            let source = info.mediaSources?.first(where: {
                $0.isSupportsTranscoding == true && $0.transcodingSubProtocol == .hls
                    && $0.requiresOpening != true && $0.requiresClosing != true
                    && ($0.requiredHTTPHeaders ?? [:]).isEmpty
            }), let sourceID = source.id, !sourceID.isEmpty,
            let returnedURL = source.transcodingURL
        else { throw FoundationLibraryError.unavailable }
        let url = try Self.hlsURL(
            returnedURL, itemID: item.id, sourceID: sourceID, serverSession: serverSession,
            base: session.serverURL, token: session.accessToken, deviceID: session.deviceID)
        #if DEBUG
            let cleanupLoad = Self.hlsCleanupLoad ?? Self.signOutLoad
        #else
            let cleanupLoad = Self.signOutLoad
        #endif
        let lease = FoundationHLSLease(owner: hlsCleanup, key: serverSession) {
            // One exact-session attempt using the existing bounded 8-second transport.
            // A completed DELETE does not prove late segment requests cannot restart work.
            do {
                let endpoint = Request<Data>(
                    path: "/Videos/ActiveEncodings", method: "DELETE",
                    query: [("deviceId", session.deviceID), ("playSessionId", serverSession)])
                _ = try await responseData(endpoint, loadOverride: cleanupLoad)
                #if DEBUG
                    FoundationJournal.shared.record("player.hls.cleanup outcome=returned")
                #endif
            } catch {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "player.hls.cleanup outcome=failed category=\(FoundationLibraryError.category(error).rawValue)"
                    )
                #endif
            }
        }
        do {
            try Task.checkCancellation()
            var playbackURL = url
            if resolveMetadata {
                let audio = (source.mediaStreams ?? []).filter { $0.type == .audio }
                guard source.id == selectedSource?.id, audio.count == 1,
                    let expected = selectedAudio,
                    audio[0].index == expected.index,
                    audio[0].codec?.lowercased() == expected.codec?.lowercased(),
                    audio[0].bitRate == expected.bitRate,
                    audio[0].sampleRate == expected.sampleRate,
                    audio[0].channels == expected.channels,
                    audio[0].bitDepth == expected.bitDepth,
                    audio[0].profile == expected.profile
                else {
                    #if DEBUG
                        FoundationJournal.shared.record(
                            "player.hls.copy outcome=rejected stage=sourceDrift")
                    #endif
                    throw FoundationLibraryError.unavailable
                }
            }
            if let cap = quality.aacBitrate {
                let fixedURL = try Self.validateFixedAACURL(
                    returnedURL, cap: cap, audioIndex: selectedAudio?.index)
                playbackURL = try Self.hlsURL(
                    fixedURL, itemID: item.id, sourceID: sourceID, serverSession: serverSession,
                    base: session.serverURL, token: session.accessToken, deviceID: session.deviceID)
            }
            if let copyCodec, let expected = selectedAudio {
                let audio = [expected]
                #if DEBUG
                    FoundationJournal.shared.record(
                        "player.hls.copy.source bitrate=\(audio[0].bitRate ?? -1) "
                            + "sampleRate=\(audio[0].sampleRate ?? -1) channels=\(audio[0].channels ?? -1)"
                    )
                #endif
                let master = try Self.hlsCopyMaster(
                    returnedURL, audio: audio[0], codec: copyCodec, container: container)
                let endpoint = Request<Data>(
                    path: master.path, method: "GET",
                    query: (master.queryItems ?? []).filter {
                        !["api_key", "apikey"].contains($0.name.lowercased())
                    }.map { ($0.name, $0.value) })
                // Audio preparation uses the existing transport directly, never optional GET admission.
                let data = try await responseData(
                    endpoint, accept: "application/vnd.apple.mpegurl", loadOverride: load)
                try Task.checkCancellation()
                playbackURL = try Self.hlsCopyURL(
                    data, container: container, audio: expected, codec: copyCodec,
                    itemID: item.id, sourceID: sourceID, serverSession: serverSession,
                    base: session.serverURL, token: session.accessToken,
                    deviceID: session.deviceID)
            }
            try Task.checkCancellation()
            return FoundationPlaybackResource(
                url: playbackURL,
                source: .init(
                    delivery: copyOnly ? .hlsCopy : .hlsAAC,
                    mediaSourceID: sourceID, serverSessionID: serverSession)
            ) { await lease.release() }
        } catch {
            await lease.release()
            throw error
        }
    }

    /// Reject a server decision that would bypass the explicit fixed AAC policy.
    @discardableResult
    static func validateFixedAACURL(_ raw: String, cap: Int, audioIndex: Int?) throws -> String {
        guard var components = URLComponents(string: raw), let index = audioIndex, index >= 0 else {
            throw FoundationLibraryError.invalidResponse
        }
        let query = components.queryItems ?? []
        func value(_ key: String) throws -> String {
            let matches = query.filter { $0.name.lowercased() == key }
            guard matches.count == 1, let value = matches[0].value else {
                throw FoundationLibraryError.invalidResponse
            }
            return value
        }
        for key in ["allowaudiostreamcopy", "enableautostreamcopy", "static"] {
            let matches = query.filter { $0.name.lowercased() == key }
            guard
                matches.isEmpty
                    || (matches.count == 1 && matches[0].value?.lowercased() == "false")
            else { throw FoundationLibraryError.invalidResponse }
        }
        guard try value("audiocodec").lowercased() == "aac",
            let bitrate = Int(try value("audiobitrate")), bitrate > 0, bitrate <= cap,
            try value("segmentcontainer").lowercased() == "ts"
        else { throw FoundationLibraryError.invalidResponse }
        // Jellyfin's audio-only StreamInfo may omit this optional URL field even
        // when requested. The caller has already verified exactly one unchanged
        // audio stream in the selected source. Keep that selection explicit.
        let indices = query.filter { $0.name.lowercased() == "audiostreamindex" }
        guard indices.count <= 1,
            indices.isEmpty || indices[0].value.flatMap(Int.init) == index
        else { throw FoundationLibraryError.invalidResponse }
        if indices.isEmpty {
            components.queryItems =
                query + [URLQueryItem(name: "AudioStreamIndex", value: String(index))]
        }
        guard let result = components.string else { throw FoundationLibraryError.invalidResponse }
        return result
    }

    private static func decodePlaybackMetadata(_ data: Data) throws -> BaseItemDto {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: text) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: text) else {
                throw FoundationLibraryError.invalidResponse
            }
            return value
        }
        return try decoder.decode(BaseItemDto.self, from: data)
    }

    static func hlsCopyReason(_ audio: MediaStream) -> String {
        guard let codec = audio.codec?.lowercased(),
            ["mp3", "aac", "flac", "alac"].contains(codec)
        else { return "unsupportedCodec" }
        guard let bitrate = audio.bitRate, bitrate > 0,
            let rate = audio.sampleRate, rate > 0,
            let channels = audio.channels, channels > 0
        else { return "unknownMetadata" }
        guard bitrate <= 50_000_000, rate <= 192_000, channels <= 8,
            codec != "mp3" || (bitrate <= 320_000 && rate <= 48_000 && channels <= 2)
        else { return "sourceLimits" }
        if ["flac", "alac"].contains(codec) {
            guard let depth = audio.bitDepth else { return "unknownMetadata" }
            guard (1...24).contains(depth) else { return "bitDepth" }
        }
        if codec == "aac" {
            guard let profile = audio.profile?.lowercased(),
                ["lc", "he-aac", "he-aacv2", "he-aac v2", "he", "hev2"].contains(profile)
            else { return "aacProfile" }
        }
        return "compatible"
    }

    static func hlsCopyCodec(_ audio: MediaStream) -> String? {
        hlsCopyReason(audio) == "compatible" ? audio.codec?.lowercased() : nil
    }

    static func hlsMP3CopyMaster(_ raw: String, audio: MediaStream) throws
        -> URLComponents
    {
        try hlsCopyMaster(raw, audio: audio, codec: "mp3", container: "ts")
    }

    static func hlsMP3CopyURL(
        _ data: Data, itemID: String, sourceID: String, serverSession: String,
        base: URL, token: String, deviceID: String
    ) throws -> URL {
        try hlsCopyURL(
            data, container: "ts", itemID: itemID, sourceID: sourceID,
            serverSession: serverSession, base: base, token: token, deviceID: deviceID)
    }

    /// Called only after route/session validation. Audio-only HLS does not automatically
    /// select copy on every server version; request it explicitly without bypassing limits.
    static func hlsCopyMaster(
        _ raw: String, audio: MediaStream, codec: String, container: String
    ) throws -> URLComponents {
        func reject(_ reason: String) -> FoundationLibraryError {
            #if DEBUG
                FoundationJournal.shared.record(
                    "player.hls.copy outcome=rejected stage=masterConstraints reason=\(reason)")
            #endif
            return .unavailable
        }
        guard var master = URLComponents(string: raw),
            Self.hlsCopyCodec(audio) == codec, let bitrate = audio.bitRate
        else { throw reject("source") }
        var query = master.queryItems ?? []
        func value(_ key: String, required: Bool = false) throws -> String? {
            let matches = query.filter { $0.name.lowercased() == key }
            guard matches.count <= 1, !required || matches.count == 1,
                matches.isEmpty || matches[0].value?.isEmpty == false
            else { throw reject("ambiguousLimit") }
            return matches.first?.value
        }
        guard let codec = try value("audiocodec", required: true),
            [audio.codec?.lowercased(), "copy"].contains(codec.lowercased()),
            try value("segmentcontainer", required: true)?.lowercased() == container
        else { throw reject("format") }
        for key in ["allowaudiostreamcopy", "enableautostreamcopy"] {
            if let flag = try value(key), flag.lowercased() != "true" {
                throw reject("copyDisabled")
            }
        }
        func limit(_ key: String, source: Int?, exact: Bool = false, required: Bool = false)
            throws
        {
            guard let raw = try value(key, required: required) else { return }
            guard let bound = Int(raw), bound > 0, let source, source > 0,
                exact ? source == bound : source <= bound
            else { throw reject(key) }
        }
        try limit("audiobitrate", source: bitrate, required: true)
        try limit("maxstreamingbitrate", source: bitrate)
        try limit("audiosamplerate", source: audio.sampleRate, exact: true)
        try limit("audiochannels", source: audio.channels, exact: true)
        try limit("maxaudiochannels", source: audio.channels)
        try limit("transcodingmaxaudiochannels", source: audio.channels)
        try limit("audiobitdepth", source: audio.bitDepth, exact: true)
        try limit("maxaudiobitdepth", source: audio.bitDepth)
        if let rawIndex = try value("audiostreamindex") {
            guard let index = Int(rawIndex), index >= 0, audio.index == index else {
                throw reject("audioStreamIndex")
            }
        }
        // Jellyfin includes this encoding preference even for copy requests.
        // The audio copy branch ignores it; preserve a valid negotiated boolean.
        if let flag = try value("enableaudiovbrencoding"),
            !["true", "false"].contains(flag.lowercased())
        {
            throw reject("audioVbrEncoding")
        }
        let understood = Set([
            "audiocodec", "allowaudiostreamcopy", "audiobitrate", "audiosamplerate",
            "audiochannels", "maxaudiochannels", "audiobitdepth", "maxaudiobitdepth",
            "audiostreamindex", "enableaudiovbrencoding", "transcodingmaxaudiochannels",
        ])
        guard
            !query.contains(where: {
                $0.name.lowercased().contains("audio")
                    && !understood.contains($0.name.lowercased())
            })
        else { throw reject("unknownAudioConstraint") }
        // Preserve every negotiated limit and identity; replace only the codec decision.
        let index = query.firstIndex { $0.name.lowercased() == "audiocodec" }!
        query[index].value = "copy"
        master.queryItems = query
        #if DEBUG
            FoundationJournal.shared.record("player.hls.copy.master outcome=explicitCopy")
        #endif
        return master
    }

    /// A copy-only experiment: reject alternative renditions and any encoding decision.
    /// The resolved child is handed to AVPlayer so a second master fetch cannot choose encoding.
    static func hlsCopyURL(
        _ data: Data, container: String, audio: MediaStream? = nil, codec: String = "mp3",
        itemID: String, sourceID: String, serverSession: String,
        base: URL, token: String, deviceID: String
    ) throws -> URL {
        guard data.count <= 65_536, let text = String(data: data, encoding: .utf8) else {
            throw FoundationLibraryError.invalidResponse
        }
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let variants = lines.filter { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        let paths = lines.filter { !$0.hasPrefix("#") }
        guard lines.first == "#EXTM3U", variants.count == 1, paths.count == 1,
            !lines.contains(where: {
                $0.hasPrefix("#EXT-X-MEDIA:") || $0.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
                    || ($0.hasPrefix("#") && $0.uppercased().contains("URI="))
            }),
            let child = URLComponents(string: paths[0]), child.scheme == nil,
            child.host == nil, child.fragment == nil, child.user == nil, child.password == nil,
            child.percentEncodedPath == "main.m3u8"
        else { throw FoundationLibraryError.invalidResponse }
        let query = child.queryItems ?? []
        // Only fixed categories and parsed numbers; never emit arbitrary server query values.
        #if DEBUG
            for key in [
                "audiocodec", "segmentcontainer", "allowaudiostreamcopy", "enableautostreamcopy",
            ] {
                let matches = query.filter { $0.name.lowercased() == key }
                let raw = matches.first?.value?.lowercased()
                let known = ["copy", "mp3", "aac", "mp4", "ts", "true", "false"]
                let decision = raw.map { known.contains($0) ? $0 : "other" } ?? "missing"
                FoundationJournal.shared.record(
                    "player.hls.copy.decision field=\(key) value=\(decision) count=\(matches.count)"
                )
            }
            for key in ["audiobitrate", "audiosamplerate", "audiochannels", "maxaudiochannels"] {
                let matches = query.filter { $0.name.lowercased() == key }
                let number = matches.first?.value.flatMap(Int.init) ?? -1
                FoundationJournal.shared.record(
                    "player.hls.copy.limit field=\(key) value=\(number) count=\(matches.count)")
            }
        #endif
        for (key, value) in [("audiocodec", "copy"), ("segmentcontainer", container)] {
            let matches = query.filter { $0.name.lowercased() == key }
            guard matches.count == 1, matches[0].value == value else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "player.hls.copy outcome=rejected stage=serverDecision field=\(key)")
                #endif
                throw FoundationLibraryError.unavailable
            }
        }
        // Reuse the negotiated route and exact session/source/device checks.
        var route = child
        route.percentEncodedPath = "/audio/\(itemID)/master.m3u8"
        if let audio {
            _ = try hlsCopyMaster(
                route.string ?? "", audio: audio, codec: codec, container: container)
        }
        let validated = try hlsURL(
            route.string ?? "", itemID: itemID, sourceID: sourceID,
            serverSession: serverSession,
            base: base, token: token, deviceID: deviceID)
        guard var result = URLComponents(url: validated, resolvingAgainstBaseURL: false) else {
            throw FoundationLibraryError.invalidResponse
        }
        result.percentEncodedPath =
            String(result.percentEncodedPath.dropLast("master.m3u8".count)) + "main.m3u8"
        guard let url = result.url else { throw FoundationLibraryError.invalidResponse }
        #if DEBUG
            FoundationJournal.shared.record("player.hls.copy outcome=validated")
        #endif
        return url
    }

    /// Accept only the negotiated API-relative audio playlist, retaining the reverse-proxy base.
    static func hlsURL(
        _ raw: String, itemID: String, sourceID: String, serverSession: String,
        base: URL, token: String, deviceID: String
    ) throws -> URL {
        guard let returned = URLComponents(string: raw),
            returned.scheme == nil, returned.host == nil, returned.user == nil,
            returned.password == nil, returned.fragment == nil,
            var result = URLComponents(
                url: try validatedServerURL(base), resolvingAgainstBaseURL: false)
        else { throw FoundationLibraryError.invalidResponse }
        // Jellyfin's StreamInfo formats ItemId as a GUID in the route, while
        // catalog identifiers may be compact. Compare identity, not spelling.
        // Keep exact route boundaries; encoded paths and traversal remain invalid.
        let pathParts = returned.percentEncodedPath.split(
            separator: "/", omittingEmptySubsequences: false)
        guard pathParts.count == 4, pathParts[0].isEmpty,
            pathParts[1].lowercased() == "audio",
            pathParts[3].lowercased() == "master.m3u8",
            Self.validID(itemID), Self.validID(String(pathParts[2])),
            pathParts[2].replacingOccurrences(of: "-", with: "").lowercased()
                == itemID.replacingOccurrences(of: "-", with: "").lowercased()
        else {
            #if DEBUG
                FoundationJournal.shared.record(
                    "player.hls.negotiation outcome=rejected stage=playlistRoute")
            #endif
            throw FoundationLibraryError.invalidResponse
        }
        #if DEBUG
            FoundationJournal.shared.record("player.hls.playlist outcome=validated")
        #endif
        var query = returned.queryItems ?? []
        for (key, expected) in [
            ("playsessionid", serverSession), ("mediasourceid", sourceID),
            ("deviceid", deviceID),
        ] {
            let values = query.filter { $0.name.lowercased() == key }
            guard values.count == 1, values.first?.value == expected else {
                #if DEBUG
                    FoundationJournal.shared.record(
                        "player.hls.negotiation outcome=rejected stage=identity field=\(key) count=\(values.count)"
                    )
                #endif
                throw FoundationLibraryError.invalidResponse
            }
        }
        // Do not forward a server-supplied credential or accept ambiguous authentication keys.
        query.removeAll {
            $0.name.lowercased() == "api_key" || $0.name.lowercased() == "apikey"
        }
        query.append(URLQueryItem(name: "ApiKey", value: token))
        var path = result.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        result.percentEncodedPath = path + returned.percentEncodedPath
        result.queryItems = query
        guard let url = result.url else { throw FoundationLibraryError.invalidResponse }
        return url
    }

    // Compatibility URL-only helper; live playback uses playbackResource to retain its HLS lease.
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

    func retryArtwork(for item: FoundationItem) async {
        await artworkCache?.clearFailures(for: item)
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
                    FoundationCurrentArtwork.decode($0, maximumPixels: min(2048, max(1, size)))
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
        let pixels = min(2048, max(1, size))
        return try await responseData(
            Paths.getItemImage(
                itemID: item.id, imageType: item.resolvedArtworkRole.jellyfinImageType,
                parameters: .init(
                    maxWidth: pixels, maxHeight: pixels, tag: tag,
                    format: item.resolvedArtworkRole == .logo ? .png : .jpg)),
            accept: item.resolvedArtworkRole == .logo ? "image/png" : "image/jpeg",
            allowsCellular: allowsCellular)
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
                logoImageTag: kind == .artist ? entry.imageTags?["Logo"] : nil,
                backdropImageTag: kind == .artist ? entry.backdropImageTags?.first : nil,
                isFavorite: kind == .genre ? nil : entry.userData?.isFavorite,
                album: album, artist: artist,
                genres: (entry.genreItems ?? []).compactMap { reference in
                    guard let id = reference.id, Self.validID(id), let title = reference.name,
                        !title.isEmpty
                    else { return nil }
                    return FoundationItemReference(id: id, title: title)
                }, playCount: max(0, entry.userData?.playCount ?? 0), sortName: entry.sortName,
                playlistEntryID: entry.playlistItemID,
                trackNumber: entry.indexNumber, discNumber: entry.parentIndexNumber)
        }
    }

    private func send<Response: Decodable>(_ endpoint: Request<Response>) async throws -> Response {
        #if DEBUG
            let timing = FoundationLoadTiming.current ?? FoundationLoadTiming(.catalog)
            timing.record(.requestStarted)
        #endif
        let data = try await responseData(endpoint)
        #if DEBUG
            timing.record(.responseReceived)
            timing.record(.decodeStarted)
        #endif
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
            let value = try decoder.decode(Response.self, from: data)
            #if DEBUG
                timing.record(.decodeFinished)
            #endif
            return value
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
            case "GetLatestMedia": return "recentMusicSuggestions"
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
        notFoundIsEmpty: Bool = false, allowsCellular: Bool? = nil, loadOverride: Load? = nil
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
                    if let loadOverride { return try await loadOverride(request) }
                    return try await admittedLoad(request)
                } onCancel: {
                    FoundationJournal.shared.record(
                        "api operation=\(operationID) purpose=\(purpose) \(traceFields) event=cancellationRequested"
                    )
                }
            #else
                // Playback preparation and exact-session cleanup retain their explicit
                // transports in Release too; neither waits behind optional browsing.
                let data: Data
                let response: URLResponse
                if let loadOverride {
                    (data, response) = try await loadOverride(request)
                } else {
                    (data, response) = try await admittedLoad(request)
                }
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

    /// Only catalog/artwork reads participate. Authentication, writes and native audio do not.
    private func admittedLoad(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard request.httpMethod == "GET" else { return try await load(request) }
        let permit = try await networkAdmission.acquire()
        do {
            try Task.checkCancellation()
            let response = try await load(request)
            await networkAdmission.release(permit)
            return response
        } catch {
            await networkAdmission.release(permit)
            throw error
        }
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

/// At most ten interleaved candidates for five visible cards, not complete membership.
/// Keep explicit false DTOs for reconciliation; presentation filters them after observation.
/// Never use absence here to infer unfavorite.
func foundationFavoriteCollectionsPreview(albums: FoundationPage, playlists: FoundationPage)
    -> FoundationPage
{
    let albumCandidates = Array(albums.items.filter { $0.kind == .album }.prefix(5))
    let playlistCandidates = Array(playlists.items.filter { $0.kind == .playlist }.prefix(5))
    let albums = albumCandidates.filter { $0.isFavorite != false }
    let playlists = playlistCandidates.filter { $0.isFavorite != false }
    var items: [FoundationItem] = []
    for index in 0..<max(albums.count, playlists.count) {
        if albums.indices.contains(index) { items.append(albums[index]) }
        if playlists.indices.contains(index) { items.append(playlists[index]) }
    }
    // Reconcile rejected candidates too, without letting them displace the mixed preview.
    items.append(
        contentsOf: (albumCandidates + playlistCandidates).filter { $0.isFavorite == false })
    return FoundationPage(items: items, nextStartIndex: nil)
}

extension FoundationItem.ArtworkRole {
    fileprivate var jellyfinImageType: String {
        switch self {
        case .primary: "Primary"
        case .logo: "Logo"
        case .backdrop: "Backdrop"
        }
    }
}

/// Intent is explicit and independent of screen, Swift task priority or debug tracing.
enum FoundationRequestIntent {
    @TaskLocal static var isPlayback = false
    @TaskLocal static var artworkJob: UUID?
}

/// Account-owned admission of optional reads. Streams never enter this owner.
actor FoundationNetworkAdmission {
    private struct Waiter {
        let id: UUID
        let job: UUID?
        let playback: Bool
        let continuation: CheckedContinuation<UUID, Error>
    }
    private let limit: Int
    private var waiters: [Waiter] = []
    private var active: [UUID: Bool] = [:]
    private var promotedArtwork: Set<UUID> = []
    private var protectedPlayback = false
    private var stateRevision: UInt = 0
    private var live = true

    init(limit: Int = 6) { self.limit = max(2, limit) }

    func updatePlaybackProtection(_ protected: Bool, revision: UInt) {
        guard live, revision >= stateRevision else { return }
        stateRevision = revision
        protectedPlayback = protected
        pump()
    }

    func promoteArtwork(_ id: UUID) {
        guard live else { return }
        promotedArtwork.insert(id)
        pump()
    }

    func finishArtwork(_ id: UUID) { promotedArtwork.remove(id) }

    func acquire() async throws -> UUID {
        try Task.checkCancellation()
        guard live else { throw CancellationError() }
        let id = UUID()
        let job = FoundationRequestIntent.artworkJob
        let playback = FoundationRequestIntent.isPlayback
        let permit = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(
                    Waiter(id: id, job: job, playback: playback, continuation: continuation))
                pump()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Cancellation can race with admission. Release a granted slot before throwing.
        if Task.isCancelled {
            release(permit)
            throw CancellationError()
        }
        guard live else {
            release(permit)
            throw CancellationError()
        }
        return permit
    }

    func release(_ id: UUID) {
        active.removeValue(forKey: id)
        pump()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func isProtected(_ waiter: Waiter) -> Bool {
        waiter.playback || waiter.job.map { promotedArtwork.contains($0) } == true
    }

    private func pump() {
        while live, active.count < limit {
            // Reserve one slot for playback-related reads, even during normal browsing.
            let browseLimit = protectedPlayback ? 1 : limit - 1
            let browseCount = active.values.filter { !$0 }.count
            let index =
                waiters.firstIndex(where: isProtected)
                ?? (browseCount < browseLimit ? waiters.startIndex : nil)
            guard let index, waiters.indices.contains(index) else { return }
            let waiter = waiters.remove(at: index)
            active[waiter.id] = isProtected(waiter)
            waiter.continuation.resume(returning: waiter.id)
        }
    }

    func retire() {
        live = false
        let abandoned = waiters
        waiters.removeAll()
        promotedArtwork.removeAll()
        for waiter in abandoned { waiter.continuation.resume(throwing: CancellationError()) }
    }

    #if DEBUG
        var pendingCount: Int { waiters.count }
        var activeCount: Int { active.count }
    #endif
}
