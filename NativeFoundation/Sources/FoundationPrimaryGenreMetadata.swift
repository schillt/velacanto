import Foundation

/// Dedicated metadata census payload. No media URLs, artwork or entire track DTOs survive decoding.
struct FoundationPrimaryGenreMetadataPage: Sendable {
    struct Song: Sendable {
        let id: String
        let genres: [FoundationItemReference]
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
        guard snapshot.scope == scope,
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
