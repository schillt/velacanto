import SwiftUI

#if os(macOS)
    import AppKit
#endif

#if os(macOS)

    /// Native presentation only. The caller owns loading, playback and destination content.
    struct FoundationMacLibraryShell<
        Content: View, MiniPlayer: View, LibrarySidebar: View, Profile: View
    >: View {
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @Binding var selection: FoundationDestination
        @Binding var searchQuery: String
        let searchActivation: Int
        let libraryNavigationID: String
        let navigationRevision: Int
        @FocusState private var searchFocused: Bool
        @State private var columnVisibility = NavigationSplitViewVisibility.all
        @State private var sidebarWidth: CGFloat = 200
        @Binding var playbackInset: CGFloat
        let showsMiniPlayer: Bool
        @ScaledMetric(relativeTo: .body) private var homeIconSize = 18.0
        private let content: (FoundationDestination) -> Content
        private let miniPlayer: () -> MiniPlayer
        private let librarySidebar: () -> LibrarySidebar
        private let profile: () -> Profile

        init(
            selection: Binding<FoundationDestination>,
            searchQuery: Binding<String>, searchActivation: Int, libraryNavigationID: String,
            navigationRevision: Int, playbackInset: Binding<CGFloat>,
            showsMiniPlayer: Bool,
            @ViewBuilder content: @escaping (FoundationDestination) -> Content,
            @ViewBuilder miniPlayer: @escaping () -> MiniPlayer,
            @ViewBuilder librarySidebar: @escaping () -> LibrarySidebar,
            @ViewBuilder profile: @escaping () -> Profile
        ) {
            _selection = selection
            _searchQuery = searchQuery
            self.searchActivation = searchActivation
            self.libraryNavigationID = libraryNavigationID
            self.navigationRevision = navigationRevision
            _playbackInset = playbackInset
            self.showsMiniPlayer = showsMiniPlayer
            self.content = content
            self.miniPlayer = miniPlayer
            self.librarySidebar = librarySidebar
            self.profile = profile
        }

        var body: some View {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                List {
                    Section("Browse") {
                        ForEach(
                            FoundationDestination.allCases.filter {
                                $0 != .search && $0 != .library
                            }, id: \.self
                        ) { destination in
                            Button {
                                selection = destination
                            } label: {
                                Label {
                                    Text(destination.title)
                                } icon: {
                                    if destination == .home {
                                        destination.icon.resizable().scaledToFit()
                                            .frame(width: homeIconSize, height: homeIconSize)
                                    } else {
                                        destination.icon.symbolVariant(
                                            selection == destination ? .fill : .none)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                selection == destination ? Color.accentColor : Color.primary
                            )
                            .accessibilityValue(selection == destination ? "Selected" : "")
                            .accessibilityIdentifier("mac-sidebar-" + String(destination.rawValue))
                        }
                    }
                    librarySidebar()
                }
                .listStyle(.sidebar)
                .accessibilityLabel("Main navigation")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    profile().padding(10)
                }
                .navigationTitle("Velacanto")
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    sidebarWidth = $0
                }
            } detail: {
                NavigationStack {
                    content(selection)
                }
                .scrollClipDisabled()
                .scrollEdgeEffectStyle(.soft, for: .top)
                .id("\(selection.rawValue)-\(libraryNavigationID)-\(navigationRevision)")
                .frame(minWidth: 560)
            }
            // Native split navigation can retain promoted detail destinations across a
            // detail-stack identity change. Recreate that navigation owner on activation.
            .id(navigationRevision)
            .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search music")
            .searchFocused($searchFocused)
            .onChange(of: searchActivation) { _, _ in searchFocused = true }
            .onChange(of: searchQuery) { _, _ in
                if selection != .search { selection = .search }
            }
            .onChange(of: searchFocused) { _, focused in
                if focused, selection != .search { selection = .search }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9),
                value: columnVisibility
            )
            .frame(minWidth: 760, minHeight: 480)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) {
                GeometryReader { geometry in
                    Rectangle().fill(.ultraThinMaterial)
                        .frame(height: geometry.safeAreaInsets.top + 32)
                        .mask {
                            LinearGradient(
                                colors: [.black, .black, .clear],
                                startPoint: .top, endPoint: .bottom)
                        }
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .padding(.leading, columnVisibility == .detailOnly ? 0 : sidebarWidth)
                .allowsHitTesting(false)
            }
            // Anchor to the split shell, outside destinations promoted by native navigation.
            // The inspector is a sibling of this shell, so it stays outside these bounds.
            .overlay(alignment: .bottom) {
                if showsMiniPlayer {
                    miniPlayer()
                        .padding(6)
                        .background {
                            if reduceTransparency {
                                RoundedRectangle(cornerRadius: 24).fill(.background)
                            }
                        }
                        .glassEffect(
                            reduceTransparency ? .identity : .regular,
                            in: .rect(cornerRadius: 24)
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .padding(.leading, columnVisibility == .detailOnly ? 0 : sidebarWidth)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            playbackInset = $0 + 12
                        }
                }
            }
        }
    }
