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
                if connectivity.localOnly, item.kind != .track, let player {
                    let ready = downloads.browseTracks(for: item)
                    if !ready.isEmpty { player.setQueue(ready, selectedIndex: 0) }
                } else {
                    play()
                }
            }.disabled(connectivity.localOnly && downloads.browseTracks(for: item).isEmpty)
        }
        if let player,
            item.kind == .track
                || ((item.kind == .album || item.kind == .playlist) && library != nil)
        {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                if connectivity.localOnly {
                    player.enqueue(downloads.browseTracks(for: item), position: .next)
                } else {
                    actions.enqueue(item, position: .next, library: library, player: player)
                }
            }.disabled(
                actions.isQueueLoading
                    || (connectivity.localOnly && downloads.browseTracks(for: item).isEmpty))
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                if connectivity.localOnly {
                    player.enqueue(downloads.browseTracks(for: item), position: .last)
                } else {
                    actions.enqueue(item, position: .last, library: library, player: player)
                }
            }.disabled(
                actions.isQueueLoading
                    || (connectivity.localOnly && downloads.browseTracks(for: item).isEmpty))
        }
        if item.kind == .track || item.kind == .album, let navigate {
            FoundationRelatedDestinations(
                item: item, navigate: navigate, currentPageKind: currentPageKind)
        }
        if !connectivity.localOnly, item.kind == .track || item.kind == .album, let addToPlaylist {
            Button("Add to Playlist", systemImage: "music.note.list") { addToPlaylist(item) }
        }
        if item.kind == .track || item.kind == .album || item.kind == .playlist {
            FoundationDownloadActionButton(item: item, showsTitle: true)
            if let owner = downloads.owners.first(where: {
                $0.item.id == item.id && $0.item.kind == item.kind
            }) {
                switch owner.state {
                case .queued, .expanding, .waitingForWiFi, .downloading:
                    Button("Cancel Download", systemImage: "xmark.circle") {
                        downloads.cancel(ownerID: owner.id)
                    }
                case .cancelled, .failed:
                    Button("Retry Download", systemImage: "arrow.clockwise") {
                        downloads.retry(ownerID: owner.id)
                    }.disabled(connectivity.localOnly)
                case .ready:
                    EmptyView()
                }
            }
        }
        if item.kind != .genre {
            let favorite = actions.favoriteState(for: item, initial: initialFavorite)
            Button(
                favorite == true ? "Unfavorite" : "Favorite",
                systemImage: favorite == true ? "star.slash" : "star"
            ) {
                guard !connectivity.localOnly, let favorite else { return }
                Task {
                    guard !connectivity.localOnly else { return }
                    await actions.setFavorite(for: item, isFavorite: !favorite)
                }
            }
            .disabled(connectivity.localOnly || favorite == nil || actions.isPending(item))
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

    var body: some View {
        if currentPageKind != .album, let album = item.album {
            let albumItem = FoundationItem(
                id: album.id, title: album.title, subtitle: item.artist?.title ?? "",
                kind: .album, duration: nil, primaryImageTag: album.primaryImageTag,
                artist: item.artist)
            Button("View Album", systemImage: "square.stack") { navigate(albumItem) }
                .disabled(connectivity.localOnly && downloads.browseTracks(for: albumItem).isEmpty)
        }
        if !connectivity.localOnly, currentPageKind != .artist, let artist = item.artist {
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

/// One native action shared by item menus and the album/playlist toolbar.
struct FoundationDownloadActionButton: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationRequestDownloadRemoval) private var requestRemoval
    let item: FoundationItem
    var showsTitle = false
    @State private var confirmingRemoval = false

    private var hasDownload: Bool { downloads.hasDownloadedData(for: item) }
    private var title: String { hasDownload ? "Remove Downloads" : "Download" }
    private var symbol: String {
        guard hasDownload else { return "arrow.down.circle" }
        return downloads.availability(for: item) == .ready
            ? "arrow.down.circle.fill" : "arrow.down.circle.dotted"
    }

    var body: some View {
        Button {
            if hasDownload {
                if let requestRemoval { requestRemoval(item) } else { confirmingRemoval = true }
            } else {
                downloads.downloadAgain(item)
            }
        } label: {
            if showsTitle {
                Label(title, systemImage: symbol)
            } else {
                Image(systemName: symbol)
            }
        }
        .disabled(
            (!hasDownload && connectivity.localOnly)
                || (hasDownload && showsTitle && requestRemoval == nil)
        )
        .accessibilityLabel(title)
        .confirmationDialog(
            "Remove downloads?", isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { downloads.removeDownloads(for: item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundationDownloadRemovalMessage(item: item, downloads: downloads))
        }
    }
}

/// Native menus dismiss before an alert appears; their removal request belongs to a stable host.
struct FoundationDownloadRemovalPresentation: ViewModifier {
    @EnvironmentObject private var downloads: FoundationDownloads
    @State private var item: FoundationItem?

    func body(content: Content) -> some View {
        content
            .environment(\.foundationRequestDownloadRemoval, { item = $0 })
            .confirmationDialog(
                "Remove downloads?",
                isPresented: Binding(
                    get: { item != nil }, set: { if !$0 { item = nil } }), titleVisibility: .visible
            ) {
                if let item {
                    Button("Remove", role: .destructive) {
                        downloads.removeDownloads(for: item)
                        self.item = nil
                    }
                }
                Button("Cancel", role: .cancel) { item = nil }
            } message: {
                if let item {
                    Text(foundationDownloadRemovalMessage(item: item, downloads: downloads))
                }
            }
    }
}

@MainActor
private func foundationDownloadRemovalMessage(item: FoundationItem, downloads: FoundationDownloads)
    -> String
{
    if downloads.removalAffectsPlaylist(for: item) {
        return
            "This music belongs to downloaded playlists. Removing it reduces their offline availability on this device. Removed tracks stay removed until you explicitly download them again. Your server playlists are unchanged."
    }
    return
        "This changes downloaded music on this device. Your server library and playlists are unchanged. Music currently playing is removed after playback releases it."
}

private struct FoundationRequestDownloadRemovalKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (FoundationItem) -> Void)? = nil
}

extension EnvironmentValues {
    var foundationRequestDownloadRemoval: (@MainActor @Sendable (FoundationItem) -> Void)? {
        get { self[FoundationRequestDownloadRemovalKey.self] }
        set { self[FoundationRequestDownloadRemovalKey.self] = newValue }
    }
}

extension View {
    func foundationDownloadRemovalPresentation() -> some View {
        modifier(FoundationDownloadRemovalPresentation())
    }
}
