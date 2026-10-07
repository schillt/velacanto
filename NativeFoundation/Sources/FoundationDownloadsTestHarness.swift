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

        private var usesAccessibilitySizedText: Bool {
            ProcessInfo.processInfo.environment["FOUNDATION_UI_LARGE_TEXT"] == "1"
        }

        private var productionShell: Bool {
            ProcessInfo.processInfo.arguments.contains("-fixtureProductionShell")
        }

        var body: some View {
            VStack(spacing: 0) {
                fixtureControls
                if fixture.canonicalReady { Text("Canonical fixture ready").font(.caption) }
                if fixture.membershipReady { Text("Membership fixture ready").font(.caption) }
                content
            }
            .task {
                await fixture.prepareCanonicalCollections()
                await fixture.prepareMembershipCollections()
            }
            .foundationDownloadRemovalPresentation()
            .environmentObject(fixture.downloads)
            .environmentObject(fixture.preferences)
            .environmentObject(fixture.connectivity)
            .environmentObject(fixture.actions)
            .environmentObject(fixture.artwork)
            .environmentObject(playlistChanges)
            .environment(
                \.dynamicTypeSize,
                usesAccessibilitySizedText ? .accessibility3 : systemDynamicTypeSize)
        }

        @ViewBuilder private var content: some View {
            if productionShell {
                FoundationLibraryView(library: fixture.library, player: fixture.player, signOut: {})
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

        @State private var artworkCounts = ""
        private var fixtureControls: some View {
            VStack {
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
                    playlist: fixture.playlist, productionShell: productionShell)
            }
        }
    }

    /// Observe policy and connectivity owners directly so synthetic toggles follow external updates.
    private struct FoundationDownloadUIControls: View {
        @ObservedObject var downloads: FoundationDownloads
        @ObservedObject var connectivity: FoundationConnectivity
        let playlist: FoundationItem
        let productionShell: Bool
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        var body: some View {
            VStack {
                Text("Synthetic fixture controls").font(.caption)
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
                if downloads.owners.contains(where: { $0.state == .ready }),
                    !downloads.downloadedSongs.isEmpty
                {
                    Text("Fixture download ready").font(.caption)
                }
                if let owner = downloads.owners.first(where: { $0.state != .ready }) {
                    Text(owner.status).font(.caption)
                    if owner.state == .downloading {
                        ProgressView()
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Fixture transfer in progress")
                            .accessibilityIdentifier("fixture-download-progress")
                    }
                }
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
                Toggle(
                    "Use Cellular Data",
                    isOn: Binding(
                        get: { downloads.allowsCellular },
                        set: { downloads.setAllowsCellular($0) }))
            }.padding().background(.regularMaterial)
                // Synthetic controls must not consume the landscape app viewport. Production
                // content still receives accessibility3 from the enclosing harness environment.
                .dynamicTypeSize(.medium)
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

    @MainActor
    private final class FoundationDownloadUIFixture: ObservableObject {
        @Published private(set) var canonicalReady = false
        @Published private(set) var membershipReady = false
        let downloads: FoundationDownloads
        let player: FoundationPlayer
        let library: FoundationDownloadUILibrary
        let actions = FoundationLibraryActions(
            sourceScope: "synthetic-ui", read: { _ in nil }, write: { _, _ in },
            mutateFavorite: { _, _ in })
        let artwork: FoundationCurrentArtwork
        let preferences = FoundationPlaybackPreferences(
            defaults: UserDefaults(
                suiteName: "FoundationDownloadUIFixture."
                    + ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"]!)!)
        let connectivity = FoundationConnectivity(
            monitorConnectivity: false, settleDuration: .zero, retry: {})
        let playlist = FoundationItem(
            id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic", kind: .playlist,
            duration: nil)

        init() {
            let root = FoundationDownloadsTestHarness.storageRoot
            let library = FoundationDownloadUILibrary()
            self.library = library
            let transfer = FoundationDownloadUITransfer(
                failOnce: ProcessInfo.processInfo.arguments.contains("-fixtureFailOnce"))
            let downloads = FoundationDownloads(
                scope: "synthetic-ui", library: library, root: root,
                transfer: { _, destination, _, progress in
                    try await transfer.write(to: destination, progress: progress)
                }, monitorConnectivity: false)
            self.downloads = downloads
            self.player = FoundationPlayer(
                library: library, resolveResource: { try await downloads.playbackResource(for: $0) }
            )
            self.artwork = FoundationCurrentArtwork(player: player) { item in
                await downloads.retainedArtwork(for: item)
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
                kind: .track, duration: 30)
            if state != "full" { downloads.removeTrack(missing) }
            if state == "none" {
                downloads.removeTrack(
                    FoundationItem(
                        id: "tone", title: "Fixture Tone", subtitle: "", kind: .track,
                        duration: 30))
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
            .init(
                items: (usesCache
                    || ProcessInfo.processInfo.arguments.contains("-fixtureMembership"))
                    ? [
                        FoundationItem(
                            id: "artist", title: "Fixture Artist", subtitle: "", kind: .artist,
                            duration: nil, primaryImageTag: "synthetic")
                    ] : [], nextStartIndex: nil)
        }
        func genres(startIndex: Int) async throws -> FoundationPage {
            .init(
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
            kind: .track, duration: 30, isFavorite: false,
            album: .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic"),
            artist: .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"))
        private var orderedTracks: [FoundationItem] {
            canonical ? [track, missing, track] : [track, track]
        }
        func songs(startIndex: Int) async throws -> FoundationPage {
            .init(items: canonical ? [track, missing] : [track], nextStartIndex: nil)
        }
        func search(query: String, kind: FoundationItem.Kind, startIndex: Int, limit: Int)
            async throws -> FoundationPage
        {
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
            .init(
                items: [
                    .init(
                        id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic",
                        kind: .playlist, duration: nil,
                        primaryImageTag: usesCache ? "synthetic" : nil, isFavorite: false)
                ], nextStartIndex: nil)
        }
        func playlistTracks(playlistID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: orderedTracks, nextStartIndex: nil)
        }

        private let track = FoundationItem(
            id: "tone", title: "Fixture Tone", subtitle: "Generated silent PCM", kind: .track,
            duration: 30, isFavorite: false,
            album: .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic"),
            artist: .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"))
        private let album = FoundationItem(
            id: "album", title: "Fixture Album", subtitle: "Synthetic Artist", kind: .album,
            duration: 30, primaryImageTag: "synthetic", isFavorite: false,
            artist: .init(id: "artist", title: "Fixture Artist", primaryImageTag: "synthetic"),
            genres: ProcessInfo.processInfo.arguments.contains("-fixtureArtworkCache")
                ? [.init(id: "genre", title: "Fixture Genre", primaryImageTag: "synthetic")] : [])
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [album], nextStartIndex: nil)
        }
        func albums(artistID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: [album], nextStartIndex: nil)
        }
        func tracks(artistID: String, startIndex: Int) async throws -> FoundationPage {
            .init(items: canonical ? [track, missing] : [track], nextStartIndex: nil)
        }
        func recentAlbums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [album], nextStartIndex: nil)
        }
        func recentTracks(startIndex: Int) async throws -> FoundationPage {
            .init(items: [track], nextStartIndex: nil)
        }
        func recentlyPlayed(startIndex: Int) async throws -> FoundationPage {
            .init(items: [track], nextStartIndex: nil)
        }
        func favoriteAlbums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func homeGenres() async throws -> FoundationPage {
            try await genres(startIndex: 0)
        }
        func searchGenres() async throws -> FoundationPage {
            try await genres(startIndex: 0)
        }
        func artwork(for item: FoundationItem) async throws -> Data? {
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
            .init(items: canonical ? orderedTracks : [track], nextStartIndex: nil)
        }
        func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
            .init(name: "Fixture Playlist", canEdit: false, canDelete: false)
        }
        func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
            .init(
                entries: orderedTracks.enumerated().map {
                    .init(
                        id: "occurrence-\($0.offset)", mutationID: "occurrence-\($0.offset)",
                        item: $0.element)
                }, nextStartIndex: nil)
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
            // Valid 30-second mono PCM silence; no external audio or account data.
            let bytes: UInt32 = 22_050 * 30 * 2
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
#endif
