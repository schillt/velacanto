import Combine
import Foundation

/// Shared account/library owner. Only an explicit start schedules network reads.
@MainActor
final class FoundationPrimaryGenresModel: ObservableObject {
    @Published private(set) var record: FoundationPrimaryGenreRecord?
    @Published private(set) var readySongIDs: Set<String> = []
    @Published private(set) var isBuilding = false
    @Published private(set) var processedSongs = 0
    @Published private(set) var totalSongs: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var publicationRevision = 0

    private var library: any FoundationLibrary
    private var scope: FoundationPrimaryGenreIndex.Scope?
    private var index = FoundationPrimaryGenreIndex()
    private var job: Task<Void, Never>?
    private var operationID = UUID()
    private var permit = FoundationPageWritePermit()
    private var restoreID = UUID()
    private var restored = false
    private weak var boundDownloads: FoundationDownloads?
    private var downloadObservation: AnyCancellable?
    private var downloadBindingID = UUID()

    init(library: any FoundationLibrary) {
        self.library = library
        scope = library.primaryGenreIndexScope
    }

    deinit {
        job?.cancel()
        permit.revoke()
    }

    var isSupported: Bool { scope != nil }
    var buildCompletion: Task<Void, Never>? { job }

    func bind(_ library: any FoundationLibrary) {
        let next = library.primaryGenreIndexScope
        if next?.source != scope?.source { bindDownloads(nil) }
        if next != scope {
            cancel()
            let departing = index
            index = FoundationPrimaryGenreIndex()
            scope = next
            record = nil
            errorMessage = nil
            restored = false
            restoreID = UUID()
            publicationRevision += 1
            Task { await departing.retire() }
        }
        self.library = library
    }

    func configure(_ library: any FoundationLibrary) async {
        bind(library)
        await restoreBoundCache()
    }

    func restoreBoundCache() async {
        let library = library
        guard !restored, let scope else { return }
        restored = true
        let owner = restoreID
        do {
            let saved = try await library.catalogPageCache?.readPrimaryGenres(
                key: library.catalogCacheKey("primary-genres-v\(scope.policyVersion)"), scope: scope
            )
            guard owner == restoreID, self.scope == scope, !isBuilding else { return }
            if let saved {
                record = saved
                publicationRevision += 1
            }
        } catch {
            guard owner == restoreID, self.scope == scope else { return }
            errorMessage = "The saved primary genre index could not be read. Build it again."
        }
    }

    func start() {
        guard !isBuilding, let scope else { return }
        let owner = UUID()
        operationID = owner
        restoreID = UUID()
        permit.revoke()
        permit = FoundationPageWritePermit()
        let writePermit = permit
        let library = library
        let index = index
        errorMessage = nil
        processedSongs = 0
        totalSongs = nil
        isBuilding = true
        job = Task { [weak self] in
            guard let self else { return }
            var token: FoundationPrimaryGenreIndex.Generation?
            do {
                let generation = try await index.begin(scope: scope)
                token = generation
                var descriptors: [String: FoundationItem] = [:]
                var offset = 0
                var requestedPages = 0
                let maximumPages = FoundationPrimaryGenreIndex.Limits().pages
                while true {
                    try Task.checkCancellation()
                    guard requestedPages < maximumPages else {
                        throw FoundationPrimaryGenreIndex.Failure.resourceLimit
                    }
                    requestedPages += 1
                    let page = try await library.primaryGenreMetadataPage(startIndex: offset)
                    try Task.checkCancellation()
                    guard self.operationID == owner, self.scope == scope else { return }
                    let songs = page.songs.map {
                        FoundationPrimaryGenreIndex.Song(id: $0.id, genreIDs: $0.genres.map(\.id))
                    }
                    try await index.append(
                        .init(
                            startIndex: page.startIndex, total: page.total, songs: songs,
                            nextStartIndex: page.nextStartIndex), generation: generation)
                    for song in page.songs {
                        for genre in song.genres {
                            if let old = descriptors[genre.id], old.title != genre.title {
                                throw FoundationPrimaryGenreIndex.Failure.invalidPage
                            }
                            descriptors[genre.id] = FoundationItem(
                                id: genre.id, title: genre.title, subtitle: "", kind: .genre,
                                duration: nil, catalogSource: scope.source)
                        }
                    }
                    guard self.operationID == owner, self.scope == scope else { return }
                    self.processedSongs += page.songs.count
                    self.totalSongs = page.total
                    guard let next = page.nextStartIndex else { break }
                    offset = next
                }
                let snapshot = try await index.finish(generation: generation)
                try Task.checkCancellation()
                guard self.operationID == owner, self.scope == scope else { return }
                let result = FoundationPrimaryGenreRecord(
                    snapshot: snapshot,
                    descriptors: descriptors.values.map { item in
                        var canonical = item
                        canonical.primaryGenreCensusID = snapshot.censusID
                        return canonical
                    }.sorted { $0.id < $1.id })
                guard result.isValid(for: scope) else {
                    throw FoundationPrimaryGenreIndex.Failure.unknownMetadata
                }
                self.record = result
                self.publicationRevision += 1
                if let cache = library.catalogPageCache {
                    do {
                        try await cache.writePrimaryGenres(
                            result,
                            key: library.catalogCacheKey("primary-genres-v\(scope.policyVersion)"),
                            permit: writePermit)
                    } catch {
                        guard self.operationID == owner, self.scope == scope else { return }
                        self.errorMessage =
                            "Primary genres are ready, but this index could not be saved."
                    }
                }
            } catch {
                if let token { await index.cancel(generation: token) }
                guard self.operationID == owner, self.scope == scope else { return }
                if !Task.isCancelled {
                    self.errorMessage = Self.message(for: error, hasPrevious: self.record != nil)
                }
            }
            guard self.operationID == owner else { return }
            self.isBuilding = false
            self.job = nil
        }
    }

