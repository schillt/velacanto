import SwiftUI

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

extension Color {
    /// Velacanto's adaptive icon-derived identity color.
    ///
    /// The light appearance matches the icon's harbor-blue field, while the
    /// dark appearance uses a restrained version of its warm musical mark.
    static let velacantoAccent: Color = {
        #if os(iOS)
            Color(
                uiColor: UIColor { traits in
                    if traits.userInterfaceStyle == .dark {
                        return UIColor(
                            red: 140 / 255,
                            green: 108 / 255,
                            blue: 57 / 255,
                            alpha: 1
                        )
                    }
                    return UIColor(
                        red: 24 / 255,
                        green: 56 / 255,
                        blue: 106 / 255,
                        alpha: 1
                    )
                }
            )
        #elseif os(macOS)
            Color(
                nsColor: NSColor(name: NSColor.Name("VelacantoAccent")) { appearance in
                    let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    if isDark {
                        return NSColor(
                            srgbRed: 140 / 255,
                            green: 108 / 255,
                            blue: 57 / 255,
                            alpha: 1
                        )
                    }
                    return NSColor(
                        srgbRed: 24 / 255,
                        green: 56 / 255,
                        blue: 106 / 255,
                        alpha: 1
                    )
                }
            )
        #endif
    }()
}

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
