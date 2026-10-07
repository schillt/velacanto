import SwiftUI

struct FoundationPlayerView: View {
    @ObservedObject var player: FoundationPlayer
    let library: any FoundationLibrary
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    @EnvironmentObject private var actions: FoundationLibraryActions
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
        @Environment(\.foundationClosePlayer) private var closePlayer
        @Environment(\.foundationPlayerArtworkPresentation) private var artworkPresentation
    #endif
    @Environment(\.foundationReduceMotion) private var reduceMotion
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
    @State private var relatedItem: FoundationItem?

    private enum ContentMode { case artwork, lyrics, queue }

    private var contentMode: ContentMode {
        if showingQueue { return .queue }
        return lyricsPresentation == nil ? .artwork : .lyrics
    }

    private var current: FoundationItem? {
        player.queue.first { $0.id == player.selectedEntryID }?.item
    }

    private var album: FoundationItem? { current?.relatedAlbum }

    private var artist: FoundationItem? { current?.relatedArtist }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    GeometryReader { artworkGeometry in
                        ZStack(alignment: .topLeading) {
                            artworkView(
                                size: artworkGeometry.size.width,
                                height: artworkGeometry.size.width
                                    + max(
                                        0, artworkGeometry.size.height - artworkGeometry.size.width)
                                    * 0.75
                            )
                            #if DEBUG && os(iOS) && targetEnvironment(simulator)
                                .modifier(FoundationPlayerArtworkFixtureTarget())
                            #endif
                            #if os(iOS)
                                .foundationPlayerArtworkRegistration(
                                    role: .expanded, identity: current?.sharedArtworkIdentity)
                            #endif
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
                            .compositingGroup()
                            .opacity(contentMode == .artwork ? 1 : 0)
                            .accessibilityHidden(lyricsPresentation != nil || showingQueue)
                            .allowsHitTesting(lyricsPresentation == nil && !showingQueue)
                            if let presentation = lyricsPresentation {
                                let entry = presentation.entry
                                FoundationLyricsView(
                                    item: entry.item, entryID: entry.id, library: library,
                                    player: player, model: presentation.model
                                )
                                .id(presentation.id)
                                .frame(
                                    width: artworkGeometry.size.width,
                                    height: artworkGeometry.size.height
                                )
                                .clipped()
                                .transition(.opacity)
                            }
                            if showingQueue {
                                FoundationQueueView(player: player, isPresented: $showingQueue) {
                                    item in
                                    guard showingQueue else { return }
                                    relatedItem = item
                                }
                                .frame(
                                    width: artworkGeometry.size.width,
                                    height: artworkGeometry.size.height
                                )
                                .clipped()
                                .transition(.opacity)
                            }
                        }
                        .frame(
                            width: artworkGeometry.size.width, height: artworkGeometry.size.height,
                            alignment: .topLeading
                        )
                    }
                    VStack(alignment: .leading, spacing: geometry.size.height < 700 ? 8 : 14) {
                        VStack(spacing: 0) {
                            trackDetails
                            timeline
                        }
                        transport
                        volumeControl
                        HStack {
                            Button {
                                showingQueue = false
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
                            .disabled(current == nil || connectivity.localOnly)
                            .accessibilityLabel(
                                lyricsPresentation == nil ? "Show lyrics" : "Show artwork"
                            )
                            .accessibilityAddTraits(lyricsPresentation == nil ? [] : .isSelected)
                            Spacer()
                            FoundationAirPlayPicker(player: player)
                                .frame(width: 44, height: 44)
                            Spacer()
                            Button {
                                lyricsPresentation?.model.cancel()
                                lyricsPresentation = nil
                                showingQueue.toggle()
                            } label: {
                                Image(systemName: "list.bullet")
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(showingQueue ? "Show artwork" : "Show queue")
                            .accessibilityAddTraits(showingQueue ? .isSelected : [])
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
                            Color.black.opacity(contentMode == .artwork ? 0 : 0.6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .frame(width: background.size.width, height: background.size.height)
                        .clipped()
                    }.ignoresSafeArea()
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: contentMode)
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
                Capsule().fill(.white.opacity(0.65))
                    .frame(width: 36, height: 5).padding(.top, 8)
                    .opacity(showingGrabber ? 1 : 0)
                    .allowsHitTesting(false).accessibilityHidden(true)
            #endif
        }
        .sheet(item: $relatedItem) { item in
            FoundationPlayerRelatedSheet(item: item, library: library, player: player)
                .environment(\.foundationShowsDownloadBadges, true)
        }
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .overlay(alignment: .bottomTrailing) {
                if FoundationDownloadsTestHarness.enabled {
                    ZStack {
                        if let artworkPresentation {
                            FoundationPlayerArtworkTransitionEvidence(model: artworkPresentation)
                        }
                        FoundationDownloadUIPlaybackIdentity(
                            player: player, identifier: "fixture-player-playback-identity"
                        )
                        .font(.system(size: 1)).frame(width: 1, height: 1).clipped().opacity(0.05)
                        .allowsHitTesting(false)
                    }
                }
            }
        #endif
        .environment(\.foundationShowsDownloadBadges, false)
        .interactiveDismissDisabled(scrubbing)
        .accessibilityAction(.escape) { dismissPlayer() }
        #if os(iOS)
            .onAppear { updateArtworkDismissalAvailability() }
            .onChange(of: scrubbing) { _, _ in updateArtworkDismissalAvailability() }
            .onChange(of: showingQueue) { _, _ in updateArtworkDismissalAvailability() }
            .onChange(of: lyricsPresentation != nil) { _, _ in updateArtworkDismissalAvailability()
            }
            .onChange(of: relatedItem != nil) { _, _ in updateArtworkDismissalAvailability() }
        #endif
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
            .onAppear { FoundationTrace.event("surface origin=nowPlaying event=appeared") }
            .onDisappear { FoundationTrace.event("surface origin=nowPlaying event=disappeared") }
            .onChange(of: showingQueue) { _, shown in
                FoundationTrace.event("surface origin=nowPlaying queueInline=\(shown ? 1 : 0)")
            }
        #endif
        .onChange(of: connectivity.localOnly) { _, localOnly in
            if localOnly {
                lyricsPresentation?.model.cancel()
                lyricsPresentation = nil
            }
        }
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
    }

    private func dismissPlayer() {
        #if os(iOS)
            if let closePlayer {
                closePlayer()
                return
            }
        #endif
        dismiss()
    }

    #if os(iOS)
        private func updateArtworkDismissalAvailability() {
            artworkPresentation?.allowsInteractiveDismissal =
                !scrubbing && !showingQueue
                && lyricsPresentation == nil && relatedItem == nil
        }
    #endif

    @ViewBuilder private func artworkView(size: CGFloat, height: CGFloat) -> some View {
        if let album {
            FoundationCatalogArtwork(
                source: .current(currentArtwork.result(for: album)), item: album, library: library,
                isActive: isVisible, size: size,
                displayHeight: height,
                sampledColor: $artworkTint, isHero: true,
                loadedImage: $artworkFill,
                upperEdgeColors: $artworkUpperEdgeColors
            ).id(album.sharedArtworkIdentity)
        } else {
            Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary)
                .frame(width: size, height: height)
        }
    }

