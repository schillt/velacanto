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
    #if os(iOS)
        @UIApplicationDelegateAdaptor(FoundationCarPlayApplicationDelegate.self) private
            var carPlayDelegate
    #else
        @NSApplicationDelegateAdaptor(FoundationHandoffApplicationDelegate.self) private
            var handoffDelegate
    #endif
    @StateObject private var model = FoundationAppRuntime.model
    @State private var localLibrary = FoundationLocalLibraryModel.appOwned()

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
                        .environment(\.foundationLocalLibrary, localLibrary)
                        .task { await localLibrary.restore().value }
                        .frame(minWidth: 320, minHeight: 480)
                }
            #else
                FoundationRootView(model: model)
                    .environment(\.foundationLocalLibrary, localLibrary)
                    .task { await localLibrary.restore().value }
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
            .windowToolbarStyle(.unified)
        #endif
    }
}

/// Every application entry point uses this owner; readiness never creates a second player.
@MainActor
enum FoundationAppRuntime {
    static let model = FoundationAppModel()
}

enum FoundationCredentialUpgradeError: Error {
    case confirmationRequired(UUID)
}

enum FoundationRetainedScopeMatch: Equatable { case empty, matching, unmatched }

/// Existing account stores share one retention boundary; injection keeps upgrade tests disposable.
@MainActor
struct FoundationAccountRetention {
    var inventory: (String) throws -> FoundationRetainedScopeMatch
    var pins: (String?) -> Bool
    var playback: (String?) -> Bool
    var downloads: (String?) -> Bool
    var selections: (String?) -> Bool
    var artwork: (String?) async -> Bool
    var pages: (String?) async -> Bool

    static var system: Self {
        Self(
            inventory: { try inventory(scope: $0) },
            pins: { FoundationPinStorage.removeStoredPins(retaining: $0) },
            playback: { FoundationPlaybackSessionStore.clear(retaining: $0) },
            downloads: { FoundationDownloads.clearStoredDownloads(retaining: $0) },
            selections: { FoundationMusicLibraryStore.clear(retaining: $0) },
            artwork: { await FoundationArtworkCache.clearStoredArtwork(retaining: $0) },
            pages: { await FoundationCatalogPageCache.clearStoredPages(retaining: $0) })
    }

    static func inventory(
        scope: String, defaults: UserDefaults = .standard,
        roots: [(URL, String)]? = nil
    ) throws -> FoundationRetainedScopeMatch {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let digest = FoundationArtworkCache.digest(scope)
        let stores =
            roots ?? [
                (FoundationPlaybackSessionStore.defaultRoot, scope),
                (FoundationMusicLibraryStore.defaultRoot, scope),
                (FoundationDownloadStorage.base, digest),
                (cacheRoot.appendingPathComponent("VelacantoArtwork"), digest),
                (FoundationCatalogPageCache.defaultRoot, digest),
            ]
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(FoundationPinStorage.keyPrefix)
        }
        var any = !keys.isEmpty
        var matching = keys.contains(FoundationPinStorage.key(for: scope))
        for (root, retained) in stores {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FoundationLibraryError.credentials
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey])
            guard entries.count <= 4096 else { throw FoundationLibraryError.credentials }
            any = any || !entries.isEmpty
            matching = matching || entries.contains { $0.lastPathComponent == retained }
        }
        return matching ? .matching : any ? .unmatched : .empty
    }

}

@MainActor
final class FoundationAppModel: ObservableObject {
    let handoff = FoundationHandoffController()
    let continueListeningDismissals = FoundationContinueListeningDismissals()

    @discardableResult
    func receiveHandoff(_ activity: NSUserActivity) -> Bool {
        handoff.receive(activity) { [weak self] in
            guard let self else { return false }
            return await self.ensureReady() == .ready
        }
    }
    enum Readiness: Equatable {
        case ready, signedOut, unavailable, cancelled
    }

