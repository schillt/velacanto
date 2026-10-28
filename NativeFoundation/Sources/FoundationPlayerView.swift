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
    @Environment(\.foundationPlayerSystemColorScheme) private var systemColorScheme
    @State private var artworkFill: Image?
    @State private var artworkTint = Color(white: 0.12)
    @State private var isVisible = false
    @State private var scrubbing = false
    @State private var scrubPosition = 0.0
    @State private var scrubEntryID: UUID?
    @State private var showingQueue = false
    @State private var lyricsPresentation: FoundationLyricsPresentation?
    @State private var missingLyricsEntryID: UUID?
    @State private var showsDelayedLoading = false
    @State private var sheetDestination: PlayerSheetDestination?

    private enum PlayerSheetDestination: Identifiable {
        case related(FoundationItem)
        case credits(FoundationItem)

        var id: String {
            switch self {
            case .related(let item): "related." + item.id
            case .credits(let item): "credits." + item.id
            }
        }
    }

    private enum ContentMode { case artwork, lyrics, queue }

    private var contentMode: ContentMode {
        if showingQueue { return .queue }
        return lyricsPresentation == nil ? .artwork : .lyrics
    }

    private var current: FoundationItem? {
        player.queue.first { $0.id == player.selectedEntryID }?.item
    }

    private var lyricsUnavailable: Bool {
        current?.hasLyrics == false
            || (player.selectedEntryID != nil && missingLyricsEntryID == player.selectedEntryID)
    }

    // The first transition frame uses the same already-decoded cover as the bar.
    // Palette sampling may publish later, without an initial uncolored background.
    private var backgroundArtwork: Image? {
        if let current, let result = currentArtwork.result(for: current) {
            return Image(decorative: result.image, scale: 1)
        }
        return artworkFill
    }

    private var backgroundTint: Color {
        current.flatMap { currentArtwork.result(for: $0)?.tint } ?? artworkTint
    }

    private var album: FoundationItem? { current?.relatedAlbum }

    private var artist: FoundationItem? { current?.relatedArtist }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    GeometryReader { artworkGeometry in
                        let artworkHeight =
                            artworkGeometry.size.width
                            + max(0, artworkGeometry.size.height - artworkGeometry.size.width)
                            * 0.75 + geometry.safeAreaInsets.top
                        ZStack(alignment: .topLeading) {
                            artworkView(
                                size: artworkGeometry.size.width,
                                height: artworkHeight
                            )
                            #if DEBUG && os(iOS) && targetEnvironment(simulator)
                                .modifier(FoundationPlayerArtworkFixtureTarget())
                            #endif
                            #if os(iOS)
                                .foundationPlayerArtworkRegistration(
                                    role: .expanded, identity: current?.sharedArtworkIdentity)
                            #endif
                            .mask(artworkFade)
                            .frame(width: artworkGeometry.size.width, alignment: .top)
                            .compositingGroup()
                            .offset(y: -geometry.safeAreaInsets.top)
                            .opacity(contentMode == .artwork ? 1 : 0)
                            .accessibilityHidden(lyricsPresentation != nil || showingQueue)
                            .allowsHitTesting(lyricsPresentation == nil && !showingQueue)
                            #if os(iOS)
                                FoundationPlayerQueueTransitionLayer(model: artworkPresentation)
                                    .frame(width: artworkGeometry.size.width, height: artworkHeight)
                                    .mask(artworkFade)
                                    .offset(y: -geometry.safeAreaInsets.top)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            #endif
                            if let presentation = lyricsPresentation {
                                let entry = presentation.entry
                                FoundationLyricsView(
                                    item: entry.item, entryID: entry.id, library: library,
                                    player: player, model: presentation.model,
                                    availabilityChanged: { available in
                                        guard player.selectedEntryID == entry.id else { return }
                                        missingLyricsEntryID = available ? nil : entry.id
                                    }
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
                                FoundationQueueView(
                                    player: player, library: library, isPresented: $showingQueue
                                ) {
                                    item in
                                    guard showingQueue else { return }
                                    sheetDestination = .related(item)
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
                            if !showingQueue { trackDetails }
                            timeline
                        }
                        transport
                        volumeControl
                        HStack {
                            Button {
                                toggleLyrics()
                            } label: {
                                FoundationLyricsIcon(unavailable: lyricsUnavailable)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                            }
                            .disabled(
                                current == nil || connectivity.localOnly
                                    || (lyricsUnavailable && lyricsPresentation == nil)
                            )
                            .accessibilityLabel(
                                lyricsPresentation == nil
                                    ? (lyricsUnavailable ? "Lyrics unavailable" : "Show lyrics")
                                    : "Show artwork"
                            )
                            .accessibilityAddTraits(lyricsPresentation == nil ? [] : .isSelected)
                            Spacer()
                            FoundationAirPlayPicker(player: player)
                                .frame(width: 44, height: 44)
                            Spacer()
                            Button {
                                toggleQueue()
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
                            backgroundTint
                            if let backgroundArtwork {
                                backgroundArtwork.resizable().scaledToFill().blur(radius: 28)
                                    .frame(
                                        width: background.size.width, height: background.size.height
                                    )
                            }
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.12), location: 0.50),
                                    .init(color: backgroundTint.opacity(0.8), location: 0.80),
                                    .init(color: backgroundTint, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                            Color.black.opacity(contentMode == .artwork ? 0 : 0.6)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .frame(width: background.size.width, height: background.size.height)
                        .clipped()
                    }.ignoresSafeArea()
                }
                #if os(iOS)
                    .overlay {
                        FoundationPlayerQueueTransitionLayer(
                            model: artworkPresentation, isMetadata: true
                        )
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                #endif
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
        // Keep artwork/transport dark without forcing the appearance of presented details.
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .top) {
            #if os(iOS)
                Button(action: dismissPlayer) {
                    Capsule().fill(.white.opacity(0.65))
                        .frame(width: 36, height: 5)
                        .foundationGrabberVisibility()
                        .frame(width: 80, height: 32, alignment: .top)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse Now Playing")
            #endif
        }
        .foundationIdleGrabber(showsOverlay: false)
        .sheet(item: $sheetDestination) { destination in
            Group {
                switch destination {
                case .related(let item):
                    FoundationPlayerRelatedSheet(item: item, library: library, player: player)
                        .environment(\.foundationShowsDownloadBadges, true)
                case .credits(let item):
                    FoundationItemMetadataView(item: item, library: library)
                }
            }
            .preferredColorScheme(systemColorScheme)
        }
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .overlay(alignment: .bottomTrailing) {
                if FoundationDownloadsTestHarness.enabled {
                    ZStack {
                        if let artworkPresentation {
                            FoundationPlayerArtworkTransitionEvidence(model: artworkPresentation)
                        }
                        if ProcessInfo.processInfo.arguments.contains("-fixtureQueuePresentation") {
                            FoundationDownloadUIQueueSnapshot(player: player)
                            .font(.system(size: 1)).frame(width: 1, height: 1).clipped()
                            .opacity(0.05).allowsHitTesting(false)
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
        .interactiveDismissDisabled(
            scrubbing || lyricsPresentation != nil || sheetDestination != nil
        )
        .accessibilityAction(.escape) { dismissPlayer() }
        #if os(iOS)
            .onAppear {
                artworkPresentation?.queuePresentationChanged(showing: showingQueue)
                updateArtworkDismissalAvailability()
            }
            .onDisappear {
                artworkPresentation?.cancelQueueTransition()
                artworkPresentation?.queuePresentationChanged(showing: false)
                artworkPresentation?.interactiveDismissalHeaderOnly = false
            }
            .onChange(of: currentArtwork.result?.revision) { _, _ in
                artworkPresentation?.queueArtworkChanged(
                    identity: current?.sharedArtworkIdentity,
                    imageID: current.flatMap { currentArtwork.result(for: $0)?.id })
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { artworkPresentation?.cancelQueueTransition() }
            }
            .onChange(of: scrubbing) { _, _ in updateArtworkDismissalAvailability() }
            .onChange(of: showingQueue) { _, shown in
                artworkPresentation?.queuePresentationChanged(showing: shown)
                updateArtworkDismissalAvailability()
            }
            .onChange(of: lyricsPresentation != nil) { _, presented in
                if presented { artworkPresentation?.cancelQueueTransition() }
                updateArtworkDismissalAvailability()
            }
            .onChange(of: sheetDestination != nil) { _, presented in
                if presented { artworkPresentation?.cancelQueueTransition() }
                updateArtworkDismissalAvailability()
            }
        #endif
        .onAppear { currentArtwork.retryMissingArtwork() }
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
        #if os(iOS)
            // The artwork presentation owns status-bar contrast; detail sheets have their own scheme.
            .preferredColorScheme(.dark)
        #endif
        #if os(macOS)
            .frame(minWidth: 420, idealWidth: 520, minHeight: 660, idealHeight: 800)
        #endif
        .onChange(of: album?.id) { _, _ in
            artworkTint = Color(white: 0.12)
            artworkFill = nil
        }
        .onChange(of: player.selectedEntryID) { _, _ in
            #if os(iOS)
                artworkPresentation?.cancelQueueTransition()
            #endif
            scrubbing = false
            scrubEntryID = nil
            let keepLyricsOpen = lyricsPresentation != nil && !connectivity.localOnly
            lyricsPresentation?.model.cancel()
            missingLyricsEntryID = nil
            lyricsPresentation =
                keepLyricsOpen
                ? player.queue.first(where: { $0.id == player.selectedEntryID })
                    .map { FoundationLyricsPresentation(entry: $0) }
                : nil
        }
    }

    private func toggleLyrics() {
        showingQueue = false
        lyricsPresentation?.model.cancel()
        if lyricsPresentation == nil {
            let entry = player.queue.first { $0.id == player.selectedEntryID }
            lyricsPresentation = entry.map { FoundationLyricsPresentation(entry: $0) }
        } else {
            lyricsPresentation = nil
        }
    }

    private func toggleQueue() {
        lyricsPresentation?.model.cancel()
        lyricsPresentation = nil
        #if os(iOS)
            let image: FoundationPlayerArtworkPresentationModel.Artwork?
            if let current, let result = currentArtwork.result(for: current) {
                image = .init(identity: current.sharedArtworkIdentity, result: result)
            } else {
                image = nil
            }
            artworkPresentation?.prepareQueueTransition(
                showing: !showingQueue, artwork: image, reduceMotion: reduceMotion)
        #endif
        showingQueue.toggle()
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
            artworkPresentation?.interactiveDismissalHeaderOnly = showingQueue
            artworkPresentation?.allowsInteractiveDismissal =
                !scrubbing
                && lyricsPresentation == nil && sheetDestination == nil
        }
    #endif

    private var artworkFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0.84),
                .init(color: .white.opacity(0.82), location: 0.90),
                .init(color: .white.opacity(0.35), location: 0.96),
                .init(color: .white.opacity(0.07), location: 0.99),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder private func artworkView(size: CGFloat, height: CGFloat) -> some View {
        if let album {
            FoundationCatalogArtwork(
                source: .current(currentArtwork.result(for: album)), item: album, library: library,
                isActive: isVisible, size: size,
                displayHeight: height,
                sampledColor: $artworkTint, isHero: true,
                loadedImage: $artworkFill
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
                    #if os(iOS)
                        .modifier(
                            FoundationPlayerMetadataModifier(
                                role: .expanded, field: .title,
                                identity: current?.sharedArtworkIdentity ?? "",
                                text: current?.title ?? "Nothing selected"))
                    #endif
                Menu {
                    Button("View Album", systemImage: "square.stack") {
                        if let album { sheetDestination = .related(album) }
                    }.disabled(
                        album == nil
                            || (connectivity.localOnly
                                && album.map { downloads.browseTracks(for: $0).isEmpty } == true)
                    )
                    Button("View Artist", systemImage: "music.mic") {
                        if let artist { sheetDestination = .related(artist) }
                    }.disabled(
                        artist == nil
                            || (connectivity.localOnly
                                && artist.map {
                                    downloads.downloadedAlbums(artistID: $0.id).isEmpty
                                }
                                    == true)
                    )
                    Button("Song Credits", systemImage: "person.text.rectangle") {
                        if let current { sheetDestination = .credits(current) }
                    }.disabled(current == nil)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .menuStyle(.borderlessButton)
                .foundationEllipsisMenuIndicator()
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
                Text(foundationQueueMetadataDetail(current))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    #if os(iOS)
                        .modifier(
                            FoundationPlayerMetadataModifier(
                                role: .expanded, field: .detail,
                                identity: current.sharedArtworkIdentity,
                                text: foundationQueueMetadataDetail(current)))
                    #endif
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
                    .contentShape(Rectangle())
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
                .contentShape(Rectangle())
            }.accessibilityLabel(player.wantsPlayback ? "Pause" : "Play")
                .accessibilityValue(showsDelayedLoading ? "Loading audio" : "")
                .disabled(current == nil)
            Spacer()
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").frame(width: 60, height: 60)
                    .contentShape(Rectangle())
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
    let library: any FoundationLibrary
    @Binding var isPresented: Bool
    let openItem: (FoundationItem) -> Void

    @EnvironmentObject private var actions: FoundationLibraryActions
    @Environment(\.foundationAddToPlaylist) private var addToPlaylist
    @Environment(\.foundationRequestDownloadRemoval) private var requestDownloadRemoval
    @Environment(\.foundationHandoff) private var handoff
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var currentArtwork: FoundationCurrentArtwork
    #if os(iOS)
        @Environment(\.foundationPlayerArtworkPresentation) private var artworkPresentation
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var hasAnchoredOnOpen = false
    @State private var currentHeaderHeight: CGFloat = 0
    @State private var historyIsVisible = false
    #if os(macOS)
        @State private var currentHeaderBottom: CGFloat = 0
        @State private var historyHeaderBottom: CGFloat = 0
    #endif

    private enum ScrollTarget: Hashable {
        case current
    }

    var body: some View {
        let upcoming = player.upcoming
        VStack(spacing: 0) {
            #if os(iOS)
                FoundationQueueReorderList(
                    history: player.history,
                    current: player.queue.first { $0.id == player.selectedEntryID },
                    upcoming: upcoming,
                    dynamicTypeSize: dynamicTypeSize,
                    shuffleEnabled: player.shuffleEnabled, repeatMode: player.repeatMode,
                    historyIsVisible: historyIsVisible,
                    historyVisibilityChanged: { historyIsVisible = $0 },
                    play: { id, position in
                        guard isPresented else { return }
                        player.moveQueuedEntry(id, position: position)
                    },
                    remove: { id in
                        guard isPresented else { return }
                        player.removeUpcoming(id)
                    },
                    geometryReady: { artworkPresentation?.queueGeometryReady() },
                    move: { id, boundary in
                        guard isPresented else { return }
                        player.reorderUpcoming([id], before: boundary)
                    },
                    header: {
                        currentHeader
                            .environment(\.foundationPlayerArtworkPresentation, artworkPresentation)
                            .environment(\.foundationAddToPlaylist, addToPlaylist)
                            .environment(\.foundationRequestDownloadRemoval, requestDownloadRemoval)
                            .environment(\.foundationHandoff, handoff)
                            .environmentObject(connectivity)
                            .environmentObject(downloads)
                            .environment(\.dynamicTypeSize, dynamicTypeSize)
                            .environment(\.colorScheme, .dark)
                            .foregroundStyle(.white).tint(.white)
                    },
                    historyHeader: {
                        historyHeader
                            .environment(\.colorScheme, .dark)
                            .foregroundStyle(.white).tint(.white)
                    },
                    row: { entry, canReorder in
                        row(entry, canReorder: canReorder)
                            .environment(\.foundationAddToPlaylist, addToPlaylist)
                            .environment(\.foundationRequestDownloadRemoval, requestDownloadRemoval)
                            .environment(\.foundationHandoff, handoff)
                            .environmentObject(connectivity)
                            .environmentObject(downloads)
                            .environment(\.dynamicTypeSize, dynamicTypeSize)
                            .environment(\.colorScheme, .dark)
                            .foregroundStyle(.white).tint(.white)
                    }
                )
                .padding(.top, 40)
                .modifier(FoundationQueueFixtureIdentifier(kind: "list", entryID: nil))
                .clipped()
            #else
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(
                                alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]
                            ) {
                                if !player.history.isEmpty {
                                    Section {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(player.history) { row($0) }
                                        }
                                        .mask { rowsBelowHeader(historyHeaderBottom) }
                                    } header: {
                                        historyHeader
                                            .onGeometryChange(for: CGFloat.self) {
                                                $0.frame(in: .named("queue-scroll")).maxY
                                            } action: {
                                                historyHeaderBottom = $0
                                            }
                                    }
                                }
                                Section {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(upcoming) { entry in
                                            row(entry, canReorder: true)
                                                .swipeActions(
                                                    edge: .leading, allowsFullSwipe: true,
                                                    content: {
                                                        Button(
                                                            "Play Next",
                                                            systemImage:
                                                                "text.line.first.and.arrowtriangle.forward"
                                                        ) {
                                                            queueEntry(entry, position: .next)
                                                        }.tint(.indigo).labelStyle(.iconOnly)
                                                        Button(
                                                            "Play Last",
                                                            systemImage:
                                                                "text.line.last.and.arrowtriangle.forward"
                                                        ) {
                                                            queueEntry(entry, position: .last)
                                                        }.tint(.blue).labelStyle(.iconOnly)
                                                    }, onPresentationChanged: { _ in }
                                                )
                                                .swipeActions(
                                                    edge: .trailing, allowsFullSwipe: true,
                                                    content: {
                                                        Button(
                                                            "Remove from Up Next",
                                                            systemImage: "minus", role: .destructive
                                                        ) {
                                                            guard isPresented else { return }
                                                            player.removeUpcoming(entry.id)
                                                        }
                                                        .font(
                                                            .system(
                                                                .body, design: .rounded,
                                                                weight: .bold)
                                                        )
                                                        .labelStyle(.iconOnly)
                                                    }, onPresentationChanged: { _ in })
                                        }
                                        .reorderable()
                                    }
                                    .mask { rowsBelowHeader(currentHeaderBottom) }
                                    .frame(
                                        minHeight: max(
                                            0, geometry.size.height - currentHeaderHeight),
                                        alignment: .top)
                                } header: {
                                    currentHeader
                                        .onGeometryChange(for: CGRect.self) {
                                            $0.frame(in: .named("queue-scroll"))
                                        } action: { frame in
                                            currentHeaderHeight = frame.height
                                            currentHeaderBottom = frame.maxY
                                            historyIsVisible = frame.minY > 2
                                        }
                                        .id(ScrollTarget.current)
                                }
                            }
                            .reorderContainer(
                                for: FoundationQueueEntry.self, isEnabled: isPresented
                            ) { difference in
                                let boundary: UUID?
                                switch difference.destination.position {
                                case .before(let id): boundary = id
                                case .end: boundary = nil
                                }
                                player.reorderUpcoming(difference.sources, before: boundary)
                            }
                            .padding(.bottom, 12)
                        }
                        .toolbar {
                            if isPresented {
                                ToolbarItem(placement: .principal) {
                                    GlassEffectContainer(spacing: 8) {
                                        HStack(spacing: 12) {
                                            macModeControls(
                                                labelWidth: max(44, (geometry.size.width - 92) / 2))
                                        }
                                    }
                                    .frame(width: max(0, geometry.size.width - 32), height: 36)
                                    .padding(.vertical, 8)
                                }
                                .sharedBackgroundVisibility(.hidden)
                            }
                        }
                        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                        .scrollContentBackground(.hidden)
                        .swipeActionsContainer()
                        .coordinateSpace(name: "queue-scroll")
                        .onGeometryChange(for: CGSize.self) {
                            $0.size
                        } action: { size in
                            guard !hasAnchoredOnOpen, size.width > 0, size.height > 0 else {
                                return
                            }
                            hasAnchoredOnOpen = true
                            proxy.scrollTo(ScrollTarget.current, anchor: .top)
                        }
                    }
                }
                .modifier(FoundationQueueFixtureIdentifier(kind: "list", entryID: nil))
                .clipped()
            #endif
        }
        .disabled(!isPresented)
        .allowsHitTesting(isPresented)
        .accessibilityHidden(!isPresented)
    }

    private var historyHeader: some View {
        HStack {
            Text("History").font(.headline).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Clear") {
                guard isPresented else { return }
                player.clearHistory()
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Clear History")
        }
        .padding(.horizontal, 16)
    }

    private var currentHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
                currentRow
            #endif
            queueHeading("Up Next")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.clear)
    }

    @ViewBuilder private var currentRow: some View {
        if let current = player.queue.first(where: { $0.id == player.selectedEntryID }) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    currentTrack(current)
                    modeControls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 8) {
                    currentTrack(current)
                    modeControls
                }
            }
        } else {
            modeControls.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    #if os(macOS)
        /// Native inspector material remains visible; scrolling rows cannot paint over headings.
        private func rowsBelowHeader(_ headerBottom: CGFloat) -> some View {
            GeometryReader { geometry in
                let hiddenHeight = min(
                    geometry.size.height,
                    max(0, headerBottom - geometry.frame(in: .named("queue-scroll")).minY))
                Rectangle().padding(.top, hiddenHeight)
            }
        }
    #endif

    private var currentArtworkSize: CGFloat {
        #if os(macOS)
            36
        #else
            64
        #endif
    }

    private var currentTextLineLimit: Int {
        #if os(macOS)
            1
        #else
            2
        #endif
    }

    private func currentTrack(_ entry: FoundationQueueEntry) -> some View {
        Button {
            guard isPresented else { return }
            player.select(entry.id)
        } label: {
            HStack(spacing: 12) {
                queueArtwork(entry, size: currentArtworkSize, isCurrent: true)
                    #if os(iOS)
                        .foundationPlayerArtworkRegistration(
                            role: .queue, identity: entry.item.sharedArtworkIdentity,
                            cornerRadius: 6)
                    #endif
                VStack(alignment: .leading, spacing: 3) {
                    #if os(iOS)
                        if historyIsVisible {
                            Text("Now Playing").font(.caption).foregroundStyle(.secondary)
                        }
                    #endif
                    Text(entry.item.title).font(.headline).lineLimit(currentTextLineLimit)
                        #if os(iOS)
                            .modifier(
                                FoundationPlayerMetadataModifier(
                                    role: .queue, field: .title,
                                    identity: entry.item.sharedArtworkIdentity,
                                    text: entry.item.title))
                        #endif
                    Text(foundationQueueMetadataDetail(entry.item))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(currentTextLineLimit)
                        #if os(iOS)
                            .modifier(
                                FoundationPlayerMetadataModifier(
                                    role: .queue, field: .detail,
                                    identity: entry.item.sharedArtworkIdentity,
                                    text: foundationQueueMetadataDetail(entry.item)))
                        #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue("Current track")
        .accessibilityAddTraits(.isSelected)
        .modifier(FoundationQueueFixtureIdentifier(kind: "select", entryID: entry.id))
        .contextMenu { menu(entry) }
    }

    private func queueArtwork(
        _ entry: FoundationQueueEntry, size: CGFloat, isCurrent: Bool = false
    ) -> some View {
        FoundationCatalogArtwork(
            source: isCurrent ? .current(currentArtwork.result(for: entry.item)) : .catalog,
            item: entry.item, library: library, isActive: isPresented, size: size)
    }

    #if os(macOS)
        /// Native toolbar toggles own their glass, sizing and selected-state contrast.
        private func macModeControls(labelWidth: CGFloat) -> some View {
            Group {
                Toggle(
                    isOn: Binding(
                        get: { player.shuffleEnabled },
                        set: { player.setShuffle($0) }
                    )
                ) {
                    Image(systemName: "shuffle").frame(width: labelWidth, height: 22)
                }
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                Toggle(
                    isOn: Binding(
                        get: { player.repeatMode != .off },
                        set: { _ in
                            let next: FoundationPlayer.RepeatMode =
                                player.repeatMode == .off
                                ? .all : player.repeatMode == .all ? .one : .off
                            player.setRepeat(next)
                        }
                    )
                ) {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .frame(width: labelWidth, height: 22)
                }
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.rawValue.capitalized)
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .labelStyle(.iconOnly)
            .controlSize(.regular)
        }
    #endif

    private var modeControls: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    player.setShuffle(!player.shuffleEnabled)
                } label: {
                    modeIcon("shuffle")
                }
                .modifier(FoundationQueueModeControlStyle(active: player.shuffleEnabled))
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                .accessibilityAddTraits(player.shuffleEnabled ? .isSelected : [])
                Button {
                    let next: FoundationPlayer.RepeatMode =
                        player.repeatMode == .off ? .all : player.repeatMode == .all ? .one : .off
                    player.setRepeat(next)
                } label: {
                    modeIcon(player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .modifier(FoundationQueueModeControlStyle(active: player.repeatMode != .off))
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode.rawValue.capitalized)
                .accessibilityAddTraits(player.repeatMode == .off ? [] : .isSelected)

            }
        }
        .fixedSize()
    }

    private func modeIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: 32, height: 32)
    }

    private func queueHeading(_ title: String) -> some View {
        Text(title).font(.headline).foregroundStyle(.secondary)
            .padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ entry: FoundationQueueEntry, canReorder: Bool = false) -> some View {
        HStack {
            Button {
                guard isPresented else { return }
                player.select(entry.id)
            } label: {
                HStack(spacing: 12) {
                    queueArtwork(entry, size: 40)
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
            .modifier(FoundationQueueFixtureIdentifier(kind: "select", entryID: entry.id))
            .contextMenu { menu(entry) }
            if canReorder {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Reorder " + entry.item.title)
                    .accessibilityActions {
                        if let index = player.upcoming.firstIndex(where: { $0.id == entry.id }) {
                            if index > 0 {
                                Button("Move Up") {
                                    moveAccessibleEntry(entry.id, offset: -1)
                                }
                            }
                            if index + 1 < player.upcoming.count {
                                Button("Move Down") {
                                    moveAccessibleEntry(entry.id, offset: 1)
                                }
                            }
                        }
                    }
            }
        }
        .frame(minHeight: 44)
        .padding(.leading, 16).padding(.trailing, canReorder ? 4 : 16)
        .padding(.vertical, 8)
        .contentShape(.dragPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        #if os(iOS)
            .contentShape(
                .contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(alignment: .bottom) {
                Divider().padding(.leading, 68).padding(.trailing, 16)
            }
        #endif
        .id(entry.id)
    }

    private func moveAccessibleEntry(_ id: UUID, offset: Int) {
        let entries = player.upcoming
        guard isPresented, let index = entries.firstIndex(where: { $0.id == id }),
            entries.indices.contains(index + offset)
        else { return }
        let boundary = offset < 0 ? index - 1 : index + 2
        player.reorderUpcoming([id], before: boundary < entries.count ? entries[boundary].id : nil)
    }

    private func queueEntry(_ entry: FoundationQueueEntry, position: FoundationPlayer.QueuePosition)
    {
        guard isPresented, player.queue.contains(where: { $0.id == entry.id }) else { return }
        if player.upcoming.contains(where: { $0.id == entry.id }) {
            player.moveQueuedEntry(entry.id, position: position)
        } else {
            // Replaying history adds a new occurrence; played/current identity stays intact.
            player.enqueue([entry.item], position: position)
        }
    }

    @ViewBuilder private func menu(_ entry: FoundationQueueEntry) -> some View {
        Section {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                queueEntry(entry, position: .next)
            }
            Button("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") {
                queueEntry(entry, position: .last)
            }
            if player.upcoming.contains(where: { $0.id == entry.id }) {
                Button("Remove from Up Next", systemImage: "minus", role: .destructive) {
                    guard isPresented else { return }
                    player.removeUpcoming(entry.id)
                }
            }
        }
        FoundationItemMenu(
            item: entry.item, actions: actions, initialFavorite: entry.item.isFavorite,
            showsQueueActions: false, showsDownloadActions: false, library: library, player: player,
            navigate: openItem,
            canPerform: { _ in
                isPresented && player.queue.contains(where: { $0.id == entry.id })
            })
    }

}

private func foundationQueueMetadataDetail(_ item: FoundationItem) -> String {
    [item.subtitle, item.relatedAlbum?.title].compactMap { $0 }
        .filter { !$0.isEmpty }.joined(separator: " · ")
}

private struct FoundationQueueModeControlStyle: ViewModifier {
    let active: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.buttonStyle(.glassProminent).buttonBorderShape(.circle).tint(.blue)
        } else {
            content.buttonStyle(.glass).buttonBorderShape(.circle).tint(.primary)
        }
    }
}