    @ViewBuilder private var volumeControl: some View {
        #if os(iOS)
            FoundationSystemVolumeView().frame(height: 44)
        #elseif os(macOS)
            VStack(alignment: .leading, spacing: 4) {
                Text("Player volume").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").accessibilityHidden(true)
                    Slider(
                        value: Binding(
                            get: { player.playerVolume }, set: { player.playerVolume = $0 }),
                        in: 0...1
                    )
                    .accessibilityLabel("Player volume")
                    Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                }
                .font(.caption)
            }
        #endif
    }

    private var trackDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(current?.title ?? "Nothing selected").font(.title2.bold())
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    Button("View Album", systemImage: "square.stack") {
                        if let album { relatedItem = album }
                    }.disabled(
                        album == nil
                            || (connectivity.localOnly
                                && album.map { downloads.browseTracks(for: $0).isEmpty } == true)
                    )
                    Button("View Artist", systemImage: "music.mic") {
                        if let artist { relatedItem = artist }
                    }.disabled(
                        artist == nil
                            || (connectivity.localOnly
                                && artist.map {
                                    downloads.downloadedAlbums(artistID: $0.id).isEmpty
                                }
                                    == true)
                    )
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More playback options")
                if let current {
                    let favorite = actions.favoriteState(for: current, initial: current.isFavorite)
                    Button {
                        guard !connectivity.localOnly, let favorite else { return }
                        Task {
                            guard !connectivity.localOnly else { return }
                            await actions.setFavorite(for: current, isFavorite: !favorite)
                        }
                    } label: {
                        Image(systemName: favorite == true ? "star.fill" : "star")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(favorite == true ? "Unfavorite" : "Favorite")
                    .disabled(
                        connectivity.localOnly || favorite == nil || actions.isPending(current))
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
                !player.canAdvance)
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
    @Binding var isPresented: Bool
    let openItem: (FoundationItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Button {
                    player.setShuffle(!player.shuffleEnabled)
                } label: {
                    Image(systemName: "shuffle").frame(width: 44, height: 44)
                }
                .opacity(player.shuffleEnabled ? 1 : 0.5)
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                .accessibilityAddTraits(player.shuffleEnabled ? .isSelected : [])
                Menu {
                    ForEach(FoundationPlayer.RepeatMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue.capitalized) { player.setRepeat(mode) }
                    }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .frame(width: 44, height: 44)
                }
                .opacity(player.repeatMode == .off ? 0.5 : 1)
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.rawValue.capitalized)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .environment(\.colorScheme, .dark)
            List {
                if !player.history.isEmpty {
                    Section("History") {
                        ForEach(player.history) { row($0) }
                    }
                }
                if let current = player.queue.first(where: { $0.id == player.selectedEntryID }) {
                    Section("Now Playing") { row(current) }
                }
                Section("Up Next") {
                    ForEach(player.upcoming) { row($0) }
                        .reorderable()
                }
            }
            .reorderContainer(for: FoundationQueueEntry.self, isEnabled: isPresented) {
                difference in
                switch difference.destination.position {
                case .before(let id): player.reorderUpcoming(difference.sources, before: id)
                case .end: player.reorderUpcoming(difference.sources, before: nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .clipped()
            .mask { FoundationPlayerContentFade() }
        }
        .disabled(!isPresented)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }

    private func row(_ entry: FoundationQueueEntry) -> some View {
        HStack {
            Button {
                guard isPresented else { return }
                player.select(entry.id)
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.item.title).font(.body.weight(.semibold)).lineLimit(2)
                        Text(entry.item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.id == player.selectedEntryID {
                        Image(systemName: "speaker.wave.2.fill")
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(entry.id == player.selectedEntryID ? "Current track" : "")
            .accessibilityAddTraits(entry.id == player.selectedEntryID ? .isSelected : [])
            Menu {
                menu(entry)
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Queue actions for " + entry.item.title)
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 8, leading: 24, bottom: 8, trailing: 24))
        .listRowBackground(Color.clear)
        .id(entry.id)
        .contextMenu { menu(entry) }
    }

    @ViewBuilder private func menu(_ entry: FoundationQueueEntry) -> some View {
        if player.upcoming.contains(where: { $0.id == entry.id }) {
            Button("Play Next") { player.moveQueuedEntry(entry.id, position: .next) }
            Button("Play Last") { player.moveQueuedEntry(entry.id, position: .last) }
            Button("Remove from Up Next", role: .destructive) { player.removeUpcoming(entry.id) }
        }
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

extension View {
    func foundationPlayerCover<PlayerContent: View>(
        isPresented: Binding<Bool>, player: FoundationPlayer,
        @ViewBuilder content: @escaping () -> PlayerContent
    ) -> some View {
        modifier(
            FoundationPlayerPresentation(
                isPresented: isPresented, player: player, playerContent: content))
    }
}

private struct FoundationPlayerPresentation<PlayerContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let player: FoundationPlayer
    @ViewBuilder let playerContent: () -> PlayerContent
    #if os(iOS)
        @StateObject private var standalone = FoundationPlayerArtworkPresentationModel()
        @Environment(\.foundationPlayerArtworkPresentation) private var shared
        @Environment(\.self) private var inheritedEnvironment
        @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
        @EnvironmentObject private var actions: FoundationLibraryActions
        @EnvironmentObject private var connectivity: FoundationConnectivity
        @EnvironmentObject private var downloads: FoundationDownloads
        @EnvironmentObject private var playbackPreferences: FoundationPlaybackPreferences
        @EnvironmentObject private var playlistChanges: FoundationPlaylistChanges
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
            content.background {
                FoundationPlayerArtworkFullscreen(
                    isPresented: $isPresented, model: shared ?? standalone,
                    content: AnyView(
                        playerContent()
                            .environmentObject(currentArtwork)
                            .environmentObject(actions)
                            .environmentObject(connectivity)
                            .environmentObject(downloads)
                            .environmentObject(playbackPreferences)
                            .environmentObject(playlistChanges)
                            .environment(\.foundationReduceMotion, reduceMotion)
                            .environment(\.foundationReduceTransparency, reduceTransparency)
                            .environment(\.dynamicTypeSize, dynamicTypeSize)
                            .environment(\.colorScheme, colorScheme)
                            .environment(\.scenePhase, scenePhase)),
                    inheritedEnvironment: inheritedEnvironment,
                    artwork: { [weak player, weak artwork = currentArtwork] in
                        guard let player, let artwork,
                            let item = player.queue.first(where: {
                                $0.id == player.selectedEntryID
                            })?.item,
                            let result = artwork.result(for: item)
                        else { return nil }
                        return .init(identity: item.sharedArtworkIdentity, result: result)
                    }, reduceMotion: reduceMotion
                ).frame(width: 0, height: 0)
            }
        #else
            content.sheet(isPresented: $isPresented) { playerContent() }
        #endif
    }
}

private struct FoundationRelatedItemSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var foundationRelatedItemSheet: Bool {
        get { self[FoundationRelatedItemSheetKey.self] }
        set { self[FoundationRelatedItemSheetKey.self] = newValue }
    }
}

/// Only the presentation changes: catalog content and collection ownership are shared.
private struct FoundationPlayerRelatedSheet: View {
    let item: FoundationItem
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.foundationReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @State private var detent = PresentationDetent.medium
    @State private var playlistSource: FoundationItem?

    private var catalogContent: some View {
        NavigationStack {
            FoundationItemDestination(
                item: item, library: library, player: player, isActive: scenePhase == .active
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("now-playing-related-close")
                }
            }
        }
        .environment(\.foundationRelatedItemSheet, true)
        .foundationDownloadRemovalPresentation()
        .sheet(item: $playlistSource) { source in
            FoundationPlaylistPicker(source: source, library: library)
        }
        .environment(\.foundationAddToPlaylist, playlistPresentation)
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .safeAreaInset(edge: .bottom) {
                if FoundationDownloadsTestHarness.enabled {
                    FoundationDownloadUIPlaybackIdentity(
                        player: player, identifier: "fixture-related-playback-identity")
                }
            }
        #endif
    }

    private var playlistPresentation: (@MainActor @Sendable (FoundationItem) -> Void)? {
        guard !connectivity.localOnly, library.supportsPlaylistManagement else { return nil }
        return { playlistSource = $0 }
    }

    @ViewBuilder var body: some View {
        if reduceTransparency {
            presentedContent.presentationBackground(.background)
        } else {
            presentedContent.presentationBackground(.ultraThinMaterial)
        }
    }

    private var presentedContent: some View {
        catalogContent
            .accessibilityElement(children: .contain)
            .accessibilityLabel(item.kind == .artist ? "Artist details" : "Album details")
            .accessibilityIdentifier("now-playing-related-sheet")
            .accessibilityValue(detent == .large ? "large" : "medium")
            .accessibilityAction(.escape) { dismiss() }
            .accessibilityAction(named: "Expand details") { detent = .large }
            .accessibilityAction(named: "Collapse details") { detent = .medium }
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(detent == .large ? .hidden : .visible)
            .presentationContentInteraction(.resizes)
            .preferredColorScheme(.dark)
            #if os(macOS)
                .frame(minWidth: 420, idealWidth: 520, minHeight: 460, idealHeight: 660)
            #endif
    }
}

