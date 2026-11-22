import Foundation

/// Value-only catalog shaping. Downloads retains readiness, visibility and collection ownership.
enum FoundationOfflineCatalogProjection {
    static func uniqueSongs(_ readyTracks: [FoundationItem]) -> [FoundationItem] {
        var seen: Set<String> = []
        return readyTracks.filter { seen.insert($0.id).inserted }
    }

    /// Expanded owners stay reachable even when empty; eligible remembered seeds only add new IDs.
    static func containers(
        expanded: [FoundationItem], remembered: [FoundationItem]
    ) -> [FoundationItem] {
        var result = expanded
        var seen = Set(result.map(\.id))
        for item in remembered where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }

    static func albums(seeds: [FoundationItem], songs: [FoundationItem]) -> [FoundationItem] {
        var result = seeds
        var seen = Set(result.map(\.id))
        for song in songs {
            if let album = song.album, seen.insert(album.id).inserted {
                var item = FoundationItem(
                    id: album.id, title: album.title, subtitle: song.subtitle,
                    kind: .album, duration: nil, primaryImageTag: album.primaryImageTag)
                item.artist = song.artist
                result.append(item)
            }
        }
        return result
    }

    static func artists(songs: [FoundationItem], albums: [FoundationItem]) -> [FoundationItem] {
        var seen: Set<String> = []
        return (songs + albums).compactMap { item in
            guard let artist = item.artist, seen.insert(artist.id).inserted else { return nil }
            return FoundationItem(
                id: artist.id, title: artist.title, subtitle: "", kind: .artist,
                duration: nil, primaryImageTag: artist.primaryImageTag)
        }
    }

    static func albums(
        artistID: String, songs: [FoundationItem], albums: [FoundationItem]
    ) -> [FoundationItem] {
        let albumIDs = Set(
            songs.filter { $0.artist?.id == artistID }.compactMap { $0.album?.id })
        return albums.filter { $0.artist?.id == artistID || albumIDs.contains($0.id) }
    }

    static func catalogItems(
        songs: [FoundationItem], availableContainers: [FoundationItem],
        kind: FoundationItem.Kind?
    ) -> [FoundationItem] {
        var seen: Set<String> = []
        return (songs + availableContainers).filter {
            (kind == nil || kind == $0.kind) && seen.insert(key($0)).inserted
        }
    }

    /// The facade trims and rejects empty queries before capturing current catalog candidates.
    static func searchItems(
        matching query: String, in candidates: [FoundationItem]
    ) -> [FoundationItem] {
        candidates.filter { item in
            [item.title, item.subtitle, item.album?.title ?? "", item.artist?.title ?? ""]
                .contains { $0.localizedStandardContains(query) }
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? key($0) < key($1) : order == .orderedAscending
        }
    }

    static func page(
        of results: [FoundationItem], startIndex: Int, limit: Int
    ) -> FoundationPage {
        let start = min(max(0, startIndex), results.count)
        let end = start + min(max(1, min(limit, 10_000)), results.count - start)
        return FoundationPage(
            items: Array(results[start..<end]), nextStartIndex: end < results.count ? end : nil)
    }

    private static func key(_ item: FoundationItem) -> String {
        item.kind.rawValue + ":" + item.id
    }
}
