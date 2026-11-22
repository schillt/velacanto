import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Capture the window's semantic appearance before immersive artwork changes detail colors.
private struct FoundationBrowsingColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

extension EnvironmentValues {
    var foundationBrowsingColorScheme: ColorScheme? {
        get { self[FoundationBrowsingColorSchemeKey.self] }
        set { self[FoundationBrowsingColorSchemeKey.self] = newValue }
    }
}

/// Optional item text owns one visible-page read; presenting it adds no work.
struct FoundationOverviewSection: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    var maximumLines: Int? = 3
    var horizontalInset: CGFloat = 16
    var retryMetadata: (() -> Void)? = nil
    var artistUsesLightText: Bool? = nil
    #if os(macOS)
        @ScaledMetric(relativeTo: .body) private var overviewTextSize = 15.0
    #endif

    private var overviewFont: Font {
        #if os(macOS)
            .system(size: overviewTextSize)
        #else
            item.kind == .artist ? .body : .subheadline
        #endif
    }

    private var overviewForeground: Color {
        guard item.kind == .artist else { return .secondary }
        return artistUsesLightText.map { $0 ? .white : .black } ?? .primary
    }

    @State private var overview: String?
    @State private var loaded = false
    @State private var loadedRetryRevision: Int?
    @State private var failed = false
    @State private var retryRevision = 0
    @State private var showingOverview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if item.kind == .artist, overview == nil, !loaded, !failed,
                isActive, !connectivity.localOnly
            {
                FoundationLoadingPlaceholder(layout: .overview)
                    .font(overviewFont)
                    .padding(.horizontal, horizontalInset).padding(.bottom, 8)
                    .transition(.opacity)
            }
            if let overview, !overview.isEmpty {
                Button {
                    showingOverview = true
                } label: {
                    Group {
                        if item.kind == .artist {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(overview).lineLimit(maximumLines).lineSpacing(4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("Read More").font(.subheadline.weight(.semibold))
                            }
                        } else {
                            HStack(alignment: .bottom, spacing: 6) {
                                Text(overview).lineLimit(maximumLines)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("… MORE").font(.caption.weight(.semibold))
                            }
                        }
                    }
                    .font(overviewFont).multilineTextAlignment(.leading)
                    .foregroundStyle(overviewForeground)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, horizontalInset).padding(.bottom, 8)
                .accessibilityLabel("Overview: " + overview)
                .accessibilityHint("Opens the complete overview")
                .transition(.opacity)
                .sheet(isPresented: $showingOverview) {
                    FoundationOverviewSheet(item: item, overview: overview) {
                        showingOverview = false
                    }
                }
            }
            if failed, !connectivity.localOnly {
                Button(item.kind == .artist ? "Retry Artist Details" : "Retry Overview") {
                    retryMetadata?()
                    failed = false
                    loaded = false
                    retryRevision += 1
                }
                .font(.caption).padding(.horizontal, horizontalInset)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: overview != nil)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: loaded || failed)
        .task(
            id:
                "\(library.catalogScopeID)-\(item.id)-\(isActive)-\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)-\(retryRevision)"
        ) {
            guard isActive, item.kind == .artist || item.kind == .album else { return }
            if let cached = await library.cachedArtistDetails(for: item) {
                guard !Task.isCancelled else { return }
                overview = cached.overview
            }
            guard !connectivity.localOnly,
                !loaded || loadedRetryRevision != connectivity.successfulRetryRevision
            else { return }
            do {
                let text = try await library.overview(for: item)
                try Task.checkCancellation()
                overview = text
                loaded = true
                loadedRetryRevision = connectivity.successfulRetryRevision
                failed = false
            } catch {
                // A failed optional read remains eligible for explicit connection retry.
                // Keep any previously loaded overview visible.
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// A text reading surface follows the window, rather than the presenting artwork's tint.
struct FoundationOverviewSheet: View {
    let item: FoundationItem
    let overview: String
    let dismiss: () -> Void
    @Environment(\.foundationBrowsingColorScheme) private var browsingColorScheme
    @Environment(\.colorScheme) private var inheritedColorScheme
    #if os(iOS)
        @State private var detent = PresentationDetent.medium
    #endif
    #if os(macOS)
        @ScaledMetric(relativeTo: .body) private var textSize = 15.0
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(overview)
                    #if os(macOS)
                        .font(.system(size: textSize))
                    #else
                        .font(.body)
                    #endif
                    .lineSpacing(5)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: 600, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            #if os(iOS)
                .scrollDisabled(detent != .large)
            #else
                .background(.background)
            #endif
            .navigationTitle("About " + item.title)
            .foundationOfflineBrowsingBanner()
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            #if os(macOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done", action: dismiss)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("overview-done")
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                    .background(.background)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("overview-reading-footer")
                }
            #endif
        }
        #if os(macOS)
            // Reset the immersive presenter's style before resolving hierarchical text and actions.
            .foregroundStyle(Color.primary)
            .onExitCommand(perform: dismiss)
        #endif
        // Immersive detail controls may use a white tint; native sheet actions use the app accent.
        .tint(.accentColor)
        .preferredColorScheme(browsingColorScheme ?? inheritedColorScheme)
        .environment(\.colorScheme, browsingColorScheme ?? inheritedColorScheme)
        .accessibilityAction(.escape, dismiss)
        #if os(iOS)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
        #else
            .presentationBackground(.background)
            .frame(minWidth: 400, idealWidth: 600, minHeight: 360, idealHeight: 600)
        #endif
    }
}

