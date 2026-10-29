import Foundation

/// Dedicated metadata census payload. No media URLs, artwork or entire track DTOs survive decoding.
struct FoundationPrimaryGenreMetadataPage: Sendable {
    struct Song: Sendable {
        let id: String
        let genres: [FoundationItemReference]
        var content: FoundationPrimaryGenreContentMetadata? = nil
    }
    let startIndex: Int
    let total: Int
    let songs: [Song]
    let nextStartIndex: Int?
}

/// One atomically published descriptor map and its complete-census policy result.
struct FoundationPrimaryGenreRecord: Equatable, Codable, Sendable {
    let snapshot: FoundationPrimaryGenreIndex.Snapshot
    let descriptors: [FoundationItem]
    /// Optional for records saved by earlier app versions. Persisted only after a complete census.
    let builtWithAppVersion: String?
    /// A completed attempt is recorded even when a provider cannot supply content metadata.
    let contentMetadataVersion: Int?
    let contentIndex: FoundationPrimaryGenreContentIndex?

    init(
        snapshot: FoundationPrimaryGenreIndex.Snapshot, descriptors: [FoundationItem],
        builtWithAppVersion: String? = nil, contentMetadataVersion: Int? = nil,
        contentIndex: FoundationPrimaryGenreContentIndex? = nil
    ) {
        self.snapshot = snapshot
        self.descriptors = descriptors
        self.builtWithAppVersion = builtWithAppVersion
        self.contentMetadataVersion = contentMetadataVersion
        self.contentIndex = contentIndex
    }

    func page(
        query: String = "", startIndex: Int = 0, limit: Int = 50,
        eligibleIDs: Set<String>? = nil
    ) -> FoundationPage {
        guard startIndex >= 0, (1...200).contains(limit) else {
            return .init(items: [], nextStartIndex: nil)
        }
        let items = matchingItems(query: query, eligibleIDs: eligibleIDs)
        guard startIndex < items.count else { return .init(items: [], nextStartIndex: nil) }
        let end = startIndex + min(limit, items.count - startIndex)
        return .init(
            items: Array(items[startIndex..<end]), nextStartIndex: end < items.count ? end : nil)
    }

