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
        self.contentIndex =
            (try? contentIndex?.bindingSongIDs(snapshot.orderedSongIDs)) ?? contentIndex
    }

    /// Metadata-only copy: the census worker already bound and validated this immutable content.
    /// In particular, changing the save marker must not rebuild all track rows on MainActor.
    func replacingBuiltWithAppVersion(_ version: String?) -> Self {
        .init(copying: self, builtWithAppVersion: version)
    }

    private init(copying record: Self, builtWithAppVersion: String?) {
        snapshot = record.snapshot
        descriptors = record.descriptors
        self.builtWithAppVersion = builtWithAppVersion
        contentMetadataVersion = record.contentMetadataVersion
        contentIndex = record.contentIndex
    }

    private enum CodingKeys: String, CodingKey {
        case storageVersion, packedSnapshot, snapshot, descriptors, builtWithAppVersion,
            contentMetadataVersion, contentIndex
    }
    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let version = try box.decodeIfPresent(Int.self, forKey: .storageVersion) {
            guard version == 2, !box.contains(.snapshot) else {
                throw FoundationLibraryError.invalidResponse
            }
            snapshot = try box.decode(
                FoundationPrimaryGenrePackedSnapshot.self, forKey: .packedSnapshot
            ).unpack()
        } else {
            guard !box.contains(.packedSnapshot) else {
                throw FoundationLibraryError.invalidResponse
            }
            snapshot = try box.decode(FoundationPrimaryGenreIndex.Snapshot.self, forKey: .snapshot)
        }
        descriptors = try box.decode([FoundationItem].self, forKey: .descriptors)
        builtWithAppVersion = try box.decodeIfPresent(String.self, forKey: .builtWithAppVersion)
        contentMetadataVersion = try box.decodeIfPresent(Int.self, forKey: .contentMetadataVersion)
        contentIndex = try box.decodeIfPresent(
            FoundationPrimaryGenreContentIndex.self, forKey: .contentIndex)?.bindingSongIDs(
                snapshot.orderedSongIDs)
    }
    func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(2, forKey: .storageVersion)
        try box.encode(FoundationPrimaryGenrePackedSnapshot(snapshot), forKey: .packedSnapshot)
        try box.encode(descriptors, forKey: .descriptors)
        try box.encodeIfPresent(builtWithAppVersion, forKey: .builtWithAppVersion)
        try box.encodeIfPresent(contentMetadataVersion, forKey: .contentMetadataVersion)
        try box.encodeIfPresent(contentIndex, forKey: .contentIndex)
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
            contentMetadataVersion == nil || contentMetadataVersion == 1
                || contentMetadataVersion == FoundationPrimaryGenreContentIndex.version,
            contentIndex.map({ $0.isValid(songIDs: Set(snapshot.orderedSongIDs)) }) ?? true,
            contentIndex == nil || contentMetadataVersion == 1
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
    static let version = 2
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
    var nameRanks: FoundationPrimaryGenreNameRanks? = nil
    private enum CodingKeys: String, CodingKey {
        case tracks, albums, artists, ranks, duration, year, dateAdded
    }
    init(
        tracks: [String: Track], albums: [String: String], artists: [String: String],
        nameRanks: FoundationPrimaryGenreNameRanks? = nil
    ) {
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.nameRanks = nameRanks
    }
    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        if let ranks = try box.decodeIfPresent(FoundationPrimaryGenreNameRanks.self, forKey: .ranks)
        {
            nameRanks = ranks
            tracks = [:]
            albums = [:]
            artists = [:]
            encodedDuration = try box.decodeIfPresent(Data.self, forKey: .duration)
            encodedYear = try box.decodeIfPresent(Data.self, forKey: .year)
            encodedDate = try box.decodeIfPresent(Data.self, forKey: .dateAdded)
        } else {
            tracks = try box.decode([String: Track].self, forKey: .tracks)
            albums = try box.decode([String: String].self, forKey: .albums)
            artists = try box.decode([String: String].self, forKey: .artists)
        }
    }
    private var encodedDuration: Data? = nil
    private var encodedYear: Data? = nil
    private var encodedDate: Data? = nil
    func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        guard let nameRanks else {
            try box.encode(tracks, forKey: .tracks)
            try box.encode(albums, forKey: .albums)
            try box.encode(artists, forKey: .artists)
            return
        }
        try box.encode(nameRanks, forKey: .ranks)
        func numeric(_ value: (Track) -> Double?) -> Data? {
            guard nameRanks.songIDs.contains(where: { tracks[$0].flatMap(value) != nil }) else {
                return nil
            }
            var data = Data()
            for id in nameRanks.songIDs {
                let bits = tracks[id].flatMap(value)?.bitPattern ?? Double.nan.bitPattern
                for shift in stride(from: 0, to: 64, by: 8) {
                    data.append(UInt8((bits >> shift) & 255))
                }
            }
            return data
        }
        try box.encodeIfPresent(numeric { $0.duration }, forKey: .duration)
        try box.encodeIfPresent(numeric { $0.year.map(Double.init) }, forKey: .year)
        try box.encodeIfPresent(
            numeric { $0.dateAdded?.timeIntervalSinceReferenceDate }, forKey: .dateAdded)
    }
    func bindingSongIDs(_ ids: [String]) throws -> Self {
        guard let nameRanks else { return self }
        let bound = try nameRanks.binding(ids)
        let albumPositions = try FoundationPrimaryGenreWords.decode(
            bound.trackAlbums, count: ids.count)
        let artistPositions = try FoundationPrimaryGenreWords.decode(
            bound.trackArtists, count: ids.count)
        func numeric(_ data: Data?) throws -> [Double?]? {
            guard let data else { return nil }
            guard data.count == ids.count * 8 else { throw FoundationLibraryError.invalidResponse }
            let bytes = [UInt8](data)
            return try (0..<ids.count).map { index in
                var bits: UInt64 = 0
                for offset in 0..<8 { bits |= UInt64(bytes[index * 8 + offset]) << (offset * 8) }
                let value = Double(bitPattern: bits)
                guard !value.isInfinite else { throw FoundationLibraryError.invalidResponse }
                return value.isNaN ? nil : value
            }
        }
        let durations = try numeric(encodedDuration)
        let years = try numeric(encodedYear)
        let dates = try numeric(encodedDate)
        var output: [String: Track] = [:]
        for (offset, id) in ids.enumerated() {
            let album = albumPositions[offset]
            let artist = artistPositions[offset]
            let year = years?[offset] ?? tracks[id]?.year.map(Double.init)
            guard year.map({ $0.rounded() == $0 && (1...9999).contains($0) }) ?? true else {
                throw FoundationLibraryError.invalidResponse
            }
            output[id] = .init(
                title: "",
                albumID: album == FoundationPrimaryGenreWords.missing
                    ? nil : bound.albumIDs.ids[Int(album)],
                artistID: artist == FoundationPrimaryGenreWords.missing
                    ? nil : bound.artistIDs.ids[Int(artist)],
                duration: durations?[offset] ?? tracks[id]?.duration, year: year.map(Int.init),
                dateAdded: (dates?[offset]).flatMap { $0 }.map {
                    Date(timeIntervalSinceReferenceDate: $0)
                } ?? tracks[id]?.dateAdded)
        }
        return .init(tracks: output, albums: [:], artists: [:], nameRanks: bound)
    }
    func omitting(_ field: FoundationPrimaryGenreSort) -> Self {
        .init(
            tracks: tracks.mapValues {
                .init(
                    title: $0.title, albumID: $0.albumID, artistID: $0.artistID,
                    duration: field == .duration ? nil : $0.duration,
                    year: field == .year ? nil : $0.year,
                    dateAdded: field == .dateAdded ? nil : $0.dateAdded)
            }, albums: albums, artists: artists, nameRanks: nameRanks)
    }
    private func rankedIDs(
        membership: [String], kind: FoundationItem.Kind, sort: FoundationPrimaryGenreSort,
        descending: Bool, readySongIDs: Set<String>?
    ) -> [String]? {
        guard let ranks = nameRanks,
            let trackNames = try? FoundationPrimaryGenreWords.decode(
                ranks.trackNames, count: ranks.songIDs.count),
            let albumNames = try? FoundationPrimaryGenreWords.decode(
                ranks.albumNames, count: ranks.albumIDs.ids.count),
            let artistNames = try? FoundationPrimaryGenreWords.decode(
                ranks.artistNames, count: ranks.artistIDs.ids.count)
        else { return nil }
        let trackPositions = Dictionary(
            uniqueKeysWithValues: ranks.songIDs.enumerated().map { ($1, $0) })
        let albumPositions = Dictionary(
            uniqueKeysWithValues: ranks.albumIDs.ids.enumerated().map { ($1, $0) })
        let artistPositions = Dictionary(
            uniqueKeysWithValues: ranks.artistIDs.ids.enumerated().map { ($1, $0) })
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
        func name(_ id: String) -> UInt16 {
            switch kind {
            case .track: return trackNames[trackPositions[id]!]
            case .album: return albumNames[albumPositions[id]!]
            case .artist: return artistNames[artistPositions[id]!]
            default: return 0
            }
        }
        func value(_ id: String) -> Double? {
            switch sort {
            case .name: return Double(name(id))
            case .album:
                return tracks[id]?.albumID.flatMap { albumPositions[$0] }.map {
                    Double(albumNames[$0])
                }
            case .artist:
                return tracks[id]?.artistID.flatMap { artistPositions[$0] }.map {
                    Double(artistNames[$0])
                }
            case .duration: return tracks[id]?.duration
            case .year: return tracks[id]?.year.map(Double.init)
            case .dateAdded: return tracks[id]?.dateAdded?.timeIntervalSinceReferenceDate
            }
        }
        return ids.sorted { left, right in
            switch (value(left), value(right)) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?) where a != b: return descending ? a > b : a < b
            default: break
            }
            return name(left) == name(right) ? left < right : name(left) < name(right)
        }
    }

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
        if let ordered = rankedIDs(
            membership: membership, kind: kind, sort: sort, descending: descending,
            readySongIDs: readySongIDs)
        {
            return ordered
        }
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
        if let nameRanks {
            guard Set(nameRanks.songIDs) == songIDs, Set(tracks.keys) == songIDs,
                (try? nameRanks.validate()) != nil
            else { return false }
            return tracks.values.allSatisfy { item in
                item.title.isEmpty && (item.duration.map { $0.isFinite && $0 >= 0 } ?? true)
                    && (item.year.map { (1...9999).contains($0) } ?? true)
                    && (item.dateAdded.map { $0.timeIntervalSinceReferenceDate.isFinite } ?? true)
            }
        }
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
                guard tracks.count < 50_000,
                    bytes + 8 * 1_024 * 1_024
                        <= FoundationPrimaryGenreContentWorker.maximumLogicalWorkspaceBytes
                else {
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
            guard result.isValid(songIDs: songIDs),
                let ranks = try? FoundationPrimaryGenreNameRanks.make(
                    tracks: tracks, albums: albums, artists: artists)
            else { return nil }
            let ranked = FoundationPrimaryGenreContentIndex(
                tracks: tracks, albums: [:], artists: [:], nameRanks: ranks)
            return try? ranked.bindingSongIDs(ranks.songIDs)
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

/// Lossless identity codec. UUID spelling is retained; generic fixture/provider IDs use explicit text.
struct FoundationPrimaryGenreIdentityTable: Equatable, Codable, Sendable {
    let ids: [String]
    private enum CodingKeys: String, CodingKey { case count, uuidBytes, spelling, text }
    init(_ ids: [String]) throws {
        guard ids.count <= 50_000, Set(ids).count == ids.count,
            ids.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 256
                    && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            })
        else { throw FoundationLibraryError.invalidResponse }
        self.ids = ids
    }
    init(from decoder: any Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let count = try box.decode(Int.self, forKey: .count)
        guard (0...50_000).contains(count) else { throw FoundationLibraryError.invalidResponse }
        if let text = try box.decodeIfPresent([String].self, forKey: .text) {
            guard text.count == count, !box.contains(.uuidBytes), !box.contains(.spelling) else {
                throw FoundationLibraryError.invalidResponse
            }
            try self.init(text)
            return
        }
        let bytes = [UInt8](try box.decode(Data.self, forKey: .uuidBytes))
        let spelling = [UInt8](try box.decode(Data.self, forKey: .spelling))
        guard bytes.count == count * 16, spelling.count == count * 5 else {
            throw FoundationLibraryError.invalidResponse
        }
        let hex = Array("0123456789abcdef".utf8)
        var values: [String] = []
        values.reserveCapacity(count)
        for index in 0..<count {
            guard spelling[index * 5] <= 1 else { throw FoundationLibraryError.invalidResponse }
            let hyphens = spelling[index * 5] == 1
            var raw: [UInt8] = []
            for digit in 0..<32 {
                if hyphens && [8, 12, 16, 20].contains(digit) { raw.append(45) }
                let byte = bytes[index * 16 + digit / 2]
                var value = hex[Int(digit.isMultiple(of: 2) ? byte >> 4 : byte & 15)]
                if spelling[index * 5 + 1 + digit / 8] & (1 << (digit % 8)) != 0 {
                    guard value >= 97 else { throw FoundationLibraryError.invalidResponse }
                    value -= 32
                }
                raw.append(value)
            }
            values.append(String(decoding: raw, as: UTF8.self))
        }
        try self.init(values)
    }
    func encode(to encoder: any Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(ids.count, forKey: .count)
        guard ids.allSatisfy(FoundationJellyfinLibrary.validID) else {
            try box.encode(ids, forKey: .text)
            return
        }
        var bytes = Data()
        var spelling = Data()
        for id in ids {
            let digits = Array(id.utf8.filter { $0 != 45 })
            guard digits.count == 32 else { throw FoundationLibraryError.invalidResponse }
            var mask = [UInt8](repeating: 0, count: 5)
            mask[0] = id.utf8.count == 36 ? 1 : 0
            func nibble(_ byte: UInt8) throws -> UInt8 {
                switch byte {
                case 48...57: return byte - 48
                case 65...70: return byte - 65 + 10
                case 97...102: return byte - 97 + 10
                default: throw FoundationLibraryError.invalidResponse
                }
            }
            for offset in stride(from: 0, to: 32, by: 2) {
                bytes.append(try nibble(digits[offset]) << 4 | nibble(digits[offset + 1]))
            }
            for (offset, digit) in digits.enumerated() where (65...70).contains(digit) {
                mask[1 + offset / 8] |= 1 << (offset % 8)
            }
            spelling.append(contentsOf: mask)
        }
        try box.encode(bytes, forKey: .uuidBytes)
        try box.encode(spelling, forKey: .spelling)
    }
}

