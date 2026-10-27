import SwiftUI

/// A replaced natural layout retires its old target; chrome padding is not part
/// of this identity, so a resize can preserve the same already-visible footer.
struct FoundationHomeNaturalExtent: Hashable {
    let widthPixels: Int
    let heightPixels: Int

    init?(size: CGSize, displayScale: CGFloat) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
            displayScale.isFinite, displayScale > 0
        else { return nil }
        let scale = max(1, displayScale)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0,
            width < CGFloat(Int.max), height < CGFloat(Int.max)
        else { return nil }
        widthPixels = Int(width)
        heightPixels = Int(height)
    }
}

/// Only independent natural extent changes advance this invalidation revision.
struct FoundationHomeNaturalLayout {
    private(set) var extent: FoundationHomeNaturalExtent?
    private(set) var revision: UInt64 = 0

    mutating func update(_ next: FoundationHomeNaturalExtent?) {
        guard extent != next else { return }
        extent = next
        revision &+= 1
    }
}

/// Home composes independently owned, visible catalog sections around the existing player.
struct FoundationHomeView<Profile: View>: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    let profile: Profile
    let library: any FoundationLibrary
    let player: FoundationPlayer
    @ObservedObject var recentTracks: FoundationBrowseModel
    @ObservedObject var favorites: FoundationBrowseModel
    @ObservedObject var recentAlbums: FoundationBrowseModel
    let isActive: Bool
    var hasQueue = false
    var accountLibrary: (any FoundationLibrary)? = nil
    @State private var isVisible = false
    @State private var collectionOperationOwner = UUID()
    @State private var refreshRevision = 0
    @State private var showingPlayer = false
    @State private var openedItem: FoundationItem?
    @State private var showingGenreIndex = false
    @EnvironmentObject private var actions: FoundationLibraryActions
    #if os(iOS)
        @Environment(\.foundationBottomChromeGeometry) private var bottomChrome
        @Environment(\.displayScale) private var displayScale
        @State private var nativeBottomInset: CGFloat?
        #if DEBUG
            @State private var nativeAtEnd = false
            @State private var nativeCorrectionCount = 0
        #endif
        @State private var naturalLayout = FoundationHomeNaturalLayout()
        @State private var idleEndPreserver = FoundationHomeIdleEndPreserver()
        @State private var offeredViewport: CGRect?
    #endif

    var body: some View {
        homeScrollViewport
            .environment(\.foundationCollectionOperationOwner, collectionOperationOwner)
            .foundationCollectionOutcomePresentation(owner: collectionOperationOwner)
            .onAppear {
                isVisible = true
                #if DEBUG
                    FoundationTrace.event("ui origin=home appeared")
                #endif
            }
            .onDisappear {
                actions.cancelQueueAdditionOwned(by: collectionOperationOwner)
                isVisible = false
                #if os(iOS)
                    idleEndPreserver.attach(nil)
                #endif
                #if DEBUG
                    FoundationTrace.event("ui origin=home disappeared")
                #endif
            }
            .refreshable {
                guard isActive, !connectivity.localOnly else { return }
                recentTracks.request(.refresh)
                favorites.request(.refresh)
                recentAlbums.request(.refresh)
                refreshRevision += 1
            }
            .onChange(of: connectivity.successfulRetryRevision) { _, _ in
                guard isActive else { return }
                recentTracks.request(.refresh)
                favorites.request(.refresh)
                recentAlbums.request(.refresh)
                refreshRevision += 1
            }
            .foundationHeader("Home", profile: profile)
            .navigationDestination(isPresented: $showingGenreIndex) {
                FoundationPrimaryGenresView(
                    library: library, player: player, isActive: isActive, context: .libraryRows
                ).foundationCatalogHeader("Genres")
            }
            #if DEBUG
                .onChange(of: showingPlayer) { _, presented in
                    FoundationTrace.event(
                        presented
                            ? "ui origin=home player=presented" : "ui origin=home player=dismissed")
                }
            #endif
            .foundationPlayerCover(isPresented: $showingPlayer, player: player) {
                FoundationPlayerView(player: player, library: accountLibrary ?? library)
            }
            .foundationCollectionDestination(
                item: $openedItem, library: library, player: player, isActive: isActive)
    }

    private var homeScrollViewport: some View {
        homeScrollView
            #if os(iOS)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    offeredViewport = $0
                }
            #endif
    }

    private var homeScrollView: some View {
        ScrollView {
            #if os(iOS)
                naturalContent
                    .onGeometryChange(for: FoundationHomeNaturalExtent?.self) {
                        [scale = displayScale] proxy in
                        FoundationHomeNaturalExtent(size: proxy.size, displayScale: scale)
                    } action: {
                        naturalLayout.update($0)
                    }
                    .background {
                        FoundationHomeIdleEndBridge(
                            owner: idleEndPreserver, chrome: bottomChrome?.accessory,
                            revision: naturalLayout.revision, displayScale: displayScale,
                            enabled: isActive && isVisible && hasQueue
                                && naturalLayout.extent != nil
                        )
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .foundationBottomChromeEndPadding()
                    #if DEBUG
                        .modifier(FoundationHomeReboundContentProbe())
                    #endif
            #else
                naturalContent
            #endif
        }
        .swipeActionsContainer()
        .accessibilityIdentifier("foundation-home-scroll")
        .foundationBottomChromeScrollClearance()
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .environment(\.foundationChromeUIContext, "home")
        #endif
        #if os(iOS)
            .onScrollGeometryChange(for: FoundationHomeGeometryEvent.self) {
                FoundationHomeGeometryEvent($0)
            } action: { _, value in
                if nativeBottomInset != value.bottom { nativeBottomInset = value.bottom }
                idleEndPreserver.observe()
                #if DEBUG
                    updateIdleEndDiagnostic()
                #endif
            }
            .onScrollPhaseChange { previous, current, context in
                #if DEBUG
                    FoundationHomeReboundDiagnostic.shared?.phase(
                        from: previous, to: current, geometry: context.geometry)
                #endif
                idleEndPreserver.phaseChanged(current)
                #if DEBUG
                    updateIdleEndDiagnostic()
                    FoundationHomeReboundDiagnostic.shared?.phaseFinished(current)
                #endif
            }
            #if DEBUG
                .onChange(of: clearanceDiagnostic, initial: true) { _, value in
                    FoundationHomeReboundDiagnostic.shared?.clearance(value)
                }
            #endif
        #endif
        #if DEBUG && os(iOS)
            .modifier(FoundationHomeReboundViewportProbe(isActive: isActive))
        #endif
        #if DEBUG && os(iOS) && targetEnvironment(simulator)
            .modifier(FoundationHomeScrollBoundaryProbe(clearance: clearanceDiagnostic))
        #endif
    }

    #if DEBUG && os(iOS)
        private func updateIdleEndDiagnostic() {
            let atEnd = idleEndPreserver.isAtEnd
            if nativeAtEnd != atEnd { nativeAtEnd = atEnd }
            let count = idleEndPreserver.correctionCount
            if nativeCorrectionCount != count { nativeCorrectionCount = count }
        }

        private var clearanceDiagnostic: FoundationHomeClearanceDiagnostic {
            .init(
                host: bottomChrome?.host, accessory: bottomChrome?.accessory,
                nativeBottomInset: nativeBottomInset,
                reserve: bottomChrome?.clearance(
                    nativeBottomInset: nativeBottomInset, displayScale: displayScale) ?? 0,
                hasQueue: hasQueue,
                nativeAtEnd: nativeAtEnd, correctionCount: nativeCorrectionCount,
                naturalHeight: naturalLayout.extent.map {
                    CGFloat($0.heightPixels) / max(1, displayScale)
                }, offeredViewport: offeredViewport, boundedHeight: nil)
        }
    #endif

    private var naturalContent: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if connectivity.hasConnectionIssue
                || [recentTracks, favorites, recentAlbums].contains(
                    where: \.hasConnectionIssue)
            {
                FoundationOfflineNotice()
            }
            // One existing media-card surface; local playback stays in Now Playing.
            VStack(alignment: .leading, spacing: 0) {
                FoundationContinueListening(
                    library: library, isActive: isActive && isVisible,
                    refreshRevision: refreshRevision
                )
                .id(library.listeningActivityScope)
                FoundationHomeShelf(
                    title: "Recently Played", model: recentTracks, library: library, player: player,
                    isActive: isActive, refreshRevision: refreshRevision, showsTracks: true,
                    openedItem: $openedItem
                ) { try await library.recentlyPlayed(startIndex: $0) }
            }
            // A bounded mixed collection preview; the heading opens complete Favorites.
            FoundationHomeShelf(
                title: "Favorites", model: favorites, library: library, player: player,
                isActive: isActive, refreshRevision: refreshRevision, isFavorites: true,
                openedItem: $openedItem
            ) { _ in try await library.favoriteCollectionsPreview() }
            FoundationHomeShelf(
                title: "Recently Added", model: recentAlbums, library: library, player: player,
                isActive: isActive, refreshRevision: refreshRevision,
                openedItem: $openedItem
            ) { try await library.recentAlbums(startIndex: $0) }
            genreShelves
            if let error = actions.pinErrorMessage { Text(error).foregroundStyle(.red) }
        }.padding()
    }

    @ViewBuilder private var genreShelves: some View {
        if let record = primaryGenres.completedRecord(libraryScope: library.primaryGenreIndexScope)
        {
            let eligible =
                connectivity.localOnly
                ? Set(primaryGenres.items(localOnly: true).map(\.id)) : nil
            let genres = record.prominentGenres(eligibleIDs: eligible)
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(genres, id: \.genreIdentity) { genre in
                    FoundationHomeGenreShelf(
                        genre: genre, record: record, library: library, player: player,
                        isActive: isActive, refreshRevision: refreshRevision,
                        openedItem: $openedItem
                    ).id(record.snapshot.censusID)
                }
                if connectivity.localOnly, let error = primaryGenres.offlineErrorMessage {
                    Text(error).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Primary Genres").font(.title2.bold())
                Text("Build primary genres to browse music by its common song tags.")
                    .foregroundStyle(.secondary)
                Button {
                    showingGenreIndex = true
                } label: {
                    Label("Open Genres", systemImage: "guitars")
                }
                .accessibilityIdentifier("home-build-primary-genres")
            }
        }
    }

}

