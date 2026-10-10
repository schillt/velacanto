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
        @State private var sidebarWidth: CGFloat = 230
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
                .navigationSplitViewColumnWidth(min: 170, ideal: 230, max: 280)
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
        case item(FoundationItem)

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
                        FoundationMacPlaybackGlyph(kind: .previous).frame(width: 36, height: 36)
                            .foregroundStyle(Color.white).opacity(item == nil ? 0.35 : 1)
                    }
                    .disabled(item == nil).help("Previous track (⌘←)")
                    .accessibilityLabel("Previous")
                    Button {
                        player.togglePlayback()
                    } label: {
                        FoundationMacPlaybackGlyph(kind: player.wantsPlayback ? .pause : .play)
                            .frame(width: 36, height: 36)
                            .foregroundStyle(Color.white).opacity(item == nil ? 0.35 : 1)
                    }
                    .disabled(item == nil)
                    .accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
                    .accessibilityIdentifier("foundation-mini-playback-toggle")
                    Button {
                        player.next()
                    } label: {
                        FoundationMacPlaybackGlyph(kind: .next).frame(width: 36, height: 36)
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
                            .accessibilityLabel("Velacanto — Nothing playing")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                FoundationMacTransportTools(
                    player: player, lyricsEnabled: lyricsEnabled,
                    lyricsSelected: lyricsSelected, queueSelected: queueSelected,
                    toggleLyrics: toggleLyrics, toggleQueue: toggleQueue
                ).frame(width: 156)
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
                    Image(systemName: "quote.bubble").frame(width: 32, height: 36)
                }
                .disabled(!lyricsEnabled)
                .foregroundStyle(lyricsSelected ? Color.accentColor : Color.primary)
                .help("Lyrics (⇧⌘L)").accessibilityLabel("Show lyrics")
                .accessibilityAddTraits(lyricsSelected ? .isSelected : [])
                Button(action: toggleQueue) {
                    Image(systemName: "list.bullet").frame(width: 32, height: 36)
                }
                .disabled(player.queue.isEmpty)
                .foregroundStyle(queueSelected ? Color.accentColor : Color.primary)
                .help("Queue (⇧⌘Q)").accessibilityLabel("Show queue")
                .accessibilityAddTraits(queueSelected ? .isSelected : [])
                FoundationAirPlayPicker(player: player).frame(width: 32, height: 36)
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
                    .frame(width: 32, height: 36)
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
                .ignoresSafeArea(.container, edges: .horizontal)
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
