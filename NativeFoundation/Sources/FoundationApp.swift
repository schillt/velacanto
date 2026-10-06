import Combine
import CryptoKit
import NowPlaying
import SwiftUI

@MainActor
enum FoundationSignInPolicy {
    static func authenticate(
        clearPins: () -> Bool, clearPlaybackSessions: () -> Bool = { true },
        clearDownloads: () -> Bool = { true },
        signIn: @MainActor () async throws -> FoundationSession
    ) async throws -> FoundationSession {
        guard clearPins() else { throw FoundationPinStorageError.couldNotRemovePins }
        guard clearPlaybackSessions() else {
            throw FoundationPlaybackSessionStore.StorageError.cleanupFailed
        }
        guard clearDownloads() else { throw FoundationDownloadAccountError.cleanupFailed }
        return try await signIn()
    }
}

enum FoundationDownloadAccountError: LocalizedError {
    case cleanupFailed
    var errorDescription: String? { "Downloaded music could not be removed from this device." }
}

@MainActor
enum FoundationSignOutPolicy {
    static func begin(
        startRevocation: () -> Task<Bool, Never>, clear: () throws -> Void,
        clearPins: () -> Bool
    ) -> (localCleared: Bool, pinsCleared: Bool, revocation: Task<Bool, Never>) {
        let revocation = startRevocation()
        let localCleared: Bool
        do {
            try clear()
            localCleared = true
        } catch {
            localCleared = false
        }
        // Keep storage in sync with the still-active account if Keychain removal fails.
        guard localCleared else { return (false, false, revocation) }
        // Pin cleanup is independent of the server result.
        return (true, clearPins(), revocation)
    }
}

@main
struct VelacantoFoundationApp: App {
    @StateObject private var model = FoundationAppModel()

    var body: some Scene {
        WindowGroup {
            #if DEBUG && os(iOS) && targetEnvironment(simulator)
                if FoundationDownloadsTestHarness.enabled {
                    if ProcessInfo.processInfo.arguments.contains("-fixtureCleanup") {
                        FoundationDownloadsTestCleanup()
                    } else {
                        FoundationDownloadsTestHarness()
                    }
                } else {
                    FoundationRootView(model: model)
                        .frame(minWidth: 320, minHeight: 480)
                }
            #else
                FoundationRootView(model: model)
                    .frame(minWidth: 320, minHeight: 480)
            #endif
        }
    }
}

@MainActor
final class FoundationAppModel: ObservableObject {
    @Published private(set) var library: FoundationJellyfinLibrary?
    @Published private(set) var player: FoundationPlayer?
    @Published private(set) var actions: FoundationLibraryActions?
    @Published private(set) var currentArtwork: FoundationCurrentArtwork?
    @Published private(set) var downloads: FoundationDownloads?
    @Published private(set) var isCleaningDownloads = false
    @Published var credentialError: String?
    @Published var signOutNotice: String?
    private var playbackSessionSubscription: AnyCancellable?
    private var restored = false
    private var accountEpoch = 0
    private var nowPlaying: FoundationNowPlaying?
    private var mediaSession: MediaSession<FoundationNowPlaying>?

    isolated deinit {
        downloads?.invalidate()
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
    }