private struct FoundationQueueFixtureIdentifier: ViewModifier {
    let kind: String
    let entryID: UUID?
    func body(content: Content) -> some View {
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            if FoundationDownloadsTestHarness.enabled,
                ProcessInfo.processInfo.arguments.contains("-fixtureQueuePresentation")
            {
                content.accessibilityIdentifier(
                    entryID.map { "fixture-queue-" + kind + "-" + $0.uuidString }
                        ?? "fixture-queue-list")
            } else {
                content
            }
        #else
            content
        #endif
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
        sourceNamespace: Namespace.ID? = nil, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> PlayerContent
    ) -> some View {
        modifier(
            FoundationPlayerPresentation(
                isPresented: isPresented, player: player, sourceNamespace: sourceNamespace,
                onDismiss: onDismiss, playerContent: content))
    }
}

private struct FoundationPlayerPresentation<PlayerContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let player: FoundationPlayer
    let sourceNamespace: Namespace.ID?
    let onDismiss: (() -> Void)?
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
            if let sourceNamespace {
                content.fullScreenCover(isPresented: $isPresented, onDismiss: onDismiss) {
                    playerContent()
                        .environment(\.foundationPlayerSystemColorScheme, colorScheme)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("foundation-now-playing")
                        .accessibilityAddTraits(.isModal)
                        .environment(\.foundationClosePlayer, { isPresented = false })
                        .navigationTransition(
                            .zoom(sourceID: "now-playing", in: sourceNamespace))
                }
            } else {
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
                                .environment(\.foundationPlayerSystemColorScheme, colorScheme)
                                .environment(\.scenePhase, scenePhase)),
                        inheritedEnvironment: inheritedEnvironment,
                        contentContextID: [
                            String(describing: dynamicTypeSize), String(describing: colorScheme),
                            String(describing: scenePhase), String(reduceMotion),
                            String(reduceTransparency),
                        ].joined(separator: ":"),
                        artwork: { [weak player, weak artwork = currentArtwork] in
                            guard let player, let artwork,
                                let item = player.queue.first(where: {
                                    $0.id == player.selectedEntryID
                                })?.item,
                                let result = artwork.result(for: item)
                            else { return nil }
                            return .init(identity: item.sharedArtworkIdentity, result: result)
                        }, reduceMotion: reduceMotion, reduceTransparency: reduceTransparency
                    ).frame(width: 0, height: 0)
                }
            }
        #else
            content  // macOS uses the library inspector and persistent transport bar.
        #endif
    }
}

