import SwiftUI

enum AppDestination: String, Hashable, Identifiable, CaseIterable {
    case home
    case library
    case search

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library:
            "Library"
        case .search:
            "Search"
        }
    }

    var symbolName: String {
        switch self {
        case .home:
            "house"
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
    }
#endif
