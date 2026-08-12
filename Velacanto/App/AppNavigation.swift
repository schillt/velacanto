import SwiftUI

enum AppDestination: String, Hashable, Identifiable, CaseIterable {
    case home
    case new
    case library
    case search

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .new:
            "New"
        case .library:
            "Library"
        case .search:
            "Search"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            "house.fill"
        case .new:
            "music.note.list"
        case .library:
            "rectangle.stack"
        case .search:
            "magnifyingglass"
        }
    }
}

#if os(macOS)
    enum MacDestination: Hashable {
        case home
        case library(MusicLibraryCategory)
        case playlist(MusicCatalogItem)

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.home, .home):
                true
            case (.library(let lhsCategory), .library(let rhsCategory)):
                lhsCategory == rhsCategory
            case (.playlist(let lhsPlaylist), .playlist(let rhsPlaylist)):
                lhsPlaylist.id == rhsPlaylist.id
            default:
                false
            }
        }

        func hash(into hasher: inout Hasher) {
            switch self {
            case .home:
                hasher.combine(0)
            case .library(let category):
                hasher.combine(1)
                hasher.combine(category)
            case .playlist(let playlist):
                hasher.combine(2)
                hasher.combine(playlist.id)
            }
        }
    }
#endif
