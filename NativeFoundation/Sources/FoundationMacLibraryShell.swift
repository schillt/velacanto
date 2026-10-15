import SwiftUI

#if os(macOS)

    struct FoundationMacScrolledHeaderPreference: PreferenceKey {
        static let defaultValue: [String: Bool] = [:]
        static func reduce(value: inout [String: Bool], nextValue: () -> [String: Bool]) {
            value.merge(nextValue(), uniquingKeysWith: { _, newest in newest })
        }
    }

    enum FoundationMacLayout {
        static let sidebarRowHeight: CGFloat = 36
        static let catalogHorizontalInset: CGFloat = 24
        static let minimumSidebarWidth: CGFloat = 170
        // Includes the fixed transport groups, shell margins and a usable artwork/title area.
        static let minimumDetailWidth: CGFloat = 480
        static let minimumInspectorWidth: CGFloat = 280
        static let maximumInspectorWidth: CGFloat = 460
        static let minimumWindowWidth: CGFloat = 760
        static var minimumSplitWidth: CGFloat { minimumSidebarWidth + minimumDetailWidth }
        static var minimumInspectingWindowWidth: CGFloat {
            minimumSplitWidth + minimumInspectorWidth
        }
    }

    /// Fixed icon geometry keeps bitmap and symbol destinations aligned in compact native rows.
    struct FoundationMacSidebarLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 10) {
                configuration.icon.frame(width: 20, height: 20)
                configuration.title
            }
        }
    }

    struct FoundationMacNavigationItem: Hashable {
        let item: FoundationItem
        let headerOwnerID = UUID().uuidString

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.headerOwnerID == rhs.headerOwnerID }
        func hash(into hasher: inout Hasher) {
            hasher.combine(headerOwnerID)
        }
    }

    @MainActor
    final class FoundationMacNavigation: ObservableObject {
        @Published var path: [FoundationMacNavigationItem] = []

        func open(_ item: FoundationItem) { path.append(.init(item: item)) }
        func returnToRoot() { path.removeAll() }
    }

    private struct FoundationMacNavigationKey: EnvironmentKey {
        static let defaultValue: FoundationMacNavigation? = nil
    }

    private struct FoundationMacHeaderOwnerKey: EnvironmentKey {
        static let defaultValue = ""
    }

    extension EnvironmentValues {
        var foundationMacHeaderOwnerID: String {
            get { self[FoundationMacHeaderOwnerKey.self] }
            set { self[FoundationMacHeaderOwnerKey.self] = newValue }
        }
        var foundationMacNavigation: FoundationMacNavigation? {
            get { self[FoundationMacNavigationKey.self] }
            set { self[FoundationMacNavigationKey.self] = newValue }
        }
    }
    import AppKit
#endif

