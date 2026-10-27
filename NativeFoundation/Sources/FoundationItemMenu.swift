import SwiftUI

/// Use identical content in a visible Menu and the native contextMenu modifier.
struct FoundationItemMenu: View {
    @Environment(\.foundationHandoff) private var handoff
    let item: FoundationItem
    @ObservedObject var actions: FoundationLibraryActions
    let initialFavorite: Bool?
    /// Detail pages with a primary Favorite control can omit its duplicate menu action.
    var showsFavoriteAction = true
    var open: (() -> Void)?
    var play: (() -> Void)?

    var library: (any FoundationLibrary)?
    var player: FoundationPlayer?
    var navigate: ((FoundationItem) -> Void)?
    var currentPageKind: FoundationItem.Kind?
    var removeFromPlaylist: (() -> Void)?
    var removalPending = false
    var canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = { _ in true }
    @Environment(\.foundationCollectionOperationOwner) private var collectionOperationOwner
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @Environment(\.foundationAddToPlaylist) private var addToPlaylist

    var body: some View {
        Section {
            if showsFavoriteAction, item.kind != .genre {
                let favorite = actions.favoriteState(for: item, initial: initialFavorite)
                Button(
                    favorite == true ? "Unfavorite" : "Favorite",
                    systemImage: favorite == true ? "star.slash" : "star"
                ) {
                    guard canPerform(.favorites), !connectivity.localOnly, let favorite else {
                        return
                    }
                    Task {
                        guard canPerform(.favorites), !connectivity.localOnly else { return }
                        await actions.setFavorite(for: item, isFavorite: !favorite)
                    }
                }
                .disabled(connectivity.localOnly || favorite == nil || actions.isPending(item))
            }
            if item.kind != .track {
                Button(
                    actions.isPinned(item) ? "Unpin" : "Pin",
                    systemImage: actions.isPinned(item) ? "pin.slash" : "pin"
                ) { if canPerform(.catalogPresence) { actions.togglePin(item) } }
                if actions.isPinned(item) {
                    Button("Move Pin Earlier", systemImage: "arrow.up") {
                        guard canPerform(.catalogPresence) else { return }
                        actions.movePin(item, earlier: true)
                    }.disabled(!actions.canMovePin(item, earlier: true))
                    Button("Move Pin Later", systemImage: "arrow.down") {
                        guard canPerform(.catalogPresence) else { return }
                        actions.movePin(item, earlier: false)
                    }.disabled(!actions.canMovePin(item, earlier: false))
                }
            }
        }
        Section {
            if let open {
                let performOpen = {
                    guard canPerform(.catalogPresence) else { return }
                    handoff?.navigationChangedByUser()
                    open()
                }
                switch item.kind {
                case .album: Button("View Album", systemImage: "square.stack", action: performOpen)
                case .artist: Button("View Artist", systemImage: "music.mic", action: performOpen)
                case .playlist:
                    Button("View Playlist", systemImage: "music.note.list", action: performOpen)
                case .genre: Button("View Genre", systemImage: "guitars", action: performOpen)
                case .track: EmptyView()
                }
            }
            if let play {
                Button("Play", systemImage: "play.fill") {
                    guard canPerform(.playback) else { return }
                    if connectivity.localOnly, item.kind != .track, let player {
                        let ready = actions.collectionTracks(
                            downloads.browseTracks(for: item), for: item)
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
                    guard canPerform(.playback) else { return }
                    if connectivity.localOnly {
                        player.enqueue(
                            actions.collectionTracks(downloads.browseTracks(for: item), for: item),
                            position: .next)
                    } else {
                        actions.enqueue(
                            item, position: .next, library: library, player: player,
                            owner: collectionOperationOwner)
                    }
                }.disabled(
                    actions.isQueueLoading
                        || (connectivity.localOnly && downloads.browseTracks(for: item).isEmpty))
                Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    guard canPerform(.playback) else { return }
                    if connectivity.localOnly {
                        player.enqueue(
                            actions.collectionTracks(downloads.browseTracks(for: item), for: item),
                            position: .last)
                    } else {
                        actions.enqueue(
                            item, position: .last, library: library, player: player,
                            owner: collectionOperationOwner)
                    }
                }.disabled(
                    actions.isQueueLoading
                        || (connectivity.localOnly && downloads.browseTracks(for: item).isEmpty))
            }
            if item.kind == .track || item.kind == .album, let navigate {
                FoundationRelatedDestinations(
                    item: item, navigate: navigate, currentPageKind: currentPageKind,
                    canPerform: canPerform)
            }
            if !connectivity.localOnly, item.kind == .track || item.kind == .album,
                let addToPlaylist
            {
                Button("Add to Playlist", systemImage: "music.note.list") {
                    guard canPerform(.catalogPresence), !connectivity.localOnly,
                        library?.supportsPlaylistManagement != false
                    else { return }
                    addToPlaylist(item)
                }
            }
            if item.kind == .track || item.kind == .album || item.kind == .playlist {
                if !downloads.hasDownloadedData(for: item) {
                    FoundationDownloadActionButton(
                        item: item, showsTitle: true, canPerform: canPerform)
                }
                if let owner = downloads.owners.first(where: {
                    $0.item.id == item.id && $0.item.kind == item.kind
                }) {
                    switch owner.state {
                    case .queued, .expanding, .waitingForWiFi, .downloading:
                        Button("Cancel Download", systemImage: "xmark.circle") {
                            guard canPerform(.downloads) else { return }
                            downloads.cancel(ownerID: owner.id)
                        }
                    case .cancelled, .failed:
                        Button("Retry Download", systemImage: "arrow.clockwise") {
                            guard canPerform(.downloads), !connectivity.localOnly else { return }
                            downloads.retry(ownerID: owner.id)
                        }.disabled(connectivity.localOnly)
                    case .ready:
                        EmptyView()
                    }
                }
            }
        }
        if downloads.hasDownloadedData(for: item) || removeFromPlaylist != nil {
            Section {
                if downloads.hasDownloadedData(for: item),
                    item.kind == .track || item.kind == .album || item.kind == .playlist
                {
                    FoundationDownloadActionButton(
                        item: item, showsTitle: true, canPerform: canPerform)
                }
                if let removeFromPlaylist {
                    Button(
                        "Remove from Playlist", systemImage: "minus.circle", role: .destructive,
                        action: { if canPerform(.catalogPresence) { removeFromPlaylist() } }
                    )
                    .disabled(connectivity.localOnly || removalPending)
                }
            }
        }
        if let error = actions.errorMessage(for: item) { Text(error) }
    }
}