/// Reuses catalog ownership and cards; each optional shelf fails independently.
struct FoundationRelatedSection<Card: View>: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    let isActive: Bool
    var twoRows = false
    var priority: TaskPriority = .userInitiated
    let loader: (Int) async throws -> FoundationPage
    @ViewBuilder let card:
        (
            FoundationItem, @escaping @MainActor @Sendable () -> FoundationItem?
        ) -> Card
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0
    @State private var isVisible = false
    @State private var pageDemand = FoundationCatalogPageDemand()

    private var displayedItems: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: model.items) : model.items
    }

    private var showsError: Bool { !connectivity.localOnly && model.errorMessage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsInitialPlaceholder || !displayedItems.isEmpty || showsError {
                Text(title).font(.title2.bold()).padding(.horizontal)
            }
            if !displayedItems.isEmpty || (model.hasMorePages && !connectivity.localOnly) {
                ScrollView(.horizontal) {
                    Group {
                        if twoRows {
                            LazyHGrid(
                                rows: [
                                    GridItem(.flexible(), spacing: 20, alignment: .top),
                                    GridItem(.flexible(), spacing: 20, alignment: .top),
                                ], alignment: .top, spacing: 16
                            ) {
                                relatedCards
                            }
                        } else {
                            LazyHStack(alignment: .top, spacing: 16) {
                                relatedCards
                            }
                        }
                    }.foundationCarouselContentPadding()
                }
                .onScrollPhaseChange { _, phase in
                    pageDemand.scrollPhaseChanged(
                        to: phase, footerVisible: pageDemand.footerVisible,
                        active: isActive && isVisible && scenePhase == .active,
                        allowsNetwork: !connectivity.localOnly,
                        isLoading: model.isLoading, hasError: model.errorMessage != nil)
                }
                .scrollBounceBehavior(.always, axes: .horizontal)
                .foundationHorizontalScrollIndicators()
                .foundationMacShelfUnderlap(horizontalInset: 0)
                .transition(.opacity)
            }
            if model.hasConnectionIssue {
                FoundationOfflineNotice().padding(.horizontal)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue, !connectivity.localOnly {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Button("Retry") { request(model.retryRequest) }.padding(.horizontal)
            }
            if displayedItems.isEmpty, showsInitialPlaceholder {
                VStack(spacing: 20) {
                    FoundationLoadingPlaceholder(layout: .albumShelf)
                    if twoRows { FoundationLoadingPlaceholder(layout: .albumShelf) }
                }.padding(.horizontal)
            }
        }
        .padding(
            .vertical,
            showsInitialPlaceholder || !displayedItems.isEmpty || showsError ? 12 : 0
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: displayedItems.isEmpty)
        .onAppear {
            // Similar/appearance shelves contain catalog entities, not memberships.
            model.configureCatalogPagination()
            isVisible = true
        }
        .onDisappear { isVisible = false }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            model.request(.refresh)
            revision += 1
        }
        .task(id: isActive && !connectivity.localOnly ? revision : nil, priority: priority) {
            model.configureFavoriteObservations(actions)
            await model.loadPending(
                ifActive: isActive && !connectivity.localOnly, waitForInitialLoad: true,
                using: loader)
        }
    }

    @ViewBuilder private var relatedCards: some View {
        ForEach(catalogRows) { row in
            card(row.item, { currentItem(row.id) }).frame(width: 150)
        }
        if model.hasMorePages, !connectivity.localOnly {
            FoundationPaginationFooter(
                demand: $pageDemand, isLoading: model.isLoading,
                isEnabled: isActive && isVisible && scenePhase == .active,
                hasError: model.errorMessage != nil, showsScrollHint: displayedItems.isEmpty
            ) {
                await model.loadNextVisiblePage(
                    ifActive: { isActive && isVisible && scenePhase == .active },
                    allowsNetwork: { !connectivity.localOnly }, using: loader)
            }
            .frame(width: 150).frame(minHeight: 44)
            .id(model.catalogIdentityContext)
        }
    }

    private var catalogRows: [FoundationLibraryIndexSelection.PositionedItem] {
        guard model.hasUniqueCatalogIdentity else { return [] }
        return FoundationLibraryIndexSelection.positionedItems(displayedItems, actions: actions)
    }

    private func currentItem(_ id: FoundationLibraryIndexSelection.Identity) -> FoundationItem? {
        guard isActive, isVisible else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedItems, actions: actions)?
            .item
    }

    private var showsInitialPlaceholder: Bool {
        isActive && !connectivity.localOnly && !model.loaded && model.errorMessage == nil
    }

    private func request(_ request: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        model.request(request)
        revision += 1
    }
}

