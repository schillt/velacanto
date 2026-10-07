import SwiftUI

/// Use identical content in a visible Menu and the native contextMenu modifier.
struct FoundationItemMenu: View {
    let item: FoundationItem
    @ObservedObject var actions: FoundationLibraryActions
    let initialFavorite: Bool?
    var open: (() -> Void)?
    var play: (() -> Void)?

    var library: (any FoundationLibrary)?
    var player: FoundationPlayer?
    var navigate: ((FoundationItem) -> Void)?
    var currentPageKind: FoundationItem.Kind?

    var body: some View {
        if let open {
            switch item.kind {
            case .album: Button("View Album", systemImage: "square.stack", action: open)
            case .artist: Button("View Artist", systemImage: "music.mic", action: open)
            case .playlist: Button("View Playlist", systemImage: "music.note.list", action: open)
            case .genre: Button("View Genre", systemImage: "guitars", action: open)
            case .track: EmptyView()
            }
        }
        if let play { Button("Play", systemImage: "play.fill", action: play) }
        if let player,
            item.kind == .track
                || ((item.kind == .album || item.kind == .playlist) && library != nil)
        {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                actions.enqueue(item, position: .next, library: library, player: player)
            }.disabled(actions.isQueueLoading)
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                actions.enqueue(item, position: .last, library: library, player: player)
            }.disabled(actions.isQueueLoading)
        }
        if item.kind == .track || item.kind == .album, let navigate {
            FoundationRelatedDestinations(
                item: item, navigate: navigate, currentPageKind: currentPageKind)
        }
        if item.kind != .genre {
            let favorite = actions.favoriteState(for: item, initial: initialFavorite)
            Button(
                favorite == true ? "Unfavorite" : "Favorite",
                systemImage: favorite == true ? "star.slash" : "star"
            ) {
                guard let favorite else { return }
                Task { await actions.setFavorite(for: item, isFavorite: !favorite) }
            }
            .disabled(favorite == nil || actions.isPending(item))
        }
        if item.kind != .track {
            Button(
                actions.isPinned(item) ? "Unpin" : "Pin",
                systemImage: actions.isPinned(item) ? "pin.slash" : "pin"
            ) { actions.togglePin(item) }
        }
        if let error = actions.errorMessage(for: item) { Text(error) }
    }
}

/// Navigate using supplied identities only; opening a menu performs no lookup.
struct FoundationRelatedDestinations: View {
    let item: FoundationItem
    let navigate: (FoundationItem) -> Void
    var currentPageKind: FoundationItem.Kind?

    var body: some View {
        if currentPageKind != .album, let album = item.album {
            Button("View Album", systemImage: "square.stack") {
                navigate(
                    FoundationItem(
                        id: album.id, title: album.title, subtitle: item.artist?.title ?? "",
                        kind: .album, duration: nil, primaryImageTag: album.primaryImageTag,
                        artist: item.artist))
            }
        }
        if currentPageKind != .artist, let artist = item.artist {
            Button("View Artist", systemImage: "music.mic") {
                navigate(
                    FoundationItem(
                        id: artist.id, title: artist.title, subtitle: "", kind: .artist,
                        duration: nil, primaryImageTag: artist.primaryImageTag))
            }
        }
    }
}