private struct FoundationReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}
private struct FoundationReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Native accessibility remains authoritative; synthetic acceptance can also reduce effects.
    var foundationReduceMotion: Bool {
        get { accessibilityReduceMotion || self[FoundationReduceMotionKey.self] }
        set { self[FoundationReduceMotionKey.self] = newValue }
    }
    var foundationReduceTransparency: Bool {
        get { accessibilityReduceTransparency || self[FoundationReduceTransparencyKey.self] }
        set { self[FoundationReduceTransparencyKey.self] = newValue }
    }
}

#if DEBUG && os(iOS) && targetEnvironment(simulator)
    private struct FoundationPlayerArtworkFixtureTarget: ViewModifier {
        @ViewBuilder func body(content: Content) -> some View {
            if FoundationDownloadsTestHarness.enabled {
                content.accessibilityElement(children: .ignore)
                    .accessibilityLabel("Expanded album artwork")
                    .accessibilityIdentifier("fixture-player-expanded-artwork")
                    .accessibilityHidden(false)
            } else {
                content
            }
        }
    }

    private struct FoundationPlayerArtworkTransitionEvidence: View {
        @ObservedObject var model: FoundationPlayerArtworkPresentationModel
        var body: some View {
            Text(verbatim: model.transitionSummary)
                .font(.system(size: 1)).frame(width: 1, height: 1).opacity(0.05)
                .accessibilityLabel(model.transitionSummary)
                .accessibilityIdentifier("fixture-player-artwork-transition")
                .allowsHitTesting(false)
        }
    }
#endif