#if DEBUG && os(iOS) && targetEnvironment(simulator)
    /// Synthetic, explicitly enabled observations; this overlay reserves no content space.
    private struct FoundationHomeScrollBoundaryProbe: ViewModifier {
        let clearance: FoundationHomeClearanceDiagnostic
        @Environment(\.displayScale) private var displayScale
        @State private var snapshot: FoundationHomeScrollBoundarySnapshot?
        @State private var phases: [String] = []
        @State private var gesture = 0
        @State private var phase = ScrollPhase.idle
        @State private var beyondEnd = false

        @ViewBuilder func body(content: Content) -> some View {
            if ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary") {
                content
                    .onScrollGeometryChange(for: FoundationHomeScrollBoundarySnapshot.self) {
                        FoundationHomeScrollBoundarySnapshot($0)
                    } action: { _, current in
                        snapshot = current
                        let beyond =
                            CGFloat(current.contentRemainder) / 10 < -1 / max(1, displayScale)
                        if beyond != beyondEnd {
                            beyondEnd = beyond
                            append("phase=\(phase) beyondEnd=\(beyond)")
                        }
                    }
                    .onScrollPhaseChange { previous, current, context in
                        phase = current
                        if current == .tracking
                            || (current == .interacting && previous != .tracking)
                        {
                            gesture += 1
                            beyondEnd = false
                        }
                        let geometry = FoundationScrollEndGeometry(context.geometry)
                        let beyond =
                            geometry.unobscuredBottom - geometry.contentSize.height
                            > 1 / max(1, displayScale)
                        append("phaseChange=\(previous)->\(current) beyondEnd=\(beyond)")
                    }
                    .overlay(alignment: .topLeading) {
                        Text("Home scroll geometry")
                            .font(.system(size: 1))
                            .foregroundStyle(.clear)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("foundation-home-scroll-boundary")
                            .accessibilityValue(snapshot?.description ?? "Awaiting geometry")
                            .allowsHitTesting(false)
                        Text("Home native scroll phases")
                            .font(.system(size: 1)).foregroundStyle(.clear)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("foundation-home-scroll-phases")
                            .accessibilityValue(phases.joined(separator: "\n"))
                            .allowsHitTesting(false)
                        Text("Home measured bottom clearance")
                            .font(.system(size: 1)).foregroundStyle(.clear)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("foundation-home-chrome-clearance")
                            .accessibilityValue(clearance.evidenceDescription)
                            .allowsHitTesting(false)
                    }
            } else {
                content
            }
        }

        private func append(_ value: String) {
            phases = Array((phases + ["gesture=\(gesture) " + value]).suffix(12))
        }
    }

    private struct FoundationHomeScrollBoundarySnapshot: Equatable {
        let offsetY: Int
        let contentHeight: Int
        let containerHeight: Int
        let insetTop: Int
        let insetBottom: Int
        let boundsMinY: Int
        let boundsHeight: Int
        let visibleMinY: Int
        let visibleHeight: Int
        let visibleMaxY: Int
        let contentRemainder: Int

        init(_ geometry: ScrollGeometry) {
            func quantize(_ value: CGFloat) -> Int { Int((value * 10).rounded()) }
            offsetY = quantize(geometry.contentOffset.y)
            contentHeight = quantize(geometry.contentSize.height)
            containerHeight = quantize(geometry.containerSize.height)
            insetTop = quantize(geometry.contentInsets.top)
            insetBottom = quantize(geometry.contentInsets.bottom)
            boundsMinY = quantize(geometry.bounds.minY)
            boundsHeight = quantize(geometry.bounds.height)
            visibleMinY = quantize(geometry.visibleRect.minY)
            visibleHeight = quantize(geometry.visibleRect.height)
            visibleMaxY = quantize(geometry.visibleRect.maxY)
            contentRemainder = quantize(geometry.contentSize.height - geometry.visibleRect.maxY)
        }

        var description: String {
            "offsetY=\(Double(offsetY) / 10) contentHeight=\(Double(contentHeight) / 10)"
                + " containerHeight=\(Double(containerHeight) / 10)"
                + " insetTop=\(Double(insetTop) / 10) insetBottom=\(Double(insetBottom) / 10)"
                + " boundsMinY=\(Double(boundsMinY) / 10)"
                + " boundsHeight=\(Double(boundsHeight) / 10)"
                + " visibleMinY=\(Double(visibleMinY) / 10)"
                + " visibleHeight=\(Double(visibleHeight) / 10)"
                + " visibleMaxY=\(Double(visibleMaxY) / 10)"
                + " contentRemainder=\(Double(contentRemainder) / 10)"
        }
    }