    func matchingItems(query: String = "", eligibleIDs: Set<String>? = nil) -> [FoundationItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return descriptors.filter {
            (eligibleIDs ?? snapshot.eligibleGenreIDs).contains($0.id)
                && (term.isEmpty || $0.title.localizedStandardContains(term))
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func songIDs(for genreID: String) -> [String] {
        snapshot.orderedSongIDs.filter { snapshot.primaryBySongID[$0]?.contains(genreID) == true }
    }

    /// A Home presentation cap never changes eligibility or per-song membership.
    func prominentGenres(limit: Int = 5, eligibleIDs: Set<String>? = nil) -> [FoundationItem] {
        guard limit > 0 else { return [] }
        return descriptors.compactMap { genre -> (item: FoundationItem, count: Int)? in
            guard snapshot.eligibleGenreIDs.contains(genre.id),
                eligibleIDs?.contains(genre.id) ?? true,
                let count = snapshot.songCountsByGenre[genre.id]
            else { return nil }
            return (genre, count)
        }.sorted {
            $0.count == $1.count ? $0.item.id < $1.item.id : $0.count > $1.count
        }.prefix(limit).map(\.item)
    }

    struct RecentGenre {
        let genre: FoundationItem
        let artwork: FoundationItem
    }

    /// Recent songs already loaded by New choose descriptors; album tags never classify membership.
    func recentGenres(
        songs: [FoundationItem], readySongIDs: Set<String>? = nil, limit: Int = 6
    ) -> [RecentGenre] {
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        var seen = Set<String>()
        var result: [RecentGenre] = []
        guard limit > 0 else { return result }
        for song in songs
        where song.kind == .track
            && (song.catalogSource == nil || song.catalogSource == snapshot.scope.source)
            && (readySongIDs?.contains(song.id) ?? true)
        {
            for id in snapshot.primaryBySongID[song.id] ?? [] {
                guard snapshot.eligibleGenreIDs.contains(id), seen.insert(id).inserted,
                    let genre = byID[id]
                else { continue }
                result.append(.init(genre: genre, artwork: song.catalogArtworkItem))
                if result.count == limit { return result }
            }
        }
        return result
    }

    /// Disk restoration is subject to the same bounds and source/policy checks as publication.
    func isValid(for scope: FoundationPrimaryGenreIndex.Scope) -> Bool {
        let limits = FoundationPrimaryGenreIndex.Limits()
        guard
            builtWithAppVersion.map({
                !$0.isEmpty && $0.utf8.count <= 128
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }) ?? true,
            snapshot.scope == scope,
            scope.policyVersion == FoundationPrimaryGenreIndex.currentPolicyVersion,
            snapshot.songCount >= 0, snapshot.songCount <= limits.songs,
            snapshot.primaryBySongID.count == snapshot.songCount,
            snapshot.orderedSongIDs.count == snapshot.songCount,
            Set(snapshot.orderedSongIDs).count == snapshot.songCount,
            Set(snapshot.orderedSongIDs) == Set(snapshot.primaryBySongID.keys),
            snapshot.primaryBySongID.allSatisfy({
                !$0.key.isEmpty && $0.key.utf8.count <= limits.identifierBytesPerValue
                    && $0.value.count <= 2 && Set($0.value).count == $0.value.count
                    && $0.value.allSatisfy { snapshot.songCountsByGenre[$0] != nil }
            }),
            Set(snapshot.primaryBySongID.values.flatMap { $0 }) == snapshot.eligibleGenreIDs,
            descriptors.count <= limits.genres,
            Set(descriptors.map(\.id)).count == descriptors.count,
            Set(descriptors.map(\.id)) == Set(snapshot.songCountsByGenre.keys),
            snapshot.eligibleGenreIDs.isSubset(of: Set(descriptors.map(\.id)))
        else { return false }
        guard
            contentMetadataVersion == nil
                || contentMetadataVersion == FoundationPrimaryGenreContentIndex.version,
            contentIndex.map({ $0.isValid(songIDs: Set(snapshot.orderedSongIDs)) }) ?? true,
            contentIndex == nil
                || contentMetadataVersion == FoundationPrimaryGenreContentIndex.version
        else { return false }
        return descriptors.allSatisfy {
            !$0.id.isEmpty && $0.id.utf8.count <= limits.identifierBytesPerValue
                && !$0.title.isEmpty && $0.title.utf8.count <= 512
                && $0.kind == .genre && $0.catalogSource == scope.source
                && $0.primaryGenreCensusID == snapshot.censusID
                && ($0.primaryImageTag == nil) && $0.genres.isEmpty
                && (snapshot.songCountsByGenre[$0.id] ?? -1) > 0
                && (snapshot.songCountsByGenre[$0.id] ?? Int.max) <= snapshot.songCount
        }
    }
}

/// Small ordering facts from the existing complete metadata census, never a track DTO or media URL.
struct FoundationPrimaryGenreContentMetadata: Equatable, Sendable {
    let title: String
    var album: FoundationItemReference? = nil
    var artist: FoundationItemReference? = nil
    var duration: Double? = nil
    var year: Int? = nil
    var dateAdded: Date? = nil
}

enum FoundationPrimaryGenreSort: String, CaseIterable, Identifiable, Sendable {
    case name = "Name"
    case album = "Album"
    case artist = "Artist"
    case duration = "Duration"
    case year = "Year"
    case dateAdded = "Date Added"
    var id: Self { self }

    func title(for kind: FoundationItem.Kind) -> String {
        self == .name && kind == .track ? "Title" : rawValue
    }
}

/// Names are normalized once per album/artist; tracks retain only relationship IDs.
struct FoundationPrimaryGenreContentIndex: Equatable, Codable, Sendable {
    static let version = 1
    static let maximumBytes = 8 * 1_024 * 1_024

    struct Track: Equatable, Codable, Sendable {
        let title: String
        let albumID: String?
        let artistID: String?
        let duration: Double?
        let year: Int?
        let dateAdded: Date?
    }

    let tracks: [String: Track]
    let albums: [String: String]
    let artists: [String: String]

    func supportedSorts(kind: FoundationItem.Kind, membership: [String])
        -> [FoundationPrimaryGenreSort]
    {
        guard kind == .track else { return [.name] }
        let values = membership.compactMap { tracks[$0] }
        return FoundationPrimaryGenreSort.allCases.filter { field in
            switch field {
            case .name: true
            case .album: values.contains { $0.albumID != nil }
            case .artist: values.contains { $0.artistID != nil }
            case .duration: values.contains { $0.duration != nil }
            case .year: values.contains { $0.year != nil }
            case .dateAdded: values.contains { $0.dateAdded != nil }
            }
        }
    }

    /// Filter and order the complete logical membership BEFORE any provider page is requested.
    func orderedIDs(
        membership: [String], kind: FoundationItem.Kind, sort: FoundationPrimaryGenreSort = .name,
        descending: Bool = false, readySongIDs: Set<String>? = nil
    ) -> [String] {
        let members = membership.filter {
            tracks[$0] != nil && (readySongIDs?.contains($0) ?? true)
        }
        let ids: [String]
        switch kind {
        case .track: ids = members
        case .album: ids = Array(Set(members.compactMap { tracks[$0]?.albumID }))
        case .artist: ids = Array(Set(members.compactMap { tracks[$0]?.artistID }))
        default: return []
        }
        func title(_ id: String) -> String {
            switch kind {
            case .track: tracks[id]?.title ?? ""
            case .album: albums[id] ?? ""
            case .artist: artists[id] ?? ""
            default: ""
            }
        }
        func text(_ id: String) -> String? {
            switch sort {
            case .album: tracks[id]?.albumID.flatMap { albums[$0] }
            case .artist: tracks[id]?.artistID.flatMap { artists[$0] }
            default: title(id)
            }
        }
        func number(_ id: String) -> Double? {
            switch sort {
            case .duration: tracks[id]?.duration
            case .year: tracks[id]?.year.map(Double.init)
            case .dateAdded: tracks[id]?.dateAdded?.timeIntervalSinceReferenceDate
            default: nil
            }
        }
        return ids.sorted { left, right in
            let order: ComparisonResult
            if [.duration, .year, .dateAdded].contains(sort) {
                switch (number(left), number(right)) {
                case (nil, nil): order = .orderedSame
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?):
                    order = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
                }
            } else {
                switch (text(left), text(right)) {
                case (nil, nil): order = .orderedSame
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?): order = a.localizedStandardCompare(b)
                }
            }
            if order != .orderedSame {
                return order == (descending ? .orderedDescending : .orderedAscending)
            }
            let nameOrder = title(left).localizedStandardCompare(title(right))
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return left < right
        }
    }