/// Navigate using supplied identities only; opening a menu performs no lookup.
struct FoundationRelatedDestinations: View {
    @Environment(\.foundationHandoff) private var handoff
    let item: FoundationItem
    let navigate: (FoundationItem) -> Void
    var currentPageKind: FoundationItem.Kind?
    var canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = { _ in true }
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads

    var body: some View {
        if currentPageKind != .album, let album = item.relatedAlbum {
            Button("View Album", systemImage: "square.stack") {
                guard canPerform(.catalogPresence) else { return }
                handoff?.navigationChangedByUser()
                navigate(album)
            }
            .disabled(connectivity.localOnly && downloads.browseTracks(for: album).isEmpty)
        }
        if currentPageKind != .artist, let artist = item.relatedArtist {
            Button("View Artist", systemImage: "music.mic") {
                guard canPerform(.catalogPresence) else { return }
                handoff?.navigationChangedByUser()
                navigate(artist)
            }
            .disabled(
                connectivity.localOnly
                    && downloads.downloadedAlbums(artistID: artist.id).isEmpty)
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
    var iconFont: Font = .caption
    var canPerform: @MainActor @Sendable (FoundationCatalogCapabilities) -> Bool = { _ in true }
    @State private var confirmingRemoval = false

    private var hasDownload: Bool { downloads.hasDownloadedData(for: item) }
    private var title: String { hasDownload ? "Remove Downloads" : "Download" }
    private var transferDescription: String {
        guard let owner = downloads.transferOwner(for: item) else { return "" }
        if owner.state == .downloading, item.kind == .track {
            guard owner.activeTrackID == item.id else { return "Download queued" }
            if let progress = owner.activeTrackProgress {
                return "Downloading, \(Int(min(1, max(0, progress)) * 100)) percent"
            }
        }
        return owner.status
    }

    var body: some View {
        Button(role: hasDownload && showsTitle ? .destructive : nil) {
            guard canPerform(.downloads) else { return }
            if hasDownload {
                if let requestRemoval {
                    requestRemoval(
                        .init(item: item, isCurrent: { [canPerform] in canPerform(.downloads) }))
                } else {
                    confirmingRemoval = true
                }
            } else {
                downloads.downloadAgain(item)
            }
        } label: {
            if showsTitle {
                HStack {
                    FoundationDownloadIndicator(
                        item: item, showsUnavailable: true, iconFont: iconFont)
                    Text(title)
                }
            } else {
                FoundationDownloadIndicator(item: item, showsUnavailable: true, iconFont: iconFont)
            }
        }
        .disabled(
            (!hasDownload && connectivity.localOnly)
                || (hasDownload && showsTitle && requestRemoval == nil)
        )
        .accessibilityLabel(title)
        .accessibilityValue(transferDescription)
        .confirmationDialog(
            "Remove downloads?", isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                guard canPerform(.downloads) else { return }
                downloads.removeDownloads(for: item)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(foundationDownloadRemovalMessage(item: item, downloads: downloads))
        }
    }
}

/// Native menus dismiss before an alert appears; their removal request belongs to a stable host.
struct FoundationDownloadRemovalPresentation: ViewModifier {
    @EnvironmentObject private var downloads: FoundationDownloads
    @State private var request: FoundationDownloadRemovalRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.foundationRequestDownloadRemoval, { request = $0 })
            .confirmationDialog(
                "Remove downloads?",
                isPresented: Binding(
                    get: { request != nil }, set: { if !$0 { request = nil } }),
                titleVisibility: .visible
            ) {
                if let request {
                    Button("Remove", role: .destructive) {
                        if request.isCurrent() { downloads.removeDownloads(for: request.item) }
                        self.request = nil
                    }
                }
                Button("Cancel", role: .cancel) { request = nil }
            } message: {
                if let request {
                    Text(foundationDownloadRemovalMessage(item: request.item, downloads: downloads))
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

struct FoundationDownloadRemovalRequest: Sendable {
    let item: FoundationItem
    let isCurrent: @MainActor @Sendable () -> Bool
}

private struct FoundationRequestDownloadRemovalKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (FoundationDownloadRemovalRequest) -> Void)? =
        nil
}

extension EnvironmentValues {
    var foundationRequestDownloadRemoval:
        (@MainActor @Sendable (FoundationDownloadRemovalRequest) -> Void)?
    {
        get { self[FoundationRequestDownloadRemovalKey.self] }
        set { self[FoundationRequestDownloadRemovalKey.self] = newValue }
    }
}

extension View {
    func foundationDownloadRemovalPresentation() -> some View {
        modifier(FoundationDownloadRemovalPresentation())
    }
}