    func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("-foundationTesting") else { return }
        #endif
        var credentialReadCompleted = false
        do {
            let savedSession = try FoundationCredentials.load()
            credentialReadCompleted = true
            if let session = savedSession {
                let scope = Self.sourceScope(for: session)
                if !FoundationPinStorage.removeStoredPins(retaining: scope) {
                    credentialError = "Older saved pins could not be removed from this device."
                }
                if !FoundationPlaybackSessionStore.clear(retaining: scope) {
                    credentialError =
                        "Older playback sessions could not be removed from this device."
                }
                if !FoundationDownloads.clearStoredDownloads(retaining: scope) {
                    credentialError =
                        "Older downloaded music could not be removed from this device."
                }
                open(session, sourceScope: scope)
            } else if !FoundationPinStorage.removeStoredPins() {
                credentialError = "Saved pins could not be removed from this device."
            }
        } catch {
            credentialError = "Saved sign-in could not be read. Please sign in again."
            if !FoundationPinStorage.removeStoredPins() {
                credentialError =
                    "Saved sign-in could not be read. Please sign in again. "
                    + "Saved pins could not be removed from this device."
            }
        }
        if library == nil, !FoundationPlaybackSessionStore.clear() {
            credentialError = "Saved playback sessions could not be removed from this device."
        }
        if credentialReadCompleted, library == nil, !FoundationDownloads.clearStoredDownloads() {
            credentialError = FoundationDownloadAccountError.cleanupFailed.errorDescription
        }
        #if DEBUG
            FoundationJournal.shared.record("app phase=opened")
        #endif
    }

    fileprivate func accept(_ session: FoundationSession) throws {
        try FoundationCredentials.save(session)
        open(session, sourceScope: Self.sourceScope(for: session))
    }

    private static func sourceScope(for session: FoundationSession) -> String {
        // Persist only a digest of source/account identity, never the server or credentials.
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func open(_ session: FoundationSession, sourceScope: String) {
        playbackSessionSubscription = nil
        accountEpoch += 1
        signOutNotice = nil
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
        currentArtwork = nil
        mediaSession = nil
        nowPlaying = nil
        actions?.invalidate()
        player?.stop()
        downloads?.invalidate()
        let library = FoundationJellyfinLibrary(session: session)
        self.actions = FoundationLibraryActions(sourceScope: sourceScope) { item, favorite in
            try await library.setFavorite(for: item, isFavorite: favorite)
        }
        self.library = library
        let downloads = FoundationDownloads(scope: sourceScope, library: library)
        self.downloads = downloads
        self.player = FoundationPlayer(
            library: library, resolveResource: { try await downloads.playbackResource(for: $0) })
        if let player = self.player {
            let store = FoundationPlaybackSessionStore(scope: sourceScope)
            do {
                if let snapshot = try store.load() { player.restoreSession(snapshot) }
            } catch {
                credentialError = "Saved playback session could not be read on this device."
            }
            playbackSessionSubscription = player.sessionChanged.sink { [weak self, weak player] in
                guard let self, let player else { return }
                if !store.save(FoundationPlaybackSnapshot(player: player)) {
                    self.credentialError = "Playback session could not be saved on this device."
                }
            }
            let artwork = FoundationCurrentArtwork(player: player) { item in
                try await library.artwork(for: item, size: 640)
            }
            self.currentArtwork = artwork
            let bridge = FoundationNowPlaying(player: player, artwork: artwork)
            let mediaSession = MediaSession(bridge)
            self.nowPlaying = bridge
            self.mediaSession = mediaSession
            bridge.attach(mediaSession)
        }
    }

    func signOut() {
        guard let session = library?.session else { return }
        player?.stop()
        let epoch = accountEpoch
        let attempt = FoundationSignOutPolicy.begin {
            // Keep the captured session until this bounded attempt completes.
            Task.detached(priority: .userInitiated) {
                let adapter = FoundationJellyfinLibrary(
                    session: session, load: FoundationJellyfinLibrary.signOutLoad)
                do {
                    try await adapter.endSession()
                    return true
                } catch {
                    return false
                }
            }
        } clear: {
            try FoundationCredentials.clear()
        } clearPins: {
            FoundationPinStorage.removeStoredPins()
        }
        guard attempt.localCleared else {
            credentialError =
                "Sign-out failed here. Saved pins remain on this device. "
                + "Jellyfin may have ended the session."
            return
        }
        let retiringDownloads = downloads
        retiringDownloads?.invalidate()
        downloads = nil
        isCleaningDownloads = true
        playbackSessionSubscription = nil
        let playbackSessionsCleared = FoundationPlaybackSessionStore.clear()
        actions?.invalidate()
        actions = nil
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
        currentArtwork = nil
        mediaSession = nil
        nowPlaying = nil
        player = nil
        library = nil
        credentialError = nil
        Task { [weak self] in
            let downloadsCleared: Bool
            if let retiringDownloads {
                downloadsCleared = await retiringDownloads.clearAccount(waitForPlayback: true)
            } else {
                downloadsCleared = FoundationDownloads.clearStoredDownloads()
            }
            guard let self, self.accountEpoch == epoch else { return }
            self.isCleaningDownloads = false
            if !downloadsCleared {
                self.credentialError = FoundationDownloadAccountError.cleanupFailed.errorDescription
            }
            let serverAccepted = await attempt.revocation.value
            guard self.accountEpoch == epoch, self.library == nil else { return }
            let pinResult: String
            if attempt.pinsCleared {
                pinResult = "Saved pins were removed from this device."
            } else {
                pinResult = "Saved pins could not be removed from this device."
            }
            let sessionResult =
                playbackSessionsCleared
                ? "Saved playback sessions were removed."
                : "Saved playback sessions could not be removed from this device."
            let downloadResult =
                downloadsCleared
                ? "Downloaded music was removed."
                : "Downloaded music could not be removed from this device."
            if serverAccepted {
                self.signOutNotice =
                    "Signed out here. \(pinResult) \(sessionResult) \(downloadResult) "
                    + "Jellyfin accepted the sign-out request."
            } else {
                self.signOutNotice =
                    "Signed out here. \(pinResult) \(sessionResult) \(downloadResult) "
                    + "Jellyfin sign-out could not be confirmed."
            }
        }
    }

    func dismissAccountAlertAfterUpdate() {
        let dismissedError = credentialError
        let dismissedNotice = signOutNotice
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let dismissedError, self.credentialError == dismissedError {
                self.credentialError = nil
            }
            if let dismissedNotice, self.signOutNotice == dismissedNotice {
                self.signOutNotice = nil
            }
        }
    }
}

struct FoundationRootView: View {
    @ObservedObject var model: FoundationAppModel
    @Environment(\.scenePhase) private var scenePhase

    var accountAlertPresented: Binding<Bool> {
        Binding(
            get: { model.credentialError != nil || model.signOutNotice != nil },
            set: { if !$0 { model.dismissAccountAlertAfterUpdate() } }
        )
    }