enum FoundationPrimaryGenreWords {
    static let missing = UInt16.max
    static func encode(_ values: [UInt16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for value in values {
            data.append(UInt8(value & 255))
            data.append(UInt8(value >> 8))
        }
        return data
    }
    static func decode(_ data: Data, count: Int) throws -> [UInt16] {
        guard count >= 0, count <= 100_000, data.count == count * 2 else {
            throw FoundationLibraryError.invalidResponse
        }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
        }
    }
}

/// Versioned persistence only; public Snapshot and its canonical policy remain unchanged.
struct FoundationPrimaryGenrePackedSnapshot: Codable, Sendable {
    let scope: FoundationPrimaryGenreIndex.Scope
    let songCount: Int
    let censusID: UUID
    let completedAt: Date
    let genreIDs: [String]
    let songCountsByGenre: [String: Int]
    let eligibleGenreIDs: Set<String>
    let songIDs: FoundationPrimaryGenreIdentityTable
    let primaryPairs: Data

    init(_ snapshot: FoundationPrimaryGenreIndex.Snapshot) throws {
        scope = snapshot.scope
        songCount = snapshot.songCount
        censusID = snapshot.censusID
        completedAt = snapshot.completedAt
        songCountsByGenre = snapshot.songCountsByGenre
        eligibleGenreIDs = snapshot.eligibleGenreIDs
        genreIDs = snapshot.songCountsByGenre.keys.sorted()
        guard genreIDs.count <= 4096, snapshot.orderedSongIDs.count == songCount else {
            throw FoundationLibraryError.invalidResponse
        }
        songIDs = try .init(snapshot.orderedSongIDs)
        let positions = Dictionary(
            uniqueKeysWithValues: genreIDs.enumerated().map { ($1, UInt16($0)) })
        var pairs: [UInt16] = []
        for id in snapshot.orderedSongIDs {
            guard let primary = snapshot.primaryBySongID[id], primary.count <= 2 else {
                throw FoundationLibraryError.invalidResponse
            }
            for offset in 0..<2 {
                if offset < primary.count {
                    guard let position = positions[primary[offset]] else {
                        throw FoundationLibraryError.invalidResponse
                    }
                    pairs.append(position)
                } else {
                    pairs.append(FoundationPrimaryGenreWords.missing)
                }
            }
        }
        primaryPairs = FoundationPrimaryGenreWords.encode(pairs)
    }
    func unpack() throws -> FoundationPrimaryGenreIndex.Snapshot {
        guard (0...50_000).contains(songCount), songIDs.ids.count == songCount,
            genreIDs.count <= 4096, Set(genreIDs).count == genreIDs.count,
            Set(genreIDs) == Set(songCountsByGenre.keys),
            eligibleGenreIDs.isSubset(of: Set(genreIDs))
        else { throw FoundationLibraryError.invalidResponse }
        let words = try FoundationPrimaryGenreWords.decode(primaryPairs, count: songCount * 2)
        var membership: [String: [String]] = [:]
        for (index, id) in songIDs.ids.enumerated() {
            let a = words[index * 2]
            let b = words[index * 2 + 1]
            guard
                a != FoundationPrimaryGenreWords.missing
                    || b == FoundationPrimaryGenreWords.missing,
                b == FoundationPrimaryGenreWords.missing || a != b
            else { throw FoundationLibraryError.invalidResponse }
            membership[id] = try [a, b].compactMap { position in
                guard position != FoundationPrimaryGenreWords.missing else { return nil }
                guard Int(position) < genreIDs.count else {
                    throw FoundationLibraryError.invalidResponse
                }
                return genreIDs[Int(position)]
            }
        }
        return .init(
            scope: scope, songCount: songCount, censusID: censusID, completedAt: completedAt,
            songCountsByGenre: songCountsByGenre, eligibleGenreIDs: eligibleGenreIDs,
            primaryBySongID: membership, orderedSongIDs: songIDs.ids)
    }
}

