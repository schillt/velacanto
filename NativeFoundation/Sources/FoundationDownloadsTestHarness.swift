#if DEBUG && os(iOS) && targetEnvironment(simulator)
    import SwiftUI

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

        var body: some View {
            NavigationStack {
                List {
                    Text("Synthetic download UI fixture — no server connection")
                    Button("Queue fixture playlist") {
                        fixture.downloads.download(fixture.playlist)
                    }
                    NavigationLink("On Device") {
                        FoundationDownloadsView(player: fixture.player)
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
            .environmentObject(fixture.downloads)
        }
    }

    /// Production sign-in form with a bounded in-memory authenticator; no Keychain or server.
    struct FoundationAccountUITestHarness: View {
        @State private var signedIn = false
        @State private var failedOnce = false
        @State private var notice: String?

        var body: some View {
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
                    FoundationSignInView { url, username, password in
                        guard url.host == "example.invalid", username == "synthetic-ui",
                            password == "synthetic-not-a-password"
                        else { throw FoundationLibraryError.authentication }
                        let delayed = ProcessInfo.processInfo.arguments.contains(
                            "-fixtureDelayedAuth")
                        if delayed {
                            // Return a successful response even after cancellation to exercise the form guard.
                            try? await Task.sleep(for: .seconds(3))
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
        let playlist = FoundationItem(
            id: "playlist", title: "Fixture Playlist", subtitle: "Synthetic", kind: .playlist,
            duration: nil)

        init() {
            let root = FoundationDownloadsTestHarness.storageRoot
            let library = FoundationDownloadUILibrary()
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
            // Start on synthetic cellular; the production toggle governs transfer permission.
            downloads.updateConnectivity(isConnected: true, usesWiFi: false)
        }

        isolated deinit { downloads.invalidate() }
    }

    private actor FoundationDownloadUILibrary: FoundationLibrary {
        private let track = FoundationItem(
            id: "tone", title: "Fixture Tone", subtitle: "Generated silent PCM", kind: .track,
            duration: 30)
        func albums(startIndex: Int) async throws -> FoundationPage {
            .init(items: [], nextStartIndex: nil)
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
