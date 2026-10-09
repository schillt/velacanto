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
                    } else if ProcessInfo.processInfo.arguments.contains("-fixtureAccount") {
                        FoundationAccountUITestHarness()
                    } else {
                        FoundationDownloadsTestHarness()
                    }
                } else {
                    FoundationRootView(model: model)
                        .frame(minWidth: 320, minHeight: 480)
                }
            #else
                FoundationRootView(model: model)
                    #if os(macOS)
                        .frame(minWidth: 1080, minHeight: 640)
                    #else
                        .frame(minWidth: 320, minHeight: 480)
                    #endif
            #endif
        }
        #if os(macOS)
            .defaultSize(width: 1100, height: 760)
            .windowResizability(.contentMinSize)
            .windowToolbarStyle(.unified)
            .commands { FoundationMacCommands() }
        #endif
        #if os(macOS)
            Settings {
                FoundationMacSettingsRoot(model: model)
            }
            .defaultSize(width: 520, height: 640)
        #endif
    }
}

@MainActor
final class FoundationAppModel: ObservableObject {
    @Published private(set) var library: FoundationJellyfinLibrary?
    @Published private(set) var browseLibrary: FoundationJellyfinLibrary?
    @Published private(set) var librarySelection: FoundationMusicLibrarySelection?
    @Published private(set) var player: FoundationPlayer?
    @Published private(set) var actions: FoundationLibraryActions?
    @Published private(set) var currentArtwork: FoundationCurrentArtwork?
    @Published private(set) var downloads: FoundationDownloads?
    @Published private(set) var connectivity: FoundationConnectivity?
    #if os(macOS)
        @Published var profileName = ""
        @Published var profileImage: Image?
    #endif
    let playbackPreferences = FoundationPlaybackPreferences()
    private var policySubscriptions: Set<AnyCancellable> = []
    private var currentRetainedArtworkIdentity: String?
    private var currentArtworkLocalOnly = false
    @Published private(set) var isCleaningDownloads = false
    @Published private(set) var requiresSignIn = false
    #if os(macOS)
        @Published var settingsShowsSignIn = false

        func requireMacSignIn() {
            player?.stop()
            requiresSignIn = true
            settingsShowsSignIn = true
        }
    #endif
    @Published var credentialError: String?
    @Published var signOutNotice: String?
    private var playbackSessionSubscription: AnyCancellable?
    @Published private(set) var isPreparingCaches = true
    @Published private(set) var cachesReady = false
    private var restored = false
    private var accountEpoch = 0
    private var nowPlaying: FoundationNowPlaying?
    private var mediaSession: MediaSession<FoundationNowPlaying>?

    isolated deinit {
        FoundationAlphabetAccountLifecycle.retire(library)
        librarySelection?.invalidate()
        if let cache = library?.artworkCache {
            Task { _ = await cache.invalidate(removeDisk: false) }
        }
        if let pages = library?.catalogPageCache {
            Task { _ = await pages.invalidate(removeDisk: false) }
        }
        downloads?.invalidate()
        connectivity?.invalidate()
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
    }

