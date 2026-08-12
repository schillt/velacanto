import SwiftUI

struct MusicFavoriteButton: View {
    enum Presentation {
        case icon
        case label
    }

    @EnvironmentObject private var actions: MusicItemActionStateOwner

    let item: MusicCatalogItem
    var presentation = Presentation.label

    var body: some View {
        Button {
            actions.toggleFavorite(item)
        } label: {
            switch presentation {
            case .icon:
                Image(systemName: symbolName)
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

private struct MusicFavoriteActionsModifier: ViewModifier {
    let item: MusicCatalogItem

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
            content
                .contextMenu {
                    MusicFavoriteButton(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    MusicFavoriteButton(item: item, presentation: .icon)
                        .tint(.pink)
                }
        #else
            content.contextMenu {
                MusicFavoriteButton(item: item)
            }
        #endif
    }
}

extension View {
    func musicFavoriteActions(for item: MusicCatalogItem) -> some View {
        modifier(MusicFavoriteActionsModifier(item: item))
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
