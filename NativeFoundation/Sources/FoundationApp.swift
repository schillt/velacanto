import CryptoKit
import SwiftUI

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
    @Published var credentialError: String?
    private var restored = false

    func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("-foundationTesting") else { return }
        #endif
        do {
            if let session = try FoundationCredentials.load() { open(session) }
        } catch {
            credentialError = "Saved sign-in could not be read. Please sign in again."
        }
        #if DEBUG
            FoundationJournal.shared.record("app phase=opened")
        #endif
    }

    func accept(_ session: FoundationSession) throws {
        try FoundationCredentials.save(session)
        open(session)
    }

    private func open(_ session: FoundationSession) {
        actions?.invalidate()
        player?.stop()
        let library = FoundationJellyfinLibrary(session: session)
        // Persist only a digest of source/account identity, never the server or credentials.
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        let scope = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        self.actions = FoundationLibraryActions(sourceScope: scope) { item, favorite in
            try await library.setFavorite(for: item, isFavorite: favorite)
        }
        self.library = library
        self.player = FoundationPlayer(library: library)
    }

    func signOut() {
        player?.stop()
        do {
            try FoundationCredentials.clear()
            actions?.invalidate()
            actions = nil
            player = nil
            library = nil
            credentialError = nil
        } catch {
            credentialError = "Saved sign-in could not be removed. Please try again."
        }
    }
}

struct FoundationRootView: View {
    @ObservedObject var model: FoundationAppModel

    var body: some View {
        Group {
            if let library = model.library, let player = model.player, let actions = model.actions {
                FoundationLibraryView(library: library, player: player, signOut: model.signOut)
                    .environmentObject(actions)
                    .id(ObjectIdentifier(actions))
            } else {
                FoundationSignInView(model: model)
            }
        }
        .task { model.restore() }
        .alert(
            "Sign-in",
            isPresented: Binding(
                get: { model.credentialError != nil },
                set: { if !$0 { model.credentialError = nil } }
            )
        ) {
            Button("OK") { model.credentialError = nil }
        } message: {
            Text(model.credentialError ?? "")
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
                    let session = try await FoundationJellyfinLibrary.signIn(
                        serverURL: url, username: username, password: password)
                    try Task.checkCancellation()
                    guard signingIn, attempt == owner else { return }
                    try model.accept(session)
                    password = ""
                    signingIn = false
                } catch {
                    guard !Task.isCancelled, signingIn, attempt == owner else { return }
                    signingIn = false
                    errorMessage = FoundationLibraryError.category(error).errorDescription
                }
            }
        }
    }
}
