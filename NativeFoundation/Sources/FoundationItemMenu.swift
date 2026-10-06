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
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationAddToPlaylist) private var addToPlaylist
    @Environment(\.foundationDownloadedBrowsing) private var downloadedBrowsing
    private var localBrowsing: Bool { connectivity.localOnly || downloadedBrowsing }

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
        if let play {
            Button("Play", systemImage: "play.fill") {
                if localBrowsing, item.kind != .track, let player {
                    let ready = downloads.browseTracks(for: item)
                    if !ready.isEmpty { player.setQueue(ready, selectedIndex: 0) }
                } else {
                    play()
                }
            }.disabled(localBrowsing && downloads.browseTracks(for: item).isEmpty)
        }
        if let player,
            item.kind == .track
                || ((item.kind == .album || item.kind == .playlist) && library != nil)
        {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                if localBrowsing {
                    player.enqueue(downloads.browseTracks(for: item), position: .next)
                } else {
                    actions.enqueue(item, position: .next, library: library, player: player)
                }
            }.disabled(
                actions.isQueueLoading
                    || (localBrowsing && downloads.browseTracks(for: item).isEmpty))
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                if localBrowsing {
                    player.enqueue(downloads.browseTracks(for: item), position: .last)
                } else {
                    actions.enqueue(item, position: .last, library: library, player: player)
                }
            }.disabled(
                actions.isQueueLoading
                    || (localBrowsing && downloads.browseTracks(for: item).isEmpty))
        }
        if item.kind == .track || item.kind == .album, let navigate {
            FoundationRelatedDestinations(
                item: item, navigate: navigate, currentPageKind: currentPageKind)
        }
        if !localBrowsing, item.kind == .track || item.kind == .album, let addToPlaylist {
            Button("Add to Playlist", systemImage: "music.note.list") { addToPlaylist(item) }
        }
        if item.kind == .track || item.kind == .album || item.kind == .playlist {
            Button(
                downloads.availability(for: item) == .unavailable ? "Download" : "Download Again",
                systemImage: "arrow.down.circle"
            ) { downloads.downloadAgain(item) }.disabled(connectivity.localOnly)
        }
        if item.kind != .genre {
            let favorite = actions.favoriteState(for: item, initial: initialFavorite)
            Button(
                favorite == true ? "Unfavorite" : "Favorite",
                systemImage: favorite == true ? "star.slash" : "star"
            ) {
                guard !localBrowsing, let favorite else { return }
                Task {
                    guard !localBrowsing else { return }
                    await actions.setFavorite(for: item, isFavorite: !favorite)
                }
            }
            .disabled(localBrowsing || favorite == nil || actions.isPending(item))
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
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.foundationDownloadedBrowsing) private var downloadedBrowsing
    private var localBrowsing: Bool { connectivity.localOnly || downloadedBrowsing }

    var body: some View {
        if currentPageKind != .album, let album = item.album {
            let albumItem = FoundationItem(
                id: album.id, title: album.title, subtitle: item.artist?.title ?? "",
                kind: .album, duration: nil, primaryImageTag: album.primaryImageTag,
                artist: item.artist)
            Button("View Album", systemImage: "square.stack") { navigate(albumItem) }
                .disabled(localBrowsing && downloads.browseTracks(for: albumItem).isEmpty)
        }
        if !localBrowsing, currentPageKind != .artist, let artist = item.artist {
            Button("View Artist", systemImage: "music.mic") {
                navigate(
                    FoundationItem(
                        id: artist.id, title: artist.title, subtitle: "", kind: .artist,
                        duration: nil, primaryImageTag: artist.primaryImageTag))
            }
        }
    }
}

private struct FoundationAddToPlaylistKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (FoundationItem) -> Void)? = nil
}

extension EnvironmentValues {
    var foundationAddToPlaylist: (@MainActor @Sendable (FoundationItem) -> Void)? {
        get { self[FoundationAddToPlaylistKey.self] }
        set { self[FoundationAddToPlaylistKey.self] = newValue }
    }
}