/// A stable bounded discovery shelf, including artists without listening history.
struct FoundationArtistSuggestedSongs: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let artist: FoundationItem
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    let navigate: (FoundationItem) -> Void
    @StateObject private var model = FoundationBrowseModel(
        refreshInterval: 30 * 60, usesCachedFreshness: true)
    @State private var revision = 0
    @State private var isVisible = false

    private var displayedItems: [FoundationItem] {
        connectivity.localOnly ? downloads.itemsWithDownloadedMusic(in: model.items) : model.items
    }

    private var showsError: Bool { !connectivity.localOnly && model.errorMessage != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsInitialPlaceholder || !displayedItems.isEmpty || showsError {
                Text("Suggested Songs").font(.title2.bold()).padding(.horizontal)
            }
            if !displayedItems.isEmpty {
                ScrollView(.horizontal) {
                    LazyHGrid(
                        rows: [
                            GridItem(.flexible(), spacing: 16, alignment: .top),
                            GridItem(.flexible(), spacing: 16, alignment: .top),
                        ], alignment: .top, spacing: 20
                    ) {
                        ForEach(
                            FoundationLibraryIndexSelection.positionedItems(
                                displayedItems, actions: actions)
                        ) { row in
                            FoundationLibraryItemRow(
                                item: row.item, library: library,
                                isActive: isActive && isVisible,
                                open: {}, play: { play(row.id) }, player: player,
                                showsTrackArtwork: true,
                                navigate: { navigateRelated($0, from: row.id) },
                                currentPageKind: .artist,
                                subtitleOverride: row.item.album?.title ?? "",
                                canPerform: { _ in
                                    FoundationLibraryIndexSelection.admits(
                                        row.item, current: currentItem(row.id))
                                }
                            )
                            .frame(width: 300)
                        }
                    }.foundationCarouselContentPadding()
                }.foundationHorizontalScrollIndicators()
                    .foundationMacShelfUnderlap(horizontalInset: 0)
                    .transition(.opacity)
            }
            if model.hasConnectionIssue {
                FoundationOfflineNotice().padding(.horizontal)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue, !connectivity.localOnly {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Button("Retry") {
                    guard !connectivity.localOnly else { return }
                    model.request(model.retryRequest)
                    revision += 1
                }.disabled(connectivity.localOnly).padding(.horizontal)
            }
            if displayedItems.isEmpty, showsInitialPlaceholder {
                FoundationLoadingPlaceholder(rowCount: 2, rowArtworkSize: 52).padding(.horizontal)
            }
        }
        .padding(
            .vertical,
            showsInitialPlaceholder || !displayedItems.isEmpty || showsError ? 12 : 0
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: displayedItems.isEmpty)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            model.request(.refresh)
            revision += 1
        }
        .task(
            id:
                "\(library.catalogScopeID)-\(artist.id)-\(isActive && !connectivity.localOnly)-\(revision)"
        ) {
            model.configureCache(
                library.catalogPageCache,
                key: library.catalogCacheKey("artist-suggested-songs-" + artist.id))
            model.configureFavoriteObservations(actions)
            await model.loadPending(
                ifActive: isActive && !connectivity.localOnly, waitForInitialLoad: true
            ) { _ in
                try await library.suggestedSongs(artistID: artist.id)
            }
        }
    }

    private var showsInitialPlaceholder: Bool {
        isActive && !connectivity.localOnly && !model.loaded && model.errorMessage == nil
    }

    private func currentItem(_ id: FoundationLibraryIndexSelection.Identity) -> FoundationItem? {
        guard isActive, isVisible else { return nil }
        return FoundationLibraryIndexSelection.resolve(id, in: displayedItems, actions: actions)?
            .item
    }

    private func navigateRelated(
        _ target: FoundationItem, from id: FoundationLibraryIndexSelection.Identity
    ) {
        guard isActive, isVisible,
            let item = FoundationLibraryIndexSelection.relatedDestination(
                target, from: id, in: displayedItems, actions: actions)
        else { return }
        navigate(item)
    }

    private func play(_ id: FoundationLibraryIndexSelection.Identity) {
        let items = displayedItems
        guard isActive, isVisible,
            let match = FoundationLibraryIndexSelection.resolve(id, in: items, actions: actions),
            let selection = FoundationTrackQueueSelection(
                in: items, selecting: match.sourceIndex,
                isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }
}