    private let prepareCaches: @MainActor () async -> Bool
    private let restoreAccount: (@MainActor (FoundationAppModel) -> Void)?
    private var startupTask: Task<Void, Never>?
    private var startupGeneration = 0
    private let credentialOperations: FoundationCredentials.Operations
    private let accountRetention: FoundationAccountRetention
    private let credentialDefaults: UserDefaults
    private let publishAccount: ((FoundationSession, String) -> Void)?
    private var accountCleanupTask: Task<Void, Never>?
    private var authenticationGeneration = 0
    private var pendingUpgradeAuthentication:
        (
            ticket: UUID, session: FoundationSession, epoch: Int, startup: Int, authentication: Int
        )?
    static let credentialBackendKey = "Velacanto.Foundation.CredentialBackend.v1"

    var awaitsCredentialUpgrade: Bool {
        #if os(macOS)
            credentialDefaults.string(forKey: Self.credentialBackendKey) != "data-protection-ready"
        #else
            false
        #endif
    }

    init(
        prepareCaches: (@MainActor () async -> Bool)? = nil,
        restoreAccount: (@MainActor (FoundationAppModel) -> Void)? = nil,
        credentialOperations: FoundationCredentials.Operations = .system,
        accountRetention: FoundationAccountRetention? = nil,
        credentialDefaults: UserDefaults = .standard,
        publishAccount: ((FoundationSession, String) -> Void)? = nil
    ) {
        self.prepareCaches =
            prepareCaches ?? {
                await FoundationDisposableCachePolicy.shared.prepare(
                    version: FoundationDisposableCachePolicy.currentVersion)
            }
        self.restoreAccount = restoreAccount
        self.credentialOperations = credentialOperations
        self.accountRetention = accountRetention ?? .system
        self.credentialDefaults = credentialDefaults
        self.publishAccount = publishAccount
    }

    @Published private(set) var library: FoundationJellyfinLibrary?
    @Published private(set) var primaryGenres: FoundationPrimaryGenresModel?
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
            primaryGenres?.cancel()
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
        startupTask?.cancel()
        accountCleanupTask?.cancel()
        retirePrimaryGenres()
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

    /// Starts one retained preparation task, independently of a phone window's lifetime.
    func restore() {
        guard !restored else { return }
        restored = true
        #if DEBUG
            if restoreAccount == nil,
                ProcessInfo.processInfo.arguments.contains("-foundationTesting")
            {
                return
            }
        #endif
        let epoch = accountEpoch
        let generation = startupGeneration
        let prepare = prepareCaches
        startupTask = Task { [weak self] in
            let prepared = await prepare()
            guard !Task.isCancelled, let self,
                self.startupGeneration == generation, self.accountEpoch == epoch
            else { return }
            self.cachesReady = prepared
            self.isPreparingCaches = false
            guard prepared else {
                self.credentialError =
                    "Disposable caches could not be cleared. Retry to open your library."
                return
            }
            if let restoreAccount = self.restoreAccount {
                restoreAccount(self)
            } else {
                self.restoreCredentials()
            }
        }
    }

    /// A cancelled caller cannot cancel another surface's shared account restoration.
    func ensureReady() async -> Readiness {
        guard !Task.isCancelled else { return .cancelled }
        restore()
        let generation = startupGeneration
        await startupTask?.value
        guard !Task.isCancelled, startupGeneration == generation else { return .cancelled }
        if isPreparingCaches || !cachesReady || isCleaningDownloads { return .unavailable }
        if library != nil, player != nil { return .ready }
        return credentialError == nil ? .signedOut : .unavailable
    }

    func retryCachePreparation() {
        cancelCredentialUpgrade()
        accountCleanupTask?.cancel()
        startupGeneration += 1
        startupTask?.cancel()
        startupTask = nil
        restored = false
        isPreparingCaches = true
        credentialError = nil
        restore()
    }

    /// Retire suspended startup work together with an account's local ownership.
    func invalidateAccountReadiness() {
        continueListeningDismissals.configure(scope: nil)
        handoff.invalidate()
        cancelCredentialUpgrade()
        accountCleanupTask?.cancel()
        accountEpoch += 1
        startupGeneration += 1
        startupTask?.cancel()
        startupTask = nil
        restored = true
        isPreparingCaches = false
    }

