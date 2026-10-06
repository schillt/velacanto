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

        static var storageRoot: URL {
            let runID = ProcessInfo.processInfo.environment["FOUNDATION_UI_RUN_ID"]!
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("DownloadUITestFixtures", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)
        }

        @StateObject private var fixture = FoundationDownloadUIFixture()
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
                content
            }
            .environmentObject(fixture.downloads)
            .environmentObject(fixture.preferences)
            .environmentObject(fixture.connectivity)
            .environmentObject(fixture.actions)
            .environmentObject(fixture.artwork)
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
                        FoundationDownloadsView(player: fixture.player)
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

        private var fixtureControls: some View {
            FoundationDownloadUIControls(
                downloads: fixture.downloads, connectivity: fixture.connectivity,
                playlist: fixture.playlist, productionShell: productionShell)
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
                    Toggle(
                        "Simulate unavailable network",
                        isOn: Binding(
                            get: { connectivity.localOnly },
                            set: { offline in
                                connectivity.update(
                                    status: offline ? .unavailable : .available,
                                    wifiOrWired: !offline, cellular: false)
                            }))
                }
                Toggle(
                    "Use Cellular Data",
                    isOn: Binding(
                        get: { downloads.allowsCellular },
                        set: { downloads.setAllowsCellular($0) }))
            }.padding().background(.regularMaterial)
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
            downloads.updateConnectivity(isConnected: true, usesWiFi: productionShell)
            connectivity.update(
                status: .available, wifiOrWired: productionShell, cellular: !productionShell)
        }

        isolated deinit {
            artwork.invalidate()
            actions.invalidate()
            connectivity.invalidate()
            downloads.invalidate()
        }
    }

    private actor FoundationDownloadUILibrary: FoundationLibrary {
        private let track = FoundationItem(
            id: "tone", title: "Fixture Tone", subtitle: "Generated silent PCM", kind: .track,
            duration: 30, isFavorite: false,
            album: .init(id: "album", title: "Fixture Album", primaryImageTag: "synthetic"))
        private let album = FoundationItem(
            id: "album", title: "Fixture Album", subtitle: "Synthetic Artist", kind: .album,
            duration: 30, primaryImageTag: "synthetic", isFavorite: false)
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [album], nextStartIndex: nil)
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
            .init(items: [], nextStartIndex: nil)
        }
        func searchGenres() async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
        }
        func artwork(for item: FoundationItem) async throws -> Data? {
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
            .init(items: [track], nextStartIndex: nil)
        }
        func playlistPermissions(id: String) async throws -> FoundationPlaylistPermissions {
            .init(name: "Fixture Playlist", canEdit: false, canDelete: false)
        }
        func playlistEntries(id: String, startIndex: Int) async throws -> FoundationPlaylistPage {
            .init(
                entries: [
                    .init(id: "one", mutationID: "one", item: track),
                    .init(id: "two", mutationID: "two", item: track),
                ], nextStartIndex: nil)
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
            try await Task.sleep(for: .seconds(failOnce ? 5 : 1))
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
