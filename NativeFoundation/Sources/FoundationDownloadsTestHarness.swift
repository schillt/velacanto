#if DEBUG && os(iOS) && targetEnvironment(simulator)
    import SwiftUI
    import UIKit

    /// Synthetic UI automation only; never opens a server session or the real account store.
    struct FoundationDownloadsTestHarness: View {
        static var enabled: Bool {
            ProcessInfo.processInfo.arguments.contains("-foundationDownloadsUITesting")
                && Bundle.main.bundleIdentifier == "com.chameleonenterprise.velacanto.uitesting"
                && UUID(
                    uuidString: ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"] ?? "")
                    != nil
        }

        // Bounded valid silence outlasts native Simulator animation-idle waits.
        nonisolated static var generatedToneSeconds: UInt32 {
            ProcessInfo.processInfo.arguments.contains("-fixtureLongPlayback") ? 3600 : 30
        }

        nonisolated static var storageRoot: URL {
            let runID = ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"]!
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("DownloadUITestFixtures", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        }

        @StateObject private var fixture = FoundationDownloadUIFixture()
        @StateObject private var playlistChanges = FoundationPlaylistChanges()
        var onSignedOut: (() -> Void)?
        @State private var cleaningAccount = false
        @Environment(\.dynamicTypeSize) private var systemDynamicTypeSize
        @State private var showingFixtureControls = false

        private var usesAccessibilitySizedText: Bool {
            ProcessInfo.processInfo.environment["FOUNDATION_UI_LARGE_TEXT"] == "1"
        }

        private var productionShell: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixtureProductionShell")
        }

        private var compactFixtureControls: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixtureCompactControls")
        }

        var body: some View {
            VStack(spacing: 0) {
                if compactFixtureControls { fixtureControlBand } else { fixtureControls }
                if ProcessInfo.processInfo.environment["FOUNDATION_UI_REDUCE_MOTION"] == "1",
                    ProcessInfo.processInfo.environment["FOUNDATION_UI_REDUCE_TRANSPARENCY"] == "1"
                {
                    Text("Synthetic accessibility: reduced motion, reduced transparency")
                        .font(.caption).dynamicTypeSize(.medium)
                        .accessibilityIdentifier("fixture-accessibility-effects")
                }
                if fixture.canonicalReady && !compactFixtureControls {
                    Text("Canonical fixture ready").font(.caption).dynamicTypeSize(.medium)
                }
                if fixture.membershipReady {
                    Text("Membership fixture ready").font(.caption).dynamicTypeSize(.medium)
                }
                content
            }
            .task {
                await fixture.primaryGenres.restoreBoundCache()
                await fixture.prepareCanonicalCollections()
                await fixture.prepareMembershipCollections()
                if !fixture.connectivity.localOnly {
                    await fixture.librarySelection?.validateSavedChoice()
                }
            }
            .foundationDownloadRemovalPresentation()
            .environmentObject(fixture.primaryGenres)
            .onChange(of: fixture.connectivity.localOnly) { _, localOnly in
                if localOnly { fixture.primaryGenres.cancel() }
            }
            .environmentObject(fixture.downloads)
            .environmentObject(fixture.preferences)
            .environmentObject(fixture.connectivity)
            .environmentObject(fixture.actions)
            .environmentObject(fixture.artwork)
            .environmentObject(fixture.continueListeningDismissals)
            .modifier(FoundationRemoteListeningUITestStorage())
            .environmentObject(playlistChanges)
            .environment(
                \.dynamicTypeSize,
                usesAccessibilitySizedText ? .accessibility3 : systemDynamicTypeSize
            )
            .modifier(FoundationUITestAppearance())
        }

        @ViewBuilder private var content: some View {
            if productionShell {
                FoundationLibraryView(
                    library: fixture.catalogLibrary, accountLibrary: fixture.library,
                    player: fixture.player, primaryGenres: fixture.primaryGenres,
                    signOut: {}, librarySelection: fixture.librarySelection)
            } else {
                fixtureNavigation
            }
        }

        private var fixtureNavigation: some View {
            NavigationStack {
                List {
                    Text("Synthetic download UI fixture — no server connection")
                    Button("Queue fixture playlist") {
                        fixture.downloads.download(fixture.playlist)
                    }
                    NavigationLink("Downloads") {
                        FoundationDownloadsView(library: fixture.library, player: fixture.player)
                    }
                    NavigationLink("Downloaded Music") {
                        FoundationDownloadManagementView()
                    }
                    FoundationDownloadUIPlaybackStatus(player: fixture.player)
                    if let onSignedOut {
                        Button(cleaningAccount ? "Cleaning fixture account…" : "Sign out fixture") {
                            cleaningAccount = true
                            fixture.player.stop()
                            Task {
                                let cleared = await fixture.downloads.clearAccount(
                                    waitForPlayback: true)
                                cleaningAccount = false
                                if cleared { onSignedOut() }
                            }
                        }.disabled(cleaningAccount)
                    }
                }
                .navigationTitle("Download Test Library")
            }
        }

        private var fixtureControlBand: some View {
            HStack {
                Button("Fixture controls") { showingFixtureControls = true }
                    .frame(minWidth: 44, minHeight: 44)
                    .modifier(
                        FoundationFixtureConnectivityValue(connectivity: fixture.connectivity))
                Button("Read catalog counts") {
                    Task { catalogCounts = await fixture.library.catalogCounts() }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityValue(catalogCounts)
                VStack(spacing: 0) {
                    if ProcessInfo.processInfo.arguments.contains("-fixturePlaylistReorder") {
                        FoundationDownloadUIQueueSnapshot(player: fixture.player)
                            .font(.system(size: 1)).frame(height: 1).clipped()
                    }
                    if ProcessInfo.processInfo.arguments.contains("-fixtureLongPlayback") {
                        FoundationDownloadUIPlaybackIdentity(player: fixture.player)
                            .lineLimit(1)
                    }
                    if fixture.canonicalReady {
                        Text("Canonical fixture ready").font(.caption)
                    }
                }
            }
            .frame(height: 44)
            .sheet(isPresented: $showingFixtureControls) {
                NavigationStack {
                    ScrollView {
                        VStack {
                            fixtureControls
                            if fixture.canonicalReady {
                                Text("Canonical fixture ready").font(.caption)
                            }
                        }.padding()
                    }
                    .navigationTitle("Fixture controls")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close fixture controls") { showingFixtureControls = false }
                        }
                    }
                }
            }
        }

        @State private var artworkCounts = ""
        @State private var catalogCounts = ""
        @State private var primaryGenreCounts = ""
        @State private var remoteFixtureRevision = 0
        @State private var remoteFixtureState = "playing"
        private var fixtureControls: some View {
            VStack {
                if ProcessInfo.processInfo.arguments.contains("-fixtureRemoteListening") {
                    Button("Next remote fixture track") {
                        Task {
                            remoteFixtureRevision = await fixture.catalogLibrary
                                .advanceRemoteTrack()
                            remoteFixtureState = "playing"
                        }
                    }
                    Text("Remote generation \(remoteFixtureRevision)")
                        .accessibilityIdentifier("fixture-remote-generation")
                    Text(remoteFixtureState).accessibilityIdentifier("fixture-remote-state")
                    Button("End remote fixture playback") {
                        Task {
                            await fixture.catalogLibrary.endRemotePlayback()
                            remoteFixtureState = "ended"
                        }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-fixtureHoldHomeGenres") {
                    Button("Release Home genres") {
                        Task { await fixture.library.releaseHomeGenres() }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-fixturePrimaryGenres")
                    || ProcessInfo.processInfo.arguments.contains("-fixtureArtworkCache")
                    || ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary")
                {
                    Button("Build primary genres") { fixture.primaryGenres.start() }
                        .accessibilityIdentifier("fixture-build-primary-genres")
                    Button("Release primary genre metadata") {
                        Task { await fixture.library.releasePrimaryGenreMetadata() }
                    }
                    Button("Read primary genre counts") {
                        Task { primaryGenreCounts = await fixture.library.primaryGenreCounts() }
                    }
                    Text(primaryGenreCounts).accessibilityIdentifier("fixture-primary-genre-counts")
                }
                if ProcessInfo.processInfo.arguments.contains("-fixtureHoldArtistAlbums") {
                    Button("Release artist albums") {
                        Task { await fixture.library.releaseArtistAlbums() }
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("-fixturePagedCatalog")
                    || ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetCatalog")
                    || ProcessInfo.processInfo.arguments.contains("-fixtureHoldFirstPlaylistTracks")
                {
                    if ProcessInfo.processInfo.arguments.contains("-fixtureHoldInitialCatalog") {
                        Button("Release initial catalog page") {
                            Task { await fixture.library.releaseInitialCatalogPage() }
                        }
                    }
                    if ProcessInfo.processInfo.arguments.contains(
                        "-fixtureDelayedAlphabetCapability")
                    {
                        Button("Release alphabet capability") {
                            Task { await fixture.library.releaseAlphabetCapability() }
                        }
                    }
                    Button("Read catalog counts") {
                        Task { catalogCounts = await fixture.library.catalogCounts() }
                    }
                    Text(catalogCounts).accessibilityIdentifier("fixture-catalog-counts")
                }
                if ProcessInfo.processInfo.arguments.contains("-fixtureArtworkCache") {
                    Button("Read artwork counts") {
                        Task {
                            for _ in 0..<20 {
                                guard !Task.isCancelled else { return }
                                artworkCounts = await fixture.library.artworkCounts()
                                try? await Task.sleep(for: .milliseconds(100))
                            }
                        }
                    }
                    Text(artworkCounts).accessibilityIdentifier("fixture-artwork-counts")
                }
                FoundationDownloadUIControls(
                    downloads: fixture.downloads, connectivity: fixture.connectivity,
                    playlist: fixture.playlist, productionShell: productionShell
                )
                if ProcessInfo.processInfo.arguments.contains("-fixtureLongPlayback")
                    && !compactFixtureControls
                {
                    FoundationDownloadUIPlaybackIdentity(player: fixture.player)
                }
            }
        }
    }

    /// The compact band's accessibility status observes the actual child owner directly.
    private struct FoundationFixtureConnectivityValue: ViewModifier {
        @ObservedObject var connectivity: FoundationConnectivity

        func body(content: Content) -> some View {
            content.accessibilityValue(connectivity.localOnly ? "offline" : "online")
        }
    }

    /// Observe policy and connectivity owners directly so synthetic toggles follow external updates.
    private struct FoundationDownloadUIControls: View {
        @ObservedObject var downloads: FoundationDownloads
        @ObservedObject var connectivity: FoundationConnectivity
        let playlist: FoundationItem
        let productionShell: Bool
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize
        @Environment(\.verticalSizeClass) private var verticalSizeClass

        var body: some View {
            Group {
                if verticalSizeClass == .compact {
                    HStack(spacing: 16) {
                        VStack(spacing: 2) { statusControls }
                        networkToggle
                        cellularToggle
                    }.padding(.horizontal).padding(.vertical, 4)
                } else {
                    VStack {
                        statusControls
                        networkToggle
                        cellularToggle
                    }.padding()
                }
            }.background(.regularMaterial)
                // Only synthetic controls are capped; production content remains accessibility3.
                .dynamicTypeSize(.medium)
        }

        @ViewBuilder private var statusControls: some View {
            if verticalSizeClass != .compact { Text("Synthetic fixture controls").font(.caption) }
            if ProcessInfo.processInfo.environment["FOUNDATION_UI_LARGE_TEXT"] == "1" {
                Text(
                    dynamicTypeSize == .accessibility3
                        ? "Synthetic Dynamic Type: accessibility3"
                        : "Synthetic Dynamic Type override missing"
                )
                .font(.caption)
                .accessibilityIdentifier("fixture-dynamic-type-size")
            }
            if productionShell {
                Button("Queue fixture playlist") { downloads.download(playlist) }
            }
            if verticalSizeClass != .compact,
                downloads.owners.contains(where: { $0.state == .ready }),
                !downloads.downloadedSongs.isEmpty
            {
                Text("Fixture download ready").font(.caption)
            }
            if verticalSizeClass != .compact,
                let owner = downloads.owners.first(where: { $0.state != .ready })
            {
                Text(owner.status).font(.caption)
                if owner.state == .downloading {
                    ProgressView()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Fixture transfer in progress")
                        .accessibilityIdentifier("fixture-download-progress")
                }
            }
        }

        private var networkToggle: some View {
            Toggle(
                "Simulate unavailable network",
                isOn: Binding(
                    get: { connectivity.localOnly },
                    set: { offline in
                        connectivity.update(
                            status: offline ? .unavailable : .available,
                            wifiOrWired: !offline && productionShell,
                            cellular: !offline && !productionShell)
                        downloads.updateConnectivity(
                            isConnected: !offline, usesWiFi: !offline && productionShell)
                    }))
        }

        private var cellularToggle: some View {
            Toggle(
                "Use Cellular Data",
                isOn: Binding(
                    get: { downloads.allowsCellular },
                    set: { downloads.setAllowsCellular($0) }))
        }
    }

    /// Production sign-in form with a bounded in-memory authenticator; no Keychain or server.
    struct FoundationAccountUITestHarness: View {
        @State private var signedIn = false
        @State private var failedOnce = false
        @State private var notice: String?
        @StateObject private var delayedResponse = FoundationDelayedAuthenticationResponse()

        private var delayedAuthentication: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixtureDelayedAuth")
        }

        var body: some View {
            Group {
                if signedIn {
                    FoundationDownloadsTestHarness {
                        let result = FoundationSignOutPolicy.begin {
                            Task { true }
                        } clear: {
                            signedIn = false
                        } clearPins: {
                            true
                        }
                        if result.localCleared {
                            notice = "Fixture account cleanup complete"
                        }
                    }
                } else {
                    VStack {
                        if let notice { Text(notice) }
                        if delayedAuthentication {
                            Button("Complete delayed authentication") { delayedResponse.complete() }
                                .disabled(!delayedResponse.isWaiting)
                            if delayedResponse.wasDelivered {
                                Text("Delayed authentication response delivered")
                            }
                        }
                        FoundationSignInView { url, username, password in
                            if ProcessInfo.processInfo.arguments.contains(
                                "-fixtureUnreachableServer")
                            {
                                throw URLError(.cannotConnectToHost)
                            }
                            if ProcessInfo.processInfo.arguments.contains("-fixtureInvalidServer") {
                                throw URLError(.badURL)
                            }
                            guard url.host == "example.invalid", username == "synthetic-ui",
                                password == "synthetic-not-a-password"
                            else { throw FoundationLibraryError.authentication }
                            if delayedAuthentication {
                                // Deliberately return success after Cancel; the production form owns rejection.
                                try await delayedResponse.waitForCompletion()
                            } else {
                                try await Task.sleep(for: .milliseconds(500))
                                try Task.checkCancellation()
                                if !failedOnce {
                                    failedOnce = true
                                    throw FoundationLibraryError.authentication
                                }
                            }
                            return {
                                notice = nil
                                signedIn = true
                            }
                        }
                    }
                }
            }
            .onDisappear { delayedResponse.complete() }
            .modifier(FoundationUITestAppearance())
        }
    }

    /// At most one pending response; the fixture view explicitly owns its completion lifetime.
    @MainActor
    private final class FoundationDelayedAuthenticationResponse: ObservableObject {
        @Published private(set) var isWaiting = false
        @Published private(set) var wasDelivered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func waitForCompletion() async throws {
            guard continuation == nil else { throw FoundationLibraryError.unavailable }
            wasDelivered = false
            await withCheckedContinuation { (pending: CheckedContinuation<Void, Never>) in
                continuation = pending
                isWaiting = true
            }
            wasDelivered = true
        }

        func complete() {
            let pending = continuation
            continuation = nil
            isWaiting = false
            pending?.resume()
        }

        isolated deinit { continuation?.resume() }
    }

    struct FoundationDownloadsTestCleanup: View {
        @State private var status = "Cleaning fixture"
        var body: some View {
            Text(status).task {
                // Called only after the app entry validates the isolated bundle and UUID.
                let root = FoundationDownloadsTestHarness.storageRoot
                do {
                    if FileManager.default.fileExists(atPath: root.path) {
                        try FileManager.default.removeItem(at: root)
                    }
                    UserDefaults.standard.removePersistentDomain(
                        forName: "FoundationDownloadUIFixture."
                            + ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"]!)
                    status = "Fixture cleanup complete"
                } catch {
                    status = "Fixture cleanup failed"
                }
            }
        }
    }

    private struct FoundationDownloadUIPlaybackStatus: View {
        @ObservedObject var player: FoundationPlayer
        var body: some View {
            Text("Fixture playback: \(String(describing: player.state))")
                .accessibilityIdentifier("fixture-playback-state")
        }
    }

    /// Synthetic continuity evidence: route navigation must retain the exact queue occurrence.
    struct FoundationDownloadUIPlaybackIdentity: View {
        @ObservedObject var player: FoundationPlayer
        @EnvironmentObject private var actions: FoundationLibraryActions
        var identifier = "fixture-playback-identity"

        private var collectionOutcomeStatus: String {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureCollectionOutcome") else {
                return ""
            }
            return "loading \(actions.isQueueLoading); loaded \(actions.queueLoadedCount); "
                + "error \(actions.queueErrorMessage ?? "none"); "
                + "notice \(actions.queueNotice ?? "none"); retry \(actions.canRetryQueueAddition)"
        }

        var body: some View {
            Text(
                verbatim:
                    "Fixture identity: \(player.selectedEntryID?.uuidString ?? "none"); item \(player.queue.first { $0.id == player.selectedEntryID }?.item.id ?? "none"); intent \(player.wantsPlayback); state \(String(describing: player.state))"
            )
            .font(.caption).lineLimit(1).dynamicTypeSize(.medium)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(collectionOutcomeStatus)
        }
    }

    struct FoundationDetailUIContextEvidence: View {
        let item: FoundationItem
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.foundationRelatedItemSheet) private var relatedItemSheet

        var body: some View {
            Text(
                "Detail context: \(relatedItemSheet ? "related" : "browsing"); "
                    + "appearance \(colorScheme == .dark ? "dark" : "light")"
            )
            .font(.system(size: 1)).frame(width: 1, height: 1).clipped().opacity(0.05)
            .allowsHitTesting(false)
            .accessibilityIdentifier("fixture-detail-context-\(item.kind)-\(item.id)")
        }
    }

    struct FoundationDownloadUIQueueSnapshot: View {
        @ObservedObject var player: FoundationPlayer
        var body: some View {
            let snapshot: [String: Any] = [
                "queue": player.queue.map { $0.id.uuidString },
                "history": player.history.map { $0.id.uuidString },
                "upcoming": player.upcoming.map { $0.id.uuidString },
                "selected": player.selectedEntryID?.uuidString ?? "none",
                "shuffle": player.shuffleEnabled,
                "repeat": player.repeatMode.rawValue,
            ]
            let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
            Text(verbatim: data.flatMap { String(data: $0, encoding: .utf8) } ?? "invalid")
                .accessibilityIdentifier("fixture-player-queue-snapshot")
        }
    }

    @MainActor
    private final class FoundationDownloadUIFixture: ObservableObject {
        @Published private(set) var canonicalReady = false
        @Published private(set) var membershipReady = false
        let downloads: FoundationDownloads
        let player: FoundationPlayer
        let library: FoundationDownloadUILibrary
        let primaryGenres: FoundationPrimaryGenresModel
        @Published private(set) var catalogLibrary: FoundationDownloadUILibrary
        private(set) var librarySelection: FoundationMusicLibrarySelection?
        let actions: FoundationLibraryActions
        let artwork: FoundationCurrentArtwork
        let preferences: FoundationPlaybackPreferences
        let continueListeningDismissals = FoundationContinueListeningDismissals()
        let connectivity = FoundationConnectivity(
            monitorConnectivity: false, settleDuration: .zero, retry: {})
        let playlist = FoundationItem(
            id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic", kind: .playlist,
            duration: nil)

        init() {
            let preferences = FoundationPlaybackPreferences(
                defaults: UserDefaults(
                    suiteName: "FoundationDownloadUIFixture."
                        + ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"]!)!)
            self.preferences = preferences
            let actions = FoundationLibraryActions(
                sourceScope: "synthetic-ui", read: { _ in nil }, write: { _, _ in },
                trackPreferences: preferences,
                mutateFavorite: { _, _ in })
            self.actions = actions
            let root = FoundationDownloadsTestHarness.storageRoot
            let library = FoundationDownloadUILibrary()
            self.library = library
            self.catalogLibrary = library
            self.primaryGenres = FoundationPrimaryGenresModel(library: library)
            let transfer = FoundationDownloadUITransfer(
                failOnce: ProcessInfo.processInfo.arguments.contains("-fixtureFailOnce"))
            let downloads = FoundationDownloads(
                scope: "synthetic-ui", library: library, root: root,
                transfer: { _, destination, _, progress in
                    try await transfer.write(to: destination, progress: progress)
                }, monitorConnectivity: false,
                observeTracks: { items, albumID in
                    actions.observeTrackCopies(items, albumID: albumID)
                },
                projectTracks: { items, albumID in actions.visibleTracks(items, albumID: albumID) })
            self.downloads = downloads
            self.player = FoundationPlayer(
                library: library, resolveResource: { try await downloads.playbackResource(for: $0) }
            )
            self.player.configureTrackProjection(
                project: { actions.visibleTracks($0) }, observe: { actions.observeTrackCopies($0) })
            self.artwork = FoundationCurrentArtwork(player: player) { item in
                await downloads.retainedArtwork(for: item)
            }
            let connectivity = self.connectivity
            actions.configureTrackAvailability { [weak connectivity, weak downloads] item in
                connectivity?.localOnly != true || downloads?.isReady(item) == true
            }
            // Start on synthetic cellular; the production toggle governs transfer permission.
            let productionShell = ProcessInfo.processInfo.arguments.contains(
                "-fixtureProductionShell")
            downloads.updateConnectivity(
                isConnected: !ProcessInfo.processInfo.arguments.contains("-fixtureStartOffline"),
                usesWiFi: productionShell)
            connectivity.update(
                status: ProcessInfo.processInfo.arguments.contains("-fixtureStartOffline")
                    ? .unavailable : .available,
                wifiOrWired: productionShell, cellular: !productionShell)
            if ProcessInfo.processInfo.arguments.contains("-fixtureLibrarySelection") {
                let store = FoundationMusicLibraryStore(
                    scope: FoundationMusicLibraryStore.digest("synthetic-selection-account"),
                    root: root.appendingPathComponent("library-selections", isDirectory: true))
                let selected = try? store.load()
                catalogLibrary = FoundationDownloadUILibrary(selectionID: selected?.id)
                primaryGenres.bind(catalogLibrary)
                librarySelection = FoundationMusicLibrarySelection(
                    selected: selected,
                    load: {
                        if ProcessInfo.processInfo.arguments.contains(
                            "-fixtureSelectedLibraryUnavailable")
                        {
                            return [
                                .init(
                                    id: "000000000000000000000000000000c2",
                                    name: "Fixture Silver Library")
                            ]
                        }
                        return [
                            .init(
                                id: "000000000000000000000000000000c1",
                                name: "Fixture Cedar Library"),
                            .init(
                                id: "000000000000000000000000000000c2",
                                name: "Fixture Silver Library"),
                        ]
                    }, save: { try store.save($0) },
                    apply: { [weak self] id, available in
                        guard let self else { return }
                        let scoped = FoundationDownloadUILibrary(
                            selectionID: id, selectionAvailable: available)
                        self.primaryGenres.bind(scoped)
                        self.primaryGenres.bindDownloads(self.downloads)
                        self.catalogLibrary = scoped
                        self.continueListeningDismissals.configure(
                            scope: scoped.listeningActivityScope)
                        Task { await self.primaryGenres.restoreBoundCache() }
                    })
            }
            primaryGenres.bindDownloads(downloads)
            continueListeningDismissals.configure(scope: catalogLibrary.listeningActivityScope)
        }

        func prepareCanonicalCollections() async {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureCanonicalCollections"),
                !canonicalReady
            else { return }
            let album = FoundationItem(
                id: "album", title: "Fixture Album", subtitle: "Synthetic Artist", kind: .album,
                duration: 90, primaryImageTag: "synthetic", isFavorite: false)
            downloads.download(playlist)
            downloads.download(album)
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                if downloads.owners.count == 2,
                    downloads.owners.allSatisfy({ $0.state == .ready })
                {
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard downloads.owners.count == 2,
                downloads.owners.allSatisfy({ $0.state == .ready })
            else { return }
            let arguments = ProcessInfo.processInfo.arguments
            let state =
                arguments.firstIndex(of: "-fixtureDownloadState").flatMap {
                    arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
                } ?? "partial"
            let missing = FoundationItem(
                id: "missing-tone", title: "Fixture Missing Tone", subtitle: "Generated silent PCM",
                kind: .track,
                duration: TimeInterval(FoundationDownloadsTestHarness.generatedToneSeconds))
            if state != "full" { downloads.removeTrack(missing) }
            if state == "none" {
                downloads.removeTrack(
                    FoundationItem(
                        id: "tone", title: "Fixture Tone", subtitle: "", kind: .track,
                        duration: 30))
            }
            if ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetCatalog"),
                let page = try? await library.tracks(albumID: "album", startIndex: 0)
            {
                downloads.rememberCollection(
                    .init(
                        id: "numbered-album", title: "# Fixture Album",
                        subtitle: "Synthetic catalog",
                        kind: .album, duration: 90, primaryImageTag: "synthetic"),
                    tracks: page.items, complete: true)
            }
            canonicalReady = true
        }

        func prepareMembershipCollections() async {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-fixtureMembership"),
                arguments.indices.contains(index + 1), !membershipReady
            else { return }
            // Inventory verifies retained files asynchronously. Never race it by seeding a cold launch.
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                if !downloads.isLoading { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            guard !downloads.isLoading else { return }
            // Offline readiness proves verified restore only: no library lookup, rewrite, or retry.
            if arguments.contains("-fixtureStartOffline") {
                membershipReady = !downloads.downloadedSongs.isEmpty
                return
            }
            if !downloads.downloadedSongs.isEmpty {
                membershipReady = true
                return
            }
            let album = FoundationItem(
                id: "album", title: "Fixture Album", subtitle: "Fixture Artist", kind: .album,
                duration: 60, primaryImageTag: "synthetic",
                artist: .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"))
            let tracks = try? await library.tracks(albumID: "album", startIndex: 0)
            guard let tracks else { return }
            downloads.rememberCollection(album, tracks: tracks.items, complete: true)
            downloads.rememberCollection(playlist, tracks: tracks.items, complete: true)
            downloads.download(arguments[index + 1] == "track" ? tracks.items[0] : album)
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                if downloads.owners.first?.state == .ready { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard downloads.owners.first?.state == .ready else { return }
            if arguments[index + 1] == "album" { downloads.removeTrack(tracks.items[1]) }
            membershipReady = true
        }

        isolated deinit {
            artwork.invalidate()
            actions.invalidate()
            connectivity.invalidate()
            downloads.invalidate()
        }
    }

    private actor FoundationDownloadUILibrary: FoundationLibrary {
        nonisolated var listeningActivityScope: String {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureRemoteListening") else {
                return ""
            }
            return "synthetic-remote-"
                + (ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"] ?? "missing")
        }
        private var remoteTrackGeneration = 0
        private var remotePlaybackEnded = false
        func advanceRemoteTrack() -> Int {
            remoteTrackGeneration += 1
            remotePlaybackEnded = false
            return remoteTrackGeneration
        }
        func endRemotePlayback() { remotePlaybackEnded = true }
        func remoteListeningActivity() async throws -> [FoundationRemoteListeningActivity] {
            guard !listeningActivityScope.isEmpty, !remotePlaybackEnded else { return [] }
            let item = FoundationItem(
                id: "remote-fixture-track-\(remoteTrackGeneration)",
                title: "Remote Fixture Track \(remoteTrackGeneration)",
                subtitle: "Remote Fixture Artist", kind: .track, duration: 180,
                primaryImageTag: "synthetic",
                album: .init(
                    id: "remote-fixture-album", title: "Remote Fixture Album",
                    primaryImageTag: "synthetic"))
            let older = FoundationItem(
                id: "remote-older-track", title: "Older Remote Fixture",
                subtitle: item.subtitle, kind: .track, duration: 180,
                primaryImageTag: "synthetic", album: item.album)
            return [
                .init(
                    id: "remote-session-track-\(remoteTrackGeneration)",
                    deviceKey: "remote-fixture-Mac", deviceLabel: "Mac", checkedInAt: Date(),
                    item: item, albumTitle: "Remote Fixture Album", elapsed: 90),
                .init(
                    id: "remote-older-session", deviceKey: "remote-fixture-iPad",
                    deviceLabel: "iPad",
                    checkedInAt: Date().addingTimeInterval(-5), item: older,
                    albumTitle: "Remote Fixture Album", elapsed: 30),
            ]
        }

        private var alphabetCapabilityReleased = false
        func releaseAlphabetCapability() { alphabetCapabilityReleased = true }
        private let alphabetCatalog = ProcessInfo.processInfo.arguments.contains(
            "-fixtureAlphabetCatalog")
        private var alphabetFailures: Set<String> = []
        private var failedPlaybackCollections: Set<String> = []

        /// Affect only explicit Play/Shuffle expansion, never browsing or download preparation.
        private func playbackCollectionOutcome(key: String) throws -> FoundationPage? {
            guard FoundationRequestIntent.isPlayback else { return nil }
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-fixtureCollectionOutcome"),
                arguments.indices.contains(index + 1)
            else { return nil }
            catalogRequests["collection-playback-" + key, default: 0] += 1
            switch arguments[index + 1] {
            case "fail-once":
                if failedPlaybackCollections.insert(key).inserted { throw URLError(.timedOut) }
            case "empty": return .init(items: [], nextStartIndex: nil)
            default: break
            }
            return nil
        }

        func alphabetCapability() async -> FoundationAlphabetCapability {
            guard alphabetCatalog else { return .unavailable }
            if ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetCapabilityFailOnce") {
                catalogRequests["capability", default: 0] += 1
                if catalogRequests["capability"] == 1 { return .unavailable }
            }
            if ProcessInfo.processInfo.arguments.contains("-fixtureDelayedAlphabetCapability") {
                while !alphabetCapabilityReleased {
                    guard !Task.isCancelled else { return .unavailable }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return Task.isCancelled ? .unavailable : .verified
        }

        private func alphabetItems(kind: FoundationItem.Kind) -> [FoundationItem] {
            let firstWindow = kind == .track ? 100 : 50
            let extendedSongs = ProcessInfo.processInfo.arguments.contains(
                "-fixtureExtendedSongsCatalog")
            let count =
                ProcessInfo.processInfo.arguments.contains("-fixtureSharedChromeEvidence")
                ? (kind == .track ? 24 : 12)
                : (kind == .track ? (extendedSongs ? 280 : 180) : 120)
            return (0..<count).map { index in
                let letter =
                    index < firstWindow
                    ? "A"
                    : (index < firstWindow + 50 ? "F" : (extendedSongs && index >= 260 ? "Z" : "G"))
                return .init(
                    id: "alphabet-\(kind)-\(index)",
                    title: "\(letter) Fixture \(kind) \(index)", subtitle: "Synthetic catalog",
                    kind: kind, duration: kind == .track ? 30 : nil,
                    primaryImageTag: "synthetic", isFavorite: false,
                    album: kind == .track
                        ? .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic")
                        : nil)
            }
        }

        private func alphabetBrowse(kind: FoundationItem.Kind, startIndex: Int) async throws
            -> FoundationPage
        {
            let key = "\(kind)-all-\(startIndex)"
            catalogRequests[key, default: 0] += 1
            defer { if Task.isCancelled { catalogRequests["cancelled", default: 0] += 1 } }
            if kind == .track, startIndex == 100,
                ProcessInfo.processInfo.arguments.contains("-fixtureHoldOrdinaryAlphabetPage"),
                catalogRequests[key] == 1
            {
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            try Task.checkCancellation()
            if kind == .track, startIndex == 100,
                ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetFailOnce"),
                alphabetFailures.insert(key).inserted
            {
                throw FoundationLibraryError.invalidResponse
            }
            let items = alphabetItems(kind: kind)
            let end = min(startIndex + (kind == .track ? 100 : 50), items.count)
            guard startIndex < end else { return .init(items: [], nextStartIndex: nil) }
            return .init(
                items: Array(items[startIndex..<end]),
                nextStartIndex: end < items.count ? end : nil)
        }

        func alphabetPage(kind: FoundationItem.Kind, letter: String, startIndex: Int) async throws
            -> FoundationPage
        {
            guard alphabetCatalog || kind == .track, letter.count == 1,
                letter == "#" || ("A"..."Z").contains(letter), startIndex >= 0
            else {
                throw FoundationLibraryError.unavailable
            }
            let key = "\(kind)-\(letter)-\(startIndex)"
            catalogRequests[key, default: 0] += 1
            defer { if Task.isCancelled { catalogRequests["cancelled", default: 0] += 1 } }
            if letter == "A", ProcessInfo.processInfo.arguments.contains("-fixtureHoldAlphabetA") {
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            try await Task.sleep(for: .milliseconds(150))
            try Task.checkCancellation()
            if ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetFailOnce"),
                letter == "F", startIndex == 0, alphabetFailures.insert(key).inserted
            {
                throw FoundationLibraryError.invalidResponse
            }
            let all =
                alphabetCatalog
                ? alphabetItems(kind: kind)
                : (canonical ? [missing, track] : [track])
            if kind == .track {
                let offset =
                    startIndex == 0
                    ? (letter == "#"
                        ? 0
                        : (all.firstIndex {
                            FoundationSongAlphabetSeek.key($0) >= letter.lowercased()
                        } ?? all.count))
                    : startIndex
                let end = min(offset + 50, all.count)
                guard offset < end else { return .init(items: [], nextStartIndex: nil) }
                return .init(
                    items: Array(all[offset..<end]), nextStartIndex: end < all.count ? end : nil)
            }
            let items = all.filter { String($0.title.prefix(1)) >= letter }
            let end = min(startIndex + 50, items.count)
            guard startIndex < end else { return .init(items: [], nextStartIndex: nil) }
            return .init(
                items: Array(items[startIndex..<end]), nextStartIndex: end < items.count ? end : nil
            )
        }
        private let selectionID: String?
        private let selectionAvailable: Bool
        nonisolated let catalogScopeID: String
        nonisolated let primaryGenreIndexScope: FoundationPrimaryGenreIndex.Scope?
        private nonisolated let selectionCacheScope: String?

        init(selectionID: String? = nil, selectionAvailable: Bool = true) {
            self.selectionID = selectionID
            self.selectionAvailable = selectionAvailable
            if selectionAvailable,
                let source = try? FoundationCatalogSource.jellyfin(
                    scope: String(repeating: "a", count: 64))
            {
                self.primaryGenreIndexScope = .init(source: source, libraryID: selectionID)
            } else {
                self.primaryGenreIndexScope = nil
            }
            self.selectionCacheScope = selectionID.map { FoundationMusicLibraryStore.digest($0) }
            self.catalogScopeID =
                (selectionID.map { FoundationMusicLibraryStore.digest($0) } ?? "all")
                + (selectionAvailable ? "" : ".unavailable")
        }

        nonisolated func catalogCacheKey(_ key: String) -> String {
            selectionCacheScope.map { "library." + $0 + "." + key } ?? key
        }

        private func selectedAlbums() throws -> FoundationPage? {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureLibrarySelection") else {
                return nil
            }
            guard selectionAvailable else { throw FoundationLibraryError.unavailable }
            guard let selectionID else { return nil }
            let selectionName: String
            let albumID: String
            switch selectionID {
            case "000000000000000000000000000000c1":
                selectionName = "Cedar"
                albumID = "album"
            case "000000000000000000000000000000c2":
                selectionName = "Silver"
                albumID = "other-album"
            default: throw FoundationLibraryError.invalidResponse
            }
            return .init(
                items: [
                    .init(
                        id: albumID,
                        title: "Fixture " + selectionName + " Album",
                        subtitle: "Synthetic catalog", kind: .album, duration: 30,
                        primaryImageTag: "synthetic")
                ],
                nextStartIndex: nil)
        }
        // Synthetic opt-in presentation/reorder only; no real server is contacted.
        nonisolated var supportsPlaylistManagement: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixturePlaylistPresentation")
                || ProcessInfo.processInfo.arguments.contains("-fixturePlaylistReorder")
        }
        nonisolated var supportsPlaylistReordering: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixturePlaylistReorder")
        }
        private let usesCache = ProcessInfo.processInfo.arguments.contains("-fixtureArtworkCache")
        private let cache = FoundationArtworkCache(
            scope: "synthetic-artwork",
            root: FoundationDownloadsTestHarness.storageRoot.appendingPathComponent("artwork-cache")
        )
        nonisolated let catalogPageCache: FoundationCatalogPageCache? = FoundationCatalogPageCache(
            scope: "synthetic-ui",
            root: FoundationDownloadsTestHarness.storageRoot
                .appendingPathComponent("page-cache"))
        private var fetches: [String: Int] = [:]
        private let pagedCatalog = ProcessInfo.processInfo.arguments.contains(
            "-fixturePagedCatalog")
        private var catalogRequests: [String: Int] = [:]
        private var failedCatalogPages: Set<String> = []
        private var pendingCatalogKinds: Set<FoundationItem.Kind> = []
        private var releasedCatalogKinds: Set<FoundationItem.Kind> = []

        func releaseInitialCatalogPage() {
            releasedCatalogKinds.formUnion(pendingCatalogKinds)
        }

        func catalogCounts() -> String {
            catalogRequests.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        }

        func overview(for item: FoundationItem) async throws -> String? {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureOverview"),
                item.kind == .album || item.kind == .artist
            else { return nil }
            catalogRequests["overview-\(item.kind)", default: 0] += 1
            return (1...8).map { paragraph in
                "Synthetic \(item.kind) overview paragraph \(paragraph). "
                    + "This loaded text checks readable native sheet presentation, scrolling and reopening without another metadata request."
            }.joined(separator: "\n\n")
        }

        private func catalogPage(kind: FoundationItem.Kind, startIndex: Int, query: String? = nil)
            async throws -> FoundationPage
        {
            let key = "\(kind)-\(query ?? "browse")-\(startIndex)"
            catalogRequests[key, default: 0] += 1
            if query == nil, startIndex == 0,
                ProcessInfo.processInfo.arguments.contains("-fixtureHoldInitialCatalog")
            {
                pendingCatalogKinds.insert(kind)
                defer { pendingCatalogKinds.remove(kind) }
                while !releasedCatalogKinds.contains(kind) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            let delay = query == "slow" ? 1200 : (query == nil && startIndex == 0 ? 1800 : 650)
            try await Task.sleep(for: .milliseconds(delay))
            try Task.checkCancellation()
            if startIndex > 0,
                ProcessInfo.processInfo.arguments.contains("-fixtureCatalogPageFailOnce"),
                failedCatalogPages.insert(key).inserted
            {
                throw FoundationLibraryError.invalidResponse
            }
            let count =
                ProcessInfo.processInfo.arguments.contains("-fixtureGridPartialRow") ? 7 : 12
            let all = (0..<count).map { index in
                FoundationItem(
                    id: "paged-\(kind)-\(index)", title: "Paged \(kind) \(index)",
                    subtitle: "Synthetic catalog", kind: kind, duration: kind == .track ? 30 : nil,
                    primaryImageTag: "synthetic", isFavorite: false)
            }
            let matches =
                query.map { term in
                    all.filter { $0.title.localizedStandardContains(term) }
                } ?? all
            guard startIndex < matches.count else {
                return .init(items: [], nextStartIndex: nil)
            }
            // Repeat the last occurrence at the page boundary to exercise stable deduplication.
            let first = startIndex == 0 ? 0 : startIndex - 1
            let end = min(startIndex + 6, matches.count)
            return .init(
                items: Array(matches[first..<end]),
                nextStartIndex: end < matches.count ? end : nil)
        }

        func artworkCounts() -> String {
            "Album \(fetches["album", default: 0]), Artist \(fetches["artist", default: 0]), Playlist \(fetches["playlist", default: 0]), Genre \(fetches["genre", default: 0])"
        }
        func artworkResult(for item: FoundationItem, size: Int, allowsNetwork: Bool) async throws
            -> FoundationCurrentArtwork.Result?
        {
            if usesCache {
                return try await cache.result(for: item, pixels: size, allowsNetwork: allowsNetwork)
                { item, _ in
                    try await self.artwork(for: item)
                }
            }
            guard allowsNetwork else { return nil }
            let data = try await artwork(for: item)
            return await Task.detached {
                data.flatMap { FoundationCurrentArtwork.decode($0, maximumPixels: size) }
            }.value
        }
        func artists(startIndex: Int) async throws -> FoundationPage {
            if alphabetCatalog {
                return try await alphabetBrowse(kind: .artist, startIndex: startIndex)
            }
            if pagedCatalog { return try await catalogPage(kind: .artist, startIndex: startIndex) }
            return .init(
                items: (usesCache || canonical
                    || ProcessInfo.processInfo.arguments.contains("-fixtureMembership"))
                    ? [
                        FoundationItem(
                            id: "artist", title: "Fixture Artist", subtitle: "", kind: .artist,
                            duration: nil, primaryImageTag: "synthetic")
                    ] : [], nextStartIndex: nil)
        }
        private var primaryMetadataReads = 0
        private var primaryMetadataReturned = 0
        private var heldPrimaryMetadata: [UUID: CheckedContinuation<Void, Never>] = [:]

        func releasePrimaryGenreMetadata() {
            let pending = heldPrimaryMetadata.values
            heldPrimaryMetadata.removeAll()
            for continuation in pending { continuation.resume() }
        }

        func primaryGenreCounts() -> String {
            "metadata \(primaryMetadataReads) returned \(primaryMetadataReturned)"
        }

        func primaryGenreSongs(ids: [String]) async throws -> [FoundationItem] {
            guard ids.count <= 50 else { throw FoundationLibraryError.invalidResponse }
            return ids.map { id in
                if id == track.id { return track }
                if id == "home-boundary-song" || id.hasPrefix("home-late-song-") {
                    return FoundationItem(
                        id: id, title: "Final Home Album", subtitle: "Final Home Subtitle",
                        kind: .track,
                        duration: 30,
                        album: .init(
                            id: "home-boundary-album", title: "Final Home Album",
                            primaryImageTag: "synthetic"))
                }
                return FoundationItem(
                    id: id, title: "Primary Song " + String(id.suffix(1)),
                    subtitle: "Synthetic song-only genre",
                    kind: .track, duration: 30)
            }
        }

        func primaryGenreMetadataPage(startIndex: Int) async throws
            -> FoundationPrimaryGenreMetadataPage
        {
            guard startIndex == 0 else { throw FoundationLibraryError.invalidResponse }
            primaryMetadataReads += 1
            if ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary") {
                let songs: [FoundationPrimaryGenreMetadataPage.Song]
                if ProcessInfo.processInfo.arguments.contains("-fixtureHoldHomeGenres") {
                    try await waitForHomeGenres()
                    songs = (1...3).map { index in
                        .init(
                            id: "home-late-song-\(index)",
                            genres: [
                                .init(
                                    id: "home-late-genre-\(index)",
                                    title: "Late Home Genre \(index)")
                            ])
                    }
                } else {
                    let genre = FoundationItemReference(id: "genre", title: "Fixture Genre")
                    songs = [
                        .init(id: track.id, genres: [genre]),
                        .init(id: "home-boundary-song", genres: [genre]),
                    ]
                }
                primaryMetadataReturned += 1
                return .init(startIndex: 0, total: songs.count, songs: songs, nextStartIndex: nil)
            }
            let held =
                ProcessInfo.processInfo.arguments.contains("-fixtureHoldPrimaryGenreMetadata")
                && primaryMetadataReads == 1
            if held {
                let key = UUID()
                // Synthetic late-response proof only. Always release this bounded hold after 60s.
                Task {
                    try? await Task.sleep(for: .seconds(60))
                    heldPrimaryMetadata.removeValue(forKey: key)?.resume()
                }
                await withCheckedContinuation { heldPrimaryMetadata[key] = $0 }
            }
            let genre = FoundationItemReference(id: "genre", title: "Fixture Genre")
            let other = FoundationItemReference(id: "other-genre", title: "Fixture Other Genre")
            let rare = FoundationItemReference(id: "rare-genre", title: "Fixture Rare Genre")
            var sets: [[FoundationItemReference]]
            if held {
                sets = [[rare]]
            } else if ProcessInfo.processInfo.arguments.contains("-fixturePrimaryGenres") {
                sets = [[genre, other, rare], [genre, other], [genre], []]
            } else {
                sets = [[genre]]
            }
            if ProcessInfo.processInfo.arguments.contains("-fixturePrimaryGenreScopedQuery"), !held
            {
                sets += (1...6).map { number in
                    [
                        FoundationItemReference(
                            id: "extra-genre-\(number)", title: "Fixture Genre Extra \(number)")
                    ]
                }
            }
            primaryMetadataReturned += 1
            return .init(
                startIndex: 0, total: sets.count,
                songs: sets.enumerated().map {
                    .init(
                        id: $0.offset == 0 ? track.id : "primary-song-\($0.offset)",
                        genres: $0.element)
                }, nextStartIndex: nil)
        }

        func genres(startIndex: Int) async throws -> FoundationPage {
            if alphabetCatalog {
                return try await alphabetBrowse(kind: .genre, startIndex: startIndex)
            }
            if pagedCatalog { return try await catalogPage(kind: .genre, startIndex: startIndex) }
            return .init(
                items: usesCache
                    ? [
                        FoundationItem(
                            id: "genre", title: "Fixture Genre", subtitle: "", kind: .genre,
                            duration: nil, primaryImageTag: "synthetic")
                    ] : [], nextStartIndex: nil)
        }
        private let canonical =
            ProcessInfo.processInfo.arguments.contains(
                "-fixtureCanonicalCollections")
            || ProcessInfo.processInfo.arguments.contains("-fixtureMembership")
            || ProcessInfo.processInfo.arguments.contains("-fixtureSlowTransfer")
        private let missing = FoundationItem(
            id: "missing-tone", title: "Fixture Missing Tone", subtitle: "Generated silent PCM",
            kind: .track,
            duration: TimeInterval(FoundationDownloadsTestHarness.generatedToneSeconds),
            isFavorite: false,
            album: ProcessInfo.processInfo.arguments.contains("-fixtureUnknownRelatedItems")
                ? nil
                : .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic"),
            artist: ProcessInfo.processInfo.arguments.contains("-fixtureUnknownRelatedItems")
                ? nil
                : .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"))
        private var orderedTracks: [FoundationItem] {
            if canonical && ProcessInfo.processInfo.arguments.contains("-fixtureQueuePresentation")
            {
                return [track, missing, track, missing, track]
            }
            return canonical ? [track, missing, track] : [track, track]
        }
        func songs(startIndex: Int) async throws -> FoundationPage {
            if alphabetCatalog {
                return try await alphabetBrowse(kind: .track, startIndex: startIndex)
            }
            if pagedCatalog { return try await catalogPage(kind: .track, startIndex: startIndex) }
            return .init(items: canonical ? [track, missing] : [track], nextStartIndex: nil)
        }
        func search(query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int)
            async throws -> FoundationPage
        {
            if alphabetCatalog {
                catalogRequests["\(kind)-search-\(startIndex)", default: 0] += 1
                let items = alphabetItems(kind: kind).filter {
                    $0.title.localizedStandardContains(query)
                }
                let end = min(startIndex + limit, items.count)
                guard startIndex < end else { return .init(items: [], nextStartIndex: nil) }
                return .init(
                    items: Array(items[startIndex..<end]),
                    nextStartIndex: end < items.count ? end : nil)
            }
            if pagedCatalog {
                return try await catalogPage(kind: kind, startIndex: startIndex, query: query)
            }
            let items: [FoundationItem]
            switch kind {
            case .track: items = canonical ? [track, missing] : [track]
            case .album: items = [album]
            case .artist:
                items = [
                    .init(
                        id: "artist", title: "Fixture Artist", subtitle: "", kind: .artist,
                        duration: nil)
                ]
            case .playlist:
                items = [
                    .init(
                        id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic",
                        kind: .playlist, duration: nil)
                ]
            case .genre: items = []
            }
            return .init(
                items: items.filter { $0.title.localizedStandardContains(query) },
                nextStartIndex: nil)
        }
        func playlists(startIndex: Int) async throws -> FoundationPage {
            if alphabetCatalog {
                return try await alphabetBrowse(kind: .playlist, startIndex: startIndex)
            }
            if pagedCatalog {
                return try await catalogPage(kind: .playlist, startIndex: startIndex)
            }
            return .init(
                items: [
                    .init(
                        id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic",
                        kind: .playlist, duration: nil,
                        primaryImageTag: usesCache ? "synthetic" : nil,
                        isFavorite: ProcessInfo.processInfo.arguments.contains(
                            "-fixtureFavoritesCatalog"))
                ], nextStartIndex: nil)
        }
        private var heldInitialPlaylistRead = false
        func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage {
            if let outcome = try playbackCollectionOutcome(key: "playlist") { return outcome }
            catalogRequests["playlist-tracks", default: 0] += 1
            if ProcessInfo.processInfo.arguments.contains("-fixtureHoldFirstPlaylistTracks"),
                !heldInitialPlaylistRead
            {
                heldInitialPlaylistRead = true
                // Synthetic first-entry cancellation; a subsequent visible owner can load.
                try await Task.sleep(for: .seconds(30))
            }
            try Task.checkCancellation()
            if supportsPlaylistReordering {
                return .init(items: reorderEntries().map(\.item), nextStartIndex: nil)
            }
            return .init(items: orderedTracks, nextStartIndex: nil)
        }

        private let track = FoundationItem(
            id: "tone",
            title: ProcessInfo.processInfo.arguments.contains("-fixtureAlphabetCatalog")
                ? "# Fixture Tone" : "Fixture Tone",
            subtitle: "Generated silent PCM", kind: .track,
            duration: TimeInterval(FoundationDownloadsTestHarness.generatedToneSeconds),
            isFavorite: ProcessInfo.processInfo.arguments.contains("-fixtureFavoritesCatalog"),
            album: ProcessInfo.processInfo.arguments.contains("-fixtureUnknownRelatedItems")
                ? nil
                : .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic"),
            artist: ProcessInfo.processInfo.arguments.contains("-fixtureUnknownRelatedItems")
                ? nil
                : .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"))
        private let album = FoundationItem(
            id: "album", title: "Fixture Album", subtitle: "Synthetic Artist", kind: .album,
            duration: 30, primaryImageTag: "synthetic",
            isFavorite: ProcessInfo.processInfo.arguments.contains("-fixtureFavoritesCatalog"),
            artist: .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"),
            genres: ProcessInfo.processInfo.arguments.contains("-fixtureArtworkCache")
                ? [.init(id: "genre", title: "Fixture Genre", primaryImageTag: "synthetic")] : [])
        func albums(startIndex: Int) async throws -> FoundationPage {
            if alphabetCatalog {
                return try await alphabetBrowse(kind: .album, startIndex: startIndex)
            }
            if let selected = try selectedAlbums() { return selected }
            if pagedCatalog { return try await catalogPage(kind: .album, startIndex: startIndex) }
            return .init(items: [album], nextStartIndex: nil)
        }
        private var artistAlbumsReleased = false
        func releaseArtistAlbums() { artistAlbumsReleased = true }

        func albums(artistID: String, startIndex: Int) async throws -> FoundationPage {
            if ProcessInfo.processInfo.arguments.contains("-fixtureHoldArtistAlbums") {
                while !artistAlbumsReleased {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            return .init(items: [album], nextStartIndex: nil)
        }

        func similarItems(for item: FoundationItem) async throws -> FoundationPage {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureRelatedRecommendations")
            else { throw FoundationLibraryError.unavailable }
            catalogRequests["recommendations-\(item.kind)", default: 0] += 1
            let artist = item.kind == .artist
            return .init(
                items: [
                    .init(
                        id: artist ? "recommended-artist" : "recommended-album",
                        title: artist ? "Recommended Fixture Artist" : "Recommended Fixture Album",
                        subtitle: "Synthetic recommendation", kind: artist ? .artist : .album,
                        duration: nil, primaryImageTag: "synthetic")
                ], nextStartIndex: nil)
        }

        func appearances(artistID: String, startIndex: Int) async throws -> FoundationPage {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureRelatedRecommendations")
            else { throw FoundationLibraryError.unavailable }
            catalogRequests["artist-appearances", default: 0] += 1
            return .init(items: [album], nextStartIndex: nil)
        }

        func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage {
            if let outcome = try playbackCollectionOutcome(key: "artist") { return outcome }
            if ProcessInfo.processInfo.arguments.contains("-fixtureHoldArtistTracks") {
                // User cancellation must unwind the real collection action, not a test release.
                while true { try await Task.sleep(for: .seconds(60)) }
            }
            return .init(items: canonical ? [track, missing] : [track], nextStartIndex: nil)
        }
        func recentAlbums(startIndex: Int) async throws -> FoundationPage {
            if let selected = try selectedAlbums() { return selected }
            return .init(items: [album], nextStartIndex: nil)
        }
        func recentMusicSuggestions() async throws -> FoundationPage {
            try await recentAlbums(startIndex: 0)
        }

        func recentTracks(startIndex: Int) async throws -> FoundationPage {
            guard startIndex == 0 else { return .init(items: [], nextStartIndex: nil) }
            // Preserve the synthetic provider's Date Added ascending order, distinct from album order.
            return .init(items: canonical ? [missing, track] : [track], nextStartIndex: nil)
        }
        func recentlyPlayed(startIndex: Int) async throws -> FoundationPage {
            .init(items: [track], nextStartIndex: nil)
        }
        func favorites(kind: FoundationItem.Kind, startIndex: Int) async throws -> FoundationPage {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureFavoritesCatalog"),
                [.album, .artist, .track, .playlist].contains(kind)
            else { throw FoundationLibraryError.unavailable }
            let base: FoundationItem
            switch kind {
            case .album: base = album
            case .track: base = track
            case .playlist:
                base = FoundationItem(
                    id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic",
                    kind: .playlist, duration: nil, primaryImageTag: "synthetic")
            default:
                base = FoundationItem(
                    id: "artist", title: "Fixture Artist", subtitle: "", kind: .artist,
                    duration: nil, primaryImageTag: "synthetic")
            }
            let items = (0..<8).map { index in
                var item =
                    index == 0
                    ? base
                    : FoundationItem(
                        id: base.id + "-favorite-" + String(index),
                        title: base.title + " " + String(index),
                        subtitle: base.subtitle, kind: kind, duration: base.duration,
                        primaryImageTag: base.primaryImageTag)
                item.isFavorite = true
                return item
            }
            guard startIndex < items.count else { return .init(items: [], nextStartIndex: nil) }
            let end = min(startIndex + 6, items.count)
            return .init(
                items: Array(items[startIndex..<end]), nextStartIndex: end < items.count ? end : nil
            )
        }

        func favorites(startIndex: Int) async throws -> FoundationPage {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureFavoritesCatalog") else {
                throw FoundationLibraryError.unavailable
            }
            guard startIndex == 0 else { return .init(items: [], nextStartIndex: nil) }
            let artist = FoundationItem(
                id: "artist", title: "Fixture Artist", subtitle: "", kind: .artist,
                duration: nil, primaryImageTag: "synthetic")
            let playlist = FoundationItem(
                id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic",
                kind: .playlist, duration: nil, primaryImageTag: "synthetic")
            // Deliberately mixed server order verifies presentation grouping keeps song identity.
            let items = [track, album, playlist, artist].map { item in
                var favorite = item
                favorite.isFavorite = true
                return favorite
            }
            return .init(items: items, nextStartIndex: nil)
        }

        func favoriteCollectionsPreview() async throws -> FoundationPage {
            if ProcessInfo.processInfo.arguments.contains("-fixtureEmptyFavoritePreview") {
                return .init(items: [], nextStartIndex: nil)
            }
            let albums = try await favorites(kind: .album, startIndex: 0)
            let playlists = try await favorites(kind: .playlist, startIndex: 0)
            return foundationFavoriteCollectionsPreview(albums: albums, playlists: playlists)
        }

        func favoriteAlbums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        private var homeGenresReleased = false
        private var pendingHomeGenres: (id: UUID, continuation: CheckedContinuation<Void, Error>)?

        func releaseHomeGenres() {
            homeGenresReleased = true
            let pending = pendingHomeGenres
            pendingHomeGenres = nil
            pending?.continuation.resume()
        }

        private func cancelHomeGenres(_ id: UUID) {
            guard pendingHomeGenres?.id == id else { return }
            let pending = pendingHomeGenres
            pendingHomeGenres = nil
            pending?.continuation.resume(throwing: CancellationError())
        }

        private func waitForHomeGenres() async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if homeGenresReleased {
                        continuation.resume()
                    } else if pendingHomeGenres != nil {
                        continuation.resume(throwing: FoundationLibraryError.unavailable)
                    } else {
                        pendingHomeGenres = (id, continuation)
                    }
                }
            } onCancel: {
                Task { await self.cancelHomeGenres(id) }
            }
            try Task.checkCancellation()
        }

        func homeGenres() async throws -> FoundationPage {
            if ProcessInfo.processInfo.arguments.contains("-fixtureHoldHomeGenres") {
                try await waitForHomeGenres()
                return .init(
                    items: (1...3).map { index in
                        FoundationItem(
                            id: "home-late-genre-\(index)", title: "Late Home Genre \(index)",
                            subtitle: "", kind: .genre, duration: nil, primaryImageTag: "synthetic")
                    }, nextStartIndex: nil)
            }
            // The paged fixture targets explicit Library indexes, not unrelated Home shelves.
            if pagedCatalog { return .init(items: [], nextStartIndex: nil) }
            return try await genres(startIndex: 0)
        }
        func albums(genreID: String, startIndex: Int) async throws -> FoundationPage {
            guard ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary") else {
                throw FoundationLibraryError.unavailable
            }
            let final = FoundationItem(
                id: "home-boundary-album", title: "Final Home Album",
                subtitle: "Final Home Subtitle", kind: .album, duration: nil,
                primaryImageTag: "synthetic")
            return .init(items: startIndex == 0 ? [final] : [], nextStartIndex: nil)
        }
        func searchGenres() async throws -> FoundationPage {
            try await genres(startIndex: 0)
        }
        func artwork(for item: FoundationItem) async throws -> Data? {
            if ProcessInfo.processInfo.arguments.contains("-fixtureMissingArtwork") { return nil }
            fetches[String(describing: item.kind), default: 0] += 1
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(
                size: CGSize(width: 360, height: 360), format: format)
            return renderer.pngData { context in
                UIColor.systemIndigo.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
                UIColor.systemTeal.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 70, y: 70, width: 220, height: 220))
                UIColor.white.setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 140, y: 140, width: 80, height: 80))
            }
        }
        func tracks(albumID: String, startIndex: Int) async throws -> FoundationPage {
            if let outcome = try playbackCollectionOutcome(key: "album") { return outcome }
            if ProcessInfo.processInfo.arguments.contains("-fixtureDuplicateAlbumTracks") {
                var first = track
                first.trackNumber = 1
                first.discNumber = 1
                var duplicate = FoundationItem(
                    id: "tone-duplicate", title: track.title,
                    subtitle: track.subtitle, kind: .track, duration: track.duration)
                duplicate.album = track.album
                duplicate.trackNumber = 1
                duplicate.discNumber = 1
                var second = FoundationItem(
                    id: "tone-next", title: "Fixture Second Song",
                    subtitle: track.subtitle, kind: .track, duration: track.duration)
                second.album = track.album
                second.trackNumber = 2
                second.discNumber = 1
                return .init(
                    items: startIndex == 0 ? [first, duplicate, second] : [], nextStartIndex: nil)
            }
            return .init(items: canonical ? orderedTracks : [track], nextStartIndex: nil)
        }
        func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
            .init(name: "Fixture Playlist", canEdit: supportsPlaylistReordering, canDelete: false)
        }
        func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
            if supportsPlaylistReordering {
                return .init(entries: startIndex == 0 ? reorderEntries() : [], nextStartIndex: nil)
            }
            return .init(
                entries: orderedTracks.enumerated().map {
                    .init(
                        id: "occurrence-\($0.offset)", mutationID: "occurrence-\($0.offset)",
                        item: $0.element)
                }, nextStartIndex: nil)
        }
        private var reorderedMemberships: [FoundationPlaylistEntry]?
        private var failedReorder = false

        private func reorderEntries() -> [FoundationPlaylistEntry] {
            if let reorderedMemberships { return reorderedMemberships }
            let entries = orderedTracks.enumerated().map { index, track in
                var item = track
                let id = "occurrence-\(index)"
                item.playlistEntryID = id
                return FoundationPlaylistEntry(id: id, mutationID: id, item: item)
            }
            reorderedMemberships = entries
            return entries
        }

        func moveEntry(in playlistID: String, entryID: String, to index: Int) async throws {
            guard supportsPlaylistReordering else { throw FoundationLibraryError.unavailable }
            var members = reorderEntries()
            guard let current = members.firstIndex(where: { $0.mutationID == entryID }),
                members.indices.contains(index)
            else { throw FoundationLibraryError.invalidResponse }
            members.insert(members.remove(at: current), at: index)
            reorderedMemberships = members
            if ProcessInfo.processInfo.arguments.contains("-fixturePlaylistReorderFailOnce"),
                !failedReorder
            {
                failedReorder = true
                throw URLError(.networkConnectionLost)
            }
        }
        func playbackURL(for item: FoundationItem) async throws -> URL {
            throw FoundationLibraryError.unavailable
        }
        func downloadSource(for item: FoundationItem) async throws -> FoundationDownloadSource {
            .init(
                request: URLRequest(url: URL(string: "https://example.invalid/never-requested")!),
                fileExtension: "wav", expectedBytes: nil)
        }
    }

    private actor FoundationDownloadUITransfer {
        private var failOnce: Bool
        init(failOnce: Bool) { self.failOnce = failOnce }
        func write(
            to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws {
            progress(1, 2)
            // Keep the injected failure pending long enough for native UI automation to observe progress.
            try await Task.sleep(
                for: .seconds(
                    failOnce
                        ? 5
                        : (ProcessInfo.processInfo.arguments.contains("-fixtureSlowTransfer")
                            ? 30 : 1)))
            if failOnce {
                failOnce = false
                throw CocoaError(.fileWriteOutOfSpace)
            }
            // Valid bounded mono PCM silence; no external audio or account data.
            let seconds = FoundationDownloadsTestHarness.generatedToneSeconds
            let bytes: UInt32 = 22_050 * seconds * 2
            var data = Data()
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: "RIFF".utf8)
            append(bytes + 36)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(22_050))
            append(UInt32(44_100))
            append(UInt16(2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(bytes)
            data.append(Data(repeating: 0, count: Int(bytes)))
            try Task.checkCancellation()
            try data.write(to: destination)
            progress(2, 2)
        }
    }
    private struct FoundationUITestAppearance: ViewModifier {
        @Environment(\.foundationReduceMotion) private var reduceMotion
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        func body(content: Content) -> some View {
            let values = ProcessInfo.processInfo.environment
            content
                .environment(
                    \.foundationReduceMotion,
                    reduceMotion || values["FOUNDATION_UI_REDUCE_MOTION"] == "1"
                )
                .environment(
                    \.foundationReduceTransparency,
                    reduceTransparency || values["FOUNDATION_UI_REDUCE_TRANSPARENCY"] == "1"
                )
                .environment(
                    \.dynamicTypeSize,
                    values["FOUNDATION_UI_LARGE_TEXT"] == "1" ? .accessibility3 : dynamicTypeSize
                )
                .preferredColorScheme(
                    values["FOUNDATION_UI_COLOR_SCHEME"] == "light"
                        ? .light
                        : values["FOUNDATION_UI_COLOR_SCHEME"] == "dark" ? .dark : nil)
        }
    }

    /// Only the explicitly opted-in remote fixture changes AppStorage's suite.
    private struct FoundationRemoteListeningUITestStorage: ViewModifier {
        @ViewBuilder func body(content: Content) -> some View {
            if FoundationDownloadsTestHarness.enabled,
                ProcessInfo.processInfo.arguments.contains("-fixtureRemoteListening"),
                let run = ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"],
                let defaults = UserDefaults(suiteName: "FoundationRemoteListeningUI." + run)
            {
                content.defaultAppStorage(defaults)
            } else {
                content
            }
        }
    }

    private struct FoundationChromeUIContextKey: EnvironmentKey {
        static let defaultValue = ""
    }
    private struct FoundationChromeUIItemCountKey: EnvironmentKey { static let defaultValue = -1 }
    private struct FoundationChromeUIHasMoreKey: EnvironmentKey { static let defaultValue = false }
    extension EnvironmentValues {
        var foundationChromeUIItemCount: Int {
            get { self[FoundationChromeUIItemCountKey.self] }
            set { self[FoundationChromeUIItemCountKey.self] = newValue }
        }
        var foundationChromeUIHasMore: Bool {
            get { self[FoundationChromeUIHasMoreKey.self] }
            set { self[FoundationChromeUIHasMoreKey.self] = newValue }
        }
        var foundationChromeUIContext: String {
            get { self[FoundationChromeUIContextKey.self] }
            set { self[FoundationChromeUIContextKey.self] = newValue }
        }
    }
    private struct FoundationChromeUIFooterFrames: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
        }
    }
    struct FoundationChromeUIFooterProbe: ViewModifier {
        @Environment(\.foundationChromeUIContext) private var context
        func body(content: Content) -> some View {
            if FoundationChromeUIScrollProbe.enabled, !context.isEmpty {
                content.background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: FoundationChromeUIFooterFrames.self,
                            value: [context: proxy.frame(in: .global)])
                    }
                }
            } else {
                content
            }
        }
    }

    /// Synthetic metrics only. No inset, offset, margin, delegate or player mutation.
    struct FoundationChromeUIScrollProbe: ViewModifier {
        static var enabled: Bool {
            FoundationDownloadsTestHarness.enabled
                && ProcessInfo.processInfo.arguments.contains("-fixtureSharedChromeEvidence")
        }
        let clearance: CGFloat
        let nativeBottomInset: CGFloat?
        @Environment(\.displayScale) private var displayScale
        @Environment(\.foundationChromeUIItemCount) private var naturalRows
        @Environment(\.foundationChromeUIHasMore) private var hasMore
        @Environment(\.foundationChromeUIContext) private var context
        @Environment(\.foundationBottomChromeGeometry) private var chrome
        @State private var swiftFacts: [String: Double] = [:]
        @State private var nativeFacts: [String: Double] = [:]
        @State private var footerFrames: [String: CGRect] = [:]
        @State private var phase = 0.0
        @State private var expansionCount = 0.0
        @State private var observedMinimized = false
        @State private var minimizedFrame: CGRect?
        @State private var expandedFrame: CGRect?
        @State private var awaitingExpansion = false

        @ViewBuilder func body(content: Content) -> some View {
            if Self.enabled, !context.isEmpty {
                content
                    .onScrollGeometryChange(for: [String: Double].self) { geometry in
                        [
                            "swiftOffset": Double(geometry.contentOffset.y),
                            "swiftContentHeight": Double(geometry.contentSize.height),
                            "swiftContainerHeight": Double(geometry.containerSize.height),
                            "swiftInsetBottom": Double(geometry.contentInsets.bottom),
                        ]
                    } action: { _, value in
                        swiftFacts = value
                    }
                    .onScrollPhaseChange { _, value in
                        switch value {
                        case .idle: phase = 0
                        case .tracking: phase = 1
                        case .interacting: phase = 2
                        case .decelerating: phase = 3
                        case .animating: phase = 4
                        @unknown default: phase = -1
                        }
                    }
                    .onChange(of: chrome?.accessory, initial: true) { _, after in
                        guard let after else { return }
                        if after.placement == .minimized {
                            observedMinimized = true
                            minimizedFrame = after.frame
                            awaitingExpansion = true
                        } else if after.placement == .normal, awaitingExpansion,
                            let minimizedFrame, after.frame != minimizedFrame
                        {
                            expansionCount += 1
                            expandedFrame = after.frame
                            awaitingExpansion = false
                        }
                    }
                    .onPreferenceChange(FoundationChromeUIFooterFrames.self) { footerFrames = $0 }
                    .background {
                        FoundationChromeUINativeLocator(
                            refresh: swiftFacts, naturalRows: naturalRows,
                            receive: { nativeFacts = $0 }
                        )
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .overlay(alignment: .topLeading) {
                        Text("Synthetic shared chrome evidence")
                            .font(.system(size: 1)).foregroundStyle(.clear)
                            .frame(width: 1, height: 1).allowsHitTesting(false)
                            .accessibilityIdentifier("fixture-chrome-" + context)
                            .accessibilityValue(evidence)
                    }
            } else {
                content
            }
        }

        private var evidence: String {
            var facts = nativeFacts.merging(swiftFacts, uniquingKeysWith: { _, newer in newer })
            facts["clearance"] = Double(clearance)
            facts["displayScale"] = Double(displayScale)
            if let nativeBottomInset { facts["scopeNativeInset"] = Double(nativeBottomInset) }
            if let host = chrome?.host { facts["hostBottom"] = Double(host.maxY) }
            facts["naturalRows"] = Double(naturalRows)
            facts["hasMore"] = hasMore ? 1 : 0
            facts["phase"] = phase
            facts["expansions"] = expansionCount
            facts["observedMinimized"] = observedMinimized ? 1 : 0
            if let minimizedFrame {
                facts["lastMinFrameTop"] = Double(minimizedFrame.minY)
                facts["lastMinFrameHeight"] = Double(minimizedFrame.height)
            }
            if let expandedFrame {
                facts["lastExpansionFrameTop"] = Double(expandedFrame.minY)
                facts["lastExpansionFrameHeight"] = Double(expandedFrame.height)
            }
            facts["hasAccessory"] = chrome?.hasAccessory == true ? 1 : 0
            facts["placement"] =
                chrome?.accessory?.placement == .normal
                ? 1
                : chrome?.accessory?.placement == .minimized ? 2 : 0
            if let frame = chrome?.accessory?.frame {
                facts["accessoryTop"] = Double(frame.minY)
                facts["accessoryBottom"] = Double(frame.maxY)
            }
            if let frame = footerFrames[context] {
                facts["footerPresent"] = 1
                facts["footerHeight"] = Double(frame.height)
                facts["footerY"] = Double(frame.minY)
            } else {
                facts["footerPresent"] = 0
                facts["footerHeight"] = 0
            }
            let data = try? JSONSerialization.data(
                withJSONObject: facts.filter { $0.value.isFinite }, options: [.sortedKeys])
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        }
    }

    private struct FoundationChromeUINativeLocator: UIViewRepresentable {
        let refresh: [String: Double]
        let naturalRows: Int
        let receive: @MainActor @Sendable ([String: Double]) -> Void
        func makeUIView(context: Context) -> ProbeView {
            let view = ProbeView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            return view
        }
        func updateUIView(_ view: ProbeView, context: Context) {
            view.receive = receive
            view.naturalRows = naturalRows
            view.sample()
        }
        final class ProbeView: UIView {
            var receive: (@MainActor @Sendable ([String: Double]) -> Void)?
            var naturalRows = -1
            private weak var previousScroll: UIScrollView?
            private var last: [String: Double] = [:]
            override func didMoveToSuperview() {
                super.didMoveToSuperview()
                sample()
            }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                sample()
            }
            override func layoutSubviews() {
                super.layoutSubviews()
                sample()
            }

            func sample() {
                guard let window, let receive else { return }
                var parent = superview
                var selected: UIScrollView?
                var ambiguous = false
                while let root = parent {
                    if let scroll = root as? UIScrollView {
                        selected = scroll
                        break
                    }
                    var queue: [UIView] = [root]
                    var candidates: [UIScrollView] = []
                    var visited = 0
                    while !queue.isEmpty, visited < 4096 {
                        let view = queue.removeLast()
                        visited += 1
                        guard !view.isHidden, view.alpha > 0.01 else { continue }
                        if let scroll = view as? UIScrollView,
                            scroll.window === window, !scroll.isHidden,
                            scroll.bounds.height >= 200, scroll.bounds.width >= 200
                        {
                            candidates.append(scroll)
                        }
                        queue.append(contentsOf: view.subviews)
                    }
                    if let largest = candidates.max(by: { $0.bounds.height < $1.bounds.height }) {
                        let ties = candidates.filter {
                            abs($0.bounds.height - largest.bounds.height) < 1
                        }
                        ambiguous = ties.count != 1
                        selected = largest
                        break
                    }
                    parent = root.superview
                }
                var facts = FoundationHomeNativeScrollSnapshot.facts(
                    selected,
                    identityConsistent: previousScroll == nil || previousScroll === selected)
                facts["ambiguousNativeScroll"] = ambiguous ? 1 : 0
                previousScroll = selected
                if let scroll = selected {
                    let end = max(
                        -scroll.adjustedContentInset.top,
                        scroll.contentSize.height - scroll.bounds.height
                            + scroll.adjustedContentInset.bottom)
                    let pixel = 1 / max(1, traitCollection.displayScale)
                    facts["nativeDisplayScale"] = Double(traitCollection.displayScale)
                    facts["nativeAtEnd"] = abs(scroll.contentOffset.y - end) <= pixel ? 1 : 0
                    if let list = scroll as? UICollectionView {
                        var count = 0
                        var extraHeight: CGFloat = 0
                        var missingAttributes = 0
                        for section in 0..<list.numberOfSections {
                            for item in 0..<list.numberOfItems(inSection: section) {
                                if let frame = list.layoutAttributesForItem(
                                    at: IndexPath(item: item, section: section))?.frame
                                {
                                    if count >= naturalRows, naturalRows >= 0 {
                                        extraHeight += frame.height
                                    }
                                    facts["lastCellHeight"] = Double(frame.height)
                                } else {
                                    missingAttributes += 1
                                }
                                count += 1
                            }
                        }
                        facts["nativeListItems"] = Double(count)
                        facts["missingListLayoutAttributes"] = Double(missingAttributes)
                        if naturalRows >= 0 { facts["extraRowsHeight"] = Double(extraHeight) }
                        facts["nativeListKind"] = 1
                        if naturalRows >= 0, count == naturalRows + 1,
                            let section = (0..<list.numberOfSections).last(where: {
                                list.numberOfItems(inSection: $0) > 0
                            }),
                            let cell = list.cellForItem(
                                at: IndexPath(
                                    item: list.numberOfItems(inSection: section) - 1,
                                    section: section)),
                            cell.window === window
                        {
                            facts["nativeFooterHeight"] = Double(cell.bounds.height)
                            facts["nativeFooterY"] = Double(
                                cell.convert(cell.bounds, to: window).minY)
                        }
                    } else if let list = scroll as? UITableView {
                        var count = 0
                        var extraHeight: CGFloat = 0
                        for section in 0..<list.numberOfSections {
                            for row in 0..<list.numberOfRows(inSection: section) {
                                let frame = list.rectForRow(
                                    at: IndexPath(row: row, section: section))
                                if count >= naturalRows, naturalRows >= 0 {
                                    extraHeight += frame.height
                                }
                                facts["lastCellHeight"] = Double(frame.height)
                                count += 1
                            }
                        }
                        facts["nativeListItems"] = Double(count)
                        if naturalRows >= 0 { facts["extraRowsHeight"] = Double(extraHeight) }
                        facts["nativeListKind"] = 2
                        facts["missingListLayoutAttributes"] = 0
                        if naturalRows >= 0, count == naturalRows + 1,
                            let section = (0..<list.numberOfSections).last(where: {
                                list.numberOfRows(inSection: $0) > 0
                            }),
                            let cell = list.cellForRow(
                                at: IndexPath(
                                    row: list.numberOfRows(inSection: section) - 1, section: section
                                )),
                            cell.window === window
                        {
                            facts["nativeFooterHeight"] = Double(cell.bounds.height)
                            facts["nativeFooterY"] = Double(
                                cell.convert(cell.bounds, to: window).minY)
                        }
                    }
                }
                var queue: [UIView] = [window]
                var visited = 0
                while !queue.isEmpty, visited < 4096 {
                    let view = queue.removeLast()
                    visited += 1
                    if let bar = view as? UITabBar,
                        let home = bar.items?.first(where: { $0.title == "Home" })
                    {
                        facts["homeIconWidth"] = Double(home.image?.size.width ?? 0)
                        facts["homeIconHeight"] = Double(home.image?.size.height ?? 0)
                        break
                    }
                    queue.append(contentsOf: view.subviews)
                }
                guard facts != last else { return }
                last = facts
                let captured = facts
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    receive(captured)
                }
            }
        }
    }

    struct FoundationRemoteListeningShelfUIProbe: ViewModifier {
        let isFavorites: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if FoundationDownloadsTestHarness.enabled, isFavorites,
                ProcessInfo.processInfo.arguments.contains("-fixtureRemoteListening")
            {
                content.accessibilityIdentifier("fixture-favorites-carousel")
            } else {
                content
            }
        }
    }
#endif