/// Equal names share a rank, preserving ascending ID ties even when name direction is reversed.
struct FoundationPrimaryGenreNameRanks: Equatable, Codable, Sendable {
    var songIDs: [String] = []  // Bound once by the enclosing record; never persisted twice.
    let albumIDs: FoundationPrimaryGenreIdentityTable
    let artistIDs: FoundationPrimaryGenreIdentityTable
    let trackNames: Data
    let albumNames: Data
    let artistNames: Data
    let trackAlbums: Data
    let trackArtists: Data
    enum CodingKeys: String, CodingKey {
        case albumIDs, artistIDs, trackNames, albumNames, artistNames, trackAlbums, trackArtists
    }

    static func make(
        tracks: [String: FoundationPrimaryGenreContentIndex.Track], albums: [String: String],
        artists: [String: String]
    ) throws -> Self {
        let songs = tracks.keys.sorted()
        let albumIDs = albums.keys.sorted()
        let artistIDs = artists.keys.sorted()
        func ranks(_ ids: [String], name: (String) -> String) throws -> Data {
            var comparisons = 0
            let sorted = try ids.enumerated().sorted { left, right in
                comparisons += 1
                if comparisons.isMultiple(of: 1024) { try Task.checkCancellation() }
                let order = name(left.element).localizedStandardCompare(name(right.element))
                return order == .orderedSame
                    ? left.element < right.element : order == .orderedAscending
            }
            var output = [UInt16](repeating: 0, count: ids.count)
            var previous: String?
            var rank: UInt16 = 0
            for entry in sorted {
                let value = name(entry.element)
                if let previous, previous.localizedStandardCompare(value) != .orderedSame {
                    rank += 1
                }
                output[entry.offset] = rank
                previous = value
            }
            try Task.checkCancellation()
            return FoundationPrimaryGenreWords.encode(output)
        }
        let albumPositions = Dictionary(
            uniqueKeysWithValues: albumIDs.enumerated().map { ($1, UInt16($0)) })
        let artistPositions = Dictionary(
            uniqueKeysWithValues: artistIDs.enumerated().map { ($1, UInt16($0)) })
        return try .init(
            songIDs: songs, albumIDs: .init(albumIDs), artistIDs: .init(artistIDs),
            trackNames: ranks(songs) { tracks[$0]!.title },
            albumNames: ranks(albumIDs) { albums[$0]! },
            artistNames: ranks(artistIDs) { artists[$0]! },
            trackAlbums: FoundationPrimaryGenreWords.encode(
                songs.map {
                    tracks[$0]!.albumID.flatMap { albumPositions[$0] }
                        ?? FoundationPrimaryGenreWords.missing
                }),
            trackArtists: FoundationPrimaryGenreWords.encode(
                songs.map {
                    tracks[$0]!.artistID.flatMap { artistPositions[$0] }
                        ?? FoundationPrimaryGenreWords.missing
                }))
    }
    func binding(_ ids: [String]) throws -> Self {
        var copy = self
        if songIDs.isEmpty {
            copy.songIDs = ids
        } else if songIDs != ids {
            guard Set(songIDs) == Set(ids) else { throw FoundationLibraryError.invalidResponse }
            let positions = Dictionary(uniqueKeysWithValues: songIDs.enumerated().map { ($1, $0) })
            func reorder(_ data: Data) throws -> Data {
                let values = try FoundationPrimaryGenreWords.decode(data, count: songIDs.count)
                return FoundationPrimaryGenreWords.encode(ids.map { values[positions[$0]!] })
            }
            copy = .init(
                songIDs: ids, albumIDs: albumIDs, artistIDs: artistIDs,
                trackNames: try reorder(trackNames), albumNames: albumNames,
                artistNames: artistNames,
                trackAlbums: try reorder(trackAlbums), trackArtists: try reorder(trackArtists))
        }
        try copy.validate()
        return copy
    }
    func validate() throws {
        guard songIDs.count <= 50_000, Set(songIDs).count == songIDs.count else {
            throw FoundationLibraryError.invalidResponse
        }
        for (data, count) in [
            (trackNames, songIDs.count), (albumNames, albumIDs.ids.count),
            (artistNames, artistIDs.ids.count),
        ] {
            let values = try FoundationPrimaryGenreWords.decode(data, count: count)
            guard values.allSatisfy({ Int($0) < count }),
                values.isEmpty || Set(values) == Set(0...values.max()!)
            else {
                throw FoundationLibraryError.invalidResponse
            }
        }
        for (data, count) in [
            (trackAlbums, albumIDs.ids.count), (trackArtists, artistIDs.ids.count),
        ] {
            let values = try FoundationPrimaryGenreWords.decode(data, count: songIDs.count)
            guard
                values.allSatisfy({ $0 == FoundationPrimaryGenreWords.missing || Int($0) < count }),
                Set(values.filter { $0 != FoundationPrimaryGenreWords.missing }).count == count
            else { throw FoundationLibraryError.invalidResponse }
        }
    }
}