/// A visual hint only; native sheet and player gestures keep ownership of dismissal.
private struct FoundationIdleGrabber: ViewModifier {
    let showsOverlay: Bool
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @State private var visible = true
    @State private var activity = 0
    @State private var touching = false
    #if os(macOS)
        @GestureState private var dragging = false
    #endif

    func body(content: Content) -> some View {
        content
            .environment(\.foundationGrabberVisible, visible)
            .overlay(alignment: .top) {
                if showsOverlay {
                    Capsule().fill(.secondary.opacity(0.65))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            #if os(iOS)
                .background {
                    FoundationGrabberTouchObserver { active in
                        touching = active
                        activity += 1
                    }
                    .allowsHitTesting(false)
                }
            #else
                .simultaneousGesture(TapGesture().onEnded { activity += 1 })
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10)
                        .updating($dragging) { _, state, _ in state = true }
                )
                .onChange(of: dragging) { _, active in
                    touching = active
                    activity += 1
                }
                .onHover { hovering in
                    if hovering { activity += 1 }
                }
            #endif
            .task(id: activity) {
                visible = true
                guard !touching else { return }
                do {
                    try await Task.sleep(for: .seconds(3))
                    try Task.checkCancellation()
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                        visible = false
                    }
                } catch {}
            }
    }
}

private struct FoundationGrabberVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    fileprivate var foundationGrabberVisible: Bool {
        get { self[FoundationGrabberVisibleKey.self] }
        set { self[FoundationGrabberVisibleKey.self] = newValue }
    }
}

private struct FoundationGrabberVisibility: ViewModifier {
    @Environment(\.foundationGrabberVisible) private var visible
    func body(content: Content) -> some View {
        content.opacity(visible ? 1 : 0)
    }
}

extension View {
    func foundationIdleGrabber(showsOverlay: Bool = false) -> some View {
        modifier(FoundationIdleGrabber(showsOverlay: showsOverlay))
    }

    func foundationGrabberVisibility() -> some View {
        modifier(FoundationGrabberVisibility())
    }
}

#if os(iOS)
    /// Observes activity without winning, cancelling, or delaying any app gesture.
    private struct FoundationGrabberTouchObserver: UIViewRepresentable {
        let interaction: (Bool) -> Void

        func makeUIView(context: Context) -> ObserverView {
            let view = ObserverView()
            view.recognizer.interaction = interaction
            return view
        }

        func updateUIView(_ view: ObserverView, context: Context) {
            view.recognizer.interaction = interaction
        }

        static func dismantleUIView(_ view: ObserverView, coordinator: ()) {
            view.recognizer.interaction = nil
            view.recognizer.view?.removeGestureRecognizer(view.recognizer)
        }

        final class ObserverView: UIView {
            let recognizer = ActivityRecognizer()

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard recognizer.view !== window else { return }
                recognizer.view?.removeGestureRecognizer(recognizer)
                window?.addGestureRecognizer(recognizer)
            }
        }

        final class ActivityRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
            var interaction: ((Bool) -> Void)?
            private var activeTouches: Set<UITouch> = []

            init() {
                super.init(target: nil, action: nil)
                cancelsTouchesInView = false
                delaysTouchesBegan = false
                delaysTouchesEnded = false
                delegate = self
            }

            override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
                false
            }

            override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer)
                -> Bool
            {
                false
            }

            func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
            ) -> Bool {
                true
            }

            override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
                let wasEmpty = activeTouches.isEmpty
                activeTouches.formUnion(touches)
                state = wasEmpty ? .began : .changed
                if wasEmpty { interaction?(true) }
            }

            override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
                state = .changed
            }

            override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
                finish(touches)
            }

            override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
                finish(touches)
            }

            private func finish(_ touches: Set<UITouch>) {
                activeTouches.subtract(touches)
                if activeTouches.isEmpty {
                    interaction?(false)
                    state = .ended
                }
            }

            override func reset() {
                super.reset()
                if !activeTouches.isEmpty { interaction?(false) }
                activeTouches.removeAll()
            }
        }
    }