    func restoreCredentials() {
        if awaitsCredentialUpgrade {
            // Quarantine scoped data until a modern credential exists. Never ask legacy storage.
            do {
                if let session = try FoundationCredentials.load(operations: credentialOperations) {
                    try accept(session, saveCredentials: false)
                }
            } catch {
                credentialError = "Saved sign-in could not be restored. Please sign in again."
            }
            return
        }
        var credentialReadCompleted = false
        do {
            let savedSession = try FoundationCredentials.load(operations: credentialOperations)
            credentialReadCompleted = true
            if let session = savedSession {
                let scope = Self.sourceScope(for: session)
                if !accountRetention.pins(scope) {
                    credentialError = "Older saved pins could not be removed from this device."
                }
                if !accountRetention.playback(scope) {
                    credentialError =
                        "Older playback sessions could not be removed from this device."
                }
                if !accountRetention.downloads(scope) {
                    credentialError =
                        "Older downloaded music could not be removed from this device."
                }
                if !accountRetention.selections(scope) {
                    credentialError = "Older music-library selections could not be removed."
                }
                open(session, sourceScope: scope)
            } else if !accountRetention.pins(nil) {
                credentialError = "Saved pins could not be removed from this device."
            }
        } catch {
            credentialError = "Saved sign-in could not be read. Please sign in again."
            if !accountRetention.pins(nil) {
                credentialError =
                    "Saved sign-in could not be read. Please sign in again. "
                    + "Saved pins could not be removed from this device."
            }
        }
        if library == nil, !accountRetention.playback(nil) {
            credentialError = "Saved playback sessions could not be removed from this device."
        }
        if credentialReadCompleted, library == nil, !accountRetention.downloads(nil) {
            credentialError = FoundationDownloadAccountError.cleanupFailed.errorDescription
        }
        if credentialReadCompleted, library == nil {
            if !accountRetention.selections(nil) {
                credentialError = "Saved music-library selections could not be removed."
            }
            let epoch = accountEpoch
            accountCleanupTask?.cancel()
            accountCleanupTask = Task { [weak self] in
                guard !Task.isCancelled, let self, self.accountEpoch == epoch, self.library == nil
                else { return }
                let cleared = await self.accountRetention.artwork(nil)
                guard !Task.isCancelled, self.accountEpoch == epoch, self.library == nil else {
                    return
                }
                let pagesCleared = await self.accountRetention.pages(nil)
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

    func prepareSignIn(
        authenticate: @MainActor () async throws -> FoundationSession
    ) async throws -> FoundationSignInView.Acceptance {
        cancelCredentialUpgrade()
        // A prior owner's cleanup cannot complete migration during a new sign-in.
        accountCleanupTask?.cancel()
        let authentication = authenticationGeneration
        let epoch = accountEpoch
        let generation = startupGeneration
        let quarantined = awaitsCredentialUpgrade
        let session = try await FoundationSignInPolicy.authenticate {
            quarantined || self.accountRetention.pins(nil)
        } clearPlaybackSessions: {
            quarantined || self.accountRetention.playback(nil)
        } clearDownloads: {
            quarantined || self.accountRetention.downloads(nil)
        } signIn: {
            try await authenticate()
        }
        try Task.checkCancellation()
        guard accountEpoch == epoch, startupGeneration == generation,
            authenticationGeneration == authentication
        else {
            throw CancellationError()
        }
        return { [weak self] in
            try Task.checkCancellation()
            guard let self, self.accountEpoch == epoch, self.startupGeneration == generation,
                self.authenticationGeneration == authentication
            else {
                throw CancellationError()
            }
            try self.accept(session)
        }
    }

    func cancelCredentialUpgrade() {
        authenticationGeneration += 1
        pendingUpgradeAuthentication = nil
    }

    func confirmCredentialUpgrade(_ ticket: UUID) throws {
        let pending = pendingUpgradeAuthentication
        guard let pending, pending.ticket == ticket, pending.epoch == accountEpoch,
            pending.startup == startupGeneration,
            pending.authentication == authenticationGeneration, awaitsCredentialUpgrade
        else {
            throw CancellationError()
        }
        pendingUpgradeAuthentication = nil
        try Task.checkCancellation()
        try accept(pending.session, allowScopeDiscard: true)
    }

    private func accept(
        _ session: FoundationSession, saveCredentials: Bool = true,
        allowScopeDiscard: Bool = false
    ) throws {
        guard cachesReady else { throw FoundationLibraryError.unavailable }
        let scope = Self.sourceScope(for: session)
        if awaitsCredentialUpgrade {
            if !allowScopeDiscard, try accountRetention.inventory(scope) == .unmatched {
                let ticket = UUID()
                pendingUpgradeAuthentication = (
                    ticket, session, accountEpoch,
                    startupGeneration, authenticationGeneration
                )
                throw FoundationCredentialUpgradeError.confirmationRequired(ticket)
            }
            guard accountRetention.pins(scope), accountRetention.playback(scope),
                accountRetention.downloads(scope), accountRetention.selections(scope)
            else { throw FoundationLibraryError.credentials }
        }
        if saveCredentials {
            try FoundationCredentials.save(session, operations: credentialOperations)
        }
        open(session, sourceScope: scope)
    }

    private func finishAccountCleanup(epoch: Int, generation: Int, cleared: Bool) {
        guard !Task.isCancelled, accountEpoch == epoch, startupGeneration == generation else {
            return
        }
        if !cleared {
            credentialError = "Older disposable caches could not be removed from this device."
        } else if awaitsCredentialUpgrade {
            credentialDefaults.set("data-protection-ready", forKey: Self.credentialBackendKey)
        }
    }

    func waitForAccountCleanup() async { await accountCleanupTask?.value }

    private func beginAccountCleanup(
        scope: String, retiringCache: FoundationArtworkCache?,
        retiringPages: FoundationCatalogPageCache?
    ) {
        let epoch = accountEpoch
        let generation = startupGeneration
        accountCleanupTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if let retiringCache {
                _ = await retiringCache.invalidate(removeDisk: retiringCache.scope != scope)
            }
            guard !Task.isCancelled else { return }
            if let retiringPages {
                _ = await retiringPages.invalidate(removeDisk: retiringPages.scope != scope)
            }
            guard !Task.isCancelled, let self, self.accountEpoch == epoch,
                self.startupGeneration == generation
            else { return }
            let cleared = await self.accountRetention.artwork(scope)
            guard !Task.isCancelled, self.accountEpoch == epoch,
                self.startupGeneration == generation
            else { return }
            let pagesCleared = await self.accountRetention.pages(scope)
            self.finishAccountCleanup(
                epoch: epoch, generation: generation,
                cleared: cleared && pagesCleared)
        }
    }

    private static func sourceScope(for session: FoundationSession) -> String {
        // Persist only a digest of source/account identity, never the server or credentials.
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func open(_ session: FoundationSession, sourceScope: String) {
        continueListeningDismissals.configure(
            scope: FoundationMusicLibraryStore.digest(sourceScope + "\0" + session.deviceID))
        if library != nil { handoff.invalidate() }
        cancelCredentialUpgrade()
        accountCleanupTask?.cancel()
        retirePrimaryGenres()
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
        player?.invalidateReporting()
        downloads?.invalidate()
        connectivity?.invalidate()
        policySubscriptions.removeAll()
        currentRetainedArtworkIdentity = nil
        let retiringCache = library?.artworkCache
        let retiringPages = library?.catalogPageCache
        let epoch = accountEpoch
        if let publishAccount {
            beginAccountCleanup(
                scope: FoundationArtworkCache.digest(sourceScope), retiringCache: retiringCache,
                retiringPages: retiringPages)
            publishAccount(session, sourceScope)
            return
        }
        let admission = FoundationNetworkAdmission()
        let cache = FoundationArtworkCache(scope: sourceScope, networkAdmission: admission)
        let pages = FoundationCatalogPageCache(scope: sourceScope)
        beginAccountCleanup(
            scope: FoundationArtworkCache.digest(sourceScope), retiringCache: retiringCache,
            retiringPages: retiringPages)
        librarySelection?.invalidate()
        let library = FoundationJellyfinLibrary(
            session: session, deviceName: FoundationClientDeviceName.current,
            streamingQuality: { [weak self, playbackPreferences] in
                #if os(macOS)
                    return await playbackPreferences.resolvedStreamingQuality(
                        for: FoundationStreamingPath())
                #else
                    let model = self
                    return await MainActor.run {
                        let path =
                            model?.accountEpoch == epoch
                            ? model?.connectivity?.streamingPath : nil
                        return playbackPreferences.resolvedStreamingQuality(
                            for: path ?? FoundationStreamingPath())
                    }
                #endif
            }, artworkCache: cache, catalogPageCache: pages, networkAdmission: admission)
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
                let scoped = library.scoped(to: id, available: available)
                self.configurePrimaryGenres(scoped)
                self.browseLibrary = scoped
            })
        self.actions = FoundationLibraryActions(
            sourceScope: sourceScope,
            trackPreferences: playbackPreferences,
            mutateFavorite: { item, favorite in
                try await library.setFavorite(for: item, isFavorite: favorite)
            })
        self.actions?.configurePinSync(
            sourceScope: sourceScope,
            containerIdentifier: Bundle.main.object(
                forInfoDictionaryKey: "VelacantoPinSyncContainerIdentifier") as? String,
            resolve: { try await library.itemDetails(for: $0) })
        self.library = library
        let downloads = FoundationDownloads(
            scope: sourceScope, library: library, monitorConnectivity: false,
            requestedQuality: { [weak playbackPreferences] in
                playbackPreferences?.downloadQuality ?? .original
            },
            observeTracks: { [weak self] items, albumID in
                self?.actions?.observeTrackCopies(items, albumID: albumID)
            },
            projectTracks: { [weak self] items, albumID in
                guard let actions = self?.actions else { return [] }
                return actions.visibleTracks(
                    items, albumID: albumID,
                    isAvailable: { item in
                        self?.connectivity?.localOnly != true
                            || self?.downloads?.isReady(item) == true
                    })
            })
        self.downloads = downloads
        configurePrimaryGenres(browseLibrary ?? library)
        let connectivity = FoundationConnectivity {
            _ = try await library.songs(startIndex: 0)
        }
        self.connectivity = connectivity
        self.actions?.configureTrackAvailability { [weak connectivity, weak downloads] item in
            connectivity?.localOnly != true || downloads?.isReady(item) == true
        }
        let preferences = playbackPreferences
        downloads.setAllowsCellular(preferences.allowsCellularDownloads)
        self.player = FoundationPlayer(
            library: library,
            resolveResource: { item in
                try await downloads.playbackResource(
                    for: item, allowsRemoteFallback: !connectivity.localOnly)
            }, makeItem: { preferences.makePlayerItem(for: $0) },
            reportingAllowed: { !connectivity.localOnly })
        player?.observePlaybackProtection { protected, revision in
            Task { await admission.updatePlaybackProtection(protected, revision: revision) }
        }
        currentArtworkLocalOnly = connectivity.localOnly
        connectivity.objectWillChange.sink { [weak self, weak downloads, weak connectivity] in
            Task { @MainActor in
                guard let self, let downloads, let connectivity,
                    self.connectivity === connectivity
                else { return }
                if connectivity.localOnly { self.primaryGenres?.cancel() }
                if connectivity.localOnly { self.player?.suspendReporting() }
                if self.currentArtworkLocalOnly != connectivity.localOnly {
                    self.currentArtworkLocalOnly = connectivity.localOnly
                    self.actions?.refreshTrackVisibility()
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
            preferences.$showDuplicateAlbumTracks.removeDuplicates().dropFirst().sink {
                [weak player] _ in
                // Retire ownership at the preference event, not in a delayed task
                // that could clear a newer restored queue. The ordinary preference
                // observation refreshes the projection after Published assignment.
                player?.clearContinuationVisibilityForPreferenceChange()
            }.store(in: &policySubscriptions)
            if let actions = self.actions {
                player.configureTrackProjection(
                    project: { [weak actions] in actions?.visibleTracks($0) ?? [] },
                    observe: { [weak actions] in actions?.observeTrackCopies($0) })
                actions.$trackVisibilityRevision.dropFirst().sink { [weak player] _ in
                    player?.refreshTrackVisibility()
                }.store(in: &policySubscriptions)
            }
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
                prepareRetry: { item in await library.retryArtwork(for: item) },
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
            handoff.configure(
                scope: sourceScope, player: player,
                resolve: { item in
                    try await FoundationHandoffResolution.resolve(
                        item, library: library, localOnly: connectivity.localOnly,
                        localItem: { item in
                            downloads.localCatalogItems(kind: item.kind)
                                .first(where: { $0.id == item.id })
                        })
                }, navigate: { [weak handoff] item in handoff?.requestBrowse(item) })
        }
    }

    func retirePrimaryGenres() {
        primaryGenres?.retire()
        primaryGenres = nil
    }

    /// One account/runtime owner shared by every window; binding never starts a census.
    func configurePrimaryGenres(_ library: any FoundationLibrary) {
        if let primaryGenres {
            primaryGenres.bind(library)
        } else {
            primaryGenres = FoundationPrimaryGenresModel(library: library)
        }
        guard let primaryGenres else { return }
        primaryGenres.bindDownloads(downloads)
        Task { await primaryGenres.restoreBoundCache() }
    }

    func signOut() {
        guard let session = library?.session else { return }
        player?.stop()
        let deviceName = FoundationClientDeviceName.current
        let attempt = FoundationSignOutPolicy.begin {
            // Keep the captured session until this bounded attempt completes.
            Task.detached(priority: .userInitiated) {
                let adapter = FoundationJellyfinLibrary(
                    session: session, deviceName: deviceName,
                    load: FoundationJellyfinLibrary.signOutLoad)
                do {
                    try await adapter.endSession()
                    return true
                } catch {
                    return false
                }
            }
        } clear: {
            try FoundationCredentials.clear(operations: credentialOperations)
            actions?.invalidate()
        } clearPins: {
            FoundationPinStorage.removeStoredPins()
        }
        guard attempt.localCleared else {
            credentialError =
                "Sign-out failed here. Saved pins remain on this device. "
                + "Jellyfin may have ended the session."
            return
        }
        invalidateAccountReadiness()
        let epoch = accountEpoch
        retirePrimaryGenres()
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
        actions = nil
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
        currentArtwork = nil
        mediaSession = nil
        nowPlaying = nil
        player?.invalidateReporting()
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
                let actions = model.actions, let primaryGenres = model.primaryGenres,
                let artwork = model.currentArtwork, let downloads = model.downloads,
                let connectivity = model.connectivity
            {
                FoundationLibraryView(
                    library: model.browseLibrary ?? library, accountLibrary: library,
                    player: player, primaryGenres: primaryGenres,
                    signOut: model.signOut, librarySelection: model.librarySelection
                )
                #if os(macOS)
                    .environmentObject(model)
                #endif
                .environmentObject(model.continueListeningDismissals)
                .environmentObject(actions)
                .environmentObject(artwork)
                .environmentObject(downloads)
                .environmentObject(connectivity)
                .environmentObject(model.playbackPreferences)
                .id(ObjectIdentifier(actions))
                .task(id: "\(connectivity.localOnly)-\(connectivity.successfulRetryRevision)") {
                    guard !connectivity.localOnly else { return }
                    if connectivity.successfulRetryRevision > 0 { artwork.retryMissingArtwork() }
                    await model.librarySelection?.validateSavedChoice()
                }
            } else if model.isCleaningDownloads {
                ProgressView("Removing downloaded music…")
            } else {
                FoundationSignInView(model: model)
            }
        }
        .modifier(
            FoundationHandoffPresentation(
                controller: model.handoff, accountAlert: accountAlertPresented.wrappedValue)
        )
        .environment(\.foundationHandoff, model.handoff)
        .task { _ = await model.ensureReady() }
        #if os(iOS)
            .onContinueUserActivity(FoundationHandoffPayload.activityType) { activity in
                // Preserve SwiftUI's phone scene proxy. Native cold/appdelegate
                // forwarding and this warm fallback share synchronous registration
                // and nonce deduplication in the existing account owner.
                _ = model.receiveHandoff(activity)
            }
            .task(id: scenePhase) {
                FoundationSiriStartupAuthorization.shared.foreground(
                    isActive: scenePhase == .active,
                    canPrompt: !accountAlertPresented.wrappedValue)
            }
            .onChange(of: accountAlertPresented.wrappedValue) { _, presented in
                FoundationSiriStartupAuthorization.shared.foreground(
                    isActive: scenePhase == .active, canPrompt: !presented)
            }
        #endif
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
    private let confirmUpgrade: @MainActor (UUID) throws -> Void
    private let cancelUpgrade: @MainActor () -> Void
    @State private var upgradeTicket: UUID?

    init(model: FoundationAppModel) {
        self.init(
            authenticate: { url, username, password in
                try await model.prepareSignIn {
                    try await FoundationJellyfinLibrary.signIn(
                        serverURL: url, username: username, password: password,
                        deviceName: FoundationClientDeviceName.current)
                }
            }, confirmUpgrade: { try model.confirmCredentialUpgrade($0) },
            cancelUpgrade: { model.cancelCredentialUpgrade() })
        #if os(macOS)
            _address = State(initialValue: model.library?.session.serverURL.absoluteString ?? "")
        #endif
    }

    init(
        authenticate: @escaping @MainActor (URL, String, String) async throws -> Acceptance,
        confirmUpgrade: @escaping @MainActor (UUID) throws -> Void = { _ in
            throw CancellationError()
        },
        cancelUpgrade: @escaping @MainActor () -> Void = {}
    ) {
        self.authenticate = authenticate
        self.confirmUpgrade = confirmUpgrade
        self.cancelUpgrade = cancelUpgrade
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
        cancelUpgrade()
        upgradeTicket = nil
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
                    .navigationTitle("VelaCanto")
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
                        if let upgrade = error as? FoundationCredentialUpgradeError {
                            if case .confirmationRequired(let ticket) = upgrade {
                                password = ""
                                upgradeTicket = ticket
                            }
                        } else if let downloadError = error as? FoundationDownloadAccountError {
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
                .onDisappear {
                    cancelUpgrade()
                    upgradeTicket = nil
                }
                .confirmationDialog(
                    "Keep existing local data?",
                    isPresented: Binding(
                        get: { upgradeTicket != nil },
                        set: { presented in
                            guard !presented, let dismissedTicket = upgradeTicket else { return }
                            // Native dismissal can precede its button callback. Let that
                            // synchronous callback consume ownership first; never retire a new ticket.
                            Task { @MainActor in
                                await Task.yield()
                                guard upgradeTicket == dismissedTicket else { return }
                                cancelUpgrade()
                                upgradeTicket = nil
                            }
                        }
                    ), presenting: upgradeTicket
                ) { ticket in
                    Button("Remove Local Data and Continue", role: .destructive) {
                        do { try confirmUpgrade(ticket) } catch {
                            errorMessage =
                                "Couldn’t finish signing in. Your library was not opened. Please retry."
                        }
                        upgradeTicket = nil
                    }
                    Button("Retry Sign-in", role: .cancel) {
                        cancelUpgrade()
                        upgradeTicket = nil
                    }
                } message: { _ in
                    Text(
                        "Existing downloads, pins, playback history and library settings don’t match this server address and account. Retry with the previous server address to keep them, or remove local data and continue. Your Jellyfin library will not be changed."
                    )
                }
        }
    }

    @ViewBuilder private var signInContent: some View {
        #if os(macOS)
            VStack(spacing: 20) {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 36))
                        .foregroundStyle(.tint)
                    Text("Sign in to VelaCanto").font(.largeTitle.bold())
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
                        Text("Your music, in VelaCanto.")
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
                        cancelUpgrade()
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

/// The application continuation seam resolves metadata in the receiver's account.
/// It never resolves audio or mutates a queue; the controller owns confirmation
/// and rejects cancelled/retired account or intent results after this await.
@MainActor
enum FoundationHandoffResolution {
    static func resolve(
        _ item: FoundationItem, library: FoundationJellyfinLibrary, localOnly: Bool,
        localItem: (FoundationItem) -> FoundationItem?
    ) async throws -> FoundationItem {
        try Task.checkCancellation()
        if localOnly {
            guard let local = localItem(item), local.id == item.id, local.kind == item.kind else {
                throw FoundationHandoffError.unavailable
            }
            return local
        }
        return try await library.handoffItem(for: item)
    }
}
