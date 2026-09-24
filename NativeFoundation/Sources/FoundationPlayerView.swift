import SwiftUI

struct FoundationPlayerView: View {
    @ObservedObject var player: FoundationPlayer
    let library: any FoundationLibrary
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var artworkFill: Image?
    @State private var artworkUpperEdgeColors: [Color]?
    @State private var artworkTint = Color(white: 0.12)
    @State private var isVisible = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var scrubEntryID: UUID?
    @State private var showingGrabber = true
    @State private var showingQueue = false
    @State private var lyricsPresentation: FoundationLyricsPresentation?
    @State private var showsDelayedLoading = false
    @Environment(\.foundationOpenLibraryItem) private var openLibraryItem
    @State private var queuedDestination: FoundationItem?

    private var current: FoundationItem? {
        player.queue.first { $0.id == player.selectedEntryID }?.item
    }

    private var album: FoundationItem? {
        guard let reference = current?.album else { return nil }
        return FoundationItem(
            id: reference.id, title: reference.title, subtitle: current?.subtitle ?? "",
            kind: .album, duration: nil, primaryImageTag: reference.primaryImageTag,
            artist: current?.artist)
    }

    private var artist: FoundationItem? {
        guard let reference = current?.artist else { return nil }
        return FoundationItem(
            id: reference.id, title: reference.title, subtitle: "", kind: .artist, duration: nil)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    GeometryReader { artworkGeometry in
                        ZStack {
                            artworkView(
                                size: artworkGeometry.size.width,
                                height: artworkGeometry.size.width
                                    + max(
                                        0, artworkGeometry.size.height - artworkGeometry.size.width)
                                    * 0.75
                            )
                            .mask {
                                LinearGradient(
                                    stops: [
                                        .init(color: .white, location: 0.84),
                                        .init(color: .white.opacity(0.82), location: 0.90),
                                        .init(color: .white.opacity(0.35), location: 0.96),
                                        .init(color: .white.opacity(0.07), location: 0.99),
                                        .init(color: .clear, location: 1),
                                    ], startPoint: .top, endPoint: .bottom)
                            }
                            .frame(width: artworkGeometry.size.width, alignment: .top)
                            .overlay(alignment: .top) {
                                if let artworkUpperEdgeColors, geometry.safeAreaInsets.top > 0 {
                                    // Broad edge colors preserve the cover palette without
                                    // reflecting objects. Retain the wider feather at the join.
                                    LinearGradient(
                                        colors: artworkUpperEdgeColors,
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                    .frame(
                                        width: artworkGeometry.size.width,
                                        height: geometry.safeAreaInsets.top + 28
                                    )
                                    .mask {
                                        VStack(spacing: 0) {
                                            Rectangle().fill(.white)
                                                .frame(height: geometry.safeAreaInsets.top)
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .white, location: 0),
                                                    .init(
                                                        color: .white.opacity(0.65),
                                                        location: 0.25),
                                                    .init(
                                                        color: .white.opacity(0.2),
                                                        location: 0.6),
                                                    .init(color: .clear, location: 1),
                                                ], startPoint: .top, endPoint: .bottom
                                            ).frame(height: 28)
                                        }
                                    }
                                    .offset(y: -geometry.safeAreaInsets.top)
                                }
                            }
                            .opacity(lyricsPresentation == nil ? 1 : 0)
                            .accessibilityHidden(lyricsPresentation != nil)
                            .allowsHitTesting(lyricsPresentation == nil)
                            if let presentation = lyricsPresentation {
                                let entry = presentation.entry
                                FoundationLyricsView(
                                    item: entry.item, entryID: entry.id, library: library,
                                    player: player, model: presentation.model
                                )
                                .id(presentation.id)
                                .transition(.opacity)
                            }
                        }
                        .frame(
                            width: artworkGeometry.size.width, height: artworkGeometry.size.height
                        )
                        .clipped()
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: lyricsPresentation?.id)
                    }
                    VStack(alignment: .leading, spacing: geometry.size.height < 700 ? 8 : 14) {
                        VStack(spacing: 0) {
                            trackDetails
                            timeline
                        }
                        transport
                        volumePlaceholder
                        HStack {
                            Button {
                                lyricsPresentation?.model.cancel()
                                if lyricsPresentation == nil {
                                    lyricsPresentation = player.queue.first {
                                        $0.id == player.selectedEntryID
                                    }.map { FoundationLyricsPresentation(entry: $0) }
                                } else {
                                    lyricsPresentation = nil
                                }
                            } label: {
                                Image(systemName: "quote.bubble")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(current == nil)
                            .accessibilityLabel(
                                lyricsPresentation == nil ? "Show lyrics" : "Show artwork"
                            )
                            .accessibilityAddTraits(lyricsPresentation == nil ? [] : .isSelected)
                            Spacer()
                            FoundationAirPlayPicker(player: player)
                                .frame(width: 44, height: 44)
                            Spacer()
                            Button {
                                showingQueue = true
                            } label: {
                                Image(systemName: "list.bullet")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }.accessibilityLabel("Show Queue")
                        }
                    }
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 580)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background {
                    GeometryReader { background in
                        ZStack {
                            artworkTint
                            if let artworkFill {
                                artworkFill.resizable().scaledToFill().blur(radius: 28)
                                    .frame(
                                        width: background.size.width, height: background.size.height
                                    )
                            }
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.12), location: 0.50),
                                    .init(color: artworkTint.opacity(0.8), location: 0.80),
                                    .init(color: artworkTint, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                        }.frame(width: background.size.width, height: background.size.height)
                            .clipped()
                    }.ignoresSafeArea()
                }
            }
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .foregroundStyle(.white).tint(.white)
            .navigationTitle("")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            #if os(macOS)
                .toolbar { Button("Done") { dismiss() } }
            #else
                .toolbar(.hidden, for: .navigationBar)
            #endif
        }
        .overlay(alignment: .top) {
            #if os(iOS)
                if !showingQueue {
                    Capsule().fill(.white.opacity(0.65))
                        .frame(width: 36, height: 5).padding(.top, 8)
                        .opacity(showingGrabber ? 1 : 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            #endif
        }
        .interactiveDismissDisabled(scrubbing)
        .accessibilityAction(.escape) { dismiss() }
        .task {
            showingGrabber = true
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            withAnimation(.easeOut(duration: 0.5)) { showingGrabber = false }
        }
        .task(id: LoadingCueKey(entryID: player.selectedEntryID, waiting: isWaitingForAudio)) {
            showsDelayedLoading = false
            guard isWaitingForAudio else { return }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            showsDelayedLoading = true
        }
        #if DEBUG
            .environment(\.foundationTraceOrigin, .nowPlaying)
            .onChange(of: isVisible) { _, visible in
                FoundationTrace.event("surface origin=nowPlaying contentVisible=\(visible ? 1 : 0)")
            }
            .onAppear { FoundationTrace.event("surface origin=nowPlaying event=appeared") }
            .onDisappear { FoundationTrace.event("surface origin=nowPlaying event=disappeared") }
            .onChange(of: showingQueue) { _, shown in
                FoundationTrace.event("surface origin=nowPlaying queueSheet=\(shown ? 1 : 0)")
            }
        #endif
        .preferredColorScheme(.dark)
        #if os(macOS)
            .frame(minWidth: 420, idealWidth: 520, minHeight: 660, idealHeight: 800)
        #endif
        .onChange(of: album?.id) { _, _ in
            artworkTint = Color(white: 0.12)
            artworkFill = nil
            artworkUpperEdgeColors = nil
        }
        .onChange(of: player.selectedEntryID) { _, _ in
            scrubbing = false
            scrubEntryID = nil
            lyricsPresentation?.model.cancel()
            lyricsPresentation = nil
        }
        .sheet(isPresented: $showingQueue, onDismiss: finishQueueDismissal) {
            FoundationQueueView(player: player) { item in
                queuedDestination = item
                showingQueue = false
            }
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }

    private func finishQueueDismissal() {
        guard let item = queuedDestination else { return }
        queuedDestination = nil
        openLibraryItem?(item)
    }

    @ViewBuilder private func artworkView(size: CGFloat, height: CGFloat) -> some View {
        if let album {
            FoundationCatalogArtwork(
                source: .current(currentArtwork.result(for: album)), item: album, library: library,
                isActive: isVisible, size: size,
                displayHeight: height,
                sampledColor: $artworkTint, isHero: true,
                loadedImage: $artworkFill,
                upperEdgeColors: $artworkUpperEdgeColors
            ).id(album.id + (album.primaryImageTag ?? ""))
        } else {
            Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary)
                .frame(width: size, height: height)
        }
    }

    private var volumePlaceholder: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
            Slider(value: .constant(0.5), in: 0...1).disabled(true)
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume control preview, unavailable")
    }

    private var trackDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(current?.title ?? "Nothing selected").font(.title2.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    #if DEBUG
                        Button("Play diagnostic tones", systemImage: "waveform") {
                            player.setQueue(FoundationDiagnosticTones.items, selectedIndex: 0)
                        }
                    #endif
                    Button("View Album", systemImage: "square.stack") {
                        if let album { openLibraryItem?(album) }
                    }.disabled(album == nil || openLibraryItem == nil)
                    Button("View Artist", systemImage: "music.mic") {
                        if let artist { openLibraryItem?(artist) }
                    }.disabled(artist == nil || openLibraryItem == nil)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More playback options")
                if let current {
                    let favorite = actions.favoriteState(for: current, initial: current.isFavorite)
                    Button {
                        guard let favorite else { return }
                        Task { await actions.setFavorite(for: current, isFavorite: !favorite) }
                    } label: {
                        Image(systemName: favorite == true ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(favorite == true ? "Unfavorite" : "Favorite")
                    .disabled(favorite == nil || actions.isPending(current))
                }
            }
            if let current {
                Text(
                    [current.subtitle, album?.title].compactMap { $0 }
                        .filter { !$0.isEmpty }.joined(separator: " · ")
                )
                .font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                if let error = actions.errorMessage(for: current) {
                    Text(error).font(.caption)
                }
            }
            if let error = player.errorMessage {
                Text(error).font(.callout)
                Button("Try Again") { if let id = player.selectedEntryID { player.select(id) } }
            }
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: {
                        scrubbing ? scrubPosition : min(player.elapsed, max(0, player.duration))
                    },
                    set: { scrubPosition = $0 }
                ), in: 0...max(1, player.duration),
                onEditingChanged: { editing in
                    if editing {
                        scrubPosition = player.elapsed
                        scrubEntryID = player.selectedEntryID
                        scrubbing = true
                    } else {
                        if scrubbing, let scrubEntryID {
                            player.seek(to: scrubPosition, entryID: scrubEntryID)
                        }
                        scrubbing = false
                        scrubEntryID = nil
                    }
                }
            ).accessibilityLabel("Playback position")
                .accessibilityValue(
                    "\(Self.time(scrubbing ? scrubPosition : player.elapsed)) of \(Self.time(player.duration))"
                )
                .disabled(
                    player.duration <= 0 || player.state == .loading || player.state == .failed)
            HStack {
                Text(Self.time(scrubbing ? scrubPosition : player.elapsed))
                Spacer()
                Text(Self.time(player.duration))
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack {
            Spacer()
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill").frame(width: 60, height: 60)
            }
            .accessibilityLabel("Previous").disabled(selectedIndex == nil)
            Spacer()
            Button {
                player.togglePlayback()
            } label: {
                Image(
                    systemName: showsDelayedLoading
                        ? "ellipsis" : (player.wantsPlayback ? "pause.fill" : "play.fill")
                )
                .symbolEffect(
                    .pulse, options: .repeating, isActive: showsDelayedLoading && !reduceMotion
                )
                .font(.system(size: 46)).frame(width: 72, height: 72)
            }.accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
                .accessibilityValue(showsDelayedLoading ? "Loading audio" : "")
                .disabled(current == nil)
            Spacer()
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").frame(width: 60, height: 60)
            }
            .accessibilityLabel("Next").disabled(
                selectedIndex == nil || selectedIndex == player.queue.count - 1)
            Spacer()
        }.font(.title).buttonStyle(.plain)
    }

    private struct LoadingCueKey: Hashable {
        let entryID: UUID?
        let waiting: Bool
    }

    private var isWaitingForAudio: Bool {
        player.state == .loading || (player.state == .waiting && player.wantsPlayback)
    }

    private var selectedIndex: Int? { player.queue.firstIndex { $0.id == player.selectedEntryID } }

    private static func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let seconds = Int(value)
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct FoundationQueueView: View {
    @ObservedObject var player: FoundationPlayer
    let openItem: (FoundationItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, entry in
                    HStack {
                        Button {
                            player.select(entry.id)
                        } label: {
                            HStack {
                                Text("\(index + 1)").font(.caption).foregroundStyle(.secondary)
                                VStack(alignment: .leading) {
                                    Text(entry.item.title)
                                    Text(entry.item.subtitle).font(.caption).foregroundStyle(
                                        .secondary)
                                }
                                Spacer()
                                if entry.id == player.selectedEntryID {
                                    Image(systemName: "speaker.wave.2.fill")
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            menu(entry)
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 44, height: 44)
                        }
                        .menuStyle(.borderlessButton).accessibilityLabel(
                            "Queue actions for " + entry.item.title)
                    }.contextMenu { menu(entry) }
                }
            }
            .navigationTitle("Queue · \(player.queue.count) songs")
            .toolbar { Button("Done") { dismiss() } }

        }
        #if os(macOS)
            .frame(minWidth: 400, minHeight: 420)
        #endif
    }

    @ViewBuilder private func menu(_ entry: FoundationQueueEntry) -> some View {
        Group {
            Button("Play Next") { player.moveQueuedEntry(entry.id, position: .next) }
            Button("Play Last") { player.moveQueuedEntry(entry.id, position: .last) }
        }.disabled(entry.id == player.selectedEntryID)
        FoundationRelatedDestinations(item: entry.item, navigate: openItem)
    }
}