    func isValid(songIDs: Set<String>) -> Bool {
        guard Set(tracks.keys) == songIDs,
            tracks.count <= FoundationPrimaryGenreIndex.Limits().songs,
            albums.count <= tracks.count, artists.count <= tracks.count,
            Set(albums.keys) == Set(tracks.values.compactMap(\.albumID)),
            Set(artists.keys) == Set(tracks.values.compactMap(\.artistID)),
            albums.allSatisfy({ Self.validID($0.key) && Self.validText($0.value) }),
            artists.allSatisfy({ Self.validID($0.key) && Self.validText($0.value) })
        else { return false }
        return tracks.allSatisfy { id, item in
            Self.validID(id) && Self.validText(item.title)
                && (item.albumID.map { albums[$0] != nil } ?? true)
                && (item.artistID.map { artists[$0] != nil } ?? true)
                && (item.duration.map { $0.isFinite && $0 >= 0 } ?? true)
                && (item.year.map { (1...9999).contains($0) } ?? true)
                && (item.dateAdded.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true)
        }
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= FoundationPrimaryGenreIndex.Limits().identifierBytesPerValue
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// Missing/oversized ordering facts never erase otherwise valid genre eligibility.
    struct Builder {
        private var tracks: [String: Track] = [:]
        private var albums: [String: String] = [:]
        private var artists: [String: String] = [:]
        private var bytes = 0
        private var complete = true
        private(set) var exceededBudget = false

        mutating func append(
            _ songs: [FoundationPrimaryGenreMetadataPage.Song], source: FoundationCatalogSource
        ) {
            guard !exceededBudget else { return }
            for song in songs {
                guard let item = song.content else {
                    complete = false
                    continue
                }
                guard Self.validate(item, source: source), tracks[song.id] == nil else {
                    complete = false
                    continue
                }
                for (reference, isAlbum) in [(item.album, true), (item.artist, false)] {
                    guard let reference else { continue }
                    let old = isAlbum ? albums[reference.id] : artists[reference.id]
                    if let old, old != reference.title { complete = false }
                    if old == nil {
                        bytes += reference.id.utf8.count + reference.title.utf8.count
                        if isAlbum {
                            albums[reference.id] = reference.title
                        } else {
                            artists[reference.id] = reference.title
                        }
                    }
                }
                bytes +=
                    song.id.utf8.count + item.title.utf8.count
                    + (item.album?.id.utf8.count ?? 0) + (item.artist?.id.utf8.count ?? 0) + 32
                guard bytes <= FoundationPrimaryGenreContentIndex.maximumBytes else {
                    tracks = [:]
                    albums = [:]
                    artists = [:]
                    exceededBudget = true
                    return
                }
                tracks[song.id] = .init(
                    title: item.title,
                    albumID: item.album?.id, artistID: item.artist?.id,
                    duration: item.duration, year: item.year, dateAdded: item.dateAdded)
            }
        }

        func finish(songIDs: Set<String>) -> FoundationPrimaryGenreContentIndex? {
            guard complete, !exceededBudget else { return nil }
            let result = FoundationPrimaryGenreContentIndex(
                tracks: tracks, albums: albums, artists: artists)
            return result.isValid(songIDs: songIDs) ? result : nil
        }

        private static func validate(
            _ item: FoundationPrimaryGenreContentMetadata, source: FoundationCatalogSource
        ) -> Bool {
            FoundationPrimaryGenreContentIndex.validText(item.title)
                && [item.album, item.artist].compactMap { $0 }.allSatisfy {
                    FoundationPrimaryGenreContentIndex.validID($0.id)
                        && FoundationPrimaryGenreContentIndex.validText($0.title)
                        && ($0.catalogSource == nil || $0.catalogSource == source)
                }
                && (item.duration.map { $0.isFinite && $0 >= 0 } ?? true)
                && (item.year.map { (1...9999).contains($0) } ?? true)
                && (item.dateAdded.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true)
        }
    }
}
