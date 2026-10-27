import Foundation

/// A complete metadata census, not a media download or an opportunistic browse sample.
/// App integration must give this actor one account/library lifetime and explicitly
/// supply genre coverage from a dedicated Fields.Genres response.
actor FoundationPrimaryGenreIndex {
    static let currentPolicyVersion = 2
    struct Scope: Equatable, Codable, Sendable {
        let source: FoundationCatalogSource
        let libraryID: String?
        let policyVersion: Int

        init(source: FoundationCatalogSource, libraryID: String?) {
            self.source = source
            self.libraryID = libraryID
            policyVersion = FoundationPrimaryGenreIndex.currentPolicyVersion
        }
    }

    struct Generation: Equatable, Sendable {
        fileprivate let scope: Scope
        fileprivate let revision: UUID
    }

    struct Song: Sendable {
        let id: String
        /// Nil means unknown/omitted coverage; [] means explicitly untagged.
        let genreIDs: [String]?
    }

    struct Page: Sendable {
        let startIndex: Int
        let total: Int
        let songs: [Song]
        let nextStartIndex: Int?
    }

    struct Snapshot: Equatable, Codable, Sendable {
        let scope: Scope
        let songCount: Int
        let censusID: UUID
        let completedAt: Date
        let songCountsByGenre: [String: Int]
        let eligibleGenreIDs: Set<String>
        let primaryBySongID: [String: [String]]
        let orderedSongIDs: [String]

        /// Nil is unresolved metadata, not an empty or zero-frequency genre list.
        /// This projection never alters the song's original genre references.
        func primaryGenreIDs(for rawIDs: [String]?) -> [String]? {
            guard let rawIDs else { return nil }
            let ids = Set(rawIDs)
            guard ids.allSatisfy({ songCountsByGenre[$0] != nil }) else { return nil }
            return Self.select(ids, counts: songCountsByGenre)
        }

        fileprivate static func select(_ ids: Set<String>, counts: [String: Int]) -> [String] {
            Array(
                ids.sorted {
                    let left = counts[$0]!
                    let right = counts[$1]!
                    return left == right ? $0 < $1 : left > right
                }.prefix(2))
        }
    }

    struct Limits: Sendable {
        var pages = 1_000
        var songsPerPage = 200
        var songs = 50_000
        var genres = 4_096
        var genreSets = 16_384
        var genreReferences = 500_000
        var genresPerSong = 128
        var identifierBytes = 16 * 1_024 * 1_024
        var identifierBytesPerValue = 256
    }

    enum Failure: Error, Equatable {
        case stale, invalidPage, unknownMetadata, duplicateSong, resourceLimit, incomplete
    }

    private struct GenreSet: Hashable { let ids: [String] }
    private struct Candidate {
        let generation: Generation
        var pages = 0
        var total: Int?
        var songSetIndices: [String: Int] = [:]
        var orderedSongIDs: [String] = []
        var counts: [String: Int] = [:]
        var genreSetIndices: [GenreSet: Int] = [:]
        var genreSets: [GenreSet] = []
        var references = 0
        var identifierBytes = 0
        var ended = false
    }

    private let limits: Limits
    private var generation: Generation?
    private var candidate: Candidate?
    private var completed: Snapshot?
    private var retired = false

    init(limits: Limits = Limits()) { self.limits = limits }

    func begin(scope: Scope) throws -> Generation {
        guard !retired else { throw Failure.stale }
        if completed?.scope != scope { completed = nil }
        let next = Generation(scope: scope, revision: UUID())
        generation = next
        candidate = Candidate(generation: next)
        return next
    }

    /// Work from another scope/generation can neither publish nor cancel its replacement.
    func append(_ page: Page, generation token: Generation) throws {
        guard !retired, generation == token, var work = candidate else { throw Failure.stale }
        candidate = nil  // Transfer the dictionaries; do not force a copy-on-write clone each page.
        do {
            try Task.checkCancellation()
            guard page.total <= limits.songs, work.pages < limits.pages,
                page.songs.count <= limits.songsPerPage
            else { throw Failure.resourceLimit }
            work.pages += 1
            guard !work.ended, page.total >= 0,
                page.startIndex == work.songSetIndices.count,
                work.total == nil || work.total == page.total,
                page.songs.count <= page.total - page.startIndex
            else { throw Failure.invalidPage }
            work.total = page.total
            for song in page.songs {
                try Task.checkCancellation()
                guard validIdentifier(song.id) else { throw Failure.resourceLimit }
                guard work.songSetIndices[song.id] == nil else { throw Failure.duplicateSong }
                guard let raw = song.genreIDs else { throw Failure.unknownMetadata }
                guard raw.count <= limits.genresPerSong, raw.allSatisfy(validIdentifier) else {
                    throw Failure.resourceLimit
                }
                let ids = Set(raw)
                work.references += ids.count
                work.identifierBytes += song.id.utf8.count + ids.reduce(0) { $0 + $1.utf8.count }
                guard work.references <= limits.genreReferences,
                    work.identifierBytes <= limits.identifierBytes
                else { throw Failure.resourceLimit }
                for id in ids { work.counts[id, default: 0] += 1 }
                let key = GenreSet(ids: ids.sorted())
                let setIndex: Int
                if let existing = work.genreSetIndices[key] {
                    setIndex = existing
                } else {
                    setIndex = work.genreSets.count
                    work.genreSetIndices[key] = setIndex
                    work.genreSets.append(key)
                }
                work.songSetIndices[song.id] = setIndex
                work.orderedSongIDs.append(song.id)
                guard work.counts.count <= limits.genres,
                    work.genreSets.count <= limits.genreSets
                else { throw Failure.resourceLimit }
            }
            let end = work.songSetIndices.count
            if let next = page.nextStartIndex {
                guard next == end, end > page.startIndex, end < page.total else {
                    throw Failure.invalidPage
                }
            } else {
                guard end == page.total else { throw Failure.incomplete }
                work.ended = true
            }
            candidate = work
        } catch {
            candidate = nil
            throw error
        }
    }

    func finish(generation token: Generation) throws -> Snapshot {
        guard !retired, generation == token, let work = candidate else { throw Failure.stale }
        if Task.isCancelled {
            candidate = nil
            throw CancellationError()
        }
        guard work.ended, work.total == work.songSetIndices.count else { throw Failure.incomplete }
        var eligible: Set<String> = []
        var choices: [[String]] = []
        var primaryBySongID: [String: [String]] = [:]
        do {
            for key in work.genreSets {
                try Task.checkCancellation()
                let selected = Snapshot.select(Set(key.ids), counts: work.counts)
                choices.append(selected)
                eligible.formUnion(selected)
            }
            for (songID, setIndex) in work.songSetIndices {
                try Task.checkCancellation()
                primaryBySongID[songID] = choices[setIndex]
            }
        } catch {
            candidate = nil
            throw error
        }
        let result = Snapshot(
            scope: token.scope, songCount: work.songSetIndices.count,
            censusID: token.revision, completedAt: Date(),
            songCountsByGenre: work.counts, eligibleGenreIDs: eligible,
            primaryBySongID: primaryBySongID, orderedSongIDs: work.orderedSongIDs)
        completed = result
        candidate = nil
        return result
    }

    func snapshot(for scope: Scope) -> Snapshot? {
        guard !retired, completed?.scope == scope else { return nil }
        return completed
    }

    func cancel(generation token: Generation) {
        guard generation == token else { return }
        candidate = nil
        generation = nil
    }

    /// Retirement is terminal; late pages, new requests and cached data are rejected.
    func retire() {
        retired = true
        candidate = nil
        generation = nil
        completed = nil
    }

    private func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= limits.identifierBytesPerValue
    }
}
