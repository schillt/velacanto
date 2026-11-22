#if FOUNDATION_ISOLATED_TEST_HOST && os(macOS)
    import Foundation
    import Security
    import SwiftUI

    /// A real app Scene for the external Mac UI test, never part of the normal app target.
    struct FoundationIsolatedLyricsRetirementScene: View {
        @StateObject private var owner = FoundationIsolatedLyricsRetirementOwner()

        var body: some View {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(owner.phase).accessibilityIdentifier("root-retirement-phase")
                    Text(owner.facts).accessibilityIdentifier("root-retirement-facts")
                    HStack {
                        Button("Sign out fixture") { owner.signOut() }
                            .accessibilityIdentifier("root-retirement-signout")
                        Button("Release held reply") { owner.releaseReply() }
                            .accessibilityIdentifier("root-retirement-release")
                        Button("Inspect retirement") { owner.inspectRetirement() }
                            .accessibilityIdentifier("root-retirement-inspect")
                        Button("Clean fixture") { owner.clean() }
                            .accessibilityIdentifier("root-retirement-clean")
                        Button("Abort fixture") { owner.abort() }
                            .accessibilityIdentifier("root-retirement-abort")
                    }
                }
                .font(.caption).padding(8)
                Divider()
                if let model = owner.model {
                    FoundationRootView(model: model)
                        .onChange(of: model.library == nil && model.player == nil) { _, _ in
                            owner.observeRoot()
                        }
                } else {
                    ProgressView("Preparing isolated root")
                }
            }
            .frame(minWidth: 1200, minHeight: 860)
            .task { await owner.start() }
        }
    }

    private actor FoundationIsolatedLyricsReply {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false

        func hold() async {
            guard !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class FoundationIsolatedLyricsRetirementOwner: ObservableObject {
        @Published private(set) var model: FoundationAppModel?
        @Published private(set) var phase = "preparing"
        @Published private(set) var facts = "not-ready"
        private let reply = FoundationIsolatedLyricsReply()
        private let revocation = FoundationIsolatedLyricsReply()
        private var root: URL?
        private var suite = ""
        private var defaults: UserDefaults?
        private var tasks: [Task<Void, Never>] = []
        private var revocations: [Task<Bool, Never>] = []
        private var retiredLibrary: FoundationJellyfinLibrary?
        private var retiredPlayer: FoundationPlayer?
        private var occurrenceID: UUID?
        private var sentinels: [URL] = []
        private var pinKey = ""
        private let bytes = Data("unrelated account must survive root retirement".utf8)
        private var entered = 0
        private var signoutInvoked = false
        private var cancelled = false
        private var returned = false
        private var held = false
        private var started = false
        private var inspection: Task<Void, Never>?

        func start() async {
            guard !started else { return }
            started = true
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "VelaCanto-RootLyrics-" + UUID().uuidString, isDirectory: true)
                self.root = root
                suite = "VelaCanto.Isolation.RootLyrics." + UUID().uuidString
                guard let defaults = UserDefaults(suiteName: suite) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                self.defaults = defaults
                let storage = FoundationScopedAccountStorage(root: root, defaults: defaults)
                defaults.set(
                    "data-protection-ready", forKey: FoundationAppModel.credentialBackendKey)
                let gate = reply
                let revocation = revocation
                let credentials = FoundationCredentials.Operations(
                    update: { _, _ in errSecSuccess }, add: { _ in errSecSuccess },
                    copy: { _ in (errSecItemNotFound, nil) }, delete: { _ in errSecSuccess })
                let isolation = FoundationAppRuntimeIsolation(
                    storage: storage, credentials: credentials,
                    load: { [weak self] request in
                        guard request.url?.path.hasSuffix("/Lyrics") == true else {
                            throw URLError(.notConnectedToInternet)
                        }
                        await self?.providerEntered()
                        await withTaskCancellationHandler {
                            // The provider deliberately ignores cancellation until released.
                            await gate.hold()
                        } onCancel: {
                            Task { @MainActor [weak self] in self?.providerCancelled() }
                        }
                        await self?.providerReturned()
                        return (
                            Data(
                                "{\"Lyrics\":[{\"Text\":\"Retired account lyrics must never appear\"}]}"
                                    .utf8),
                            HTTPURLResponse(
                                url: request.url!, statusCode: 200, httpVersion: nil,
                                headerFields: nil)!
                        )
                    },
                    revoke: { _ in
                        Task {
                            await revocation.hold()
                            return false
                        }
                    },
                    diagnostic: { _ in },
                    taskStarted: { [weak self] in self?.tasks.append($0) },
                    revocationStarted: { [weak self] in self?.revocations.append($0) })
                let model = FoundationAppModel(
                    restoreAccount: { $0.restoreCredentials() }, isolation: isolation)
                _ = await model.ensureReady()
                let accept = try await model.prepareSignIn {
                    FoundationSession(
                        serverURL: URL(string: "https://synthetic.invalid")!,
                        accessToken: "synthetic",
                        userID: "00000000000000000000000000000001",
                        deviceID: "00000000-0000-0000-0000-000000000002")
                }
                try await accept()
                for task in tasks {
                    guard await join(task) else {
                        phase = "startup-timeout"
                        return
                    }
                }
                guard let library = model.library, let player = model.player else {
                    throw CocoaError(.coderInvalidValue)
                }
                retiredLibrary = library
                retiredPlayer = player
                let track = FoundationItem(
                    id: "00000000000000000000000000000003", title: "Synthetic lyrics track",
                    subtitle: "", kind: .track, duration: nil)
                let occurrence = FoundationQueueEntry(item: track)
                occurrenceID = occurrence.id
                player.restoreSession(
                    .init(
                        entries: [occurrence], selectedEntryID: occurrence.id,
                        shuffleEnabled: false, repeatMode: .off))
                let otherScope = FoundationMusicLibraryStore.digest(
                    "jellyfin\0https://synthetic.invalid\0" + "00000000000000000000000000000002")
                let cacheScope = FoundationArtworkCache.digest(otherScope)
                pinKey = FoundationPinStorage.key(for: otherScope)
                defaults.set(bytes, forKey: pinKey)
                sentinels = [
                    storage.playback.appendingPathComponent(otherScope),
                    storage.selections.appendingPathComponent(otherScope),
                    FoundationDownloadStorage.directory(scope: otherScope, root: storage.downloads),
                    storage.artwork.appendingPathComponent(cacheScope),
                    storage.pages.appendingPathComponent(cacheScope),
                ].map { $0.appendingPathComponent("sentinel") }
                for sentinel in sentinels {
                    try FileManager.default.createDirectory(
                        at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: sentinel)
                }
                self.model = model
                phase = "ready"
                publishFacts()
            } catch {
                phase = "setup-failed"
                facts = String(describing: error)
            }
        }

        private func providerEntered() {
            entered += 1
            held = true
            phase = "provider-entered"
            publishFacts()
        }

        private func providerCancelled() {
            cancelled = true
            phase = "provider-cancelled"
            publishFacts()
        }

        private func providerReturned() {
            returned = true
            held = false
            phase = "provider-returned"
            publishFacts()
        }

        private func publishFacts(permits: Int? = nil) {
            let unchanged = occurrenceID != nil && retiredPlayer?.selectedEntryID == occurrenceID
            let intact =
                !sentinels.isEmpty
                && sentinels.allSatisfy {
                    (try? Data(contentsOf: $0)) == bytes
                } && defaults?.data(forKey: pinKey) == bytes
            let rootGone = model?.library == nil && model?.player == nil
            facts = [
                "requests=\(entered)", "held=\(held)", "cancelled=\(cancelled)",
                "signout-invoked=\(signoutInvoked)",
                "returned=\(returned)", "selection=\(unchanged)", "unrelated=\(intact)",
                "root-gone=\(rootGone)", "permits=\(permits.map(String.init) ?? "unknown")",
                "cleanup-error=\(model?.signOutCleanupError != nil)",
                "cleaning=\(model?.isCleaningDownloads ?? false)",
            ].joined(separator: ";")
        }

        func observeRoot() { publishFacts() }

        func signOut() {
            guard entered == 1, held, !cancelled else { return }
            signoutInvoked = true
            model?.signOut()
            if let task = retiredPlayer?.sessionTask { tasks.append(task) }
            publishFacts()
        }

        func releaseReply() {
            Task { await reply.release() }
        }

        func inspectRetirement() {
            guard inspection == nil else { return }
            inspection = Task {
                defer { inspection = nil }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var permits = await retiredLibrary?.networkAdmission.activeCount ?? -1
                while permits != 0, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                    permits = await retiredLibrary?.networkAdmission.activeCount ?? -1
                }
                await revocation.release()
                for task in tasks {
                    guard await join(task) else {
                        phase = "teardown-timeout"
                        return
                    }
                }
                for task in revocations {
                    let completion = Task { _ = await task.value }
                    guard await join(completion) else {
                        phase = "revocation-timeout"
                        return
                    }
                }
                publishFacts(permits: permits)
                phase = "inspected"
            }
        }

        /// Failure teardown releases both noncooperative gates before any attempted join.
        /// It deliberately retains this fixture's UUID root for private diagnosis.
        func abort() {
            guard phase != "cleaned" else { return }
            Task {
                await reply.release()
                await revocation.release()
            }
            if model?.library != nil { model?.signOut() }
        }

        private func join(_ task: Task<Void, Never>) async -> Bool {
            var completed = false
            let waiter = Task {
                await task.value
                completed = true
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !completed, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Cancelling this observer does not terminate an uncooperative underlying task.
            // A timeout fails the fixture and retains its data; the external runner ends it.
            if !completed { waiter.cancel() }
            return completed
        }

        func clean() {
            guard phase == "inspected", model?.library == nil, model?.player == nil,
                model?.signOutCleanupError == nil, model?.isCleaningDownloads == false,
                returned, cancelled, entered == 1, !held, let root
            else { return }
            Task {
                guard await retiredLibrary?.networkAdmission.activeCount == 0 else { return }
                do {
                    try FileManager.default.removeItem(at: root)
                    defaults?.removePersistentDomain(forName: suite)
                    phase = "cleaned"
                } catch {
                    phase = "cleanup-failed"
                }
            }
        }
    }
#endif
