import SwiftUI

struct MusicFavoriteButton: View {
    enum Presentation {
        case icon
        case label
    }

    @EnvironmentObject private var actions: MusicItemActionStateOwner

    let item: MusicCatalogItem
    var presentation = Presentation.label
    var iconSize: CGFloat?

    var body: some View {
        Button {
            actions.toggleFavorite(item)
        } label: {
            switch presentation {
            case .icon:
                Image(systemName: symbolName)
                    .frame(width: iconSize, height: iconSize)
            case .label:
                Label(title, systemImage: symbolName)
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue(actions.isUpdatingFavorite(item.id) ? "Updating" : "")
    }

    private var isFavorite: Bool {
        actions.isFavorite(item)
    }

    private var title: String {
        isFavorite ? "Unfavorite" : "Favorite"
    }

    private var symbolName: String {
        isFavorite ? "heart.fill" : "heart"
    }
}

struct MusicFavoriteIDButton: View {
    @EnvironmentObject private var actions: MusicItemActionStateOwner

    let itemID: MusicCatalogItemID
    var fallback = false

    var body: some View {
        Button {
            actions.toggleFavorite(itemID: itemID, fallback: fallback)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
        }
        .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")
        .accessibilityValue(actions.isUpdatingFavorite(itemID) ? "Updating" : "")
    }

    private var isFavorite: Bool {
        actions.isFavorite(itemID: itemID, fallback: fallback)
    }
}

struct MusicLibraryPinButton: View {
    @EnvironmentObject private var actions: MusicItemActionStateOwner

    let item: MusicCatalogItem

    var body: some View {
        Button {
            actions.togglePin(item)
        } label: {
            Label(title, systemImage: symbolName)
        }
        .accessibilityLabel(title)
    }

    private var title: String {
        actions.isPinned(item) ? "Unpin from Library" : "Pin to Library"
    }

    private var symbolName: String {
        actions.isPinned(item) ? "pin.slash" : "pin.fill"
    }
}

struct MusicLibraryPinMenu: View {
    let item: MusicCatalogItem

    var body: some View {
        Menu {
            MusicLibraryPinButton(item: item)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("More options")
    }
}

private struct MusicItemActionsModifier: ViewModifier {
    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .contextMenu {
                    MusicItemContextMenu(
                        item: item,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    MusicFavoriteButton(item: item, presentation: .icon)
                        .tint(.pink)
                }
        #else
            content
                .contextMenu {
                    MusicItemContextMenu(
                        item: item,
                        jellyfin: jellyfin,
                        playback: playback
                    )
                }
        #endif
    }
}

extension View {
    func musicItemActions(
        for item: MusicCatalogItem,
        jellyfin: JellyfinSessionController,
        playback: AudioPlaybackCoordinator
    ) -> some View {
        modifier(
            MusicItemActionsModifier(
                item: item,
                jellyfin: jellyfin,
                playback: playback
            )
        )
    }
}

private struct MusicItemContextMenu: View {
    @EnvironmentObject private var actions: MusicItemActionStateOwner

    let item: MusicCatalogItem
    @ObservedObject var jellyfin: JellyfinSessionController
    @ObservedObject var playback: AudioPlaybackCoordinator

    var body: some View {
        MusicFavoriteButton(item: item)

        if actions.canPin(item) {
            MusicLibraryPinButton(item: item)
        }

        if item.capabilities.contains(.playNext) || item.capabilities.contains(.playLast) {
            Divider()

            if item.capabilities.contains(.playNext) {
                Button {
                    playback.playNext(JellyfinPlaybackAdapter.playbackItem(for: item))
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }

            if item.capabilities.contains(.playLast) {
                Button {
                    playback.playLast(JellyfinPlaybackAdapter.playbackItem(for: item))
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .disabled(playback.currentItem == nil)
            }
        }

        navigationActions
    }

    @ViewBuilder
    private var navigationActions: some View {
        switch item.kind {
        case .album:
            Divider()
            NavigationLink {
                JellyfinTracksView(album: item, jellyfin: jellyfin, playback: playback)
            } label: {
                Label("View Album", systemImage: "square.stack")
            }
        case .artist:
            Divider()
            NavigationLink {
                MusicArtistView(artist: item, jellyfin: jellyfin, playback: playback)
            } label: {
                Label("View Artist", systemImage: "music.mic")
            }
        case .song:
            if let album = item.albumNavigationItem {
                Divider()
                NavigationLink {
                    JellyfinTracksView(album: album, jellyfin: jellyfin, playback: playback)
                } label: {
                    Label("View Album", systemImage: "square.stack")
                }
            }
            if let artist = item.artistNavigationItem {
                NavigationLink {
                    MusicArtistView(artist: artist, jellyfin: jellyfin, playback: playback)
                } label: {
                    Label("View Artist", systemImage: "music.mic")
                }
            }
        case .playlist:
            EmptyView()
        }
    }
}

struct MusicItemActionFailurePresenter: ViewModifier {
    @ObservedObject var actions: MusicItemActionStateOwner

    func body(content: Content) -> some View {
        content.alert(
            "Couldn’t Update Favorite",
            isPresented: Binding(
                get: { actions.failure != nil },
                set: { isPresented in
                    if !isPresented { actions.dismissFailure() }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                actions.dismissFailure()
            }
        } message: {
            Text(
                actions.failure?.message
                    ?? "Your previous favorite choice was restored."
            )
        }
    }
}
