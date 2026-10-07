import CryptoKit
import NowPlaying
import SwiftUI

@MainActor
enum FoundationSignInPolicy {
    static func authenticate(
        clearPins: () -> Bool, signIn: @MainActor () async throws -> FoundationSession
    ) async throws -> FoundationSession {
        guard clearPins() else { throw FoundationPinStorageError.couldNotRemovePins }
        return try await signIn()
    }
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
            FoundationRootView(model: model)
                .frame(minWidth: 320, minHeight: 480)
        }
    }
}

@MainActor
final class FoundationAppModel: ObservableObject {
    @Published private(set) var library: FoundationJellyfinLibrary?
    @Published private(set) var player: FoundationPlayer?
    @Published private(set) var actions: FoundationLibraryActions?
    @Published private(set) var currentArtwork: FoundationCurrentArtwork?
    @Published var credentialError: String?
    @Published var signOutNotice: String?
    private var restored = false
    private var accountEpoch = 0
    private var nowPlaying: FoundationNowPlaying?
    private var mediaSession: MediaSession<FoundationNowPlaying>?

    isolated deinit {
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
    }

    func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("-foundationTesting") else { return }
        #endif
        do {
            if let session = try FoundationCredentials.load() {
                let scope = Self.sourceScope(for: session)
                if !FoundationPinStorage.removeStoredPins(retaining: scope) {
                    credentialError = "Older saved pins could not be removed from this device."
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
        accountEpoch += 1
        signOutNotice = nil
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
        currentArtwork = nil
        mediaSession = nil
        nowPlaying = nil
        actions?.invalidate()
        player?.stop()
        let library = FoundationJellyfinLibrary(session: session)
        self.actions = FoundationLibraryActions(sourceScope: sourceScope) { item, favorite in
            try await library.setFavorite(for: item, isFavorite: favorite)
        }
        self.library = library
        self.player = FoundationPlayer(library: library)
        if let player = self.player {
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
            let serverAccepted = await attempt.revocation.value
            guard let self, self.accountEpoch == epoch, self.library == nil else { return }
            let pinResult: String
            if attempt.pinsCleared {
                pinResult = "Saved pins were removed from this device."
            } else {
                pinResult = "Saved pins could not be removed from this device."
            }
            if serverAccepted {
                self.signOutNotice =
                    "Signed out here. \(pinResult) "
                    + "Jellyfin accepted the sign-out request."
            } else {
                self.signOutNotice =
                    "Signed out here. \(pinResult) "
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

    var accountAlertPresented: Binding<Bool> {
        Binding(
            get: { model.credentialError != nil || model.signOutNotice != nil },
            set: { if !$0 { model.dismissAccountAlertAfterUpdate() } }
        )
    }

    var body: some View {
        Group {
            if let library = model.library, let player = model.player, let actions = model.actions,
                let artwork = model.currentArtwork
            {
                FoundationLibraryView(library: library, player: player, signOut: model.signOut)
                    .environmentObject(actions)
                    .environmentObject(artwork)
                    .id(ObjectIdentifier(actions))
            } else {
                FoundationSignInView(model: model)
            }
        }
        .task { model.restore() }
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
                    if let pinError = error as? FoundationPinStorageError {
                        errorMessage = pinError.errorDescription
                    } else {
                        errorMessage = FoundationLibraryError.category(error).errorDescription
                    }
                }
            }
        }
    }
}
