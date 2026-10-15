import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Optional item text owns one visible-page read; presenting it adds no work.
struct FoundationOverviewSection: View {
    @Environment(\.colorScheme) private var colorScheme
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
                    NavigationStack {
                        ScrollView {
                            Text(overview)
                                .lineSpacing(item.kind == .artist ? 4 : 0)
                                #if os(macOS)
                                    .font(overviewFont)
                                #endif
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled).padding()
                        }
                        .navigationTitle("About " + item.title)
                        #if os(iOS)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbarBackground(.hidden, for: .navigationBar)
                        #else
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { showingOverview = false }
                                }
                            }
                        #endif
                    }
                    // Match native sheet chrome to the semantic colors inherited from its detail.
                    .preferredColorScheme(colorScheme)
                    #if os(iOS)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.hidden)
                        .foundationIdleGrabber(showsOverlay: true)
                        .accessibilityAction(.escape) { showingOverview = false }
                    #else
                        .frame(minWidth: 360, idealWidth: 480, minHeight: 320, idealHeight: 520)
                        .background(.regularMaterial)
                    #endif
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

/// Reuses catalog ownership and cards; each optional shelf fails independently.
struct FoundationRelatedSection<Card: View>: View {
    @Environment(\.foundationReduceMotion) private var reduceMotion
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    let isActive: Bool
    var twoRows = false
    var priority: TaskPriority = .userInitiated
    let loader: (Int) async throws -> FoundationPage
    @ViewBuilder let card: (FoundationItem) -> Card
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsInitialPlaceholder || !model.items.isEmpty || model.errorMessage != nil {
                Text(title).font(.title2.bold()).padding(.horizontal)
            }
            if !model.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        let rows = twoRows ? 2 : 1
                        ForEach(0..<((model.items.count + rows - 1) / rows), id: \.self) { column in
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(
                                    column * rows..<min(column * rows + rows, model.items.count),
                                    id: \.self
                                ) { index in
                                    card(model.items[index]).frame(width: 150)
                                }
                            }
                        }
                    }.foundationCarouselContentPadding()
                }.scrollIndicators(.hidden)
                    .foundationMacShelfUnderlap(horizontalInset: 0)
                    .transition(.opacity)
            }
            if model.hasConnectionIssue {
                FoundationOfflineNotice().padding(.horizontal)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue {
                if connectivity.localOnly {
                    if model.items.isEmpty { FoundationOfflineNotice().padding(.horizontal) }
                } else {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    Button("Retry") { request(model.retryRequest) }.padding(.horizontal)
                }
            }
            if model.items.isEmpty, showsInitialPlaceholder {
                VStack(spacing: 20) {
                    FoundationLoadingPlaceholder(layout: .albumShelf)
                    if twoRows { FoundationLoadingPlaceholder(layout: .albumShelf) }
                }.padding(.horizontal)
            }
            if model.nextStartIndex != nil {
                Button("Load more") { request(.more) }.disabled(
                    model.isLoading || connectivity.localOnly
                ).padding(
                    .horizontal)
            }
        }
        .padding(
            .vertical,
            showsInitialPlaceholder || !model.items.isEmpty || model.errorMessage != nil ? 12 : 0
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.items.isEmpty)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsInitialPlaceholder || !model.items.isEmpty || model.errorMessage != nil {
                Text("Suggested Songs").font(.title2.bold()).padding(.horizontal)
            }
            if !model.items.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 20) {
                        ForEach(0..<((model.items.count + 1) / 2), id: \.self) { column in
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(
                                    column * 2..<min(column * 2 + 2, model.items.count), id: \.self
                                ) { index in
                                    FoundationLibraryItemRow(
                                        item: model.items[index], library: library,
                                        isActive: isActive,
                                        open: {}, play: { play(index) }, player: player,
                                        showsTrackArtwork: true, navigate: navigate,
                                        currentPageKind: .artist,
                                        subtitleOverride: model.items[index].album?.title ?? "")
                                }
                            }.frame(width: 300)
                        }
                    }.foundationCarouselContentPadding()
                }.scrollIndicators(.hidden)
                    .foundationMacShelfUnderlap(horizontalInset: 0)
                    .transition(.opacity)
            }
            if model.hasConnectionIssue {
                FoundationOfflineNotice().padding(.horizontal)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                Button("Retry") {
                    guard !connectivity.localOnly else { return }
                    model.request(model.retryRequest)
                    revision += 1
                }.disabled(connectivity.localOnly).padding(.horizontal)
            }
            if model.items.isEmpty, showsInitialPlaceholder {
                FoundationLoadingPlaceholder(rowCount: 2, rowArtworkSize: 52).padding(.horizontal)
            }
        }
        .padding(
            .vertical,
            showsInitialPlaceholder || !model.items.isEmpty || model.errorMessage != nil ? 12 : 0
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.items.isEmpty)
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

    private func play(_ index: Int) {
        guard let selection = model.trackQueue(selecting: index) else { return }
        if connectivity.localOnly {
            guard downloads.isReady(selection.items[selection.index]) else { return }
            let ready = selection.items.filter { downloads.isReady($0) }
            let index = selection.items.prefix(selection.index).filter { downloads.isReady($0) }
                .count
            player.setQueue(ready, selectedIndex: index)
        } else {
            player.setQueue(selection.items, selectedIndex: selection.index)
        }

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
