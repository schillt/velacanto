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
        #if DEBUG
            self.player = FoundationPlayer(resolve: { item in
                if let url = try FoundationDiagnosticTones.resolve(item) { return url }
                return try await library.playbackURL(for: item)
            })
        #else
            self.player = FoundationPlayer(library: library)
        #endif
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

#if DEBUG
    /// Three bounded local signals exercise the normal queue without contacting the provider.
    enum FoundationDiagnosticTones {
        static let sampleRate = 22_050
        static let duration = 8.0
        static let items = (0..<3).map { index in
            FoundationItem(
                id: "foundation-diagnostic-tone-\(index)", title: "Diagnostic tone \(index + 1)",
                subtitle: "Local audio · no streaming", kind: .track, duration: duration)
        }

        /// Resolve only exact synthetic items; all real selections retain the library resolver.
        static func resolve(_ item: FoundationItem) throws -> URL? {
            guard let index = items.firstIndex(of: item) else { return nil }
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("foundation-diagnostic-tones-v1", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("tone-\(index).wav")
            if !FileManager.default.fileExists(atPath: file.path) {
                try wave(index: index).write(to: file, options: .atomic)
            }
            try Task.checkCancellation()
            return file
        }

        /// Mono 16-bit PCM at eight percent peak, with short fades to avoid edge clicks.
        /// Fixed inputs bound all three temporary files to approximately one megabyte total.
        static func wave(index: Int) -> Data {
            precondition((0..<3).contains(index))
            let frames = Int(Double(sampleRate) * duration)
            let bytes = UInt32(frames * 2)
            var data = Data()
            func append<T: FixedWidthInteger>(_ value: T) {
                var littleEndian = value.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(contentsOf: "RIFF".utf8)
            append(bytes + 36)
            data.append(contentsOf: "WAVEfmt ".utf8)
            append(UInt32(16))
            append(UInt16(1))
            append(UInt16(1))
            append(UInt32(sampleRate))
            append(UInt32(sampleRate * 2))
            append(UInt16(2))
            append(UInt16(16))
            data.append(contentsOf: "data".utf8)
            append(bytes)
            let frequency = [330.0, 440.0, 660.0][index]
            for frame in 0..<frames {
                let fade = min(1, Double(min(frame, frames - 1 - frame)) / 441)
                let phase = 2 * Double.pi * frequency * Double(frame) / Double(sampleRate)
                append(Int16(sin(phase) * fade * 0.08 * Double(Int16.max)))
            }
            return data
        }
    }
#endif
