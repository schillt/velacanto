import SwiftUI

/// One genre presentation boundary with native layouts tailored to each context.
/// Both forms retain the exact catalog item used for collection navigation.
struct FoundationGenrePresentation: View {
    enum Context { case card, libraryRow }
    let genre: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let context: Context
    let open: () -> Void
    var navigate: ((FoundationItem) -> Void)? = nil

    var body: some View {
        switch context {
        case .card:
            FoundationGenreCard(
                genre: genre, library: library, isActive: isActive, open: open)
        case .libraryRow:
            FoundationLibraryItemRow(
                item: genre, library: library, isActive: isActive, open: open,
                player: player, showsTrackArtwork: true, navigate: navigate)
        }
    }
}

struct FoundationGenreCard: View {
    let genre: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    let open: () -> Void
    var artworkItem: FoundationItem? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tint = Color.indigo
    @State private var isVisible = false

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                if dynamicTypeSize.isAccessibilitySize {
                    Color.clear.frame(minHeight: 150)
                } else {
                    Color.clear.aspectRatio(1.6, contentMode: .fit)
                }
                Text(genre.title).font(.headline).foregroundStyle(.white)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2).padding(12)
            }
            .background {
                GeometryReader { geometry in
                    ZStack {
                        FoundationCatalogArtwork(
                            item: artworkItem ?? genre, library: library,
                            isActive: isActive && isVisible, size: geometry.size.width,
                            sampledColor: $tint
                        )
                        .id((artworkItem ?? genre).sharedArtworkIdentity)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        LinearGradient(
                            stops: [
                                .init(color: tint.opacity(0.2), location: 0),
                                .init(color: tint.opacity(0.55), location: 0.55),
                                .init(color: tint.opacity(0.9), location: 0.85),
                                .init(color: tint, location: 1),
                            ], startPoint: .topTrailing, endPoint: .bottomLeading)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(genre.title)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }
}
