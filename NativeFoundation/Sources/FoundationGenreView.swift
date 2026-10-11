import SwiftUI

/// A selected genre owns only its explicit album page; album navigation is shared.
struct FoundationGenreView: View {
    let genre: FoundationItem
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    @StateObject private var albums: FoundationBrowseModel

    init(
        genre: FoundationItem, library: any FoundationLibrary, player: FoundationPlayer,
        isActive: Bool
    ) {
        self.genre = genre
        self.library = library
        self.player = player
        self.isActive = isActive
        let model = FoundationBrowseModel()
        model.configureCache(
            library.catalogPageCache, key: library.catalogCacheKey("genre.albums." + genre.id))
        _albums = StateObject(wrappedValue: model)
    }

    var body: some View {
        FoundationCatalogView(
            title: genre.title, model: albums, library: library, player: player,
            isActive: isActive
        ) { try await library.albums(genreID: genre.id, startIndex: $0) }
    }
}