extension FoundationPlayer.State {
    var label: String {
        switch self {
        case .idle: "Stopped"
        case .loading: "Loading"
        case .waiting: "Waiting for audio"
        case .playing: "Playing"
        case .paused: "Paused"
        case .failed: "Unable to play — select a track to try again"
        case .ended: "Queue ended"
        }
    }
}

private struct FoundationPlayerTransitionKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

private struct FoundationOpenLibraryItemKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (FoundationItem) -> Void)? = nil
}

extension EnvironmentValues {
    var foundationOpenLibraryItem: (@MainActor @Sendable (FoundationItem) -> Void)? {
        get { self[FoundationOpenLibraryItemKey.self] }
        set { self[FoundationOpenLibraryItemKey.self] = newValue }
    }

    var foundationPlayerTransition: Namespace.ID? {
        get { self[FoundationPlayerTransitionKey.self] }
        set { self[FoundationPlayerTransitionKey.self] = newValue }
    }
}

extension View {
    func foundationPlayerCover<PlayerContent: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> PlayerContent
    ) -> some View {
        modifier(FoundationPlayerPresentation(isPresented: isPresented, playerContent: content))
    }

    @ViewBuilder func foundationPlayerArtworkSource(namespace: Namespace.ID) -> some View {
        #if os(iOS)
            self.matchedTransitionSource(id: "now-playing-artwork", in: namespace)
        #else
            self
        #endif
    }
}

private struct FoundationPlayerPresentation<PlayerContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let playerContent: () -> PlayerContent
    @Environment(\.foundationPlayerTransition) private var namespace
    @Environment(\.foundationOpenLibraryItem) private var openLibraryItem
    @State private var pendingDestination: FoundationItem?

    private func finishDismissal() {
        guard let item = pendingDestination else { return }
        pendingDestination = nil
        openLibraryItem?(item)
    }

    private var destinationContent: some View {
        playerContent().environment(
            \.foundationOpenLibraryItem,
            { item in
                pendingDestination = item
                isPresented = false
            })
    }

    func body(content: Content) -> some View {
        #if os(iOS)
            content.fullScreenCover(isPresented: $isPresented, onDismiss: finishDismissal) {
                if let namespace {
                    destinationContent
                        .navigationTransition(.zoom(sourceID: "now-playing-artwork", in: namespace))
                } else {
                    destinationContent
                }
            }
        #else
            content.sheet(isPresented: $isPresented, onDismiss: finishDismissal) {
                destinationContent
            }
        #endif
    }
}