/// The existing census owns this worker. Logical byte limits are not a process-RSS claim.
actor FoundationPrimaryGenreContentWorker {
    static let maximumLogicalWorkspaceBytes = 96 * 1_024 * 1_024
    private var builder = FoundationPrimaryGenreContentIndex.Builder()
    private let maximumRecordBytes: Int

    init(maximumRecordBytes: Int = FoundationPrimaryGenreContentIndex.maximumBytes) {
        self.maximumRecordBytes = min(
            max(0, maximumRecordBytes), FoundationPrimaryGenreContentIndex.maximumBytes)
    }

    func append(_ songs: [FoundationPrimaryGenreMetadataPage.Song], source: FoundationCatalogSource)
        throws
    {
        try Task.checkCancellation()
        builder.append(songs, source: source)
        guard !builder.exceededBudget else {
            throw FoundationPrimaryGenreIndex.Failure.resourceLimit
        }
    }
    func finish(
        snapshot: FoundationPrimaryGenreIndex.Snapshot, descriptors: [FoundationItem],
        builtWithAppVersion: String? = nil
    ) throws -> FoundationPrimaryGenreRecord {
        try Task.checkCancellation()
        let index = builder.finish(songIDs: Set(snapshot.orderedSongIDs))
        builder = .init()  // Release comparison names before encoding or publication.
        try Task.checkCancellation()
        guard var content = index else { throw FoundationPrimaryGenreIndex.Failure.unknownMetadata }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        func record(_ content: FoundationPrimaryGenreContentIndex) -> FoundationPrimaryGenreRecord {
            .init(
                snapshot: snapshot, descriptors: descriptors,
                builtWithAppVersion: builtWithAppVersion,
                contentMetadataVersion: FoundationPrimaryGenreContentIndex.version,
                contentIndex: content)
        }
        var result = record(content)
        // Preserve mandatory canonical Name ordering before optional own-track facts.
        for field in [FoundationPrimaryGenreSort.dateAdded, .duration, .year] {
            try Task.checkCancellation()
            guard try encoder.encode(result).count > maximumRecordBytes
            else { break }
            content = content.omitting(field)
            result = record(content)
        }
        try Task.checkCancellation()
        guard result.isValid(for: snapshot.scope),
            try encoder.encode(result).count <= maximumRecordBytes
        else { throw FoundationPrimaryGenreIndex.Failure.resourceLimit }
        return result
    }
}