    func cancel() {
        operationID = UUID()
        permit.revoke()
        job?.cancel()
        job = nil
        isBuilding = false
    }

    func retire() {
        bindDownloads(nil)
        cancel()
        record = nil
        readySongIDs = []
        scope = nil
        restoreID = UUID()
        restored = false
        let departing = index
        Task { await departing.retire() }
    }

    func page(query: String = "", startIndex: Int = 0, limit: Int = 50, localOnly: Bool)
        -> FoundationPage
    {
        guard let record else { return .init(items: [], nextStartIndex: nil) }
        let eligible: Set<String>? =
            localOnly
            ? Set(readySongIDs.flatMap { record.snapshot.primaryBySongID[$0] ?? [] }) : nil
        return record.page(
            query: query, startIndex: startIndex, limit: limit, eligibleIDs: eligible)
    }

    func items(query: String = "", localOnly: Bool) -> [FoundationItem] {
        guard let record else { return [] }
        let eligible: Set<String>? =
            localOnly
            ? Set(readySongIDs.flatMap { record.snapshot.primaryBySongID[$0] ?? [] }) : nil
        return record.matchingItems(query: query, eligibleIDs: eligible)
    }

    /// Observe only catalog metadata and verified ready membership, never transfer progress.
    func bindDownloads(_ downloads: FoundationDownloads?) {
        if let downloads, boundDownloads === downloads { return }
        downloadObservation = nil
        downloadBindingID = UUID()
        boundDownloads = downloads
        guard let downloads else {
            if !readySongIDs.isEmpty { readySongIDs = [] }
            return
        }
        let binding = downloadBindingID
        downloadObservation = Publishers.Merge(
            downloads.$catalogRevision, downloads.$verifiedReadyRevision
        ).sink { [weak self, weak downloads] _ in
            // Published revisions emit before their synchronous readiness transaction finishes.
            Task { @MainActor [weak self, weak downloads] in
                guard let self, let downloads, self.downloadBindingID == binding,
                    self.boundDownloads === downloads
                else { return }
                self.updateDownloads(downloads.downloadedSongs)
            }
        }
    }

    func updateDownloads(_ songs: [FoundationItem]) {
        let valid = songs.filter { $0.catalogSource == nil || $0.catalogSource == scope?.source }
        let next = Set(valid.map(\.id))
        if next != readySongIDs { readySongIDs = next }
    }

    var offlineErrorMessage: String? {
        let unresolved = readySongIDs.contains { record?.snapshot.primaryBySongID[$0] == nil }
        return unresolved
            ? "Some downloaded songs are not in this index. Connect and refresh primary genres."
            : nil
    }

    /// Only this account and selected library can project the completed census.
    func completedRecord(libraryScope: FoundationPrimaryGenreIndex.Scope?)
        -> FoundationPrimaryGenreRecord?
    {
        guard let scope, libraryScope == scope, let record, record.snapshot.scope == scope else {
            return nil
        }
        return record
    }

    /// A saved pin stores history, not census authority. Resolve its native ID afresh on every open.
    func resolvePinnedGenre(
        _ saved: FoundationItem, libraryScope: FoundationPrimaryGenreIndex.Scope?
    ) -> FoundationItem? {
        guard saved.kind == .genre, let record = completedRecord(libraryScope: libraryScope),
            saved.catalogSource == nil || saved.catalogSource == record.snapshot.scope.source,
            record.snapshot.eligibleGenreIDs.contains(saved.id)
        else { return nil }
        return record.descriptors.first { $0.id == saved.id }
    }

    func canonicalRecord(
        for genre: FoundationItem, libraryScope: FoundationPrimaryGenreIndex.Scope?
    ) -> FoundationPrimaryGenreRecord? {
        guard genre.kind == .genre, let record = completedRecord(libraryScope: libraryScope),
            genre.catalogSource == record.snapshot.scope.source,
            genre.primaryGenreCensusID == record.snapshot.censusID,
            record.snapshot.eligibleGenreIDs.contains(genre.id),
            record.descriptors.contains(genre)
        else { return nil }
        return record
    }

    /// Genre content observes the primary owner rather than subscribing to transfer progress.
    func readySongs(
        for genre: FoundationItem, libraryScope: FoundationPrimaryGenreIndex.Scope?
    ) -> [FoundationItem] {
        guard let record = canonicalRecord(for: genre, libraryScope: libraryScope),
            let downloads = boundDownloads
        else { return [] }
        return record.readySongs(
            membershipIDs: record.songIDs(for: genre.id), from: downloads.downloadedSongs)
    }

    func primaryGenreTitles(for item: FoundationItem) -> [String]? {
        guard item.catalogSource == nil || item.catalogSource == scope?.source,
            let record, let ids = record.snapshot.primaryBySongID[item.id]
        else { return nil }
        let titles = Dictionary(uniqueKeysWithValues: record.descriptors.map { ($0.id, $0.title) })
        return ids.compactMap { titles[$0] }
    }

    private static func message(for error: Error, hasPrevious: Bool) -> String {
        let retained =
            hasPrevious
            ? " The previous complete index is still in use." : " No partial index was saved."
        switch error as? FoundationPrimaryGenreIndex.Failure {
        case .resourceLimit:
            return "This library exceeds the primary genre indexing limits." + retained
        case .unknownMetadata:
            return "Some song tags were unavailable." + retained
        case .duplicateSong, .invalidPage, .incomplete:
            return
                "The library changed or returned incomplete pages. Refresh primary genres to try again."
                + retained
        default:
            return "Primary genres could not be updated." + retained
        }
    }
}
