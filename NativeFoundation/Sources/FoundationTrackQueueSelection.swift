/// Projects already-loaded track occurrences without replacing source-position identity with item IDs.
struct FoundationTrackQueueSelection {
    let items: [FoundationItem]
    let index: Int

    init?(
        in source: [FoundationItem], selecting sourceIndex: Int,
        isAvailable: (FoundationItem) -> Bool = { _ in true }
    ) {
        guard source.indices.contains(sourceIndex), source[sourceIndex].kind == .track else {
            return nil
        }
        var tracks: [FoundationItem] = []
        var selectedIndex: Int?
        for (position, item) in source.enumerated() where item.kind == .track {
            guard isAvailable(item) else { continue }
            if position == sourceIndex { selectedIndex = tracks.count }
            tracks.append(item)
        }
        guard let selectedIndex else { return nil }
        items = tracks
        index = selectedIndex
    }
}
