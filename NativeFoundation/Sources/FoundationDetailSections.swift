import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Optional item text owns one visible-page read; presenting it adds no work.
struct FoundationOverviewSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let item: FoundationItem
    let library: any FoundationLibrary
    let isActive: Bool
    var maximumLines: Int? = 3
    var horizontalInset: CGFloat = 16
    #if os(macOS)
        @ScaledMetric(relativeTo: .body) private var overviewTextSize = 15.0
    #endif

    private var overviewFont: Font {
        #if os(macOS)
            .system(size: overviewTextSize)
        #else
            .subheadline
        #endif
    }

    @State private var overview: String?
    @State private var loaded = false
    @State private var showingOverview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let overview, !overview.isEmpty {
                Button {
                    showingOverview = true
                } label: {
                    HStack(alignment: .bottom, spacing: 6) {
                        Text(overview).lineLimit(maximumLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("… MORE").font(.caption.weight(.semibold))
                    }
                    .font(overviewFont).multilineTextAlignment(.leading)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, horizontalInset).padding(.bottom, 8)
                .accessibilityLabel("Overview: " + overview)
                .accessibilityHint("Opens the complete overview")
                .sheet(isPresented: $showingOverview) {
                    NavigationStack {
                        ScrollView {
                            Text(overview)
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
        }
        .task(id: isActive && !connectivity.localOnly) {
            guard isActive, !connectivity.localOnly, item.kind == .artist || item.kind == .album,
                !loaded
            else { return }
            do {
                let text = try await library.overview(for: item)
                try Task.checkCancellation()
                overview = text
                loaded = true
            } catch {
                if !Task.isCancelled { loaded = true }
            }
        }
    }
}

/// Reuses catalog ownership and cards; each optional shelf fails independently.
struct FoundationRelatedSection<Card: View>: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    let isActive: Bool
    var twoRows = false
    let loader: (Int) async throws -> FoundationPage
    @ViewBuilder let card: (FoundationItem) -> Card
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty || model.errorMessage != nil {
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
                    .foundationMacShelfUnderlap(horizontalInset: 0, contentInset: 0)
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
            if model.isLoading, !connectivity.localOnly {
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
        .padding(.vertical, model.items.isEmpty && model.errorMessage == nil ? 0 : 12)
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            model.request(.refresh)
            revision += 1
        }
        .task(id: isActive && !connectivity.localOnly ? revision : nil) {
            await model.loadPending(ifActive: isActive && !connectivity.localOnly, using: loader)
        }
    }

    private func request(_ request: FoundationBrowseModel.Request) {
        guard !connectivity.localOnly else { return }
        model.request(request)
        revision += 1
    }
}

/// A bounded personal-history shelf; it never expands the artist's catalog.
struct FoundationArtistMostPlayed: View {
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let artist: FoundationItem
    let library: any FoundationLibrary
    @ObservedObject var player: FoundationPlayer
    let isActive: Bool
    let navigate: (FoundationItem) -> Void
    @StateObject private var model = FoundationBrowseModel()
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.items.isEmpty || model.errorMessage != nil {
                Text("Most Played").font(.title2.bold()).padding(.horizontal)
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
                    .foundationMacShelfUnderlap(horizontalInset: 0, contentInset: 0)
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
            if model.isLoading, !connectivity.localOnly {
                FoundationLoadingPlaceholder().padding(.horizontal)
            }
        }
        .padding(.vertical, model.items.isEmpty && model.errorMessage == nil ? 0 : 12)
        .onChange(of: connectivity.successfulRetryRevision) { _, _ in
            model.request(.refresh)
            revision += 1
        }
        .task(id: isActive && !connectivity.localOnly ? revision : nil) {
            await model.loadPending(ifActive: isActive && !connectivity.localOnly) { _ in
                try await library.mostPlayed(artistID: artist.id)
            }
        }
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
