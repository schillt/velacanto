import Foundation

/// Album presentation and explicit album playback share this reversible metadata projection.
/// Callers retain the original catalog items; this never removes files or changes playlist membership.
enum FoundationAlbumTrackPolicy {
    enum DiscHeading: Equatable {
        case disc(Int)
        case unspecified
    }

    /// Presentation boundaries only: preserve provider order and the flat playback indices.
    /// Do not guess a disc for untagged tracks, even alongside explicitly tagged discs.
    static func discHeadings(for tracks: [FoundationItem]) -> [Int: DiscHeading] {
        let discs = tracks.map { item -> Int? in
            guard let disc = item.discNumber, disc > 0 else { return nil }
            return disc
        }
        let knownDiscs = Set(discs.compactMap { $0 })
        guard knownDiscs.count > 1 || knownDiscs.contains(where: { $0 > 1 }) else {
            return [:]
        }
        var headings: [Int: DiscHeading] = [:]
        for (index, disc) in discs.enumerated() {
            if index == 0 || disc != discs[index - 1] {
                headings[index] = disc.map(DiscHeading.disc) ?? .unspecified
            }
        }
        return headings
    }

    struct Key: Hashable {
        let album: String
        let disc: Int
        let track: Int
        let title: String
    }

    static func visibleTracks(
        _ tracks: [FoundationItem], albumID: String? = nil, showDuplicates: Bool,
        isAvailable: (FoundationItem) -> Bool = { _ in true }
    ) -> [FoundationItem] {
        visibleSourceIndices(
            tracks, albumID: albumID, showDuplicates: showDuplicates,
            isAvailable: isAvailable
        ).map { tracks[$0] }
    }

    /// The one existing copy policy retains provenance of the actual selected
    /// raw occurrence, including a later available alternate file.
    static func visibleSourceIndices(
        _ tracks: [FoundationItem], albumID: String? = nil, showDuplicates: Bool,
        isAvailable: (FoundationItem) -> Bool = { _ in true }
    ) -> [Int] {
        guard !showDuplicates else { return Array(tracks.indices) }
        var positions: [Key: Int] = [:]
        var result: [Int] = []
        for (index, item) in tracks.enumerated() {
            guard let key = key(for: item, albumID: albumID) else {
                result.append(index)
                continue
            }
            if let position = positions[key] {
                if tracks[result[position]].id == item.id {
                    result.append(index)
                    continue
                }
                // Keep the existing logical slot, but return the chosen file's
                // actual raw occurrence rather than trying to recover by songID.
                if !isAvailable(tracks[result[position]]), isAvailable(item) {
                    result[position] = index
                }
            } else {
                positions[key] = result.count
                result.append(index)
            }
        }
        return result
    }
    static func key(for item: FoundationItem, albumID: String? = nil) -> Key? {
        guard item.kind == .track, let track = item.trackNumber, track > 0,
            let album = albumID ?? item.album?.id,
            !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let disc = item.discNumber ?? 1
        let title = FoundationSearchResolver.normalize(item.title)
        guard disc > 0, !title.isEmpty else { return nil }
        return Key(album: album, disc: disc, track: track, title: title)
    }

}