    func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("-foundationTesting") else { return }
        #endif
        Task { [weak self] in
            let prepared = await FoundationDisposableCachePolicy.shared.prepare(
                version: FoundationDisposableCachePolicy.currentVersion)
            guard let self else { return }
            self.cachesReady = prepared
            self.isPreparingCaches = false
            guard prepared else {
                self.credentialError =
                    "Disposable caches could not be cleared. Retry to open your library."
                return
            }
            self.restoreCredentials()
        }
    }

    func retryCachePreparation() {
        restored = false
        isPreparingCaches = true
        credentialError = nil
        restore()
    }

    private func restoreCredentials() {
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
                if !FoundationMusicLibraryStore.clear(retaining: scope) {
                    credentialError = "Older music-library selections could not be removed."
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
        if credentialReadCompleted, library == nil {
            if !FoundationMusicLibraryStore.clear() {
                credentialError = "Saved music-library selections could not be removed."
            }
            let epoch = accountEpoch
            Task { [weak self] in
                guard let self, self.accountEpoch == epoch, self.library == nil else { return }
                let cleared = await FoundationArtworkCache.clearStoredArtwork()
                let pagesCleared = await FoundationCatalogPageCache.clearStoredPages()
                guard self.accountEpoch == epoch, self.library == nil else { return }
                if !cleared || !pagesCleared {
                    self.credentialError =
                        "Saved disposable caches could not be removed from this device."
                }
            }
        }
        #if DEBUG
            FoundationJournal.shared.record("app phase=opened")
        #endif
    }

    fileprivate func accept(_ session: FoundationSession) throws {
        guard cachesReady else { throw FoundationLibraryError.unavailable }
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
        FoundationAlphabetAccountLifecycle.retire(library)
        playbackSessionSubscription = nil
        accountEpoch += 1
        signOutNotice = nil
        requiresSignIn = false
        #if os(macOS)
            settingsShowsSignIn = false
            profileName = ""
            profileImage = nil
        #endif
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
        currentArtwork = nil
        mediaSession = nil
        nowPlaying = nil
        actions?.invalidate()
        player?.stop()
        downloads?.invalidate()
        connectivity?.invalidate()
        policySubscriptions.removeAll()
        currentRetainedArtworkIdentity = nil
        let retiringCache = library?.artworkCache
        let retiringPages = library?.catalogPageCache
        let cache = FoundationArtworkCache(scope: sourceScope)
        let pages = FoundationCatalogPageCache(scope: sourceScope)
        let epoch = accountEpoch
        Task { [weak self] in
            if let retiringCache {
                _ = await retiringCache.invalidate(removeDisk: retiringCache.scope != cache.scope)
            }
            if let retiringPages {
                _ = await retiringPages.invalidate(removeDisk: retiringPages.scope != pages.scope)
            }
            guard let self, self.accountEpoch == epoch else { return }
            let cleared = await FoundationArtworkCache.clearStoredArtwork(retaining: cache.scope)
            let pagesCleared = await FoundationCatalogPageCache.clearStoredPages(
                retaining: pages.scope)
            guard self.accountEpoch == epoch else { return }
            if !cleared || !pagesCleared {
                self.credentialError =
                    "Older disposable caches could not be removed from this device."
            }
        }
        librarySelection?.invalidate()
        let library = FoundationJellyfinLibrary(
            session: session, artworkCache: cache, catalogPageCache: pages)
        let selectionStore = FoundationMusicLibraryStore(scope: sourceScope)
        let savedSelection: FoundationMusicLibraryChoice?
        let selectionReadFailed: Bool
        do {
            savedSelection = try selectionStore.load()
            selectionReadFailed = false
        } catch {
            selectionReadFailed = true
            savedSelection = nil
            credentialError = "Saved music-library selection could not be read."
        }
        browseLibrary = library.scoped(
            to: savedSelection?.id, available: savedSelection == nil && !selectionReadFailed)
        librarySelection = FoundationMusicLibrarySelection(
            selected: savedSelection, selectionReadFailed: selectionReadFailed,
            load: { try await library.musicLibraries() },
            save: { try selectionStore.save($0) },
            allowsNetwork: { [weak self] in self?.connectivity?.localOnly == false },
            apply: { [weak self] id, available in
                guard let self, self.accountEpoch == epoch else { return }
                self.browseLibrary = library.scoped(to: id, available: available)
            })
        self.actions = FoundationLibraryActions(sourceScope: sourceScope) { item, favorite in
            try await library.setFavorite(for: item, isFavorite: favorite)
        }
        self.library = library
        let downloads = FoundationDownloads(
            scope: sourceScope, library: library, monitorConnectivity: false)
        self.downloads = downloads
        let connectivity = FoundationConnectivity {
            _ = try await library.songs(startIndex: 0)
        }
        self.connectivity = connectivity
        let preferences = playbackPreferences
        downloads.setAllowsCellular(preferences.allowsCellularDownloads)
        self.player = FoundationPlayer(
            library: library,
            resolveResource: { item in
                try await downloads.playbackResource(
                    for: item, allowsRemoteFallback: !connectivity.localOnly)
            }, makeItem: { preferences.makePlayerItem(for: $0) })
        currentArtworkLocalOnly = connectivity.localOnly
        connectivity.objectWillChange.sink { [weak self, weak downloads, weak connectivity] in
            Task { @MainActor in
                guard let self, let downloads, let connectivity,
                    self.connectivity === connectivity
                else { return }
                if self.currentArtworkLocalOnly != connectivity.localOnly {
                    self.currentArtworkLocalOnly = connectivity.localOnly
                    self.currentArtwork?.refreshRetainedArtwork()
                }
                downloads.updateConnectivity(
                    isConnected: connectivity.isConnected,
                    usesWiFi: connectivity.usesWiFiOrWired)
            }
        }.store(in: &policySubscriptions)
        preferences.$allowsCellularDownloads.dropFirst().sink { [weak downloads] value in
            Task { @MainActor in downloads?.setAllowsCellular(value) }
        }.store(in: &policySubscriptions)
        preferences.$allowsCellularStreaming.dropFirst().sink { [weak player = self.player] _ in
            Task { @MainActor [weak player] in
                player?.invalidateRemoteItemForPolicyChange()
            }
        }.store(in: &policySubscriptions)
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
            let artwork = FoundationCurrentArtwork(
                player: player,
                cachedLoad: { item in
                    if let local = await downloads.retainedArtwork(for: item) { return local }
                    return try await library.cachedArtworkResult(for: item, size: 640)?.data
                },
                load: { item in
                    if let local = await downloads.retainedArtwork(for: item) { return local }
                    return try await library.artworkResult(
                        for: item, size: 640, allowsNetwork: !connectivity.localOnly)?.data
                })
            downloads.$artworkRevision.dropFirst().sink {
                [weak self, weak artwork, weak player, weak downloads] _ in
                Task { @MainActor in
                    guard let self, let artwork, let player, let downloads,
                        let item = player.queue.first(where: { $0.id == player.selectedEntryID })?
                            .item,
                        let identity = downloads.retainedArtworkIdentity(for: item)
                    else { return }
                    let selectedIdentity = item.catalogArtworkItem.id + ":" + identity
                    guard self.currentRetainedArtworkIdentity != selectedIdentity else { return }
                    self.currentRetainedArtworkIdentity = selectedIdentity
                    artwork.refreshRetainedArtwork()
                }
            }.store(in: &policySubscriptions)
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
        FoundationAlphabetAccountLifecycle.retire(library)
        let retiringCache = library?.artworkCache
        let retiringPages = library?.catalogPageCache
        let retiringDownloads = downloads
        retiringDownloads?.invalidate()
        connectivity?.invalidate()
        connectivity = nil
        policySubscriptions.removeAll()
        currentRetainedArtworkIdentity = nil
        downloads = nil
        isCleaningDownloads = true
        playbackSessionSubscription = nil
        let playbackSessionsCleared = FoundationPlaybackSessionStore.clear()
        let librarySelectionsCleared = FoundationMusicLibraryStore.clear()
        librarySelection?.invalidate()
        librarySelection = nil
        browseLibrary = nil
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
            let artworkCleared = await retiringCache?.invalidate(removeDisk: true) ?? true
            let pagesCleared = await retiringPages?.invalidate(removeDisk: true) ?? true
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
            if !librarySelectionsCleared {
                self.credentialError = "Saved music-library selections could not be removed."
            }
            if !artworkCleared || !pagesCleared {
                let notice = "Disposable caches could not be removed from this device."
                self.credentialError = self.credentialError.map { $0 + " " + notice } ?? notice
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
            if model.isPreparingCaches {
                ProgressView("Preparing library…")
            } else if !model.cachesReady {
                VStack(spacing: 12) {
                    Text("Disposable caches could not be cleared.")
                    Button("Retry") { model.retryCachePreparation() }
                }
            } else if !model.requiresSignIn, let library = model.library, let player = model.player,
                let actions = model.actions,
                let artwork = model.currentArtwork, let downloads = model.downloads,
                let connectivity = model.connectivity
            {
                FoundationLibraryView(
                    library: model.browseLibrary ?? library, accountLibrary: library,
                    player: player, signOut: model.signOut, librarySelection: model.librarySelection
                )
                #if os(macOS)
                    .environmentObject(model)
                #endif
                .environmentObject(actions)
                .environmentObject(artwork)
                .environmentObject(downloads)
                .environmentObject(connectivity)
                .environmentObject(model.playbackPreferences)
                .id(ObjectIdentifier(actions))
                .task(id: "\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)") {
                    guard !connectivity.localOnly else { return }
                    await model.librarySelection?.validateSavedChoice()
                }
            } else if model.isCleaningDownloads {
                ProgressView("Removing downloaded music…")
            } else {
                FoundationSignInView(model: model)
            }
        }
        .task { model.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.playbackPreferences.refresh()
                model.downloads?.reconcilePlaylists()
            }
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

struct FoundationSignInView: View {
    typealias Acceptance = @MainActor () throws -> Void
    private let authenticate: @MainActor (URL, String, String) async throws -> Acceptance

    init(model: FoundationAppModel) {
        self.init { url, username, password in
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
            return { try model.accept(session) }
        }
        #if os(macOS)
            _address = State(initialValue: model.library?.session.serverURL.absoluteString ?? "")
        #endif
    }

    init(authenticate: @escaping @MainActor (URL, String, String) async throws -> Acceptance) {
        self.authenticate = authenticate
    }
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var attempt = 0
    @State private var signingIn = false
    @State private var errorMessage: String?

    private enum Field: Hashable { case address, username, password }
    @FocusState private var focusedField: Field?

    private var canSignIn: Bool { !signingIn && !address.isEmpty && !username.isEmpty }

    private func beginSignIn() {
        guard canSignIn else { return }
        focusedField = nil
        signingIn = true
        attempt += 1
    }

    var body: some View {
        NavigationStack {
            signInContent
                #if os(macOS)
                    .navigationTitle("Sign In")
                #else
                    .navigationTitle("Velacanto")
                #endif
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .background {
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.12),
                                Color(uiColor: .systemGroupedBackground),
                            ],
                            startPoint: .topLeading, endPoint: .center
                        )
                        .ignoresSafeArea()
                    }
                #endif
                .task(id: attempt) {
                    guard signingIn else { return }
                    let owner = attempt
                    errorMessage = nil
                    do {
                        guard
                            let url = URL(
                                string: address.trimmingCharacters(in: .whitespacesAndNewlines))
                        else { throw URLError(.badURL) }
                        let accept = try await authenticate(url, username, password)
                        try Task.checkCancellation()
                        guard signingIn, attempt == owner else { return }
                        try accept()
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

    @ViewBuilder private var signInContent: some View {
        #if os(macOS)
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text("Sign in to Velacanto").font(.largeTitle.bold())
                    Text("Connect your Jellyfin account to listen to your music.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                signInForm.formStyle(.grouped)
                    .frame(maxWidth: 500, maxHeight: 440)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        #else
            signInForm
        #endif
    }

    private var signInForm: some View {
        Form {
            #if os(iOS)
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "music.note")
                            .font(.largeTitle)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Your music, in Velacanto.")
                            .font(.largeTitle.bold())
                            .accessibilityAddTraits(.isHeader)
                        Text("Connect to your Jellyfin server to browse your library and listen.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("sign-in-introduction")
                }
            #endif
            Section {
                TextField("Jellyfin HTTPS address", text: $address)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .address)
                    .accessibilityHint("The trusted HTTPS address of your Jellyfin server.")
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.next)
                    #endif
                    .onSubmit { focusedField = .username }
            } header: {
                Text("Your server")
            } footer: {
                Text("Use your server’s trusted HTTPS address.")
            }
            Section {
                TextField("Username", text: $username)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                        .submitLabel(.next)
                    #endif
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $password)
                    .focused($focusedField, equals: .password)
                    #if os(iOS)
                        .textContentType(.password)
                        .submitLabel(.go)
                    #endif
                    .onSubmit { beginSignIn() }
            } header: {
                Text("Your Jellyfin account")
            } footer: {
                Text(
                    "Sign in with your existing Jellyfin account. Credentials are stored in Keychain."
                )
            }
            Section {
                if let errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Couldn’t sign in", systemImage: "exclamationmark.circle")
                            .font(.headline)
                        Text(errorMessage)
                    }
                    .foregroundStyle(.primary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sign-in-error")
                }
                Button(action: beginSignIn) {
                    Text(signingIn ? "Signing in…" : "Sign in")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSignIn)
                if signingIn {
                    ProgressView("Connecting to your Jellyfin server…")
                        .accessibilityIdentifier("sign-in-progress")
                    Button("Cancel") {
                        signingIn = false
                        attempt += 1
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