#endif

/// Album reading coordinates are measured from content, never inferred from image aspect ratio.
struct FoundationAlbumBackdropProfile {
    struct Stop {
        let location: CGFloat
        let opacity: Double
    }
    let imageSide: CGFloat
    let height: CGFloat
    let readingStart: CGFloat
    let readingEnd: CGFloat
    let imageFadeStart: CGFloat

    init(imageSide: CGFloat, height: CGFloat, controlsBottom: CGFloat?, readingTop: CGFloat?) {
        self.imageSide = imageSide.isFinite && imageSide > 0 ? imageSide : 1
        self.height = height.isFinite && height > 0 ? height : 1
        let controls = controlsBottom.flatMap { $0.isFinite ? $0 : nil }
        let reading = readingTop.flatMap { $0.isFinite ? $0 : nil }
        readingStart = min(self.height, max(0, controls ?? 0))
        if let controls, controls > 0 {
            if let reading {
                readingEnd = min(self.height, max(readingStart, reading))
            } else {
                readingEnd = min(self.height, readingStart + max(48, self.height * 0.16))
            }
        } else {
            // Missing or scrolled-off controls mean reading content already fills the viewport.
            readingEnd = readingStart
        }
        imageFadeStart = min(max(0, controls ?? 0), self.imageSide * 0.55)
    }

    func readingAmount(at y: CGFloat) -> Double {
        guard y.isFinite, readingEnd > readingStart else { return 1 }
        return FoundationArtistBackdropProfile.eased(
            Double(y), from: Double(readingStart), to: Double(readingEnd))
    }

    func imageOpacity(at y: CGFloat) -> Double {
        guard y.isFinite else { return 0 }
        return 1
            - FoundationArtistBackdropProfile.eased(
                Double(y), from: Double(imageFadeStart), to: Double(imageSide))
    }

    var readingStops: [Stop] {
        stops(from: readingStart, to: readingEnd, extent: height, opacity: readingAmount)
    }

    var imageStops: [Stop] {
        stops(from: imageFadeStart, to: imageSide, extent: imageSide, opacity: imageOpacity)
    }

    var neutralStops: [Stop] {
        readingStops.map { stop in
            // Follow the smooth reading ramp without a darker intermediate band.
            // Keep the established lower-page contrast rather than peaking then brightening.
            return Stop(location: stop.location, opacity: 0.1 + stop.opacity * 0.1)
        }
    }

    private func stops(
        from start: CGFloat, to end: CGFloat, extent: CGFloat,
        opacity: (CGFloat) -> Double
    ) -> [Stop] {
        let positions = Set(
            [CGFloat.zero, extent]
                + (0...12).map {
                    start + (end - start) * CGFloat($0) / 12
                })
        return positions.sorted().map {
            Stop(location: $0 / extent, opacity: min(1, max(0, opacity($0))))
        }
    }
}

struct FoundationAlbumReadingBoundsKey: Hashable {
    enum Role: Hashable { case controls, tracks }
    let itemID: String
    let role: Role
}

struct FoundationAlbumReadingBoundsPreference: PreferenceKey {
    static let defaultValue: [FoundationAlbumReadingBoundsKey: Anchor<CGRect>] = [:]
    static func reduce(
        value: inout [FoundationAlbumReadingBoundsKey: Anchor<CGRect>],
        nextValue: () -> [FoundationAlbumReadingBoundsKey: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// One continuous diffusion surface under album content; the caller preserves hero clarity.
/// Read the effective collection appearance, including its immersive override.
struct FoundationAlbumContentBacking: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.foundationReduceTransparency) private var reduceTransparency

    private var surface: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(.background) }
        return contrast == .increased
            ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial)
    }

    private var scrimOpacity: Double {
        if reduceTransparency { return 0 }
        if contrast == .increased { return colorScheme == .dark ? 0.16 : 0.10 }
        return colorScheme == .dark ? 0.08 : 0.04
    }

    var body: some View {
        Rectangle()
            .fill(surface)
            .overlay {
                (colorScheme == .dark ? Color.black : Color.white).opacity(scrimOpacity)
            }
            // Extend only decoration beneath native top/bottom chrome, within this detail column.
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