    var body: some View {
        Group {
            if let library = model.library, let player = model.player, let actions = model.actions,
                let artwork = model.currentArtwork, let downloads = model.downloads
            {
                FoundationLibraryView(library: library, player: player, signOut: model.signOut)
                    .environmentObject(actions)
                    .environmentObject(artwork)
                    .environmentObject(downloads)
                    .id(ObjectIdentifier(actions))
            } else if model.isCleaningDownloads {
                ProgressView("Removing downloaded music…")
            } else {
                FoundationSignInView(model: model)
            }
        }
        .task { model.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.downloads?.reconcilePlaylists() }
        }
        .alert(
            model.signOutNotice == nil ? "Account" : "Sign-out",
            isPresented: accountAlertPresented
        ) {
            Button("OK") { model.dismissAccountAlertAfterUpdate() }
        } message: {
            Text(model.credentialError ?? model.signOutNotice ?? "")
        }
    }
}

private struct FoundationSignInView: View {
    @ObservedObject var model: FoundationAppModel
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var attempt = 0
    @State private var signingIn = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("A simple player for your music library.")
                    TextField("Jellyfin HTTPS address", text: $address)
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        #endif
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                    Button(signingIn ? "Signing in…" : "Sign in") {
                        signingIn = true
                        attempt += 1
                    }
                    .disabled(signingIn || address.isEmpty || username.isEmpty)
                    if signingIn {
                        Button("Cancel") {
                            signingIn = false
                            attempt += 1
                        }
                    }
                } footer: {
                    Text(
                        "Use your server’s trusted HTTPS address. Credentials are stored in Keychain."
                    )
                }
            }
            .navigationTitle("Velacanto Foundation")
            .task(id: attempt) {
                guard signingIn else { return }
                let owner = attempt
                errorMessage = nil
                do {
                    guard
                        let url = URL(
                            string: address.trimmingCharacters(in: .whitespacesAndNewlines))
                    else { throw URLError(.badURL) }
                    let session = try await FoundationSignInPolicy.authenticate {
                        FoundationPinStorage.removeStoredPins()
                    } clearPlaybackSessions: {
                        FoundationPlaybackSessionStore.clear()
                    } clearDownloads: {
                        FoundationDownloads.clearStoredDownloads()
                    } signIn: {
                        try await FoundationJellyfinLibrary.signIn(
                            serverURL: url, username: username, password: password)
                    }
                    try Task.checkCancellation()
                    guard signingIn, attempt == owner else { return }
                    try model.accept(session)
                    password = ""
                    signingIn = false
                } catch {
                    guard !Task.isCancelled, signingIn, attempt == owner else { return }
                    signingIn = false
                    if let downloadError = error as? FoundationDownloadAccountError {
                        errorMessage = downloadError.errorDescription
                    } else if let pinError = error as? FoundationPinStorageError {
                        errorMessage = pinError.errorDescription
                    } else if let storageError = error
                        as? FoundationPlaybackSessionStore.StorageError
                    {
                        errorMessage = storageError.errorDescription
                    } else {
                        errorMessage = FoundationLibraryError.category(error).errorDescription
                    }
                }
            }
        }
    }
}

/// Persistent personal metadata belongs in protected, backup-excluded account files.
@MainActor
struct FoundationPlaybackSessionStore {
    enum StorageError: LocalizedError {
        case cleanupFailed, invalidSnapshot
        var errorDescription: String? {
            switch self {
            case .cleanupFailed: "Saved playback sessions could not be removed from this device."
            case .invalidSnapshot: "Saved playback session could not be read on this device."
            }
        }
    }
    let scope: String
    var root: URL = Self.defaultRoot
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Velacanto/PlaybackSessions", isDirectory: true)
    }
    var directory: URL { root.appendingPathComponent(scope, isDirectory: true) }
    var file: URL { directory.appendingPathComponent("session-v1.json") }

    func load() throws -> FoundationPlaybackSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let value = try JSONDecoder().decode(
            FoundationPlaybackSnapshot.self, from: Data(contentsOf: file))
        guard value.isValid else { throw StorageError.invalidSnapshot }
        return value
    }

    func save(_ snapshot: FoundationPlaybackSnapshot) -> Bool {
        guard snapshot.isValid else { return false }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Self.protect(root)
            try Self.protect(directory)
            let data = try JSONEncoder().encode(snapshot)
            #if os(iOS)
                try data.write(
                    to: file,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
                try data.write(to: file, options: .atomic)
            #endif
            try Self.protect(file)
            return true
        } catch { return false }
    }

    private static func protect(_ url: URL) throws {
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: url.hasDirectoryPath ? 0o700 : 0o600
            ], ofItemAtPath: url.path)
        #if os(iOS)
            try FileManager.default.setAttributes(
                [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ], ofItemAtPath: url.path)
        #endif
    }

    static func clear(retaining scope: String? = nil, root: URL = defaultRoot) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return true }
        do {
            let directories = try manager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
            for directory in directories where directory.lastPathComponent != scope {
                try manager.removeItem(at: directory)
            }
            return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .allSatisfy { $0.lastPathComponent == scope }
        } catch { return false }
    }
}