#if os(macOS)

    /// Each visible detail route owns its vertical scroll chrome, independent of content type.
    private struct FoundationMacScrollChrome: ViewModifier {
        @Environment(\.foundationMacHeaderOwnerID) private var ownerID
        @State private var scrolled = false
        @State private var visible = false

        func body(content: Content) -> some View {
            content
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 1
                } action: { _, value in
                    scrolled = value
                }
                .preference(
                    key: FoundationMacScrolledHeaderPreference.self,
                    value: [ownerID: visible && scrolled]
                )
                .onChange(of: ownerID) { _, _ in scrolled = false }
                .onAppear { visible = true }
                .onDisappear { visible = false }
        }
    }

    /// Native presentation only. The caller owns loading, playback and destination content.
    struct FoundationMacLibraryShell<
        Content: View, MiniPlayer: View, LibrarySidebar: View, Profile: View, Destination: View
    >: View {
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @Binding var selection: FoundationDestination
        @Binding var searchQuery: String
        let searchActivation: Int
        let libraryNavigationID: String
        let navigationRevision: Int
        @ObservedObject var navigation: FoundationMacNavigation
        @FocusState private var searchFocused: Bool
        @State private var columnVisibility = NavigationSplitViewVisibility.all
        @State private var sidebarWidth: CGFloat = 230
        @State private var headerScrollByItem: [String: Bool] = [:]
        private var rootHeaderOwnerID: String {
            "root-\(selection.rawValue)-\(libraryNavigationID)-\(navigationRevision)"
        }
        private var headerScrolled: Bool {
            let owner = navigation.path.last?.headerOwnerID ?? rootHeaderOwnerID
            return headerScrollByItem[owner] ?? false
        }
        @Binding var playbackInset: CGFloat
        let showsMiniPlayer: Bool
        private let homeIconSize: CGFloat = 18
        private let content: (FoundationDestination) -> Content
        private let miniPlayer: () -> MiniPlayer
        private let librarySidebar: () -> LibrarySidebar
        private let profile: () -> Profile
        private let activateSearch: () -> Void
        private let destination: (FoundationItem) -> Destination

        init(
            selection: Binding<FoundationDestination>,
            searchQuery: Binding<String>, searchActivation: Int, libraryNavigationID: String,
            navigationRevision: Int, navigation: FoundationMacNavigation,
            playbackInset: Binding<CGFloat>,
            showsMiniPlayer: Bool,
            @ViewBuilder content: @escaping (FoundationDestination) -> Content,
            @ViewBuilder miniPlayer: @escaping () -> MiniPlayer,
            @ViewBuilder librarySidebar: @escaping () -> LibrarySidebar,
            @ViewBuilder profile: @escaping () -> Profile,
            @ViewBuilder destination: @escaping (FoundationItem) -> Destination,
            activateSearch: @escaping () -> Void
        ) {
            _selection = selection
            _searchQuery = searchQuery
            self.searchActivation = searchActivation
            self.libraryNavigationID = libraryNavigationID
            self.navigationRevision = navigationRevision
            self.navigation = navigation
            _playbackInset = playbackInset
            self.showsMiniPlayer = showsMiniPlayer
            self.content = content
            self.miniPlayer = miniPlayer
            self.librarySidebar = librarySidebar
            self.profile = profile
            self.activateSearch = activateSearch
            self.destination = destination
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
                                    Text(destination.title).font(.system(size: 14)).lineLimit(1)
                                } icon: {
                                    if destination == .home {
                                        destination.icon.resizable().scaledToFit()
                                            .frame(width: homeIconSize, height: homeIconSize)
                                    } else {
                                        destination.icon.symbolVariant(
                                            selection == destination ? .fill : .none
                                        )
                                        .font(.system(size: 18))
                                    }
                                }
                                .labelStyle(FoundationMacSidebarLabelStyle())
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: FoundationMacLayout.sidebarRowHeight,
                                    alignment: .leading
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
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
                .environment(\.defaultMinListRowHeight, FoundationMacLayout.sidebarRowHeight)
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Main navigation")
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    profile()
                        .frame(maxWidth: .infinity)
                        .background {
                            if reduceTransparency {
                                RoundedRectangle(cornerRadius: 16).fill(.background)
                            }
                        }
                        .glassEffect(
                            reduceTransparency ? .identity : .regular.interactive(),
                            in: .rect(cornerRadius: 16)
                        )
                        .padding(10)
                }
                .navigationTitle("VelaCanto")
                .navigationSplitViewColumnWidth(
                    min: FoundationMacLayout.minimumSidebarWidth, ideal: 230, max: 280
                )
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    sidebarWidth = $0
                }
            } detail: {
                NavigationStack(path: $navigation.path) {
                    content(selection)
                        .modifier(FoundationMacScrollChrome())
                        .environment(\.foundationMacHeaderOwnerID, rootHeaderOwnerID)
                        .navigationDestination(for: FoundationMacNavigationItem.self) { route in
                            destination(route.item)
                                .modifier(FoundationMacScrollChrome())
                                .environment(\.foundationMacHeaderOwnerID, route.headerOwnerID)
                        }
                }
                .scrollClipDisabled()
                .scrollEdgeEffectStyle(.soft, for: .top)
                .id("\(selection.rawValue)-\(libraryNavigationID)-\(navigationRevision)")
                .frame(minWidth: FoundationMacLayout.minimumDetailWidth)
            }
            // Native split navigation can retain promoted detail destinations across a
            // detail-stack identity change. Recreate that navigation owner on activation.
            .id(navigationRevision)
            .searchable(text: $searchQuery, placement: .sidebar, prompt: "Search music")
            .searchFocused($searchFocused)
            .onChange(of: searchActivation, initial: true) { _, activation in
                if selection == .search, activation > 0 { searchFocused = true }
            }
            .onChange(of: searchQuery) { _, _ in
                activateSearch()
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.46, dampingFraction: 0.9),
                value: columnVisibility
            )
            .frame(minWidth: FoundationMacLayout.minimumSplitWidth, minHeight: 480)
            .onPreferenceChange(FoundationMacScrolledHeaderPreference.self) {
                headerScrollByItem = $0
            }
            .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
            // Keep native window geometry stable; the noninteractive overlay reveals frost on scroll.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .overlay(alignment: .top) {
                GeometryReader { geometry in
                    Rectangle().fill(.ultraThinMaterial)
                        .frame(height: geometry.safeAreaInsets.top + 32)
                        .mask {
                            LinearGradient(
                                stops: (0...32).map { step in
                                    let progress = Double(step) / 32
                                    let eased = progress * progress * (3 - 2 * progress)
                                    return .init(
                                        color: .black.opacity(1 - eased), location: progress)
                                }, startPoint: .top, endPoint: .bottom)
                        }
                        .offset(y: -geometry.safeAreaInsets.top)
                }
                .padding(.leading, columnVisibility == .detailOnly ? 0 : sidebarWidth)
                .opacity(headerScrolled ? 1 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: headerScrolled)
                .allowsHitTesting(false)
            }
            // Anchor to the split shell, outside destinations promoted by native navigation.
            // The inspector is a sibling of this shell, so it stays outside these bounds.
            .overlay(alignment: .bottom) {
                if showsMiniPlayer {
                    miniPlayer()
                        .padding(4)
                        .background {
                            if reduceTransparency {
                                Capsule().fill(.background)
                            }
                        }
                        .glassEffect(
                            reduceTransparency ? .identity : .regular,
                            in: .capsule
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
        func body(content: Content) -> some View {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear.frame(height: inset)
                }
                .scrollClipDisabled()
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

    /// Reserve the measured difference between content and complete shell widths.
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
        case overview, pinned, favorites, albums, artists, songs, genres, playlists, downloads
        case playlist(FoundationItem)
        case item(FoundationItem)

        var identity: String {
            switch self {
            case .overview: "overview"
            case .pinned: "pinned"
            case .favorites: "favorites"
            case .albums: "albums"
            case .artists: "artists"
            case .songs: "songs"
            case .genres: "genres"
            case .playlists: "playlists"
            case .downloads: "downloads"
            case .playlist(let item): "playlist-" + item.id
            case .item(let item): item.kind.rawValue + "-" + item.id
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
    struct FoundationMacTransport<Artwork: View>: View {
        @ObservedObject var player: FoundationPlayer
        let item: FoundationItem?
        let state: FoundationPlayer.State
        let lyricsEnabled: Bool
        let lyricsSelected: Bool
        let queueSelected: Bool
        let toggleLyrics: () -> Void
        let toggleQueue: () -> Void
        let navigate: (FoundationItem) -> Void
        @ViewBuilder let artwork: () -> Artwork

        var body: some View {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Button {
                        player.previous()
                    } label: {
                        FoundationMacPlaybackGlyph(kind: .previous).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(Color.white).opacity(item == nil ? 0.35 : 1)
                    }
                    .disabled(item == nil).help("Previous track (⌘←)")
                    .accessibilityLabel("Previous")
                    Button {
                        player.togglePlayback()
                    } label: {
                        FoundationMacPlaybackGlyph(kind: player.wantsPlayback ? .pause : .play)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(Color.white).opacity(item == nil ? 0.35 : 1)
                    }
                    .disabled(item == nil)
                    .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
                    .accessibilityIdentifier("foundation-mini-playback-toggle")
                    Button {
                        player.next()
                    } label: {
                        FoundationMacPlaybackGlyph(kind: .next).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .foregroundStyle(Color.white)
                            .opacity(item == nil || !player.canAdvance ? 0.35 : 1)
                    }
                    .disabled(item == nil || !player.canAdvance)
                    .help("Next track (⌘→)").accessibilityLabel("Next")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white)
                .frame(width: 156, alignment: .leading)
                Group {
                    if let item {
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                let menu = FoundationMacTrackMenu(item: item, navigate: navigate)
                                withExtendedLifetime(menu) { menu.show() }
                            } label: {
                                HStack(spacing: 10) {
                                    artwork().frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                                        Text(state == .playing ? item.subtitle : state.label)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(item.relatedAlbum == nil && item.relatedArtist == nil)
                            .accessibilityLabel("View album or artist")
                            FoundationMacPlaybackTimeline(player: player)
                        }
                    } else {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable().scaledToFit().frame(width: 44, height: 44)
                            .accessibilityLabel("VelaCanto — Nothing playing")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                FoundationMacTransportTools(
                    player: player, lyricsEnabled: lyricsEnabled,
                    lyricsSelected: lyricsSelected, queueSelected: queueSelected,
                    toggleLyrics: toggleLyrics, toggleQueue: toggleQueue
                ).frame(width: 184)
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
        }
    }

    /// A native menu keeps the artwork label in the SwiftUI layout and routes choices
    /// straight into the main content canvas, including from an existing detail page.
    @MainActor private final class FoundationMacTrackMenu: NSObject {
        let item: FoundationItem
        let navigate: (FoundationItem) -> Void

        init(item: FoundationItem, navigate: @escaping (FoundationItem) -> Void) {
            self.item = item
            self.navigate = navigate
        }

        func show() {
            guard let window = NSApp.currentEvent?.window ?? NSApp.mainWindow ?? NSApp.keyWindow,
                let view = window.contentView
            else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            let menu = NSMenu()
            if item.relatedAlbum != nil {
                let entry = NSMenuItem(
                    title: "View Album", action: #selector(openAlbum), keyEquivalent: "")
                entry.target = self
                entry.image = NSImage(
                    systemSymbolName: "square.stack", accessibilityDescription: nil)
                menu.addItem(entry)
            }
            if item.relatedArtist != nil {
                let entry = NSMenuItem(
                    title: "View Artist", action: #selector(openArtist), keyEquivalent: "")
                entry.target = self
                entry.image = NSImage(systemSymbolName: "music.mic", accessibilityDescription: nil)
                menu.addItem(entry)
            }
            menu.popUp(
                positioning: nil,
                at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil), in: view)
        }

        @objc private func openAlbum() {
            if let album = item.relatedAlbum { navigate(album) }
        }

        @objc private func openArtist() {
            if let artist = item.relatedArtist { navigate(artist) }
        }
    }

    private struct FoundationMacTransportTools: View {
        @ObservedObject var player: FoundationPlayer
        let lyricsEnabled: Bool
        let lyricsSelected: Bool
        let queueSelected: Bool
        let toggleLyrics: () -> Void
        let toggleQueue: () -> Void
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @State private var volumeExpanded = false

        var body: some View {
            HStack(spacing: 8) {
                Button(action: toggleLyrics) {
                    Image(systemName: "quote.bubble").frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(!lyricsEnabled)
                .foregroundStyle(lyricsSelected ? Color.accentColor : Color.primary)
                .help("Lyrics (⇧⌘L)").accessibilityLabel("Show lyrics")
                .accessibilityAddTraits(lyricsSelected ? .isSelected : [])
                Button(action: toggleQueue) {
                    Image(systemName: "list.bullet").frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(player.queue.isEmpty)
                .foregroundStyle(queueSelected ? Color.accentColor : Color.primary)
                .help("Queue (⇧⌘Q)").accessibilityLabel("Show queue")
                .accessibilityAddTraits(queueSelected ? .isSelected : [])
                FoundationAirPlayPicker(player: player).frame(width: 40, height: 44)
                volumeButton
            }
            .buttonStyle(.plain)
            .opacity(volumeExpanded ? 0 : 1)
            .allowsHitTesting(!volumeExpanded)
            .accessibilityHidden(volumeExpanded)
            .overlay(alignment: .trailing) {
                if volumeExpanded {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { player.playerVolume }, set: { player.playerVolume = $0 }),
                            in: 0...1
                        )
                        .frame(width: 112).accessibilityLabel("Player volume")
                        volumeButton.keyboardShortcut(.cancelAction)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background {
                        if reduceTransparency { Capsule().fill(.background) }
                    }
                    .glassEffect(reduceTransparency ? .identity : .regular, in: .capsule)
                    .fixedSize()
                    .transition(.scale(scale: 0.85, anchor: .trailing).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86),
                value: volumeExpanded
            )
            .onExitCommand { volumeExpanded = false }
        }

        private var volumeButton: some View {
            Button {
                volumeExpanded.toggle()
            } label: {
                Image(systemName: player.playerVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .help(volumeExpanded ? "Hide volume" : "Show volume")
            .accessibilityLabel(volumeExpanded ? "Hide volume" : "Show volume")
            .accessibilityAddTraits(volumeExpanded ? .isSelected : [])
        }
    }

    private struct FoundationMacPlaybackGlyph: View {
        enum Kind { case previous, play, pause, next }
        let kind: Kind

        @ViewBuilder var body: some View {
            switch kind {
            case .play:
                FoundationMacRoundedPlayShape().frame(width: 14, height: 17)
            case .pause:
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 3.5, height: 16)
                    RoundedRectangle(cornerRadius: 1.5).frame(width: 3.5, height: 16)
                }
            case .previous, .next:
                HStack(spacing: -1) {
                    FoundationMacRoundedPlayShape().frame(width: 9, height: 15)
                    FoundationMacRoundedPlayShape().frame(width: 9, height: 15)
                }.rotationEffect(.degrees(kind == .previous ? 180 : 0))
            }
        }
    }

    private struct FoundationMacRoundedPlayShape: Shape {
        func path(in rect: CGRect) -> Path {
            let radius = min(2, rect.width / 6)
            var path = Path()
            path.move(to: CGPoint(x: radius, y: radius / 2))
            path.addLine(to: CGPoint(x: rect.width - radius, y: rect.midY - radius / 2))
            path.addQuadCurve(
                to: CGPoint(x: rect.width - radius, y: rect.midY + radius / 2),
                control: CGPoint(x: rect.width + radius / 2, y: rect.midY))
            path.addLine(to: CGPoint(x: radius, y: rect.height - radius / 2))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: rect.height - radius),
                control: CGPoint(x: 0, y: rect.height + radius / 2))
            path.addLine(to: CGPoint(x: 0, y: radius))
            path.addQuadCurve(
                to: CGPoint(x: radius, y: radius / 2),
                control: CGPoint(x: 0, y: -radius / 2))
            path.closeSubpath()
            return path
        }
    }

    struct FoundationMacPlaybackTimeline: View {
        @ObservedObject var player: FoundationPlayer
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @State private var scrubbing = false
        @State private var hovering = false
        @FocusState private var focused: Bool
        @State private var keyboardFocused = false
        @State private var position = 0.0
        @State private var entryID: UUID?

        private var showsDetails: Bool { hovering || scrubbing || keyboardFocused }
        private var currentPosition: Double { scrubbing ? position : player.elapsed }

        var body: some View {
            ZStack {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule().fill(Color.white)
                            .frame(width: geometry.size.width * progress)
                    }
                    .frame(height: 3)
                    .frame(maxHeight: .infinity)
                }
                .allowsHitTesting(false).accessibilityHidden(true)
                .opacity(showsDetails ? 0 : 1)
                HStack(spacing: 8) {
                    Text(time(currentPosition)).frame(width: 38, alignment: .leading)
                        .opacity(showsDetails ? 1 : 0).accessibilityHidden(!showsDetails)
                    Slider(
                        value: Binding(
                            get: { min(currentPosition, max(0, player.duration)) },
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
                    .tint(.white)
                    .focused($focused)
                    // Keep the native slider focusable and accessible while its visual
                    // handle is hidden beneath the progress-line presentation.
                    .opacity(showsDetails ? 1 : 0.001)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(time(player.elapsed)) of \(time(player.duration))")
                    Text(time(player.duration)).frame(width: 38, alignment: .trailing)
                        .opacity(showsDetails ? 1 : 0).accessibilityHidden(!showsDetails)
                }
            }
            .frame(height: 14)
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .onHover {
                hovering = $0
                if $0 { keyboardFocused = false }
            }
            .onChange(of: focused) { _, focused in keyboardFocused = focused && !hovering }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: showsDetails)
            .onChange(of: player.selectedEntryID) { _, _ in
                scrubbing = false
                entryID = nil
            }
        }

        private var progress: CGFloat {
            guard player.duration > 0, currentPosition.isFinite else { return 0 }
            return CGFloat(min(1, max(0, currentPosition / player.duration)))
        }

        private func time(_ value: Double) -> String {
            guard value.isFinite, value >= 0 else { return "—" }
            return "\(Int(value) / 60):\(String(format: "%02d", Int(value) % 60))"
        }
    }
#endif

#if os(macOS)
    /// Let a vertical wheel gesture over a shelf reach its enclosing page.
    private struct FoundationMacCarouselWheelRouting: NSViewRepresentable {
        func makeNSView(context: Context) -> FoundationMacCarouselWheelView {
            FoundationMacCarouselWheelView()
        }
        func updateNSView(_ view: FoundationMacCarouselWheelView, context: Context) {}
        static func dismantleNSView(_ view: FoundationMacCarouselWheelView, coordinator: ()) {
            view.stopMonitoring()
        }
    }

    private final class FoundationMacCarouselWheelView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                        !event.modifierFlags.contains(.shift),
                        abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                        self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                    else { return false }
                    var ancestor = self.superview
                    while let view = ancestor {
                        if let scroll = view as? NSScrollView,
                            let document = scroll.documentView,
                            document.bounds.height > scroll.contentView.bounds.height + 1
                        {
                            scroll.scrollWheel(with: event)
                            return true
                        }
                        ancestor = view.superview
                    }
                    return false
                }
                return handled ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
#endif

private struct FoundationMacShelfUnderlap: ViewModifier {
    let horizontalInset: CGFloat
    let contentInset: CGFloat
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
            content
                .background(FoundationMacCarouselWheelRouting())
                .contentMargins(.horizontal, contentInset, for: .scrollContent)
                .padding(.horizontal, -horizontalInset)
                // Overflow is visual; the viewport still starts inside the detail column.
                .scrollClipDisabled()
        #else
            content
        #endif
    }
}

extension View {
    /// Keep Favorites aligned with its detail column while forwarding vertical wheel input.
    @ViewBuilder func foundationMacContainedShelf() -> some View {
        #if os(macOS)
            self.background(FoundationMacCarouselWheelRouting())
                .scrollClipDisabled(false)
        #else
            self
        #endif
    }

    func foundationMacShelfUnderlap(horizontalInset: CGFloat = 16, contentInset: CGFloat = 16)
        -> some View
    {
        modifier(
            FoundationMacShelfUnderlap(horizontalInset: horizontalInset, contentInset: contentInset)
        )
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

// Carousel items reach the Mac content edges; mobile keeps its existing inset.
extension View {
    @ViewBuilder func foundationCarouselContentPadding() -> some View {
        #if os(macOS)
            self
        #else
            self.padding(.horizontal, 16)
        #endif
    }
}