#endif

#if os(macOS)
    private struct FoundationMacTransportBottomInsetKey: EnvironmentKey {
        static let defaultValue = CGFloat.zero
    }

    private struct FoundationMacToolbarTrailingReserveKey: EnvironmentKey {
        static let defaultValue = CGFloat.zero
    }

    private struct FoundationMacUsesShellToolbarKey: EnvironmentKey {
        static let defaultValue = false
    }

    extension EnvironmentValues {
        var foundationMacUsesShellToolbar: Bool {
            get { self[FoundationMacUsesShellToolbarKey.self] }
            set { self[FoundationMacUsesShellToolbarKey.self] = newValue }
        }
        var foundationMacToolbarTrailingReserve: CGFloat {
            get { self[FoundationMacToolbarTrailingReserveKey.self] }
            set { self[FoundationMacToolbarTrailingReserveKey.self] = newValue }
        }
        var foundationMacTransportBottomInset: CGFloat {
            get { self[FoundationMacTransportBottomInsetKey.self] }
            set { self[FoundationMacTransportBottomInsetKey.self] = newValue }
        }
    }

    private struct FoundationMacTransportClearance: ViewModifier {
        @Environment(\.foundationMacTransportBottomInset) private var inset
        @Environment(\.foundationMacUsesShellToolbar) private var usesShellToolbar
        @Environment(\.foundationMacToolbarTrailingReserve) private var toolbarReserve
        func body(content: Content) -> some View {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: inset)
                }
                .scrollClipDisabled()
                .toolbar {
                    if usesShellToolbar && toolbarReserve > 0 {
                        ToolbarItem(placement: .primaryAction) {
                            FoundationMacToolbarClearance()
                        }.sharedBackgroundVisibility(.hidden)
                    }
                }
        }
    }

    struct FoundationMacToolbarClearance: View {
        @Environment(\.foundationMacToolbarTrailingReserve) private var width
        var body: some View {
            FoundationMacToolbarSpacer(width: width)
                .frame(width: width, height: 28).fixedSize()
                .accessibilityHidden(true)
        }
    }

    /// A native toolbar view reserves the open inspector footprint without a button.
    private struct FoundationMacToolbarSpacer: NSViewRepresentable {
        let width: CGFloat
        func makeNSView(context: Context) -> FoundationMacToolbarSpacerView {
            let view = FoundationMacToolbarSpacerView()
            view.setContentHuggingPriority(.required, for: .horizontal)
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
            return view
        }
        func updateNSView(_ view: FoundationMacToolbarSpacerView, context: Context) {
            view.reservedWidth = width
        }
    }

    private final class FoundationMacToolbarSpacerView: NSView {
        var reservedWidth = CGFloat.zero {
            didSet { invalidateIntrinsicContentSize() }
        }
        override var intrinsicContentSize: NSSize { NSSize(width: reservedWidth, height: 28) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    enum FoundationMacLibraryRoute: Equatable {
        case overview, favorites, albums, artists, songs, genres, playlists, downloads
        case playlist(FoundationItem)

        var identity: String {
            switch self {
            case .overview: "overview"
            case .favorites: "favorites"
            case .albums: "albums"
            case .artists: "artists"
            case .songs: "songs"
            case .genres: "genres"
            case .playlists: "playlists"
            case .downloads: "downloads"
            case .playlist(let item): "playlist-" + item.id
            }
        }
    }

    struct FoundationMacActions {
        let navigate: (FoundationDestination) -> Void
        let togglePlayback: () -> Void
        let previous: () -> Void
        let next: () -> Void
        let queue: () -> Void
        let lyrics: () -> Void
        let hasSelection: Bool
        let canAdvance: Bool
        let canShowLyrics: Bool
    }

    private struct FoundationMacActionsKey: FocusedValueKey {
        typealias Value = FoundationMacActions
    }

    extension FocusedValues {
        var foundationMacActions: FoundationMacActions? {
            get { self[FoundationMacActionsKey.self] }
            set { self[FoundationMacActionsKey.self] = newValue }
        }
    }

    struct FoundationMacCommands: Commands {
        @FocusedValue(\.foundationMacActions) private var actions

        var body: some Commands {
            CommandMenu("Navigate") {
                ForEach(FoundationDestination.allCases, id: \.self) { destination in
                    Button(destination.title) { actions?.navigate(destination) }
                        .keyboardShortcut(
                            KeyEquivalent(Character(String(destination.rawValue + 1)))
                        )
                        .disabled(actions == nil)
                }
                Divider()
                Button("Search") { actions?.navigate(.search) }.keyboardShortcut("f")
                    .disabled(actions == nil)
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { actions?.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(actions?.hasSelection != true)
                Button("Previous Track") { actions?.previous() }.keyboardShortcut(.leftArrow)
                    .disabled(actions?.hasSelection != true)
                Button("Next Track") { actions?.next() }.keyboardShortcut(.rightArrow)
                    .disabled(actions?.canAdvance != true)
                Divider()
                Button("Show / Hide Queue") { actions?.queue() }
                    .keyboardShortcut("q", modifiers: [.command, .shift])
                    .disabled(actions == nil)
                Button("Show / Hide Lyrics") { actions?.lyrics() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(actions?.canShowLyrics != true)
            }
        }
    }
#endif

#if os(macOS)
    struct FoundationMacPlaybackTimeline: View {
        @ObservedObject var player: FoundationPlayer
        @State private var scrubbing = false
        @State private var position = 0.0
        @State private var entryID: UUID?

        var body: some View {
            HStack(spacing: 8) {
                Text(time(scrubbing ? position : player.elapsed))
                    .frame(width: 42, alignment: .trailing)
                Slider(
                    value: Binding(
                        get: {
                            scrubbing ? position : min(player.elapsed, max(0, player.duration))
                        },
                        set: { position = $0 }),
                    in: 0...max(1, player.duration),
                    onEditingChanged: { editing in
                        if editing {
                            position = player.elapsed
                            entryID = player.selectedEntryID
                            scrubbing = true
                        } else {
                            if scrubbing, let entryID {
                                player.seek(to: position, entryID: entryID)
                            }
                            scrubbing = false
                            entryID = nil
                        }
                    }
                )
                .disabled(player.selectedEntryID == nil || player.duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(time(player.elapsed)) of \(time(player.duration))")
                Text(time(player.duration)).frame(width: 42, alignment: .leading)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .onChange(of: player.selectedEntryID) { _, _ in
                scrubbing = false
                entryID = nil
            }
        }

        private func time(_ value: Double) -> String {
            guard value.isFinite, value >= 0 else { return "—" }
            return "\(Int(value) / 60):\(String(format: "%02d", Int(value) % 60))"
        }
    }
#endif

private struct FoundationMacShelfUnderlap: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
            content
                .contentMargins(.horizontal, 16, for: .scrollContent)
                .padding(.horizontal, -16)
                .scrollClipDisabled()
        #else
            content
        #endif
    }
}

extension View {
    func foundationMacShelfUnderlap() -> some View {
        modifier(FoundationMacShelfUnderlap())
    }
}

extension View {
    @ViewBuilder func foundationMacTransportClearance() -> some View {
        #if os(macOS)
            self.modifier(FoundationMacTransportClearance())
        #else
            self
        #endif
    }
}

// Mac ellipsis buttons communicate their menu without an extra disclosure arrow.
extension View {
    @ViewBuilder func foundationEllipsisMenuIndicator() -> some View {
        #if os(macOS)
            self.menuIndicator(.hidden)
        #else
            self
        #endif
    }
}