private struct FoundationPlayerSystemColorSchemeKey: EnvironmentKey {
    static let defaultValue: ColorScheme? = nil
}

private struct FoundationRelatedItemSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Captured outside the iOS artwork presentation, so its Dark preference cannot mask system changes.
    var foundationPlayerSystemColorScheme: ColorScheme? {
        get { self[FoundationPlayerSystemColorSchemeKey.self] }
        set { self[FoundationPlayerSystemColorSchemeKey.self] = newValue }
    }

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
            #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
            #endif
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
            // Native chrome owns this hit region even when the detail scroll view is offset.
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.resizes)
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

#if os(macOS)
    /// The existing queue and lyrics owners live only while their inspector is visible.
    struct FoundationMacPlaybackPanel: View {
        enum Mode: String, CaseIterable {
            case lyrics = "Lyrics"
            case queue = "Queue"
        }
        @ObservedObject var player: FoundationPlayer
        let library: any FoundationLibrary
        let mode: Mode
        let queuePresentation: Int
        let isPresented: Bool
        var lyricsAvailabilityChanged: (UUID, Bool) -> Void = { _, _ in }
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @EnvironmentObject private var connectivity: FoundationConnectivity
        @State private var lyrics: FoundationLyricsPresentation?
        @State private var relatedItem: FoundationItem?

        var body: some View {
            VStack(spacing: 0) {
                if mode == .queue {
                    // Inspectors can retain content after closing; reset only on a queue opening.
                    FoundationQueueView(
                        player: player, library: library, isPresented: .constant(isPresented)
                    ) {
                        relatedItem = $0
                    }
                    .id(queuePresentation)
                } else if connectivity.localOnly {
                    ContentUnavailableView(
                        "Lyrics unavailable offline", systemImage: "quote.bubble")
                } else if let lyrics {
                    FoundationLyricsView(
                        item: lyrics.entry.item, entryID: lyrics.entry.id,
                        library: library, player: player, model: lyrics.model,
                        followsAppearance: true,
                        availabilityChanged: { available in
                            lyricsAvailabilityChanged(lyrics.entry.id, available)
                        }
                    )
                    .id(lyrics.id)
                } else {
                    ContentUnavailableView("Select a track for lyrics", systemImage: "quote.bubble")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The native inspector owns its adaptive sidebar material. A second
            // edge-to-edge glass surface adds refraction highlights around the panel.
            .background {
                if reduceTransparency { Rectangle().fill(.background) }
            }
            .task(
                id:
                    "\(isPresented)-\(mode.rawValue)-\(player.selectedEntryID?.uuidString ?? "none")-\(connectivity.localOnly)"
            ) {
                lyrics?.model.cancel()
                lyrics = nil
                if isPresented, mode == .lyrics, !connectivity.localOnly,
                    let entry = player.queue.first(where: { $0.id == player.selectedEntryID })
                {
                    lyrics = FoundationLyricsPresentation(entry: entry)
                }
            }
            .onDisappear { lyrics?.model.cancel() }
            .sheet(item: $relatedItem) { item in
                FoundationPlayerRelatedSheet(item: item, library: library, player: player)
            }
            .accessibilityIdentifier("mac-playback-sidebar")
        }
    }
#endif
