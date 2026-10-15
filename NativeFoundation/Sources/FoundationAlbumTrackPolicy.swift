import Foundation

/// Album presentation and explicit album playback share this reversible metadata projection.
/// Callers retain the original catalog items; this never removes files or changes playlist membership.
enum FoundationAlbumTrackPolicy {
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
        guard !showDuplicates else { return tracks }
        var positions: [Key: Int] = [:]
        var result: [FoundationItem] = []
        for item in tracks {
            guard let key = key(for: item, albumID: albumID) else {
                result.append(item)
                continue
            }
            if let position = positions[key] {
                if result[position].id == item.id {
                    result.append(item)
                    continue
                }
                // Offline callers may prefer a playable copy without moving its logical album slot.
                if !isAvailable(result[position]), isAvailable(item) { result[position] = item }
            } else {
                positions[key] = result.count
                result.append(item)
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