#endif

private struct FoundationContinueListening: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var dismissals: FoundationContinueListeningDismissals
    @Environment(\.scenePhase) private var scenePhase
    let library: any FoundationLibrary
    let isActive: Bool
    let refreshRevision: Int
    @StateObject private var model = FoundationRemoteListeningModel()
    @State private var showingGuide = false
    @State private var inlineInstructionsForID: String?
    @AppStorage(FoundationHandoffGuidePreference.key) private var guideSuppressed = false

    private var active: Bool {
        isActive && scenePhase == .active && !connectivity.localOnly
            && !library.listeningActivityScope.isEmpty
    }

    private var selected: FoundationRemoteListeningActivity? {
        guard active else { return nil }
        return FoundationContinueListeningSelection.select(
            model.activities, dismissed: dismissals.keys)
    }

    private var instruction: String {
        #if os(macOS)
            "Choose VelaCanto’s Handoff icon in the Dock to continue here."
        #else
            "Open App Switcher and tap VelaCanto’s Handoff banner to continue here."
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let activity = selected {
                continueListening(activity)
                    .id(activity.id)
            }
        }
        .padding(.bottom, selected == nil ? 0 : 28)
        .task(id: taskIdentity) {
            guard !Task.isCancelled else { return }
            model.cancel()
            guard active, !Task.isCancelled else { return }
            await model.refresh { try await library.remoteListeningActivity() }
            guard !Task.isCancelled else { return }
            await model.expireVisibleActivity()
        }
        .onDisappear {
            model.cancel()
            showingGuide = false
            inlineInstructionsForID = nil
        }
        .onChange(of: active) { _, value in
            if !value {
                model.cancel()
                showingGuide = false
                inlineInstructionsForID = nil
            }
        }
        .onChange(of: selected?.id) { _, _ in
            showingGuide = false
            inlineInstructionsForID = nil
        }
        .sheet(isPresented: $showingGuide) {
            FoundationHandoffListeningGuide(
                instruction: instruction, suppressed: $guideSuppressed,
                done: { showingGuide = false })
        }
    }

    private var taskIdentity: String {
        "\(library.listeningActivityScope):\(active):\(refreshRevision):\(connectivity.successfulRetryRevision)"
    }

    private func openInstructions(for activity: FoundationRemoteListeningActivity) {
        switch FoundationContinueListeningInstructionAction.onTap(guideSuppressed: guideSuppressed)
        {
        case .fullGuide: showingGuide = true
        case .inlineInstructions: inlineInstructionsForID = activity.id
        }
    }

    private func dismiss(_ activity: FoundationRemoteListeningActivity) {
        dismissals.dismiss(activity.id, scope: library.listeningActivityScope)
        showingGuide = false
        inlineInstructionsForID = nil
    }

    /// Reuses the existing artwork/title/details/progress-circle media-card layout.
    /// It deliberately has no player or audio-command callback.
    private func continueListening(_ activity: FoundationRemoteListeningActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeading(activity)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    mediaButton(activity)
                    progressButton(activity)
                }
                if inlineInstructionsForID == activity.id {
                    Text(instruction).font(.subheadline).foregroundStyle(.secondary)
                    Button("Handoff Help") { showingGuide = true }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
        .accessibilityIdentifier("continue-listening-remote-card")
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                dismiss(activity)
            } label: {
                Label("Dismiss", systemImage: "trash")
            }
        }
    }

    private func cardHeading(_ activity: FoundationRemoteListeningActivity) -> some View {
        HStack {
            Text("Continue listening from \(activity.deviceLabel)")
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase).tracking(1)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button {
                dismiss(activity)
            } label: {
                Image(systemName: "trash").frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Continue Listening")
            .accessibilityHint("Hides this card. Playback continues on the other device.")
            .accessibilityIdentifier("continue-listening-dismiss")
        }
    }

    private func mediaButton(_ activity: FoundationRemoteListeningActivity) -> some View {
        let item = activity.item
        let artwork = item.catalogArtworkItem
        let artworkIdentity: String = artwork.id + (artwork.primaryImageTag ?? "")
        let accessibilityValue: String = [
            item.title, item.subtitle, activity.albumTitle, activity.progress.accessibilityValue,
        ].joined(separator: ", ")
        return Button {
            openInstructions(for: activity)
        } label: {
            HStack(spacing: 12) {
                FoundationCatalogArtwork(
                    source: .catalog, item: artwork, library: library, isActive: active, size: 64
                ).id(artworkIdentity)
                mediaDetails(activity)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue listening instructions")
        .accessibilityValue(accessibilityValue)
    }

    private func mediaDetails(_ activity: FoundationRemoteListeningActivity) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(activity.item.title).font(.headline).lineLimit(2)
            Text(activity.item.subtitle).font(.subheadline)
                .foregroundStyle(.secondary).lineLimit(1)
            Text(activity.albumTitle).font(.caption)
                .foregroundStyle(.secondary).lineLimit(1)
            Text(activity.progress.label).font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressButton(_ activity: FoundationRemoteListeningActivity) -> some View {
        Button {
            openInstructions(for: activity)
        } label: {
            Image(systemName: "play.fill")
                .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
                .overlay {
                    Circle().trim(from: 0, to: activity.progress.fraction)
                        .stroke(
                            .primary.opacity(0.75),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90)).padding(2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How to continue listening here")
        .accessibilityValue(activity.progress.accessibilityValue)
        .accessibilityHint("Shows Handoff instructions. Does not start playback.")
    }

}

private struct FoundationHomeGenreShelf: View {
    @EnvironmentObject private var connectivity: FoundationConnectivity
    @EnvironmentObject private var primaryGenres: FoundationPrimaryGenresModel
    let genre: FoundationItem
    let record: FoundationPrimaryGenreRecord
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    let refreshRevision: Int
    @Binding var openedItem: FoundationItem?
    @StateObject private var songs = FoundationBrowseModel()
    @State private var isVisible = false
    @State private var retryRevision = 0
    @State private var consumedRefreshRevision = 0

    private var previewLimit: Int {
        #if os(macOS)
            12
        #else
            5
        #endif
    }

    private var readySongs: [FoundationItem] {
        primaryGenres.readySongs(for: genre, libraryScope: library.primaryGenreIndexScope)
    }

    private var displayedSongs: [FoundationItem] {
        connectivity.localOnly ? readySongs : songs.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                openedItem = genre
            } label: {
                HStack(spacing: 6) {
                    Text(genre.title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }.frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("See all " + genre.title.lowercased())
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("home-shelf-" + genre.title)
            if !displayedSongs.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(Array(displayedSongs.prefix(previewLimit)), id: \.id) { song in
                            FoundationAlbumShelfCard(
                                item: song, library: library, player: player,
                                isActive: isActive && isVisible,
                                open: { openedItem = song }, navigate: { openedItem = $0 },
                                artworkItem: song.catalogArtworkItem)
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .foundationMacShelfUnderlap()
            } else if isActive, !connectivity.localOnly, !songs.hasConnectionIssue,
                songs.errorMessage == nil, songs.isLoading || !songs.loaded
            {
                FoundationLoadingPlaceholder(layout: .albumShelf)
            }
            if songs.hasConnectionIssue, !connectivity.hasConnectionIssue {
                FoundationOfflineNotice()
            }
            if let error = songs.errorMessage, !songs.hasConnectionIssue, !connectivity.localOnly {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    songs.request(songs.retryRequest)
                    retryRevision += 1
                }
            } else if displayedSongs.isEmpty, songs.loaded || connectivity.localOnly {
                Text("No indexed songs are available in this page.").foregroundStyle(.secondary)
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(
            id: isActive && isVisible
                ? "\(refreshRevision):\(retryRevision):\(connectivity.localOnly)" : nil
        ) {
            guard isActive, isVisible, !Task.isCancelled, !connectivity.localOnly else { return }
            if refreshRevision != consumedRefreshRevision {
                songs.request(.refresh)
                consumedRefreshRevision = refreshRevision
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .shelf) {
                    await songs.refreshVisible(allowsNetwork: true, using: loadSongs)
                }
            #else
                await songs.refreshVisible(allowsNetwork: true, using: loadSongs)
            #endif
        }
    }

    private func loadSongs(_ offset: Int) async throws -> FoundationPage {
        let page = try await record.songPage(
            genreID: genre.id, startIndex: offset, library: library)
        guard
            primaryGenres.canonicalRecord(for: genre, libraryScope: library.primaryGenreIndexScope)
                != nil
        else { throw FoundationLibraryError.unavailable }
        return page
    }
}

private struct FoundationHomeShelf: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshOnActivation = true
    @EnvironmentObject private var downloads: FoundationDownloads
    @EnvironmentObject private var connectivity: FoundationConnectivity
    let title: String
    @ObservedObject var model: FoundationBrowseModel
    let library: any FoundationLibrary
    let player: FoundationPlayer
    let isActive: Bool
    var refreshRevision = 0
    var showsTracks = false
    var isFavorites = false
    @Binding var openedItem: FoundationItem?
    let loader: (Int) async throws -> FoundationPage
    @EnvironmentObject private var actions: FoundationLibraryActions
    @State private var isVisible = false
    @State private var retryRevision = 0
    @State private var consumedRefreshRevision = 0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Wider Mac shelves use more of the retained page; full-list navigation owns pagination.
    private var previewLimit: Int {
        #if os(macOS)
            12
        #else
            showsTracks ? 6 : 5
        #endif
    }

    private var displayedItems: [FoundationItem] {
        isFavorites ? actions.favoriteItems(in: model.items) : model.items
    }

    private var favoritesActivation: Bool {
        isActive && isVisible && scenePhase == .active && !connectivity.localOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                if isFavorites || !displayedItems.isEmpty || model.nextStartIndex != nil {
                    NavigationLink {
                        if isFavorites {
                            FoundationFavoritesView(
                                library: library, player: player, isActive: isActive)
                        } else {
                            FoundationCatalogView(
                                title: title, model: model, library: library, player: player,
                                isActive: isActive, showsTrackArtwork: showsTracks, loader: loader)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(title).font(.title2.bold())
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See all " + title.lowercased())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(isFavorites ? "home-favorites" : "home-shelf-" + title)
                } else {
                    Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
            }
            if showsTracks {
                if usesVerticalRecentRows {
                    VStack(spacing: 12) {
                        recentRows
                    }
                } else {
                    ScrollView(.horizontal) {
                        LazyHGrid(rows: [GridItem(.fixed(64)), GridItem(.fixed(64))], spacing: 16) {
                            recentRows
                        }
                        .frame(height: 136)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .foundationMacShelfUnderlap()
                    .accessibilityLabel("Recently Played carousel")
                }
            } else if !displayedItems.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(
                            Array(displayedItems.prefix(previewLimit).enumerated()), id: \.offset
                        ) {
                            _, item in
                            if isFavorites {
                                FoundationCollectionCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 }
                                )
                                .frame(width: dynamicTypeSize.isAccessibilitySize ? 240 : 160)
                            } else {
                                FoundationAlbumShelfCard(
                                    item: item, library: library, player: player,
                                    isActive: isActive && isVisible, open: { openedItem = item },
                                    navigate: { openedItem = $0 })
                            }
                        }
                    }.scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .modifier(FoundationHomeShelfBoundary(contained: isFavorites))
                #if DEBUG && os(iOS) && targetEnvironment(simulator)
                    .modifier(FoundationRemoteListeningShelfUIProbe(isFavorites: isFavorites))
                #endif
            }
            if model.hasConnectionIssue, !connectivity.hasConnectionIssue {
                FoundationOfflineNotice()
            }
            if isActive, displayedItems.isEmpty, !connectivity.localOnly,
                !model.hasConnectionIssue, model.errorMessage == nil,
                model.isLoading || !model.loaded
            {
                FoundationLoadingPlaceholder(layout: showsTracks ? .rows : .albumShelf)
            }
            if let error = model.errorMessage, !model.hasConnectionIssue {
                Text(error).foregroundStyle(.red)
                Button("Retry") {
                    guard !connectivity.localOnly else { return }
                    model.request(model.retryRequest)
                    retryRevision += 1
                }.disabled(connectivity.localOnly)
            } else if !connectivity.localOnly, !model.hasConnectionIssue, model.loaded,
                displayedItems.isEmpty
            {
                Text(
                    model.nextStartIndex == nil
                        ? "No items yet."
                        : "No matches in this page. Open the full list to load more."
                ).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            isVisible = true
            #if DEBUG
                FoundationTrace.event("ui origin=home appeared")
            #endif
        }
        .onDisappear {
            isVisible = false
            refreshOnActivation = true
            #if DEBUG
                FoundationTrace.event("ui origin=home disappeared")
            #endif
        }
        .onChange(of: favoritesActivation) { _, active in
            if !active { refreshOnActivation = true }
        }
        .onChange(of: actions.favoriteRevision) { _, _ in
            if isFavorites, isActive, isVisible, !connectivity.localOnly {
                model.request(.refresh)
                retryRevision += 1
            }
        }
        .task(
            id: isActive && isVisible && scenePhase == .active
                ? "\(refreshRevision):\(retryRevision):\(connectivity.localOnly)" : nil
        ) {
            guard isActive, isVisible, scenePhase == .active, !Task.isCancelled else { return }
            if isFavorites, favoritesActivation, refreshOnActivation {
                refreshOnActivation = false
                if model.loaded { model.request(.refresh) }
            }
            // This capped preview cannot establish nonmembership from absent rows.
            model.configureFavoriteObservations(actions)
            if refreshRevision != consumedRefreshRevision {
                model.request(.refresh)
                consumedRefreshRevision = refreshRevision
            }
            #if DEBUG
                await FoundationTrace.withPage(origin: .home, page: .shelf) {
                    guard isActive, isVisible, !Task.isCancelled else {
                        return
                    }
                    await model.refreshVisible(
                        allowsNetwork: !connectivity.localOnly, using: loader)
                }
            #else
                guard isActive, isVisible, !Task.isCancelled else {
                    return
                }
                await model.refreshVisible(allowsNetwork: !connectivity.localOnly, using: loader)
            #endif
        }
    }

    private var usesVerticalRecentRows: Bool {
        dynamicTypeSize.isAccessibilitySize
            || displayedItems.prefix(previewLimit).contains { actions.errorMessage(for: $0) != nil }
    }

    private var recentRows: some View {
        ForEach(
            Array(displayedItems.prefix(previewLimit).enumerated()).filter {
                !connectivity.localOnly || downloads.isReady($0.element)
            }, id: \.offset
        ) { index, item in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button {
                        playRecent(index)
                    } label: {
                        HStack(spacing: 10) {
                            homeArtwork(
                                item, library: library, isActive: isActive && isVisible, size: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.body.weight(.medium))
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    FoundationDownloadBadge(item: item)
                    Menu {
                        recentMenu(item, index: index)
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                    }
                    .menuStyle(.borderlessButton)
                    .foundationEllipsisMenuIndicator()
                    .accessibilityLabel("Actions for " + item.title)
                }
                if let error = actions.errorMessage(for: item) {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .frame(width: usesVerticalRecentRows ? nil : 276)
            .contextMenu { recentMenu(item, index: index) }
        }
    }

    private func playRecent(_ index: Int) {
        guard
            let selection = model.trackQueue(
                selecting: index, isAvailable: { !connectivity.localOnly || downloads.isReady($0) })
        else { return }
        player.setQueue(selection.items, selectedIndex: selection.index)
    }

    private func recentMenu(_ item: FoundationItem, index: Int) -> some View {
        FoundationItemMenu(
            item: item, actions: actions, initialFavorite: item.isFavorite,
            play: { playRecent(index) }, player: player, navigate: { openedItem = $0 })
    }

}

/// Display supplied album artwork without resolving metadata or changing the source item.
@MainActor private func homeArtwork(
    _ item: FoundationItem, library: any FoundationLibrary, isActive: Bool, size: CGFloat
) -> some View {
    let artworkItem = item.catalogArtworkItem
    return FoundationCatalogArtwork(
        item: artworkItem, library: library, isActive: isActive, size: size
    ).id(artworkItem.id + (artworkItem.primaryImageTag ?? ""))
}

private struct FoundationHomeShelfBoundary: ViewModifier {
    let contained: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if contained {
            content.foundationMacContainedShelf()
        } else {
            content.foundationMacShelfUnderlap()
        }
    }
}
