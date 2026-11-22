import Combine
import CryptoKit
import NowPlaying
import SwiftUI

#if DEBUG
    import Security
#endif

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

enum FoundationCredentialReadError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        "Saved sign-in could not be read. Unlock your device if needed, then try again."
    }
}

enum FoundationDownloadAccountError: LocalizedError {
    case cleanupFailed
    case cleanupPending
    case signOutRequired
    var errorDescription: String? {
        switch self {
        case .cleanupFailed: "Downloaded music could not be removed from this device."
        case .cleanupPending:
            "Finishing the previous account cleanup. Try signing in again shortly."
        case .signOutRequired:
            "This is a different account. Sign out of your current account and wait for local cleanup to finish before signing in again."
        }
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

#if FOUNDATION_ISOLATED_TEST_HOST
    /// Unit-test process entry point: no runtime owner, app delegates, or restored user state.
    @main
    struct FoundationIsolatedTestHost: App {
        var body: some Scene {
            WindowGroup {
                #if os(macOS)
                    if ProcessInfo.processInfo.arguments.contains("-foundationTesting"),
                        ProcessInfo.processInfo.arguments.contains(
                            "-foundationRootLyricsRetirement")
                    {
                        FoundationIsolatedLyricsRetirementScene()
                    } else {
                        Color.clear
                    }
                #else
                    Color.clear
                #endif
            }
            #if os(macOS)
                .restorationBehavior(
                    ProcessInfo.processInfo.arguments.contains("-foundationRootLyricsRetirement")
                        ? .disabled : .automatic)
            #endif
        }
    }
#else
    @main
    struct VelacantoFoundationApp: App {
        #if os(iOS)
            @UIApplicationDelegateAdaptor(FoundationCarPlayApplicationDelegate.self) private
                var carPlayDelegate
        #else
            @NSApplicationDelegateAdaptor(FoundationHandoffApplicationDelegate.self) private
                var handoffDelegate
        #endif
        @Environment(\.scenePhase) private var scenePhase
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
                            .task(id: scenePhase) {
                                guard scenePhase == .active else { return }
                                #if DEBUG
                                    guard !FoundationAppRuntime.isTesting else { return }
                                #endif
                                await localLibrary.restore().value
                            }
                            .frame(minWidth: 320, minHeight: 480)
                    }
                #else
                    FoundationRootView(model: model)
                        .environment(\.foundationLocalLibrary, localLibrary)
                        .task(id: scenePhase) {
                            guard scenePhase == .active else { return }
                            #if DEBUG
                                guard !FoundationAppRuntime.isTesting else { return }
                            #endif
                            await localLibrary.restore().value
                        }
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

#endif

/// Every application entry point uses this owner; readiness never creates a second player.
@MainActor
enum FoundationAppRuntime {
    static let model: FoundationAppModel = {
        #if DEBUG
            if isTesting {
                let defaults = UserDefaults(suiteName: "FoundationTesting." + UUID().uuidString)!
                return makeTestingModel(defaults: defaults)
            }
        #endif
        return FoundationAppModel()
    }()

    #if DEBUG
        static var isTesting: Bool {
            ProcessInfo.processInfo.arguments.contains("-foundationTesting")
        }

        static func makeTestingModel(defaults: UserDefaults) -> FoundationAppModel {
            #if os(iOS) && targetEnvironment(simulator)
                if isTesting && FoundationDownloadsTestHarness.enabled {
                    // The existing validated fixture context must also confine the
                    // global model before app delegates can reach it. UI fixtures
                    // retain their own player, authentication and download owners.
                    let storage = FoundationScopedAccountStorage(
                        root: FoundationDownloadsTestHarness.storageRoot
                            .appendingPathComponent("runtime", isDirectory: true),
                        defaults: defaults)
                    let isolation = FoundationAppRuntimeIsolation(
                        storage: storage,
                        credentials: .init(
                            update: { _, _ in errSecInteractionNotAllowed },
                            add: { _ in errSecInteractionNotAllowed },
                            copy: { _ in (errSecItemNotFound, nil) },
                            delete: { _ in errSecItemNotFound }),
                        load: { _ in throw FoundationLibraryError.unavailable },
                        revoke: { _ in Task { false } }, diagnostic: { _ in },
                        taskStarted: { _ in }, revocationStarted: { _ in })
                    return FoundationAppModel(isolation: isolation)
                }
            #endif
            return FoundationAppModel(
                credentialDefaults: defaults,
                playbackPreferences: FoundationPlaybackPreferences(defaults: defaults))
        }
    #endif
}

enum FoundationCredentialUpgradeError: Error {
    case confirmationRequired(UUID)
}

enum FoundationRetainedScopeMatch: Equatable { case empty, matching, unmatched }

/// A caller-owned account namespace. Each store and its cleanup share the same root.
@MainActor
struct FoundationScopedAccountStorage {
    let defaults: UserDefaults
    let playback: URL
    let selections: URL
    let downloads: URL
    let artwork: URL
    let pages: URL

    init(root: URL, defaults: UserDefaults) {
        self.defaults = defaults
        playback = root.appendingPathComponent("playback", isDirectory: true)
        selections = root.appendingPathComponent("selections", isDirectory: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        artwork = root.appendingPathComponent("artwork", isDirectory: true)
        pages = root.appendingPathComponent("pages", isDirectory: true)
    }

    var retention: FoundationAccountRetention {
        let defaults = defaults
        let playback = playback
        let selections = selections
        let downloads = downloads
        let artwork = artwork
        let pages = pages
        return FoundationAccountRetention(
            inventory: { scope in
                let digest = FoundationArtworkCache.digest(scope)
                return try FoundationAccountRetention.inventory(
                    scope: scope, defaults: defaults,
                    roots: [
                        (playback, scope), (selections, scope), (downloads, digest),
                        (artwork, digest), (pages, digest),
                    ])
            },
            pins: { FoundationPinStorage.removeStoredPins(retaining: $0, defaults: defaults) },
            playback: { FoundationPlaybackSessionStore.clear(retaining: $0, root: playback) },
            downloads: { FoundationDownloads.clearStoredDownloads(retaining: $0, root: downloads) },
            selections: { FoundationMusicLibraryStore.clear(retaining: $0, root: selections) },
            artwork: {
                await FoundationArtworkCache.clearStoredArtwork(retaining: $0, root: artwork)
            },
            pages: { await FoundationCatalogPageCache.clearStoredPages(retaining: $0, root: pages) }
        )
    }
}

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
                || $0.hasPrefix(FoundationPinSync.storagePrefix)
        }
        let retainedKeys = [
            FoundationPinStorage.key(for: scope), FoundationPinSync.storagePrefix + scope,
        ]
        var any = !keys.isEmpty
        var matching = keys.contains { retainedKeys.contains($0) }
        var unrelated = keys.contains { !retainedKeys.contains($0) }
        for (root, retained) in stores {
            let (found, other) = try FoundationScopedAccountRemoval.inventory(
                root: root, retained: retained)
            any = any || found || other
            matching = matching || found
            unrelated = unrelated || other
        }
        return unrelated ? .unmatched : matching ? .matching : any ? .unmatched : .empty
    }

}

/// Complete instance-owned isolation for lifecycle characterization.
/// Keeps the production lease alive through late callbacks until process exit.
/// The app runtime has one model; an unexpected second model fails closed.
@MainActor
private enum FoundationAccountProcessOwnership {
    private static var lease: FoundationAccountLifetimeLease?

    static func acquire() async throws -> FoundationAccountLifetimeLease {
        guard lease == nil else { throw FoundationAccountLifetimeLease.LeaseError.busy }
        let acquired = try await Task.detached(priority: .userInitiated) {
            try FoundationAccountLifetimeLease.acquire()
        }.value
        guard lease == nil else { throw FoundationAccountLifetimeLease.LeaseError.busy }
        lease = acquired
        return acquired
    }
}

/// Orders observed background obligations with the short off-main credential commit.
/// Callers must enqueue registrations on MainActor before yielding, and must not
/// resolve a completion until its old-scope reconciliation is actually proved.
final class FoundationSignOutCommitLane: @unchecked Sendable {
    enum LaneError: Error { case pending }
    struct Event: Equatable, Sendable {
        let token: UUID
        let identifier: String
        let scope: String
    }
    private struct Entry: Sendable {
        let event: Event
        let completion: @MainActor @Sendable () -> Void
    }
    private let queue = DispatchQueue(label: "VelaCanto.SignOutCommitLane")
    private var entries: [UUID: Entry] = [:]
    private var activeCommit: UUID?

    @MainActor
    func register(
        identifier: String, scope: String,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> UUID {
        let event = Event(token: UUID(), identifier: identifier, scope: scope)
        queue.async { self.entries[event.token] = Entry(event: event, completion: completion) }
        return event.token
    }

    /// Reserve an async credential transition without holding the UI thread.
    @MainActor
    func beginCommit() async throws -> UUID {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.entries.isEmpty, self.activeCommit == nil else {
                    continuation.resume(throwing: LaneError.pending)
                    return
                }
                let token = UUID()
                self.activeCommit = token
                continuation.resume(returning: token)
            }
        }
    }

    @MainActor
    func endCommit(_ token: UUID) async -> [Event]? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.activeCommit == token else {
                    continuation.resume(returning: nil)
                    return
                }
                self.activeCommit = nil
                continuation.resume(returning: self.entries.values.map(\.event))
            }
        }
    }

    @MainActor
    func pending() async -> [Event] {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.entries.values.map(\.event)) }
        }
    }

    /// Reconciliation and finality are verified by the caller, not by this lane.
    @MainActor
    func resolve(_ token: UUID, scope: String) async -> Bool {
        let completion: (@MainActor @Sendable () -> Void)? = await withCheckedContinuation {
            continuation in
            queue.async {
                guard let entry = self.entries[token], entry.event.scope == scope else {
                    continuation.resume(returning: nil)
                    return
                }
                self.entries.removeValue(forKey: token)
                continuation.resume(returning: entry.completion)
            }
        }
        guard let completion else { return false }
        completion()
        return true
    }
}

/// Per-model account transactions; system Keychain and the ownership lock never run on MainActor.
@MainActor
struct FoundationAccountTransactions {
    let inspect: @MainActor () async throws -> FoundationAccountCredentialTransaction.Snapshot
    let prepareSignOut:
        @MainActor (
            FoundationSession, FoundationAccountCredentialTransaction.Snapshot,
            FoundationAccountCredentialTransaction.Preparation
        ) async throws -> FoundationSignOutIntentStore.Intent
    let finishCompletedSignOut:
        @MainActor (FoundationSignOutIntentStore.Intent) async throws -> Void
    let recordSignOut:
        @MainActor (
            FoundationSession, FoundationSignOutIntentStore.Intent,
            FoundationAccountCredentialTransaction.Snapshot
        ) async throws -> FoundationSignOutIntentStore.Intent

    static var system: Self {
        Self(
            inspect: {
                try await Task.detached { try FoundationAccountCredentialTransaction.inspect() }
                    .value
            },
            prepareSignOut: { session, snapshot, preparation in
                try await Task.detached {
                    try FoundationAccountCredentialTransaction.prepareSignOut(
                        session, expecting: snapshot, preparation: preparation)
                }.value
            },
            finishCompletedSignOut: { intent in
                try await Task.detached {
                    try FoundationAccountCredentialTransaction.finishCompletedSignOut(intent)
                }.value
            },
            recordSignOut: { session, intent, snapshot in
                try await Task.detached {
                    try FoundationAccountCredentialTransaction.recordCompletedSignOut(
                        session, intent: intent, expecting: snapshot)
                }.value
            })
    }
}

enum FoundationSignOutInspection: Sendable, Equatable {
    case absent, pending, unavailable, inUse
}

@MainActor
struct FoundationAppRuntimeIsolation {
    let storage: FoundationScopedAccountStorage
    let credentials: FoundationCredentials.Operations
    let load: FoundationJellyfinLibrary.Load
    let revoke: (FoundationSession) -> Task<Bool, Never>
    let diagnostic: @Sendable (String) -> Void
    let taskStarted: (Task<Void, Never>) -> Void
    let revocationStarted: (Task<Bool, Never>) -> Void
    var retention: FoundationAccountRetention? = nil
    var verifyInventoryFiles: FoundationDownloads.FileVerifier? = nil
    var leaseWaitStarted: (() -> Void)? = nil
    var backgroundReconcile: (@MainActor (String) async -> Bool)? = nil
    var emptyNativeSession:
        (
            @MainActor (
                String, @escaping @MainActor @Sendable () async -> Bool,
                @escaping @MainActor @Sendable () -> Void
            ) async -> FoundationNativeEmptySessionOutcome
        )? = nil
    var nativeRetirement: FoundationDownloads.NativeRetirement? = nil
    var useModelBackgroundRouting = false
    var inspectSignOutIntent: (@MainActor () async -> FoundationSignOutInspection)? = nil
    var prepareIsolatedCaches: (@MainActor () async -> Bool)? = nil
    var inspectionJoined: (() -> Void)? = nil
    var acquireAccountOwnership: (@MainActor () async throws -> FoundationAccountLifetimeLease?)? =
        nil
    var accountTransactions: FoundationAccountTransactions? = nil
    #if FOUNDATION_ISOLATED_TEST_HOST
        var coldNativeRetirement:
            (
                @MainActor (
                    FoundationNativeAllocationStore, UUID,
                    FoundationScopedAccountRemoval.ColdAllocatedCandidate,
                    @escaping @MainActor @Sendable () async -> Bool
                ) async -> Bool
            )? = nil
        var coldTerminalRetirement:
            (
                @MainActor (
                    FoundationNativeAllocationStore, UUID,
                    FoundationScopedAccountRemoval.ColdTerminalCandidate,
                    @escaping @MainActor @Sendable () async -> Bool
                ) async -> Bool
            )? = nil
    #endif
    let sessionLane = FoundationPlayer.SessionLane()
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

    private let isolation: FoundationAppRuntimeIsolation?
    private let prepareCaches: @MainActor () async -> Bool
    private let restoreAccount: (@MainActor (FoundationAppModel) -> Void)?
    private var startupTask: Task<Void, Never>?
    private var startupGeneration = 0
    private struct BackgroundDownloadEvents {
        let identity = UUID()
        var completions: [@MainActor () -> Void]
        var emptySessionQuiesced = false
        var observedNativeWork = false
        var replayAfterRouting = false
        var drained = false
        var reconciled = false
        var routing = false
        var admissionBlocked = false
        var signOutLaneToken: UUID?
        var signOutScope: String?
        var needsRouting: Bool { !reconciled || (!drained && !emptySessionQuiesced) }
    }
    private var backgroundDownloadEvents: [String: BackgroundDownloadEvents] = [:]
    private var backgroundDownloadTask: Task<Void, Never>?
    private var backgroundDownloadGeneration = 0
    private var backgroundRoutingFence: UUID?
    private var deferredBackgroundIdentifiers: [String] = []
    private var backgroundRoutingWaiter: (UUID, CheckedContinuation<Bool, Never>)?
    #if FOUNDATION_ISOLATED_TEST_HOST
        var isolatedBackgroundRoutingWaitStarted: (() -> Void)?
        var isolatedBackgroundDownloadTask: Task<Void, Never>? { backgroundDownloadTask }
        var isolatedColdPublicationFinished: ((String) -> Void)?
        enum IsolatedColdDiscoveryPhase { case willBegin, began, didRead }
        var isolatedColdDiscoveryPhase: (@MainActor (IsolatedColdDiscoveryPhase) async -> Void)?
        var isolatedQuiescentProofSelected: (@MainActor (Bool) async -> Void)?
        var isolatedQuiescentMetadataChecked: (@MainActor (Bool) async -> Void)?
        var isolatedColdFlightFinished: ((Bool) -> Void)?
        var isolatedColdStatusDelay: (@MainActor () async -> Void)?
        var isolatedBeforeColdCleanup: (@MainActor () async -> Void)?
        var isolatedColdPublicationCheckpoint:
            FoundationScopedAccountRemoval.ColdPublicationCheckpoint?
        func isolatedCancelColdNativeFlight() { coldNativeFlight?.task.cancel() }
    #endif
    #if DEBUG
        var backgroundRoutingSettled: ((String) -> Void)?
    #endif
    private var headlessBackgroundRecoveryInFlight = false
    private let backgroundDownloadRoot: URL?
    private let backgroundNativeRetirement: FoundationDownloads.NativeRetirement?
    private let credentialOperations: FoundationCredentials.Operations
    private let accountTransactions: FoundationAccountTransactions?
    private struct AccountAdmission: Sendable {
        let lease: FoundationAccountLifetimeLease?
        let ownershipAcquired: Bool
        let inspection: FoundationSignOutInspection
    }
    private let inspectSignOutIntent: @MainActor () async -> FoundationSignOutInspection
    private let acquireAccountOwnership:
        @MainActor () async throws -> FoundationAccountLifetimeLease?
    private var accountOwnership: FoundationAccountLifetimeLease?
    private var accountOwnershipAcquired = false
    private var signOutInspection: FoundationSignOutInspection?
    private var signOutInspectionTask: Task<AccountAdmission, Never>?
    private var signOutInspectionTaskID: UUID?
    private var pendingSignOutRecoveryTask: Task<Void, Never>?
    private enum ColdNativeCandidate: Sendable {
        case allocated(FoundationScopedAccountRemoval.ColdAllocatedCandidate)
        case terminal(FoundationScopedAccountRemoval.ColdTerminalCandidate)

        var identifier: String {
            switch self {
            case .allocated(let candidate): candidate.identifier
            case .terminal(let candidate): candidate.identifier
            }
        }
        var needsReconnection: Bool {
            switch self {
            case .allocated(let candidate): !candidate.manifestAlreadyPublished
            case .terminal(let candidate): !candidate.finalityProved
            }
        }
    }
    private struct ColdNativeFlight {
        let id: UUID
        let operation: UUID
        let scope: String
        let identifier: String
        let task: Task<Bool, Never>
    }
    private var coldNativeFlight: ColdNativeFlight?
    private var coldNativeStatusTask: Task<Void, Never>?
    private var coldNativeDiscoveryInProgress = false
    private var coldKnownAllocatedSessions: [String: UUID] = [:]
    private var coldPublishedSessions: [String: UUID] = [:]
    private var coldNativeDrains: [String: UUID] = [:]
    private var durableSignOutPreparation: Task<Void, Never>?
    private var durableSignOutFinalization: Task<Void, Never>?
    private var durableSignOutContext: DurableSignOutContext?
    private var pendingRecoveryIntent: FoundationSignOutIntentStore.Intent?
    private struct PendingRecoveryAfterRemoval {
        let scope: String
        let session: FoundationSession?
    }
    private var pendingRecoveryAfterRemoval: PendingRecoveryAfterRemoval?
    private var retryRecoveryAfterEvent = false
    private var lastSignedOutScope: String?
    private let signOutCommitLane = FoundationSignOutCommitLane()
    private var retryFinalizationAfterEvent = false
    private var credentialReadFailed = false
    private let accountRetention: FoundationAccountRetention
    private let credentialDefaults: UserDefaults
    private let publishAccount: ((FoundationSession, String) -> Void)?
    private var accountCleanupTask: Task<Void, Never>?
    private struct RetiredAccountCleanup {
        let id = UUID()
        let scope: String
        var pins = false
        var playback = false
        var selections = false
        var artwork = false
        var pages = false
        var downloads = false
        var widgets = false

        var complete: Bool {
            pins && playback && selections && artwork && pages && downloads && widgets
        }
    }
    private var retiredAccountCleanup: RetiredAccountCleanup?
    private var retiredActionDrain: Task<Void, Never>?
    private var retiredDownloadCleanupPending = false
    private var retiredDownloadOwner: FoundationDownloads?
    private var signOutCleanupFailures: [String] = []
    private var signOutServerResult: Bool?
    private var signOutPinsCleared = false
    private var signOutPlaybackCleared = false
    private var retiredDownloadRetry: Task<Void, Never>?
    private var signOutCleanupTask: Task<Void, Never>?
    private var cleanupStatusTask: Task<Void, Never>?
    private var cleanupStatusID: UUID?
    #if FOUNDATION_ISOLATED_TEST_HOST
        var isolatedActionDrainStarted: (() -> Void)?
        var isolatedBeforeRetainedArtworkDelivery: (@MainActor () async -> Void)?
        var isolatedRetainedArtworkDeliveryFinished: (@MainActor () -> Void)?
        var isolatedRetainedArtworkRefreshed: (@MainActor (FoundationCurrentArtwork) -> Void)?
        var isolatedCurrentRetainedArtworkIdentity: String? { currentRetainedArtworkIdentity }
        var isolatedSignOutPreparationTask: Task<Void, Never>? { durableSignOutPreparation }
        var isolatedAccountTransitionHeld: Bool { sameAccountCommitInProgress }
        var isolatedCacheRetryDeferred: Bool { deferredCachePreparationRetry }
        var isolatedSignOutCleanupTask: Task<Void, Never>? { signOutCleanupTask }
        var isolatedCleanupStatusTask: Task<Void, Never>? { cleanupStatusTask }
        var isolatedCleanupStatusDelay: (@MainActor () async -> Void)?
    #endif
    private var authenticationGeneration = 0
    private var sameAccountCommitInProgress = false
    private var deferredSignOut = false
    private var deferredReadinessInvalidation = false
    private var deferredCredentialUpgradeCancellation = false
    private var deferredCachePreparationRetry = false
    private var deferredCredentialRestore = false
    #if os(macOS)
        private var deferredMacSignIn = false
    #endif
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
        credentialOperations: FoundationCredentials.Operations? = nil,
        accountRetention: FoundationAccountRetention? = nil,
        credentialDefaults: UserDefaults = .standard,
        publishAccount: ((FoundationSession, String) -> Void)? = nil,
        playbackPreferences: FoundationPlaybackPreferences? = nil,
        backgroundDownloadRoot: URL? = nil,
        backgroundNativeRetirement: FoundationDownloads.NativeRetirement? = nil,
        isolation: FoundationAppRuntimeIsolation? = nil
    ) {
        self.isolation = isolation
        let widgetLocation: FoundationWidgetStore.Location
        if let isolation {
            widgetLocation = .directory(
                isolation.storage.playback.deletingLastPathComponent()
                    .appendingPathComponent("widgets", isDirectory: true))
        } else if credentialOperations != nil {
            widgetLocation = .disabled
        } else {
            widgetLocation = FoundationWidgetStore.systemLocation
        }
        if isolation != nil || credentialOperations != nil {
            widgetStorage = FoundationWidgetStorage(location: widgetLocation, reload: {})
        } else {
            widgetStorage = FoundationWidgetStorage(location: widgetLocation)
        }
        self.playbackPreferences =
            isolation.map { FoundationPlaybackPreferences(defaults: $0.storage.defaults) }
            ?? playbackPreferences ?? FoundationPlaybackPreferences()
        self.prepareCaches =
            isolation != nil
            ? isolation?.prepareIsolatedCaches ?? { true }
            : prepareCaches ?? {
                await FoundationDisposableCachePolicy.shared.prepare(
                    version: FoundationDisposableCachePolicy.currentVersion)
            }
        self.restoreAccount = restoreAccount
        self.credentialOperations = isolation?.credentials ?? credentialOperations ?? .system
        self.accountTransactions =
            isolation?.accountTransactions
            ?? (isolation == nil && credentialOperations == nil ? .system : nil)
        if let acquire = isolation?.acquireAccountOwnership {
            self.acquireAccountOwnership = acquire
        } else if isolation != nil || credentialOperations != nil {
            // Injected credentials belong to an explicitly isolated environment.
            self.acquireAccountOwnership = { nil }
        } else {
            self.acquireAccountOwnership = {
                try await FoundationAccountProcessOwnership.acquire()
            }
        }
        if let inspect = isolation?.inspectSignOutIntent {
            self.inspectSignOutIntent = inspect
        } else if isolation != nil || credentialOperations != nil {
            // Explicitly injected credentials belong to a test-owned environment.
            self.inspectSignOutIntent = { .absent }
        } else {
            self.inspectSignOutIntent = {
                await Task.detached(priority: .userInitiated) {
                    do {
                        return try FoundationSignOutIntentStore.load() == nil
                            ? FoundationSignOutInspection.absent : .pending
                    } catch {
                        return FoundationSignOutInspection.unavailable
                    }
                }.value
            }
        }
        self.accountRetention =
            isolation?.retention ?? isolation?.storage.retention ?? accountRetention ?? .system
        self.credentialDefaults = isolation?.storage.defaults ?? credentialDefaults
        self.publishAccount = publishAccount
        self.backgroundDownloadRoot = isolation?.storage.downloads ?? backgroundDownloadRoot
        self.backgroundNativeRetirement = isolation?.nativeRetirement ?? backgroundNativeRetirement
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
    let playbackPreferences: FoundationPlaybackPreferences
    private var policySubscriptions: Set<AnyCancellable> = []
    private var currentRetainedArtworkIdentity: String?
    private var currentArtworkLocalOnly = false
    @Published private(set) var isCleaningDownloads = false
    @Published private(set) var cleanupTakingLonger = false
    @Published private(set) var requiresSignIn = false
    #if os(macOS)
        @Published var settingsShowsSignIn = false

        func requireMacSignIn() {
            if sameAccountCommitInProgress {
                deferredMacSignIn = true
                return
            }
            player?.stop()
            requiresSignIn = true
            primaryGenres?.cancel()
            settingsShowsSignIn = true
        }
    #endif
    private var credentialErrorGeneration: UInt = 0
    @Published var credentialError: String? {
        didSet { credentialErrorGeneration &+= 1 }
    }
    private var signOutCleanupErrorGeneration: UInt = 0
    @Published private(set) var signOutCleanupError: String? {
        didSet { signOutCleanupErrorGeneration &+= 1 }
    }
    private var signOutNoticeGeneration: UInt = 0
    @Published var signOutNotice: String? {
        didSet { signOutNoticeGeneration &+= 1 }
    }
    private var playbackSessionSubscription: AnyCancellable?
    @Published private(set) var accountInspectionIssue: FoundationSignOutInspection?
    @Published private(set) var uncertainSignOutRequiresRestart = false
    @Published private(set) var isStartingDurableSignOut = false
    @Published private(set) var isFinalizingDurableSignOut = false
    @Published private(set) var isCheckingPendingSignOut = false
    @Published private(set) var isResumingPendingSignOut = false
    @Published private(set) var isColdNativeRecovering = false
    @Published private(set) var coldNativeTakingLonger = false
    @Published private(set) var isPreparingCaches = true
    @Published private(set) var cachesReady = false
    private var restored = false
    private var accountEpoch = 0
    private var nowPlaying: FoundationNowPlaying?
    private var mediaSession: MediaSession<FoundationNowPlaying>?
    private let widgetStorage: FoundationWidgetStorage
    private var widgetCollectionCommandID: UUID?
    private var widgetCollectionCancellation: AnyCancellable?
    private var widgetOwnerGeneration: UInt64 = 0
    private var widgetPlayback: FoundationWidgetPlayback?
    private var widgetRetirement: Task<Void, Never>?

    isolated deinit {
        startupTask?.cancel()
        coldNativeFlight?.task.cancel()
        coldNativeStatusTask?.cancel()
        accountCleanupTask?.cancel()
        cleanupStatusTask?.cancel()
        retireWidgetPresentation()
        handoff.invalidate()
        if let actions {
            let retirement = actions.invalidateAndDrain()
            isolation?.taskStarted(retirement)
        }
        _ = retireCatalogOwners()
        librarySelection?.invalidate()
        if let cache = library?.artworkCache {
            let task = Task { _ = await cache.invalidate(removeDisk: false) }
            isolation?.taskStarted(task)
        }
        if let pages = library?.catalogPageCache {
            let task = Task { _ = await pages.invalidate(removeDisk: false) }
            isolation?.taskStarted(task)
        }
        downloads?.invalidate()
        connectivity?.invalidate()
        nowPlaying?.invalidate()
        currentArtwork?.invalidate()
    }

    private func inspectAccountAdmission() async -> FoundationSignOutInspection {
        if let signOutInspection {
            switch signOutInspection {
            case .unavailable, .inUse: self.signOutInspection = nil
            case .absent, .pending: return signOutInspection
            }
        }
        let task: Task<AccountAdmission, Never>
        let taskID: UUID
        if let signOutInspectionTask, let currentID = signOutInspectionTaskID {
            isolation?.inspectionJoined?()
            task = signOutInspectionTask
            taskID = currentID
        } else {
            let acquire = acquireAccountOwnership
            let inspect = inspectSignOutIntent
            let alreadyOwned = accountOwnershipAcquired
            task = Task {
                var lease: FoundationAccountLifetimeLease?
                if !alreadyOwned {
                    do { lease = try await acquire() } catch FoundationAccountLifetimeLease
                        .LeaseError.busy
                    {
                        return AccountAdmission(
                            lease: nil, ownershipAcquired: false, inspection: .inUse)
                    } catch {
                        return AccountAdmission(
                            lease: nil, ownershipAcquired: false, inspection: .unavailable)
                    }
                }
                return AccountAdmission(
                    lease: lease, ownershipAcquired: true, inspection: await inspect())
            }
            taskID = UUID()
            signOutInspectionTask = task
            signOutInspectionTaskID = taskID
        }
        let result = await task.value
        guard signOutInspectionTaskID == taskID else {
            return await inspectAccountAdmission()
        }
        if let lease = result.lease { accountOwnership = lease }
        if result.ownershipAcquired { accountOwnershipAcquired = true }
        signOutInspection = result.inspection
        signOutInspectionTask = nil
        signOutInspectionTaskID = nil
        return result.inspection
    }

    var accountInspectionMessage: String? {
        if uncertainSignOutRequiresRestart {
            return
                "Sign-out status could not be verified. Restart VelaCanto and try again. If this continues, contact support."
        }
        return switch accountInspectionIssue {
        case .pending:
            "Sign-out didn’t finish. Try again or contact support for help with account cleanup."
        case .inUse:
            "Another VelaCanto process is using this account. Close it and try again."
        case .unavailable:
            "Account status could not be checked. Unlock your device and try again. If this continues, contact support."
        case .absent, nil: nil
        }
    }

    private func reportAccountAdmission(_ result: FoundationSignOutInspection) {
        switch result {
        case .absent: accountInspectionIssue = nil
        case .pending, .unavailable, .inUse:
            accountInspectionIssue = result
            if cachesReady { credentialError = accountInspectionMessage }
        }
    }

    func retryAccountInspection() {
        if let transactions = accountTransactions, pendingSignOutPreparation != nil {
            retrySignOutPreparation(transactions)
            return
        }
        guard !uncertainSignOutRequiresRestart else { return }
        if accountInspectionIssue == .pending, retiredDownloadCleanupPending {
            retryRetiredDownloadCleanup()
            return
        }
        if accountInspectionIssue == .pending, accountTransactions != nil {
            resumePendingSignOut()
            return
        }
        guard signOutInspectionTask == nil else { return }
        signOutInspection = nil
        accountInspectionIssue = nil
        retryCachePreparation()
    }

    private var coldSignOutHasNoOwner: Bool {
        library == nil && player == nil && downloads == nil && retiredDownloadOwner == nil
            && retiredAccountCleanup == nil && !retiredDownloadCleanupPending
            && accountCleanupTask == nil
            && !headlessBackgroundRecoveryInFlight && !sameAccountCommitInProgress
    }

    private var coldSignOutRecoveryIsIdle: Bool {
        coldSignOutHasNoOwner && coldNativeFlight == nil && !coldNativeDiscoveryInProgress
            && backgroundDownloadTask == nil && backgroundDownloadEvents.isEmpty
    }

    private func resumePendingSignOut() {
        guard pendingSignOutRecoveryTask == nil, let transactions = accountTransactions,
            accountOwnershipAcquired, accountInspectionIssue == .pending,
            coldSignOutHasNoOwner, coldNativeFlight == nil
        else { return }
        isCheckingPendingSignOut = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isCheckingPendingSignOut = false
                self.isResumingPendingSignOut = false
                self.pendingSignOutRecoveryTask = nil
                if self.retryRecoveryAfterEvent {
                    self.retryRecoveryAfterEvent = false
                    self.resumePendingSignOut()
                }
            }
            do {
                if let completed = self.pendingRecoveryAfterRemoval {
                    let events = await self.signOutCommitLane.pending()
                    guard events.isEmpty, self.coldSignOutRecoveryIsIdle else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                    self.pendingRecoveryAfterRemoval = nil
                    self.pendingRecoveryIntent = nil
                    self.coldPublishedSessions.removeAll()
                    self.coldKnownAllocatedSessions.removeAll()
                    self.coldNativeDrains.removeAll()
                    self.completeRecoveredSignOut(
                        session: completed.session, scope: completed.scope)
                    return
                }
                let snapshot = try await transactions.inspect()
                guard let intent = snapshot.intent, self.coldSignOutHasNoOwner else {
                    throw FoundationAccountCredentialTransaction.TransactionError.changed
                }
                self.pendingRecoveryIntent = intent
                self.registerOutstandingSignOutObligations()
                if intent.cleanupComplete != true {
                    guard let session = snapshot.session,
                        Self.sourceScope(for: session) == intent.scope
                    else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                    let digest = FoundationArtworkCache.digest(intent.scope)
                    let root = self.isolation?.storage.downloads ?? FoundationDownloadStorage.base
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        await self.isolatedColdDiscoveryPhase?(.willBegin)
                    #endif
                    self.coldNativeDiscoveryInProgress = true
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        await self.isolatedColdDiscoveryPhase?(.began)
                    #endif
                    let allocated = await FoundationScopedAccountRemoval.coldAllocatedCandidates(
                        root: root, scope: digest, operation: intent.operation)
                    let terminals = await FoundationScopedAccountRemoval.coldTerminalCandidates(
                        root: root, scope: digest, operation: intent.operation)
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        await self.isolatedColdDiscoveryPhase?(.didRead)
                    #endif
                    self.coldNativeDiscoveryInProgress = false
                    // Discovery's busy fence may have refused an in-flight observer.
                    // Publish this transition even if its route is still returning;
                    // the deferred replay validates every proof and snapshot again.
                    self.retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
                    guard let allocated, let terminals,
                        self.pendingRecoveryIntent == intent, self.coldSignOutHasNoOwner
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    let candidates =
                        terminals.map(ColdNativeCandidate.terminal)
                        + allocated.map(ColdNativeCandidate.allocated)
                    for candidate in candidates {
                        self.coldKnownAllocatedSessions[candidate.identifier] = intent.operation
                    }
                    if let candidate = candidates.first(where: {
                        self.coldPublishedSessions[$0.identifier] != intent.operation
                    }) {
                        self.startColdNativeRetirement(
                            candidate, root: root, digest: digest,
                            intent: intent, snapshot: snapshot)
                        self.retryPendingBackgroundDownloadEvents()
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                }
                self.retryPendingBackgroundDownloadEvents()
                guard self.coldSignOutRecoveryIsIdle else {
                    throw FoundationAccountCredentialTransaction.TransactionError.pending
                }
                let completed: FoundationSignOutIntentStore.Intent
                if intent.cleanupComplete == true {
                    self.isResumingPendingSignOut = true
                    guard await self.widgetStorage.clear(scope: intent.scope),
                        self.coldSignOutRecoveryIsIdle
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    completed = intent
                } else {
                    guard let session = snapshot.session,
                        Self.sourceScope(for: session) == intent.scope
                    else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                    @MainActor func current() async throws {
                        try Task.checkCancellation()
                        let fresh = try await transactions.inspect()
                        guard self.coldSignOutRecoveryIsIdle,
                            Self.sourceScope(for: session) == intent.scope,
                            fresh.intent == intent,
                            fresh.accessGroup == snapshot.accessGroup,
                            fresh.credentialGeneration == snapshot.credentialGeneration,
                            let active = fresh.session,
                            active.serverURL == session.serverURL, active.userID == session.userID,
                            active.deviceID == session.deviceID,
                            active.accessToken == session.accessToken
                        else {
                            throw FoundationAccountCredentialTransaction.TransactionError.changed
                        }
                    }
                    try await current()
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        await self.isolatedBeforeColdCleanup?()
                        try await current()
                    #endif
                    self.isResumingPendingSignOut = true
                    let storage = self.isolation?.storage
                    guard
                        FoundationPinStorage.removeStoredPins(
                            for: intent.scope, defaults: storage?.defaults ?? .standard)
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    try await current()
                    guard await self.widgetStorage.clear(scope: intent.scope) else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                    try await current()
                    guard
                        await FoundationPlaybackSessionStore.clearScope(
                            intent.scope,
                            root: storage?.playback ?? FoundationPlaybackSessionStore.defaultRoot)
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    try await current()
                    guard
                        await FoundationMusicLibraryStore.clearScope(
                            intent.scope,
                            root: storage?.selections ?? FoundationMusicLibraryStore.defaultRoot)
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    let digest = FoundationArtworkCache.digest(intent.scope)
                    try await current()
                    guard
                        await FoundationArtworkCache.clearStoredScope(
                            digest, root: storage?.artwork)
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    try await current()
                    guard
                        await FoundationCatalogPageCache.clearStoredScope(
                            digest, root: storage?.pages)
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    try await current()
                    let root = storage?.downloads ?? FoundationDownloadStorage.base
                    guard
                        let candidates =
                            await FoundationScopedAccountRemoval.coldAllocatedCandidates(
                                root: root, scope: digest, operation: intent.operation),
                        let terminals = await FoundationScopedAccountRemoval.coldTerminalCandidates(
                            root: root, scope: digest, operation: intent.operation),
                        candidates.allSatisfy({
                            self.coldPublishedSessions[$0.identifier] == intent.operation
                        }),
                        terminals.allSatisfy({
                            $0.finalityProved
                                && self.coldPublishedSessions[$0.identifier] == intent.operation
                        })
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                    let authorized = Dictionary(
                        uniqueKeysWithValues: candidates.map {
                            (
                                $0.identifier,
                                FoundationScopedAccountRemoval.AuthorizedAllocated(
                                    trackID: $0.trackID, package: $0.package)
                            )
                        })
                    let removal = await FoundationScopedAccountRemoval.removeNoFactoryAsync(
                        root: root, scope: digest, authorizedAllocatedSessions: authorized,
                        authorizedTerminalSessions: Set(terminals.map(\.identifier)))
                    guard removal.removed else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                    try await current()
                    let recordToken = try await self.signOutCommitLane.beginCommit()
                    do {
                        completed = try await transactions.recordSignOut(session, intent, snapshot)
                        self.pendingRecoveryIntent = completed
                        self.retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
                    } catch {
                        _ = await self.signOutCommitLane.endCommit(recordToken)
                        throw error
                    }
                    guard let events = await self.signOutCommitLane.endCommit(recordToken),
                        events.isEmpty, self.backgroundDownloadEvents.isEmpty
                    else {
                        throw FoundationAccountCredentialTransaction.TransactionError.pending
                    }
                }
                let removeToken = try await self.signOutCommitLane.beginCommit()
                do {
                    try await transactions.finishCompletedSignOut(completed)
                    self.lastSignedOutScope = completed.scope
                    self.retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
                    self.pendingRecoveryAfterRemoval = PendingRecoveryAfterRemoval(
                        scope: completed.scope, session: snapshot.session)
                } catch {
                    _ = await self.signOutCommitLane.endCommit(removeToken)
                    throw error
                }
                guard let events = await self.signOutCommitLane.endCommit(removeToken),
                    events.isEmpty, self.backgroundDownloadEvents.isEmpty
                else {
                    throw FoundationAccountCredentialTransaction.TransactionError.pending
                }
                self.pendingRecoveryAfterRemoval = nil
                self.pendingRecoveryIntent = nil
                self.coldPublishedSessions.removeAll()
                self.coldKnownAllocatedSessions.removeAll()
                self.coldNativeDrains.removeAll()
                self.completeRecoveredSignOut(session: snapshot.session, scope: completed.scope)
            } catch {
                self.accountInspectionIssue = .pending
            }
        }
        pendingSignOutRecoveryTask = task
        isolation?.taskStarted(task)
    }

    private func startColdNativeRetirement(
        _ candidate: ColdNativeCandidate,
        root: URL, digest: String, intent: FoundationSignOutIntentStore.Intent,
        snapshot: FoundationAccountCredentialTransaction.Snapshot
    ) {
        guard coldNativeFlight == nil, pendingRecoveryIntent == intent else { return }
        let flightID = UUID()
        let directory = root.appendingPathComponent(digest, isDirectory: true)
        let store = FoundationNativeAllocationStore(
            directory: directory, sessionIdentifier: candidate.identifier)
        let task = Task { [weak self] in
            guard let self else { return false }
            var succeeded = false
            defer {
                if self.coldNativeFlight?.id == flightID {
                    self.coldNativeFlight = nil
                    self.coldNativeStatusTask?.cancel()
                    self.coldNativeStatusTask = nil
                    self.isColdNativeRecovering = false
                    self.coldNativeTakingLonger = false
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        self.isolatedColdFlightFinished?(succeeded)
                    #endif
                    if succeeded {
                        self.coldPublishedSessions[candidate.identifier] = intent.operation
                        self.retryPendingBackgroundDownloadEvents(
                            identifiers: [candidate.identifier], afterCurrentRouting: true)
                        if self.pendingSignOutRecoveryTask != nil {
                            self.retryRecoveryAfterEvent = true
                        } else {
                            self.resumePendingSignOut()
                        }
                    }
                }
            }
            let ownsFlight: @MainActor @Sendable () -> Bool = {
                !Task.isCancelled && self.accountOwnershipAcquired
                    && self.pendingRecoveryIntent == intent && self.coldNativeFlight?.id == flightID
                    && self.library == nil && self.downloads == nil
                    && self.retiredDownloadOwner == nil
                    && self.retiredAccountCleanup == nil && !self.retiredDownloadCleanupPending
            }
            let markerUnchanged: @MainActor @Sendable () async -> Bool = {
                guard ownsFlight(), let transactions = self.accountTransactions,
                    let fresh = try? await transactions.inspect(), ownsFlight(),
                    fresh.intent == intent, fresh.accessGroup == snapshot.accessGroup,
                    fresh.credentialGeneration == snapshot.credentialGeneration,
                    let old = snapshot.session, let current = fresh.session
                else { return false }
                return Self.sourceScope(for: current) == intent.scope
                    && current.serverURL == old.serverURL && current.userID == old.userID
                    && current.deviceID == old.deviceID && current.accessToken == old.accessToken
            }
            guard await markerUnchanged() else { return false }
            if candidate.needsReconnection {
                let retireProduction: @MainActor () async -> Bool = {
                    await FoundationNativeDownloadTransport.retireInterruptedSessions(
                        [candidate.identifier], directory: directory, mayRetire: ownsFlight,
                        onFinality: { store in
                            guard await markerUnchanged() else {
                                throw FoundationDownloadError.cleanup
                            }
                            switch candidate {
                            case .allocated(let value):
                                try store.recordColdFinality(
                                    operation: intent.operation,
                                    expectedTrackID: value.trackID, expectedPackage: value.package)
                            case .terminal:
                                try store.recordColdTerminalFinality(operation: intent.operation)
                            }
                        }
                    ).contains(candidate.identifier)
                }
                let retired: Bool
                #if FOUNDATION_ISOLATED_TEST_HOST
                    if let isolation = self.isolation {
                        switch candidate {
                        case .allocated(let value):
                            retired =
                                await isolation.coldNativeRetirement?(
                                    store, intent.operation, value, markerUnchanged) ?? false
                        case .terminal(let value):
                            retired =
                                await isolation.coldTerminalRetirement?(
                                    store, intent.operation, value, markerUnchanged) ?? false
                        }
                    } else {
                        retired = await retireProduction()
                    }
                #else
                    retired = await retireProduction()
                #endif
                guard retired, await markerUnchanged() else { return false }
            }
            #if FOUNDATION_ISOLATED_TEST_HOST
                let checkpoint = self.isolatedColdPublicationCheckpoint
            #else
                let checkpoint: FoundationScopedAccountRemoval.ColdPublicationCheckpoint? = nil
            #endif
            guard await markerUnchanged() else { return false }
            let published: Bool
            switch candidate {
            case .allocated(let value):
                published = await FoundationScopedAccountRemoval.publishColdAllocatedRetirement(
                    root: root, scope: digest, operation: intent.operation, candidate: value,
                    checkpoint: checkpoint)
            case .terminal(let value):
                published = await FoundationScopedAccountRemoval.publishColdTerminalRetirement(
                    root: root, scope: digest, operation: intent.operation, candidate: value,
                    checkpoint: checkpoint)
            }
            guard published, ownsFlight() else { return false }
            #if FOUNDATION_ISOLATED_TEST_HOST
                self.isolatedColdPublicationFinished?(candidate.identifier)
            #endif
            succeeded = true
            return true
        }
        coldNativeFlight = .init(
            id: flightID, operation: intent.operation, scope: intent.scope,
            identifier: candidate.identifier, task: task)
        isColdNativeRecovering = true
        coldNativeTakingLonger = false
        #if FOUNDATION_ISOLATED_TEST_HOST
            let delay = isolatedColdStatusDelay
        #endif
        let status = Task { [weak self] in
            #if FOUNDATION_ISOLATED_TEST_HOST
                if let delay { await delay() } else { try? await Task.sleep(for: .seconds(10)) }
            #else
                try? await Task.sleep(for: .seconds(10))
            #endif
            guard !Task.isCancelled, let self, self.coldNativeFlight?.id == flightID else { return }
            self.coldNativeTakingLonger = true
        }
        coldNativeStatusTask = status
        if let isolation {
            isolation.taskStarted(Task { _ = await task.value })
            isolation.taskStarted(status)
        }
    }

    private func completeRecoveredSignOut(session: FoundationSession?, scope: String) {
        lastSignedOutScope = scope
        self.signOutInspection = nil
        self.accountInspectionIssue = nil
        self.retryCachePreparation()
        if let session {
            let revoke: Task<Bool, Never>
            if let isolation = self.isolation {
                revoke = isolation.revoke(session)
                isolation.revocationStarted(revoke)
            } else {
                let deviceName = FoundationClientDeviceName.current
                revoke = Task.detached(priority: .userInitiated) {
                    let adapter = FoundationJellyfinLibrary(
                        session: session, deviceName: deviceName,
                        load: FoundationJellyfinLibrary.signOutLoad)
                    do {
                        try await adapter.endSession()
                        return true
                    } catch { return false }
                }
            }
            let expectedEpoch = self.accountEpoch
            let notice = Task { [weak self] in
                let confirmed = await revoke.value
                guard let self, self.accountEpoch == expectedEpoch, self.library == nil else {
                    return
                }
                self.signOutNotice =
                    confirmed
                    ? "Signed out on this device. Server sign-out confirmed."
                    : "Signed out on this device. Server sign-out could not be confirmed."
            }
            self.isolation?.taskStarted(notice)
        } else {
            self.signOutNotice =
                "Signed out on this device. Server sign-out could not be confirmed."
        }
    }

    /// UIKit events do not authorize a normal account/catalog bootstrap. Completion
    /// requires both the native event drain and this account's durable reconciliation.
    func receiveBackgroundDownloadEvents(
        _ identifier: String, completionHandler: @escaping @MainActor () -> Void
    ) {
        if isolation != nil, isolation?.backgroundReconcile == nil,
            isolation?.useModelBackgroundRouting != true
        {
            completionHandler()
            return
        }
        if backgroundDownloadEvents[identifier] != nil {
            backgroundDownloadEvents[identifier]?.completions.append(completionHandler)
            return
        }
        backgroundDownloadEvents[identifier] = .init(completions: [completionHandler])
        registerSignOutObligation(identifier)
        if backgroundRoutingFence != nil {
            deferredBackgroundIdentifiers.append(identifier)
            cancelBackgroundRoutingWait()
            return
        }
        startBackgroundDownloadRouting(identifier)
    }

    private func registerSignOutObligation(_ identifier: String) {
        guard var pending = backgroundDownloadEvents[identifier], pending.signOutLaneToken == nil
        else { return }
        let candidates = [
            durableSignOutContext?.intent.scope, pendingRecoveryIntent?.scope, lastSignedOutScope,
        ]
        guard
            let scope = candidates.compactMap({ $0 }).first(where: { scope in
                let directory = FoundationDownloadStorage.directory(
                    scope: scope, root: backgroundDownloadRoot)
                return FoundationNativeAllocationStore(
                    directory: directory, sessionIdentifier: identifier
                ).validSession
            })
        else { return }
        let token = signOutCommitLane.register(identifier: identifier, scope: scope) {
            [weak self] in
            guard let self, var event = self.backgroundDownloadEvents[identifier] else { return }
            event.signOutLaneToken = nil
            event.signOutScope = nil
            self.backgroundDownloadEvents[identifier] = event
            self.completeBackgroundDownloadEventsIfReady(identifier)
        }
        pending.signOutLaneToken = token
        pending.signOutScope = scope
        backgroundDownloadEvents[identifier] = pending
    }

    private func registerOutstandingSignOutObligations() {
        for identifier in Array(backgroundDownloadEvents.keys) {
            registerSignOutObligation(identifier)
        }
    }

    private func startBackgroundDownloadRouting(_ identifier: String) {
        guard var pending = backgroundDownloadEvents[identifier], !pending.routing,
            pending.needsRouting
        else { return }
        pending.routing = true
        backgroundDownloadEvents[identifier] = pending
        let previous = backgroundDownloadTask
        let existingStartup = startupTask
        let epoch = accountEpoch
        let generation = startupGeneration
        backgroundDownloadGeneration += 1
        let recovery = backgroundDownloadGeneration
        backgroundDownloadTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let admission = await self.inspectAccountAdmission()
            let isSignOutEvent = self.backgroundDownloadEvents[identifier]?.signOutLaneToken != nil
            let eventScope = self.backgroundDownloadEvents[identifier]?.signOutScope
            let exactSignOutEvent: Bool
            if isSignOutEvent, let eventScope {
                let directory = FoundationDownloadStorage.directory(
                    scope: eventScope, root: self.backgroundDownloadRoot)
                exactSignOutEvent =
                    FoundationNativeAllocationStore(
                        directory: directory, sessionIdentifier: identifier
                    ).validSession
            } else {
                exactSignOutEvent = false
            }
            guard (isSignOutEvent && exactSignOutEvent) || (!isSignOutEvent && admission == .absent)
            else {
                self.reportAccountAdmission(admission)
                if self.backgroundDownloadGeneration == recovery {
                    self.backgroundDownloadTask = nil
                }
                if var pending = self.backgroundDownloadEvents[identifier] {
                    pending.routing = false
                    pending.admissionBlocked = true
                    self.backgroundDownloadEvents[identifier] = pending
                }
                self.finishBackgroundRoutingWaitIfIdle()
                if !isSignOutEvent, self.pendingRecoveryIntent != nil {
                    self.registerSignOutObligation(identifier)
                    if self.backgroundDownloadEvents[identifier]?.signOutLaneToken != nil {
                        self.retryPendingBackgroundDownloadEvents()
                    }
                }
                return
            }
            if var pending = self.backgroundDownloadEvents[identifier] {
                pending.admissionBlocked = false
                self.backgroundDownloadEvents[identifier] = pending
            }
            // If foreground startup was already authorized, reuse its resulting owner.
            // Startup created AFTER this task instead waits for this headless work.
            if !isSignOutEvent { await existingStartup?.value }
            defer {
                var replay = false
                if var pending = self.backgroundDownloadEvents[identifier] {
                    pending.routing = false
                    replay = pending.replayAfterRouting && pending.needsRouting
                    pending.replayAfterRouting = false
                    self.backgroundDownloadEvents[identifier] = pending
                }
                if self.backgroundDownloadGeneration == recovery {
                    self.backgroundDownloadTask = nil
                }
                self.finishBackgroundRoutingWaitIfIdle()
                #if DEBUG
                    self.backgroundRoutingSettled?(identifier)
                #endif
                if replay { self.retryPendingBackgroundDownloadEvents(identifiers: [identifier]) }
                if self.deferredCredentialRestore, self.backgroundDownloadTask == nil,
                    !self.headlessBackgroundRecoveryInFlight, !self.sameAccountCommitInProgress
                {
                    self.deferredCredentialRestore = false
                    self.restoreCredentials()
                }
                if self.downloads != nil || self.retiredDownloadOwner != nil,
                    self.accountEpoch != epoch || self.startupGeneration != generation
                {
                    self.retryPendingBackgroundDownloadEvents()
                }
            }
            var admitted: Bool
            var emptySessionQuiesced = false
            var previouslyDrained = false
            if let synthetic = self.isolation?.backgroundReconcile {
                admitted = await synthetic(identifier)
            } else if isSignOutEvent, let retired = self.retiredDownloadOwner,
                let retirement = self.retiredAccountCleanup?.id
            {
                let reconciled = await retired.reconcileBackgroundSession(
                    identifier, allowRetiredOwner: true)
                admitted =
                    reconciled && self.retiredDownloadOwner === retired
                    && self.retiredAccountCleanup?.id == retirement && self.library == nil
                previouslyDrained = retired.backgroundSessionHasDrained(identifier)
            } else if isSignOutEvent, let intent = self.pendingRecoveryIntent,
                self.coldSignOutHasNoOwner
            {
                if let flight = self.coldNativeFlight,
                    flight.operation == intent.operation, flight.scope == intent.scope,
                    flight.identifier == identifier
                {
                    admitted = await flight.task.value
                    previouslyDrained = self.coldNativeDrains[identifier] == intent.operation
                } else if self.coldPublishedSessions[identifier] == intent.operation {
                    admitted = true
                    previouslyDrained = self.coldNativeDrains[identifier] == intent.operation
                } else if self.coldNativeFlight != nil || self.coldNativeDiscoveryInProgress
                    || self.coldKnownAllocatedSessions[identifier] == intent.operation
                {
                    admitted = false
                } else {
                    let operation = intent.operation
                    let scope = intent.scope
                    self.headlessBackgroundRecoveryInFlight = true
                    admitted = await FoundationDownloads.reconcileBackgroundSession(
                        identifier, scope: scope, root: self.backgroundDownloadRoot,
                        retirement: self.backgroundNativeRetirement,
                        mayCommit: { [weak self] in
                            guard let self else { return false }
                            return self.pendingRecoveryIntent?.operation == operation
                                && self.pendingRecoveryIntent?.scope == scope
                                && self.library == nil && self.downloads == nil
                        })
                    self.headlessBackgroundRecoveryInFlight = false
                }
            } else if isSignOutEvent {
                admitted = false
            } else if let downloads = self.downloads,
                downloads.ownsNativeSessionInCurrentProcess(identifier)
            {
                admitted = await downloads.reconcileBackgroundSession(identifier)
                previouslyDrained = downloads.backgroundSessionHasDrained(identifier)
            } else if self.downloads != nil {
                admitted = false
            } else if let retired = self.retiredDownloadOwner,
                let retirement = self.retiredAccountCleanup?.id
            {
                let reconciled = await retired.reconcileBackgroundSession(
                    identifier, allowRetiredOwner: true)
                admitted =
                    reconciled && self.retiredDownloadOwner === retired
                    && self.retiredAccountCleanup?.id == retirement && self.library == nil
                previouslyDrained = retired.backgroundSessionHasDrained(identifier)
            } else if self.isolation == nil || self.isolation?.nativeRetirement != nil,
                self.accountEpoch == epoch,
                self.startupGeneration == generation,
                let session = try? FoundationCredentials.load(operations: self.credentialOperations)
            {
                let scope = Self.sourceScope(for: session)
                self.headlessBackgroundRecoveryInFlight = true
                admitted = await FoundationDownloads.reconcileBackgroundSession(
                    identifier, scope: scope, root: self.backgroundDownloadRoot,
                    retirement: self.backgroundNativeRetirement,
                    mayCommit: { [weak self] in
                        self?.accountEpoch == epoch && self?.startupGeneration == generation
                    })
                self.headlessBackgroundRecoveryInFlight = false
            } else {
                admitted = false
            }
            if !admitted || !previouslyDrained, self.isolation?.backgroundReconcile == nil {
                emptySessionQuiesced = await self.reconcileQuiescentNativeSession(identifier)
                admitted = admitted || emptySessionQuiesced
            }
            guard admitted, var pending = self.backgroundDownloadEvents[identifier] else { return }
            pending.reconciled = true
            pending.emptySessionQuiesced = emptySessionQuiesced
            if previouslyDrained { pending.drained = true }
            self.backgroundDownloadEvents[identifier] = pending
            self.completeBackgroundDownloadEventsIfReady(identifier)
        }
        if let backgroundDownloadTask { isolation?.taskStarted(backgroundDownloadTask) }
    }

    /// Empty-session quiescence is distinct from didFinishEvents. The native
    /// observer has no storage or task mutation authority. Account/scope identity
    /// and every existing owner remain independently fenced before and after it.
    private func reconcileQuiescentNativeSession(_ identifier: String) async -> Bool {
        guard
            FoundationNativeAllocationStore.directoryScope(forSessionIdentifier: identifier) != nil,
            accountOwnershipAcquired, let transactions = accountTransactions,
            let event = backgroundDownloadEvents[identifier],
            !event.observedNativeWork, !Task.isCancelled,
            coldNativeFlight?.identifier != identifier,
            let snapshot = try? await transactions.inspect()
        else { return false }
        let identity = event.identity
        let epoch = accountEpoch
        let startup = startupGeneration
        let active = downloads
        let retired = retiredDownloadOwner
        let activePlayer = player
        let cleanupID = retiredAccountCleanup?.id
        let durableOperation = durableSignOutContext?.intent.operation
        let recoveryOperation = pendingRecoveryIntent?.operation
        let flightID = coldNativeFlight?.id
        let operation =
            snapshot.intent?.operation
            ?? (durableSignOutContext?.markerRemoved == true ? durableOperation : nil)
        let root = backgroundDownloadRoot ?? FoundationDownloadStorage.base
        let representedOwner = active ?? retired
        let represented = representedOwner?.completedNativeSessionForObservation(
            identifier, allowRetiredOwner: active == nil && retired != nil)
        let unrepresented =
            active?.allowsUnrepresentedSessionObservation(identifier, operation: operation) != false
            && retired?.allowsUnrepresentedSessionObservation(identifier, operation: operation)
                != false
        let representedSavedAccount =
            active == nil && retired == nil && snapshot.intent == nil
            && snapshot.session.map { Self.sourceScope(for: $0) }.map {
                FoundationDownloadStorage.directory(scope: $0, root: root).lastPathComponent
                    == FoundationNativeAllocationStore.directoryScope(
                        forSessionIdentifier: identifier)
            } == true
        let representedAllowed: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, !self.coldNativeDiscoveryInProgress, self.coldNativeFlight == nil,
                !self.headlessBackgroundRecoveryInFlight
            else { return false }
            if let owner = representedOwner, let represented {
                guard
                    let latest = owner.completedNativeSessionForObservation(
                        identifier, allowRetiredOwner: active == nil && retired != nil),
                    latest.trackID == represented.trackID,
                    latest.package.sessionIdentifier == represented.package.sessionIdentifier,
                    latest.package.nativeURL == represented.package.nativeURL,
                    latest.package.bookmark == represented.package.bookmark,
                    latest.package.namespaceBookmark == represented.package.namespaceBookmark
                else { return false }
                if active != nil {
                    return snapshot.intent == nil && recoveryOperation == nil
                        && durableOperation == nil
                        && snapshot.session.map { Self.sourceScope(for: $0) }
                            == self.library?.catalogAccountIdentity
                }
                return operation != nil && operation == (durableOperation ?? recoveryOperation)
            }
            return representedSavedAccount && self.pendingRecoveryIntent == nil
                && self.durableSignOutContext == nil
        }
        let retiredProofAllowed: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, let operation, snapshot.intent?.operation == operation,
                operation == (durableOperation ?? recoveryOperation),
                active == nil, !self.coldNativeDiscoveryInProgress,
                self.coldNativeFlight == nil, !self.headlessBackgroundRecoveryInFlight,
                retired?.allowsRetiredSessionObservation(identifier) != false,
                snapshot.intent.map({
                    FoundationDownloadStorage.directory(scope: $0.scope, root: root)
                        .lastPathComponent
                })
                    == FoundationNativeAllocationStore.directoryScope(
                        forSessionIdentifier: identifier)
            else { return false }
            return true
        }
        let retirementProof =
            retiredProofAllowed()
            ? await FoundationScopedAccountRemoval.nativeSessionMetadataProof(
                root: root, identifier: identifier, expected: nil, retirementOperation: operation)
            : nil
        // Unknown empty identifiers and exact saved completed allocations have
        // separate metadata authority; neither grants task retirement authority.
        let completedProof: Data?
        if retirementProof != nil {
            completedProof = nil
        } else if represented != nil || representedSavedAccount {
            guard representedAllowed() else { return false }
            completedProof = await FoundationScopedAccountRemoval.nativeSessionMetadataProof(
                root: root, identifier: identifier, expected: represented)
            guard completedProof != nil || unrepresented else { return false }
        } else {
            guard unrepresented else { return false }
            completedProof = nil
        }
        #if FOUNDATION_ISOLATED_TEST_HOST
            await isolatedQuiescentProofSelected?(retirementProof != nil)
        #endif
        let stillOwned: @MainActor @Sendable () -> Bool = { [weak self] in
            guard let self, !Task.isCancelled, self.accountOwnershipAcquired,
                self.accountEpoch == epoch, self.startupGeneration == startup,
                self.downloads === active, self.retiredDownloadOwner === retired,
                self.player === activePlayer, self.retiredAccountCleanup?.id == cleanupID,
                self.durableSignOutContext?.intent.operation == durableOperation,
                self.pendingRecoveryIntent?.operation == recoveryOperation,
                self.coldNativeFlight?.id == flightID,
                self.backgroundDownloadEvents[identifier]?.identity == identity,
                self.coldNativeFlight?.identifier != identifier
            else { return false }
            if retirementProof != nil { return retiredProofAllowed() }
            if completedProof != nil { return representedAllowed() }
            return active?.allowsUnrepresentedSessionObservation(identifier, operation: operation)
                != false
                && retired?.allowsUnrepresentedSessionObservation(identifier, operation: operation)
                    != false
        }
        let current: @MainActor @Sendable () async -> Bool = {
            guard stillOwned() else { return false }
            let metadataMatches: Bool
            if let retirementProof {
                metadataMatches =
                    await FoundationScopedAccountRemoval.nativeSessionMetadataProof(
                        root: root, identifier: identifier, expected: nil,
                        retirementOperation: operation) == retirementProof
            } else if let completedProof {
                metadataMatches =
                    await FoundationScopedAccountRemoval.nativeSessionMetadataProof(
                        root: root, identifier: identifier, expected: represented) == completedProof
            } else {
                metadataMatches = await FoundationScopedAccountRemoval.nativeSessionIsUnrepresented(
                    root: root, identifier: identifier)
            }
            #if FOUNDATION_ISOLATED_TEST_HOST
                await self.isolatedQuiescentMetadataChecked?(metadataMatches)
            #endif
            guard metadataMatches,
                stillOwned(), let fresh = try? await transactions.inspect(), stillOwned(),
                Self.sameAccountSnapshot(snapshot, fresh)
            else { return false }
            return true
        }
        guard await current() else { return false }
        // Observer-local didFinishEvents is provisional. Its evidence reducer
        // joins that delivery with final invalidation, and current() must still
        // validate the metadata/account snapshot before quiescence is published.
        // Only the original owned transport path may publish pending.drained.
        let drained: @MainActor @Sendable () -> Void = {}
        let observed: FoundationNativeEmptySessionOutcome
        if let isolation {
            observed =
                await isolation.emptyNativeSession?(identifier, current, drained) ?? .unavailable
        } else {
            observed = await FoundationNativeDownloadTransport.observeUnrepresentedEmptySession(
                identifier, drained: drained)
        }
        // Native work is a fact about this exact event/identifier, even when
        // account identity changed or its waiter was cancelled meanwhile. Do not
        // forget it by starting a fresh empty observer on publication replay.
        if observed == .observedNativeWork {
            if backgroundDownloadEvents[identifier]?.identity == identity {
                backgroundDownloadEvents[identifier]?.observedNativeWork = true
            }
            return false
        }
        guard observed == .quiescent else { return false }
        return await current()
    }

    private static func sameAccountSnapshot(
        _ expected: FoundationAccountCredentialTransaction.Snapshot,
        _ current: FoundationAccountCredentialTransaction.Snapshot
    ) -> Bool {
        guard expected.intent == current.intent, expected.accessGroup == current.accessGroup,
            expected.credentialGeneration == current.credentialGeneration
        else { return false }
        switch (expected.session, current.session) {
        case (nil, nil): return true
        case (.some(let first), .some(let second)):
            return first.serverURL == second.serverURL && first.userID == second.userID
                && first.deviceID == second.deviceID && first.accessToken == second.accessToken
        default: return false
        }
    }

    private func retryPendingBackgroundDownloadEvents(
        admissionBlockedOnly: Bool = false, identifiers: Set<String>? = nil,
        afterCurrentRouting: Bool = false
    ) {
        for (identifier, pending) in backgroundDownloadEvents
        where pending.needsRouting
            && (!admissionBlockedOnly || pending.admissionBlocked)
            && (identifiers?.contains(identifier) ?? true)
        {
            if pending.routing {
                if afterCurrentRouting {
                    backgroundDownloadEvents[identifier]?.replayAfterRouting = true
                }
                continue
            }
            if backgroundRoutingFence != nil {
                if !deferredBackgroundIdentifiers.contains(identifier) {
                    deferredBackgroundIdentifiers.append(identifier)
                }
                cancelBackgroundRoutingWait()
            } else {
                startBackgroundDownloadRouting(identifier)
            }
        }
    }

    func finishBackgroundDownloadEvents(_ identifier: String) {
        downloads?.recordBackgroundSessionDrain(identifier)
        retiredDownloadOwner?.recordBackgroundSessionDrain(identifier)
        if let flight = coldNativeFlight, flight.identifier == identifier,
            pendingRecoveryIntent?.operation == flight.operation
        {
            coldNativeDrains[identifier] = flight.operation
        } else if let operation = coldPublishedSessions[identifier],
            pendingRecoveryIntent?.operation == operation
        {
            coldNativeDrains[identifier] = operation
        }
        guard backgroundDownloadEvents[identifier] != nil else { return }
        backgroundDownloadEvents[identifier]?.drained = true
        completeBackgroundDownloadEventsIfReady(identifier)
        if let pending = backgroundDownloadEvents[identifier], !pending.routing,
            !pending.reconciled, downloads != nil || retiredDownloadOwner != nil
        {
            retryPendingBackgroundDownloadEvents()
        }
    }

    private func completeBackgroundDownloadEventsIfReady(_ identifier: String) {
        guard let pending = backgroundDownloadEvents[identifier],
            pending.drained || pending.emptySessionQuiesced, pending.reconciled
        else { return }
        if let token = pending.signOutLaneToken, let scope = pending.signOutScope {
            let task = Task { [weak self] in
                guard let self else { return }
                _ = await self.signOutCommitLane.resolve(token, scope: scope)
            }
            isolation?.taskStarted(task)
            return
        }
        backgroundDownloadEvents.removeValue(forKey: identifier)
        // The model and UIApplicationDelegate entry point are main-actor isolated.
        for completion in pending.completions { completion() }
        finishBackgroundRoutingWaitIfIdle()
        if let retired = retiredAccountCleanup, retired.complete, durableSignOutContext != nil {
            if durableSignOutFinalization != nil {
                retryFinalizationAfterEvent = true
            } else {
                finishDurableSignOut(retired)
            }
        } else if pendingRecoveryIntent != nil, accountInspectionIssue == .pending {
            if pendingSignOutRecoveryTask != nil {
                retryRecoveryAfterEvent = true
            } else {
                resumePendingSignOut()
            }
        }
    }

    /// A fence admits no new native routing; queued events retain their OS completions.
    func beginBackgroundRoutingHandoff() -> UUID? {
        guard backgroundRoutingFence == nil else { return nil }
        let token = UUID()
        backgroundRoutingFence = token
        return token
    }

    func waitForBackgroundRoutingHandoff(_ token: UUID) async -> Bool {
        guard backgroundRoutingFence == token, backgroundRoutingWaiter == nil,
            deferredBackgroundIdentifiers.isEmpty
        else { return false }
        guard backgroundDownloadTask != nil || !backgroundDownloadEvents.isEmpty else {
            return !Task.isCancelled
        }
        let id = UUID()
        let finished = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || backgroundRoutingFence != token
                    || !deferredBackgroundIdentifiers.isEmpty
                {
                    continuation.resume(returning: false)
                    return
                }
                backgroundRoutingWaiter = (id, continuation)
                #if FOUNDATION_ISOLATED_TEST_HOST
                    isolatedBackgroundRoutingWaitStarted?()
                #endif
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.backgroundRoutingWaiter?.0 == id else { return }
                self.cancelBackgroundRoutingWait()
            }
        }
        return finished && backgroundRoutingFence == token
            && deferredBackgroundIdentifiers.isEmpty && !Task.isCancelled
    }

    /// A waiter is only a snapshot: callers must check again in the same actor turn as commit.
    func backgroundRoutingHandoffIsReady(_ token: UUID) -> Bool {
        backgroundRoutingFence == token && backgroundDownloadTask == nil
            && backgroundDownloadEvents.isEmpty && deferredBackgroundIdentifiers.isEmpty
    }

    @discardableResult
    func cancelBackgroundRoutingHandoff(_ token: UUID) -> Bool {
        guard backgroundRoutingFence == token else { return false }
        cancelBackgroundRoutingWait()
        backgroundRoutingFence = nil
        let queued = deferredBackgroundIdentifiers
        deferredBackgroundIdentifiers.removeAll()
        for identifier in queued { startBackgroundDownloadRouting(identifier) }
        return true
    }

    private func cancelBackgroundRoutingWait() {
        guard let waiter = backgroundRoutingWaiter else { return }
        backgroundRoutingWaiter = nil
        waiter.1.resume(returning: false)
    }

    private func finishBackgroundRoutingWaitIfIdle() {
        guard backgroundDownloadTask == nil, backgroundDownloadEvents.isEmpty,
            deferredBackgroundIdentifiers.isEmpty, let waiter = backgroundRoutingWaiter
        else { return }
        backgroundRoutingWaiter = nil
        waiter.1.resume(returning: true)
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
        let backgroundRecovery = backgroundDownloadTask
        startupTask = Task { [weak self] in
            guard let self else { return }
            let admission = await self.inspectAccountAdmission()
            guard !Task.isCancelled else { return }
            guard case .absent = admission else {
                self.isPreparingCaches = false
                self.reportAccountAdmission(admission)
                return
            }
            await backgroundRecovery?.value
            guard !Task.isCancelled else { return }
            let prepared = await prepare()
            guard !Task.isCancelled,
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
            // An OS callback held during contention must get another bounded routing
            // attempt even when this startup has no live account/download owner.
            self.retryPendingBackgroundDownloadEvents(admissionBlockedOnly: true)
        }
    }

    func prepareForScene(isActive: Bool) async {
        guard isActive else { return }
        _ = await ensureReady()
        if downloads != nil || retiredDownloadOwner != nil {
            retryPendingBackgroundDownloadEvents()
        }
    }

    /// Close publication synchronously; sign-out joins this exact optional work before clearing.
    private func retireWidgetPresentation() {
        guard let publisher = widgetPlayback else {
            retireWidgetCollectionCommand()
            return
        }
        widgetPlayback = nil
        let previous = widgetRetirement
        let retirement = publisher.invalidate()
        retireWidgetCollectionCommand()
        let joined = Task {
            await previous?.value
            await retirement.value
        }
        widgetRetirement = joined
        isolation?.taskStarted(joined)
    }

    private func retireWidgetCollectionCommand() {
        let command = widgetCollectionCommandID
        widgetCollectionCommandID = nil
        widgetCollectionCancellation?.cancel()
        widgetCollectionCancellation = nil
        if let command { actions?.cancelQueueAdditionOwned(by: command) }
    }

    private func observeWidgetCollectionCommand(
        _ command: UUID, player: FoundationPlayer,
        actions: FoundationLibraryActions
    ) {
        let completion = actions.$isQueueLoading.filter { !$0 }.map { _ in true }
        widgetCollectionCancellation = Publishers.Merge(
            player.playbackCommandReceived.map { _ in false }, completion
        ).first().sink { [weak self, weak actions] finished in
            guard let self, self.widgetCollectionCommandID == command else { return }
            self.widgetCollectionCommandID = nil
            self.widgetCollectionCancellation?.cancel()
            self.widgetCollectionCancellation = nil
            if !finished { actions?.cancelQueueAdditionOwned(by: command) }
        }
    }

    func refreshWidgetPresentation() { widgetPlayback?.refresh() }

    @discardableResult
    func performWidgetCommand(_ command: FoundationWidgetCommand) async throws
        -> FoundationWidgetCommandOutcome
    {
        guard await ensureReady() == .ready, !sameAccountCommitInProgress, !isCleaningDownloads,
            let library, let player, let actions, let downloads, let connectivity,
            command.matches(
                FoundationWidgetPlayback.snapshot(
                    scope: library.catalogAccountIdentity, player: player))
        else { throw FoundationWidgetIntentFailure.unavailable }
        let publication = widgetPlayback
        switch command.action {
        case .play: player.play()
        case .pause: player.pause()
        case .collection:
            guard let collection = player.lastPlaybackCollection,
                collection.matches(id: command.collectionID, kind: command.collectionKind)
            else { throw FoundationWidgetIntentFailure.unavailable }
            if connectivity.localOnly {
                let tracks = actions.collectionTracks(
                    downloads.browseTracks(for: collection.item), for: collection.item)
                guard !tracks.isEmpty,
                    tracks.count <= FoundationLibraryActions.maximumCollectionTracks
                else { throw FoundationWidgetIntentFailure.unavailable }
                retireWidgetCollectionCommand()
                player.setQueue(tracks, selectedIndex: 0, collection: collection.item)
            } else {
                guard !actions.isQueueLoading else {
                    throw FoundationWidgetIntentFailure.unavailable
                }
                retireWidgetCollectionCommand()
                let commandID = UUID()
                widgetCollectionCommandID = commandID
                let epoch = accountEpoch
                let admittedOccurrence = player.selectedEntryID
                actions.play(
                    collection.item, shuffled: false, library: library, player: player,
                    owner: commandID,
                    shouldCommit: { [weak self, weak player] in
                        self?.accountEpoch == epoch && self?.player === player
                            && self?.widgetCollectionCommandID == commandID
                            && self?.library?.catalogAccountIdentity == command.scope
                            && player?.selectedEntryID == admittedOccurrence
                    })
                if actions.isQueueLoading {
                    observeWidgetCollectionCommand(commandID, player: player, actions: actions)
                } else {
                    widgetCollectionCommandID = nil
                }
            }
        }
        let published = await publication?.flushMetadata() ?? false
        return published ? .accepted : .acceptedWithPublicationFailure
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
        if sameAccountCommitInProgress {
            deferredCachePreparationRetry = true
            return
        }
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
        if sameAccountCommitInProgress {
            deferredReadinessInvalidation = true
            return
        }
        continueListeningDismissals.configure(scope: nil)
        retireWidgetPresentation()
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
        // A delayed startup or background restore must not replace a live owner.
        // Its inventory may still hold native-session retirement authority.
        guard library == nil, downloads == nil else { return }
        guard let admission = signOutInspection else {
            let task = Task { [weak self] in
                guard let self else { return }
                let result = await self.inspectAccountAdmission()
                guard case .absent = result else {
                    self.reportAccountAdmission(result)
                    return
                }
                self.restoreCredentials()
            }
            isolation?.taskStarted(task)
            return
        }
        guard case .absent = admission else {
            reportAccountAdmission(admission)
            return
        }
        if backgroundDownloadTask != nil || headlessBackgroundRecoveryInFlight {
            deferredCredentialRestore = true
            return
        }
        if retiredDownloadCleanupPending {
            credentialError = FoundationDownloadAccountError.cleanupPending.errorDescription
            return
        }
        if sameAccountCommitInProgress {
            deferredCredentialRestore = true
            return
        }
        if awaitsCredentialUpgrade {
            // Quarantine scoped data until a modern credential exists. Never ask legacy storage.
            let session: FoundationSession?
            do {
                session = try FoundationCredentials.load(operations: credentialOperations)
                credentialReadFailed = false
                if credentialError == FoundationCredentialReadError.unavailable.errorDescription {
                    credentialError = nil
                }
            } catch {
                credentialReadFailed = true
                credentialError = FoundationCredentialReadError.unavailable.errorDescription
                return
            }
            if let session {
                do { try accept(session, saveCredentials: false) } catch {
                    credentialError = "Saved sign-in could not be restored. Please sign in again."
                }
            }
            return
        }
        do {
            let savedSession = try FoundationCredentials.load(operations: credentialOperations)
            credentialReadFailed = false
            if credentialError == FoundationCredentialReadError.unavailable.errorDescription {
                credentialError = nil
            }
            if let session = savedSession {
                open(session, sourceScope: Self.sourceScope(for: session))
            }
        } catch {
            credentialReadFailed = true
            credentialError = FoundationCredentialReadError.unavailable.errorDescription
            return
        }
        #if DEBUG
            if let isolation {
                isolation.diagnostic("app phase=opened")
            } else {
                FoundationJournal.shared.record("app phase=opened")
            }
        #endif
    }

    func prepareSignIn(
        authenticate: @MainActor () async throws -> FoundationSession
    ) async throws -> FoundationSignInView.Acceptance {
        let admission = await inspectAccountAdmission()
        try Task.checkCancellation()
        guard case .absent = admission else {
            reportAccountAdmission(admission)
            throw FoundationAccountCredentialTransaction.TransactionError.pending
        }
        try checkRetiredDownloadCleanup()
        // A user retry may resolve an idle background event, but must not start
        // authentication or open an account until its completion is reconciled.
        if backgroundDownloadTask == nil, !backgroundDownloadEvents.isEmpty {
            retryPendingBackgroundDownloadEvents()
        }
        await backgroundDownloadTask?.value
        try Task.checkCancellation()
        try checkRetiredDownloadCleanup()
        guard backgroundDownloadEvents.isEmpty else {
            throw FoundationDownloadAccountError.cleanupPending
        }
        if credentialReadFailed {
            restoreCredentials()
            guard !credentialReadFailed else { throw FoundationCredentialReadError.unavailable }
        }
        cancelCredentialUpgrade()
        // A prior owner's cleanup cannot complete migration during a new sign-in.
        accountCleanupTask?.cancel()
        let authentication = authenticationGeneration
        let epoch = accountEpoch
        let generation = startupGeneration
        let activeScope = library?.catalogAccountIdentity
        let activeDownloads = downloads
        let session = try await authenticate()
        try Task.checkCancellation()
        guard accountEpoch == epoch, startupGeneration == generation,
            authenticationGeneration == authentication
        else {
            throw CancellationError()
        }
        return { [weak self] in
            try Task.checkCancellation()
            guard let self, self.accountEpoch == epoch, self.startupGeneration == generation,
                self.authenticationGeneration == authentication,
                self.backgroundDownloadEvents.isEmpty
            else {
                throw CancellationError()
            }
            if let activeScope {
                guard let activeDownloads, self.downloads === activeDownloads,
                    self.library?.catalogAccountIdentity == activeScope
                else { throw CancellationError() }
                guard Self.sourceScope(for: session) == activeScope else {
                    throw FoundationDownloadAccountError.signOutRequired
                }
                try await self.acceptSameAccount(
                    session, downloads: activeDownloads, epoch: epoch,
                    startup: generation, authentication: authentication)
            } else {
                try self.accept(session)
            }
        }
    }

    private func checkRetiredDownloadCleanup() throws {
        guard retiredDownloadCleanupPending else { return }
        if !isCleaningDownloads, library == nil { retryRetiredDownloadCleanup() }
        throw FoundationDownloadAccountError.cleanupPending
    }

    private func beginCleanupProgress() -> UUID {
        cleanupStatusTask?.cancel()
        cleanupTakingLonger = false
        isCleaningDownloads = true
        let id = UUID()
        cleanupStatusID = id
        #if FOUNDATION_ISOLATED_TEST_HOST
            let delay = isolatedCleanupStatusDelay
        #endif
        let status = Task { [weak self] in
            #if FOUNDATION_ISOLATED_TEST_HOST
                if let delay {
                    await delay()
                } else {
                    try? await Task.sleep(for: .seconds(10))
                }
            #else
                try? await Task.sleep(for: .seconds(10))
            #endif
            guard !Task.isCancelled, let self, self.cleanupStatusID == id,
                self.isCleaningDownloads
            else { return }
            self.cleanupTakingLonger = true
        }
        cleanupStatusTask = status
        isolation?.taskStarted(status)
        return id
    }

    private func finishCleanupProgress(_ id: UUID) {
        guard cleanupStatusID == id else { return }
        cleanupStatusID = nil
        cleanupStatusTask?.cancel()
        cleanupStatusTask = nil
        cleanupTakingLonger = false
        isCleaningDownloads = false
    }

    private func ownsRetiredCleanup(_ id: UUID) -> Bool {
        !Task.isCancelled && retiredDownloadCleanupPending
            && retiredAccountCleanup?.id == id && library == nil
    }

    private func retryRetiredDownloadCleanup() {
        guard retiredDownloadCleanupPending, retiredDownloadRetry == nil, !isCleaningDownloads,
            library == nil, let initial = retiredAccountCleanup
        else { return }
        let progressID = beginCleanupProgress()
        let owner = retiredDownloadOwner
        let storage = isolation?.storage
        let retry = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.retiredAccountCleanup?.id == initial.id {
                    self.retiredDownloadRetry = nil
                    if Task.isCancelled {
                        self.signOutCleanupError =
                            FoundationDownloadAccountError.cleanupPending.errorDescription
                    }
                    self.finishCleanupProgress(progressID)
                }
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if let drain = self.retiredActionDrain { await drain.value }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            var result = initial
            if !result.pins {
                result.pins = FoundationPinStorage.removeStoredPins(
                    for: result.scope, defaults: storage?.defaults ?? .standard)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if !result.widgets {
                await self.widgetRetirement?.value
                result.widgets = await self.widgetStorage.clear(scope: result.scope)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if !result.playback {
                result.playback = await FoundationPlaybackSessionStore.clearScope(
                    result.scope,
                    root: storage?.playback ?? FoundationPlaybackSessionStore.defaultRoot)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if !result.selections {
                result.selections = await FoundationMusicLibraryStore.clearScope(
                    result.scope,
                    root: storage?.selections ?? FoundationMusicLibraryStore.defaultRoot)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            let cacheScope = FoundationArtworkCache.digest(result.scope)
            if !result.artwork {
                result.artwork = await FoundationArtworkCache.clearStoredScope(
                    cacheScope, root: storage?.artwork)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if !result.pages {
                result.pages = await FoundationCatalogPageCache.clearStoredScope(
                    cacheScope, root: storage?.pages)
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            if !result.downloads {
                if let owner {
                    result.downloads = await owner.clearAccount(
                        waitForPlayback: true, requireOrdinaryFiles: true,
                        nativeRecovery: self.retiredNativeRecovery(
                            owner: owner, cleanupID: initial.id),
                        mayContinue: { [weak self] in
                            self?.ownsRetiredCleanup(initial.id) == true
                                && self?.backgroundDownloadEvents.isEmpty == true
                        })
                } else {
                    result.downloads = false
                }
            }
            guard self.ownsRetiredCleanup(initial.id) else { return }
            self.publishRetiredCleanup(result)
            self.retiredDownloadRetry = nil
            self.finishCleanupProgress(progressID)
        }
        retiredDownloadRetry = retry
        isolation?.taskStarted(retry)
    }

    /// Retain the live cleanup owner while reconnecting only exact allocated
    /// sessions whose per-process finality was lost at launch. The transport joins
    /// final invalidation/model delivery before recording proof or removing bytes.
    private func retiredNativeRecovery(
        owner: FoundationDownloads, cleanupID: UUID
    ) -> FoundationDownloads.SignOutNativeRecovery? {
        guard let context = durableSignOutContext, !context.markerRemoved,
            let transactions = accountTransactions
        else { return nil }
        let epoch = accountEpoch
        let owned: @MainActor @Sendable () -> Bool = { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return !Task.isCancelled && self.ownsRetiredCleanup(cleanupID)
                && self.accountEpoch == epoch && self.retiredDownloadOwner === owner
                && self.downloads == nil && self.durableSignOutContext?.intent == context.intent
                && self.durableSignOutContext?.markerRemoved == false
        }
        let current: @MainActor @Sendable () async -> Bool = {
            guard owned(), let fresh = try? await transactions.inspect(), owned(),
                fresh.intent == context.intent,
                fresh.accessGroup == context.snapshot.accessGroup,
                fresh.credentialGeneration == context.snapshot.credentialGeneration,
                let saved = fresh.session, let expected = context.snapshot.session
            else { return false }
            return saved.serverURL == expected.serverURL && saved.userID == expected.userID
                && saved.deviceID == expected.deviceID && saved.accessToken == expected.accessToken
                && Self.sourceScope(for: saved) == context.intent.scope
        }
        return .init(
            operation: context.intent.operation, current: current,
            retireAllocated: { [weak self] store, candidate in
                guard let self, await current(),
                    store.directory
                        == FoundationDownloadStorage.directory(
                            scope: context.intent.scope, root: self.backgroundDownloadRoot),
                    store.sessionIdentifier == candidate.identifier
                else { return false }
                let retired: Bool
                #if FOUNDATION_ISOLATED_TEST_HOST
                    retired =
                        await self.isolation?.coldNativeRetirement?(
                            store, context.intent.operation, candidate, current) ?? false
                #else
                    retired = await FoundationNativeDownloadTransport.retireInterruptedSessions(
                        [candidate.identifier], directory: store.directory,
                        mayRetire: owned,
                        onFinality: { value in
                            guard await current() else { throw FoundationDownloadError.cleanup }
                            try value.recordColdFinality(
                                operation: context.intent.operation,
                                expectedTrackID: candidate.trackID,
                                expectedPackage: candidate.package)
                        }
                    ).contains(candidate.identifier)
                #endif
                guard retired, await current(),
                    (try? store.load().hasProvenRetirement) == true,
                    (try? store.coldFinalityMatches(
                        operation: context.intent.operation, expectedTrackID: candidate.trackID,
                        expectedPackage: candidate.package)) == true
                else { return false }
                // A callback may have arrived during finality. Its existing retired
                // owner can now reconcile the durable tombstone; do not complete it
                // merely because cancellation or final invalidation was requested.
                self.retryPendingBackgroundDownloadEvents(identifiers: [candidate.identifier])
                guard let fence = self.beginBackgroundRoutingHandoff() else { return false }
                let settled = await self.waitForBackgroundRoutingHandoff(fence)
                let ready = settled && self.backgroundRoutingHandoffIsReady(fence)
                _ = self.cancelBackgroundRoutingHandoff(fence)
                guard ready else { return false }
                return await current()
            })
    }

    private func publishRetiredCleanup(_ result: RetiredAccountCleanup) {
        let durable = durableSignOutContext != nil
        retiredAccountCleanup = result.complete && !durable ? nil : result
        retiredDownloadCleanupPending = !result.complete || durable
        if result.downloads, retiredDownloadOwner != nil {
            retiredDownloadOwner = nil
            retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
        }
        // clearAccount has returned and released its in-progress fence. A pending
        // represented event may now make one read-only attempt before user retry.
        if !result.downloads { retryPendingBackgroundDownloadEvents(afterCurrentRouting: true) }
        signOutPinsCleared = result.pins
        signOutPlaybackCleared = result.playback
        var failures: [String] = []
        if !result.pins { failures.append("Saved pins could not be removed from this device.") }
        if !result.playback {
            failures.append("Saved playback sessions could not be removed from this device.")
        }
        if !result.widgets {
            failures.append("Widget playback information could not be removed from this device.")
        }
        if !result.downloads,
            let message = FoundationDownloadAccountError.cleanupFailed.errorDescription
        {
            failures.append(message)
        }
        if !result.selections {
            failures.append("Saved music-library selections could not be removed.")
        }
        if !result.artwork || !result.pages {
            failures.append("Disposable caches could not be removed from this device.")
        }
        let previous = signOutCleanupFailures.joined(separator: " ")
        signOutCleanupFailures = failures
        let current = failures.joined(separator: " ")
        signOutCleanupError = current.isEmpty ? nil : current
        if credentialError == previous
            || credentialError == FoundationDownloadAccountError.cleanupPending.errorDescription
            || (credentialError == nil && previous.isEmpty)
        {
            credentialError = current.isEmpty ? nil : current
        }
        updateSignOutNotice()
        if durable && result.complete { finishDurableSignOut(result) }
    }

    #if FOUNDATION_ISOLATED_TEST_HOST
        func isolatedUpdateDownloadCleanupFailure(failed: Bool) {
            updateDownloadCleanupFailure(failed: failed)
        }
    #endif

    private func updateDownloadCleanupFailure(failed: Bool) {
        guard let message = FoundationDownloadAccountError.cleanupFailed.errorDescription else {
            return
        }
        let previous = signOutCleanupFailures.joined(separator: " ")
        signOutCleanupFailures.removeAll { $0 == message }
        if failed { signOutCleanupFailures.append(message) }
        let current = signOutCleanupFailures.joined(separator: " ")
        signOutCleanupError = current.isEmpty ? nil : current
        updateSignOutNotice()
        if credentialError == previous || (credentialError == nil && previous.isEmpty) {
            credentialError = current.isEmpty ? nil : current
        }
    }

    private func updateSignOutNotice() {
        guard let serverAccepted = signOutServerResult else { return }
        let pinResult = signOutPinsCleared ? "Pins removed." : "Pins couldn’t be removed."
        let sessionResult =
            signOutPlaybackCleared
            ? "Saved playback sessions removed." : "Saved playback sessions couldn’t be removed."
        let downloadFailed = signOutCleanupFailures.contains(
            FoundationDownloadAccountError.cleanupFailed.errorDescription ?? "")
        let downloadResult =
            downloadFailed ? "Downloads couldn’t be removed." : "Downloads removed."
        let serverResult =
            serverAccepted ? "Server sign-out confirmed." : "Server sign-out unconfirmed."
        signOutNotice =
            "Signed out on this device. \(pinResult) \(sessionResult) \(downloadResult) \(serverResult)"
    }

    func cancelCredentialUpgrade() {
        if sameAccountCommitInProgress {
            deferredCredentialUpgradeCancellation = true
            return
        }
        cancelCredentialUpgradeNow()
    }

    private func cancelCredentialUpgradeNow() {
        authenticationGeneration += 1
        pendingUpgradeAuthentication = nil
    }

    func confirmCredentialUpgrade(_ ticket: UUID) throws {
        guard !sameAccountCommitInProgress else { throw CancellationError() }
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
        // A live owner must use the joined same-account handoff instead of opening
        // another runtime against its storage while inventory is still retiring.
        guard library == nil, downloads == nil else { throw CancellationError() }
        guard !retiredDownloadCleanupPending else {
            throw FoundationDownloadAccountError.cleanupPending
        }
        guard cachesReady, !headlessBackgroundRecoveryInFlight else {
            throw FoundationLibraryError.unavailable
        }
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

    private func acceptSameAccount(
        _ session: FoundationSession, downloads owner: FoundationDownloads,
        epoch: Int, startup: Int, authentication: Int
    ) async throws {
        guard let token = owner.beginAccountHandoff() else { throw CancellationError() }
        var committing = false
        defer {
            _ = owner.cancelAccountHandoff(token)
            if committing {
                sameAccountCommitInProgress = false
                finishDeferredAccountRequests()
            }
        }
        guard await owner.waitForHandoffOwnerTasks(token),
            await owner.waitForHandoffOperations(token)
        else { throw CancellationError() }
        guard !sameAccountCommitInProgress else { throw CancellationError() }
        sameAccountCommitInProgress = true
        committing = true
        try Task.checkCancellation()
        let scope = Self.sourceScope(for: session)
        guard accountEpoch == epoch, startupGeneration == startup,
            authenticationGeneration == authentication, downloads === owner,
            library?.catalogAccountIdentity == scope, !retiredDownloadCleanupPending
        else { throw CancellationError() }
        guard let oldLibrary = library else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            guard accountEpoch == epoch, startupGeneration == startup,
                authenticationGeneration == authentication, downloads === owner,
                library?.networkAdmission === oldLibrary.networkAdmission,
                !retiredDownloadCleanupPending
            else { throw CancellationError() }
            let prepared = makeAccountLibrary(session, scope: scope, epoch: epoch + 1)
            guard owner.rebindSameAccountLibrary(prepared.library, token: token) else {
                throw CancellationError()
            }
            try FoundationCredentials.save(session, operations: credentialOperations)
            open(session, sourceScope: scope, prepared: prepared, retainingDownloads: owner)
            guard owner.commitSameAccountRebind(token) else { throw CancellationError() }
        } catch {
            throw error
        }
    }

    private func finishDeferredAccountRequests() {
        if deferredCredentialUpgradeCancellation {
            deferredCredentialUpgradeCancellation = false
            cancelCredentialUpgradeNow()
        }
        if deferredSignOut {
            deferredSignOut = false
            deferredReadinessInvalidation = false
            deferredCachePreparationRetry = false
            deferredCredentialRestore = false
            #if os(macOS)
                deferredMacSignIn = false
            #endif
            signOut()
            return
        }
        if deferredReadinessInvalidation {
            deferredReadinessInvalidation = false
            invalidateAccountReadiness()
        }
        if deferredCachePreparationRetry {
            deferredCachePreparationRetry = false
            if library == nil { retryCachePreparation() }
        }
        if deferredCredentialRestore {
            deferredCredentialRestore = false
            if library == nil { restoreCredentials() }
        }
        #if os(macOS)
            if deferredMacSignIn {
                deferredMacSignIn = false
                requireMacSignIn()
            }
        #endif
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
        let pruneUpgrade = awaitsCredentialUpgrade
        accountCleanupTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if let retiringCache {
                _ = await retiringCache.invalidate(
                    removeDisk: pruneUpgrade && retiringCache.scope != scope)
            }
            guard !Task.isCancelled else { return }
            if let retiringPages {
                _ = await retiringPages.invalidate(
                    removeDisk: pruneUpgrade && retiringPages.scope != scope)
            }
            guard pruneUpgrade, !Task.isCancelled, let self, self.accountEpoch == epoch,
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
        if let accountCleanupTask { isolation?.taskStarted(accountCleanupTask) }
    }

    private static func sourceScope(for session: FoundationSession) -> String {
        // Persist only a digest of source/account identity, never the server or credentials.
        let identity = "jellyfin\0" + session.serverURL.absoluteString + "\0" + session.userID
        return SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private struct PreparedAccountLibrary {
        let admission: FoundationNetworkAdmission
        let cache: FoundationArtworkCache
        let pages: FoundationCatalogPageCache
        let library: FoundationJellyfinLibrary
    }

    private func makeAccountLibrary(
        _ session: FoundationSession, scope: String, epoch: Int
    ) -> PreparedAccountLibrary {
        let admission = FoundationNetworkAdmission()
        let cache = FoundationArtworkCache(
            scope: scope, root: isolation?.storage.artwork, networkAdmission: admission)
        let pages = FoundationCatalogPageCache(scope: scope, root: isolation?.storage.pages)
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
            },
            load: isolation?.load ?? FoundationJellyfinLibrary.nativeLoad,
            artworkCache: cache, catalogPageCache: pages, networkAdmission: admission)
        return .init(admission: admission, cache: cache, pages: pages, library: library)
    }

    private func open(
        _ session: FoundationSession, sourceScope: String,
        prepared: PreparedAccountLibrary? = nil, retainingDownloads: FoundationDownloads? = nil
    ) {
        let isolation = isolation
        continueListeningDismissals.configure(
            scope: FoundationMusicLibraryStore.digest(sourceScope + "\0" + session.deviceID))
        if library != nil { handoff.invalidate() }
        retireWidgetPresentation()
        cancelCredentialUpgradeNow()
        accountCleanupTask?.cancel()
        _ = retireCatalogOwners()
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
        if let stop = player?.sessionTask { isolation?.taskStarted(stop) }
        player?.invalidateReporting()
        if downloads !== retainingDownloads { downloads?.invalidate() }
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
        let prepared = prepared ?? makeAccountLibrary(session, scope: sourceScope, epoch: epoch)
        let admission = prepared.admission
        beginAccountCleanup(
            scope: FoundationArtworkCache.digest(sourceScope), retiringCache: retiringCache,
            retiringPages: retiringPages)
        librarySelection?.invalidate()
        let library = prepared.library
        let selectionStore = FoundationMusicLibraryStore(
            scope: sourceScope,
            root: isolation?.storage.selections ?? FoundationMusicLibraryStore.defaultRoot)
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
            read: { key in
                if let isolation { return isolation.storage.defaults.data(forKey: key) }
                return UserDefaults.standard.data(forKey: key)
            },
            write: { key, data in
                if let isolation {
                    isolation.storage.defaults.set(data, forKey: key)
                } else {
                    UserDefaults.standard.set(data, forKey: key)
                }
            },
            trackPreferences: playbackPreferences,
            mutateFavorite: { item, favorite in
                try await library.setFavorite(for: item, isFavorite: favorite)
            })
        if isolation == nil {
            self.actions?.configurePinSync(
                sourceScope: sourceScope,
                containerIdentifier: FoundationPinSyncConfiguration.containerIdentifier(
                    Bundle.main.object(forInfoDictionaryKey: "VelacantoPinSyncContainerIdentifier")
                        as? String),
                resolve: { try await library.itemDetails(for: $0) })
        }
        self.library = library
        let transfer: FoundationDownloads.Transfer? =
            isolation == nil
            ? nil
            : { @Sendable _, _, _, _ in
                throw FoundationLibraryError.unavailable
            }
        let convertedTransfer: FoundationDownloads.ConvertedTransfer? =
            isolation == nil
            ? nil
            : { @Sendable _, _, _, _ in
                throw FoundationLibraryError.unavailable
            }
        let nativeTransfer: FoundationDownloads.NativeTransfer? =
            isolation == nil
            ? nil
            : { @Sendable _, _, _, _ in
                throw FoundationLibraryError.unavailable
            }
        let nativeRetirement: FoundationDownloads.NativeRetirement?
        if let isolation {
            nativeRetirement = isolation.nativeRetirement ?? { _, _ in [] }
        } else {
            nativeRetirement = nil
        }
        let isolated = isolation != nil
        let inventoryVerifier: FoundationDownloads.FileVerifier?
        if let isolation, let verify = isolation.verifyInventoryFiles {
            let root = isolation.storage.downloads
            inventoryVerifier = { files, directory in
                let rootValues = try root.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                let directoryValues = try directory.resourceValues(forKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey,
                ])
                guard
                    directory.deletingLastPathComponent().standardizedFileURL
                        == root.standardizedFileURL,
                    rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                    directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true,
                    files.values.allSatisfy({ $0.nativePackage == nil })
                else { throw FoundationLibraryError.unavailable }
                return try await verify(files, directory)
            }
        } else if isolated {
            inventoryVerifier = { _, _ in throw FoundationLibraryError.unavailable }
        } else {
            inventoryVerifier = nil
        }
        let downloads =
            retainingDownloads
            ?? FoundationDownloads(
                scope: sourceScope, library: library, root: isolation?.storage.downloads,
                transfer: transfer, monitorConnectivity: false,
                convertedTransfer: convertedTransfer,
                requestedQuality: { [weak playbackPreferences] in
                    playbackPreferences?.downloadQuality ?? .original
                },
                systemManagedDownloads: { [weak playbackPreferences] in
                    playbackPreferences?.systemManagedDownloads ?? false
                },
                nativeTransfer: nativeTransfer, nativeRetirement: nativeRetirement,
                allowNativeCleanup: !isolated,
                leaseWaitStarted: isolation?.leaseWaitStarted,
                nativeResolution: { package, scope in
                    isolated ? .unverifiable : package.resolution(scope: scope)
                },
                verifyReacquisitionFiles: isolated
                    ? { @Sendable _, _ in throw FoundationLibraryError.unavailable } : nil,
                verifyInventoryFiles: inventoryVerifier,
                nativeInventoryRetired: { [weak self] identifiers in
                    guard !identifiers.isEmpty else { return }
                    self?.retryPendingBackgroundDownloadEvents(
                        identifiers: identifiers, afterCurrentRouting: true)
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
        retryPendingBackgroundDownloadEvents()
        if retainingDownloads != nil { downloads.replayObservedTracks() }
        configurePrimaryGenres(browseLibrary ?? library)
        let connectivity = FoundationConnectivity(
            offlineMode: playbackPreferences.offlineMode, monitorConnectivity: isolation == nil
        ) {
            _ = try await library.songs(startIndex: 0)
        }
        self.connectivity = connectivity
        self.actions?.configureTrackAvailability { [weak connectivity, weak downloads] item in
            connectivity?.localOnly != true || downloads?.isReady(item) == true
        }
        let preferences = playbackPreferences
        downloads.setAllowsCellular(preferences.allowsCellularDownloads)
        let resolveResource: @Sendable (FoundationItem) async throws -> FoundationPlaybackResource =
            { item in
                try await downloads.playbackResource(
                    for: item, allowsRemoteFallback: !connectivity.localOnly)
            }
        if let isolation {
            self.player = FoundationPlayer(
                resolve: { try await library.playbackURL(for: $0) },
                resolveResource: resolveResource,
                makeItem: { preferences.makePlayerItem(for: $0) },
                activateSession: {}, deactivateSession: {},
                sessionLane: isolation.sessionLane, observeSystemEvents: false,
                diagnostic: isolation.diagnostic,
                reportPlayback: { try await library.reportPlayback($0) },
                reportingAllowed: { !connectivity.localOnly })
        } else {
            self.player = FoundationPlayer(
                library: library, resolveResource: resolveResource,
                makeItem: { preferences.makePlayerItem(for: $0) },
                reportingAllowed: { !connectivity.localOnly })
        }
        player?.observePlaybackProtection { protected, revision in
            Task { await admission.updatePlaybackProtection(protected, revision: revision) }
        }
        currentArtworkLocalOnly = connectivity.localOnly
        connectivity.objectWillChange.sink { [weak self, weak downloads, weak connectivity] in
            Task { @MainActor in
                guard let self, let downloads, let connectivity,
                    self.connectivity === connectivity
                else { return }
                if connectivity.localOnly { self.primaryGenres?.suspendForOffline() }
                if connectivity.localOnly { self.player?.suspendReporting() }
                if self.currentArtworkLocalOnly != connectivity.localOnly {
                    self.currentArtworkLocalOnly = connectivity.localOnly
                    self.actions?.refreshTrackVisibility()
                    self.currentArtwork?.refreshRetainedArtwork()
                }
                downloads.updateConnectivity(
                    isConnected: connectivity.isConnected,
                    usesWiFi: connectivity.usesWiFiOrWired)
                await self.preparePrimaryGenresIfNeeded()
            }
        }.store(in: &policySubscriptions)
        preferences.$offlineMode.removeDuplicates().dropFirst().sink {
            [weak self, weak connectivity] enabled in
            guard let self, let connectivity, self.connectivity === connectivity else { return }
            connectivity.setOfflineMode(enabled)
            if enabled { self.player?.enterOfflineMode() }
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
            let store = FoundationPlaybackSessionStore(
                scope: sourceScope,
                root: isolation?.storage.playback ?? FoundationPlaybackSessionStore.defaultRoot)
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
                #if FOUNDATION_ISOLATED_TEST_HOST
                    let before = self?.isolatedBeforeRetainedArtworkDelivery
                    let finished = self?.isolatedRetainedArtworkDeliveryFinished
                #endif
                let delivery = Task { @MainActor in
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        defer { finished?() }
                        await before?()
                    #endif
                    guard let self, let artwork, let player, let downloads,
                        self.currentArtwork === artwork, self.player === player,
                        self.downloads === downloads,
                        let item = player.queue.first(where: { $0.id == player.selectedEntryID })?
                            .item,
                        let identity = downloads.retainedArtworkIdentity(for: item)
                    else { return }
                    let selectedIdentity = item.catalogArtworkItem.id + ":" + identity
                    guard self.currentRetainedArtworkIdentity != selectedIdentity else { return }
                    self.currentRetainedArtworkIdentity = selectedIdentity
                    artwork.refreshRetainedArtwork()
                    #if FOUNDATION_ISOLATED_TEST_HOST
                        self.isolatedRetainedArtworkRefreshed?(artwork)
                    #endif
                }
                #if FOUNDATION_ISOLATED_TEST_HOST
                    self?.isolation?.taskStarted(delivery)
                #else
                    _ = delivery
                #endif
            }.store(in: &policySubscriptions)
            self.currentArtwork = artwork
            widgetOwnerGeneration &+= 1
            widgetPlayback = FoundationWidgetPlayback(
                scope: sourceScope, generation: widgetOwnerGeneration, player: player,
                artwork: artwork, storage: widgetStorage,
                collectionArtwork: { item in
                    try await library.artworkResult(
                        for: item, size: 320, allowsNetwork: !connectivity.localOnly)?.data
                })
            if isolation == nil {
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
    }

    /// Retire catalog-scoped work at its existing lifecycle boundary.
    @discardableResult
    private func retireCatalogOwners() -> Task<Void, Never>? {
        retirePrimaryGenres()
        let retirement = FoundationAlphabetAccountLifecycle.retire(library)
        if let retirement { isolation?.taskStarted(retirement) }
        return retirement
    }

    func retirePrimaryGenres() {
        if let primaryGenres {
            if let isolation {
                isolation.taskStarted(primaryGenres.retireAndDrain())
            } else {
                primaryGenres.retire()
            }
        }
        primaryGenres = nil
    }

    /// One account/runtime owner shared by every window; automatic preparation is version-scoped.
    func configurePrimaryGenres(_ library: any FoundationLibrary) {
        if let primaryGenres {
            primaryGenres.bind(library)
        } else {
            primaryGenres = FoundationPrimaryGenresModel(library: library)
        }
        guard let primaryGenres else { return }
        primaryGenres.bindDownloads(downloads)
        let preparation = Task { [weak self, weak primaryGenres] in
            guard let self, let primaryGenres, self.primaryGenres === primaryGenres else { return }
            await self.preparePrimaryGenresIfNeeded()
        }
        isolation?.taskStarted(preparation)
    }

    func preparePrimaryGenresIfNeeded() async {
        guard let primaryGenres else { return }
        if connectivity?.localOnly == true { primaryGenres.suspendForOffline() }
        await primaryGenres.prepareAutomaticallyIfNeeded(
            allowsNetwork: connectivity?.isConnected == true)
    }

    private struct DurableSignOutContext {
        let session: FoundationSession
        let snapshot: FoundationAccountCredentialTransaction.Snapshot
        let intent: FoundationSignOutIntentStore.Intent
        var markerRemoved = false
    }

    private struct PendingSignOutPreparation {
        let session: FoundationSession
        let snapshot: FoundationAccountCredentialTransaction.Snapshot
        let preparation: FoundationAccountCredentialTransaction.Preparation
        let epoch: Int
        let owner: FoundationDownloads
        let handoff: UUID
    }
    private var pendingSignOutPreparation: PendingSignOutPreparation?
    private var signOutPreparationRetry: Task<Void, Never>?

    private func preparationStillOwned(_ pending: PendingSignOutPreparation) -> Bool {
        sameAccountCommitInProgress && accountEpoch == pending.epoch
            && downloads === pending.owner && pending.owner.accountHandoffIsCurrent(pending.handoff)
            && library?.catalogAccountIdentity == Self.sourceScope(for: pending.session)
            && pendingSignOutPreparation?.preparation.operation == pending.preparation.operation
    }

    private func snapshotMatchesPreparation(
        _ checked: FoundationAccountCredentialTransaction.Snapshot,
        _ pending: PendingSignOutPreparation
    ) -> Bool {
        guard checked.accessGroup == pending.snapshot.accessGroup,
            let expected = pending.snapshot.session, let saved = checked.session,
            saved.serverURL == expected.serverURL, saved.userID == expected.userID,
            saved.deviceID == expected.deviceID, saved.accessToken == expected.accessToken
        else { return false }
        let initial = pending.snapshot.credentialGeneration
        return checked.credentialGeneration == initial
            || (initial == nil
                && checked.credentialGeneration == pending.preparation.candidateGeneration)
    }

    private func adoptSignOutPreparation(
        _ pending: PendingSignOutPreparation,
        snapshot: FoundationAccountCredentialTransaction.Snapshot
    ) -> Bool {
        guard preparationStillOwned(pending), snapshotMatchesPreparation(snapshot, pending),
            let intent = snapshot.intent, intent.operation == pending.preparation.operation,
            intent.scope == Self.sourceScope(for: pending.session), intent.cleanupComplete != true,
            intent.accessGroup == snapshot.accessGroup,
            let generation = intent.credentialGeneration,
            generation == snapshot.credentialGeneration,
            generation
                == (pending.snapshot.credentialGeneration ?? pending.preparation.candidateGeneration)
        else { return false }
        durableSignOutContext = DurableSignOutContext(
            session: pending.session, snapshot: snapshot, intent: intent)
        pendingSignOutPreparation = nil
        registerOutstandingSignOutObligations()
        signOutInspection = .pending
        accountInspectionIssue = .pending
        sameAccountCommitInProgress = false
        isStartingDurableSignOut = false
        retiredActionDrain = actions?.invalidateAndDrain()
        continueSignOut(
            session: pending.session, cleanupScope: intent.scope,
            pinsCleared: false, legacyRevocation: nil)
        finishDeferredAccountRequests()
        return true
    }

    private func retrySignOutPreparation(_ transactions: FoundationAccountTransactions) {
        guard signOutPreparationRetry == nil, durableSignOutPreparation == nil,
            let pending = pendingSignOutPreparation, preparationStillOwned(pending)
        else { return }
        isCheckingPendingSignOut = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.signOutPreparationRetry = nil
                self.isCheckingPendingSignOut = false
            }
            do {
                let checked = try await transactions.inspect()
                try Task.checkCancellation()
                guard self.preparationStillOwned(pending),
                    self.snapshotMatchesPreparation(checked, pending)
                else { return }
                if checked.intent == nil {
                    guard pending.owner.cancelAccountHandoff(pending.handoff) else { return }
                    self.pendingSignOutPreparation = nil
                    self.sameAccountCommitInProgress = false
                    self.signOutInspection = .absent
                    self.accountInspectionIssue = nil
                    self.credentialError =
                        "Sign-out could not start. Your account data remains on this device. Try again."
                    self.finishDeferredAccountRequests()
                } else {
                    let earlier = self.accountCleanupTask
                    earlier?.cancel()
                    await earlier?.value
                    try Task.checkCancellation()
                    let verified = try await transactions.inspect()
                    try Task.checkCancellation()
                    _ = self.adoptSignOutPreparation(pending, snapshot: verified)
                }
            } catch {
                // Keep the original owner, intent and retry state until exact reinspection succeeds.
            }
        }
        signOutPreparationRetry = task
        isolation?.taskStarted(task)
    }

    private func beginDurableSignOut(_ transactions: FoundationAccountTransactions) {
        guard !sameAccountCommitInProgress, durableSignOutContext == nil,
            let active = library, let owner = downloads, accountOwnershipAcquired,
            case .absent = signOutInspection
        else { return }
        guard let handoff = owner.beginAccountHandoff() else {
            credentialError = "Sign-out could not start. Try again."
            return
        }
        sameAccountCommitInProgress = true
        isStartingDurableSignOut = true
        let session = active.session
        let epoch = accountEpoch
        let preparation = FoundationAccountCredentialTransaction.Preparation()
        let task = Task { [weak self, owner] in
            guard let self else { return }
            defer { self.durableSignOutPreparation = nil }
            do {
                let initial = try await transactions.inspect()
                guard initial.intent == nil, let saved = initial.session,
                    saved.serverURL == session.serverURL, saved.userID == session.userID,
                    saved.deviceID == session.deviceID, saved.accessToken == session.accessToken,
                    self.accountEpoch == epoch, self.downloads === owner,
                    owner.accountHandoffIsCurrent(handoff),
                    self.library?.catalogAccountIdentity == Self.sourceScope(for: session)
                else { throw FoundationAccountCredentialTransaction.TransactionError.changed }
                let pending = PendingSignOutPreparation(
                    session: session, snapshot: initial,
                    preparation: preparation, epoch: epoch, owner: owner, handoff: handoff)
                self.pendingSignOutPreparation = pending
                try Task.checkCancellation()
                _ = try await transactions.prepareSignOut(session, initial, preparation)
                let earlier = self.accountCleanupTask
                earlier?.cancel()
                await earlier?.value
                try Task.checkCancellation()
                let verified = try await transactions.inspect()
                try Task.checkCancellation()
                guard self.adoptSignOutPreparation(pending, snapshot: verified) else {
                    throw FoundationAccountCredentialTransaction.TransactionError.changed
                }
            } catch {
                self.isStartingDurableSignOut = false
                if self.pendingSignOutPreparation == nil {
                    // The initial stored identity or owner could not be verified. No marker
                    // write began, but resuming an invalid or mismatched owner is unsafe.
                    self.uncertainSignOutRequiresRestart = true
                    self.signOutInspection = .unavailable
                    self.accountInspectionIssue = .unavailable
                    self.player?.stop()
                    if let stop = self.player?.sessionTask { self.isolation?.taskStarted(stop) }
                    self.downloads?.invalidate()
                    self.actions?.invalidate()
                    self.credentialError =
                        "Sign-out status could not be verified. Restart VelaCanto and try again."
                } else {
                    self.signOutInspection = .unavailable
                    self.accountInspectionIssue = .unavailable
                    self.credentialError =
                        "Sign-out status could not be verified. Try again or contact support."
                }
            }
        }
        durableSignOutPreparation = task
        isolation?.taskStarted(task)
    }

    private func finishDurableSignOut(_ result: RetiredAccountCleanup) {
        guard durableSignOutFinalization == nil, result.complete,
            let context = durableSignOutContext, let transactions = accountTransactions,
            retiredAccountCleanup?.id == result.id, library == nil,
            backgroundDownloadTask == nil, backgroundDownloadEvents.isEmpty,
            !sameAccountCommitInProgress
        else { return }
        sameAccountCommitInProgress = true
        isFinalizingDurableSignOut = true
        let epoch = accountEpoch
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.sameAccountCommitInProgress = false
                self.isFinalizingDurableSignOut = false
                self.durableSignOutFinalization = nil
                self.finishDeferredAccountRequests()
                if self.retryFinalizationAfterEvent {
                    self.retryFinalizationAfterEvent = false
                    if let retired = self.retiredAccountCleanup, retired.complete {
                        self.finishDurableSignOut(retired)
                    }
                }
            }
            do {
                if !context.markerRemoved {
                    let fresh = try await transactions.inspect()
                    let completed: FoundationSignOutIntentStore.Intent
                    if let existing = fresh.intent, existing.operation == context.intent.operation,
                        existing.scope == context.intent.scope,
                        existing.accessGroup == context.intent.accessGroup,
                        existing.credentialGeneration == context.intent.credentialGeneration,
                        existing.cleanupComplete == true
                    {
                        completed = existing
                    } else {
                        let recordToken = try await self.signOutCommitLane.beginCommit()
                        do {
                            completed = try await transactions.recordSignOut(
                                context.session, context.intent, context.snapshot)
                            self.retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
                        } catch {
                            _ = await self.signOutCommitLane.endCommit(recordToken)
                            throw error
                        }
                        guard let events = await self.signOutCommitLane.endCommit(recordToken),
                            events.isEmpty, self.backgroundDownloadEvents.isEmpty
                        else {
                            throw FoundationAccountCredentialTransaction.TransactionError.pending
                        }
                    }
                    let removeToken = try await self.signOutCommitLane.beginCommit()
                    do {
                        try await transactions.finishCompletedSignOut(completed)
                        self.durableSignOutContext?.markerRemoved = true
                        self.lastSignedOutScope = context.intent.scope
                        self.retryPendingBackgroundDownloadEvents(afterCurrentRouting: true)
                    } catch {
                        _ = await self.signOutCommitLane.endCommit(removeToken)
                        throw error
                    }
                    guard let events = await self.signOutCommitLane.endCommit(removeToken),
                        events.isEmpty, self.backgroundDownloadEvents.isEmpty
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                } else {
                    guard (await self.signOutCommitLane.pending()).isEmpty,
                        self.backgroundDownloadEvents.isEmpty
                    else { throw FoundationAccountCredentialTransaction.TransactionError.pending }
                }
                guard self.retiredAccountCleanup?.id == result.id, self.accountEpoch == epoch,
                    self.library == nil
                else { return }
                self.durableSignOutContext = nil
                self.retiredAccountCleanup = nil
                self.retiredDownloadCleanupPending = false
                self.signOutInspection = nil
                self.accountInspectionIssue = nil
                self.signOutCleanupError = nil
                self.credentialError = nil
                let revoke: Task<Bool, Never>
                if let isolation = self.isolation {
                    revoke = isolation.revoke(context.session)
                    isolation.revocationStarted(revoke)
                } else {
                    let deviceName = FoundationClientDeviceName.current
                    revoke = Task.detached(priority: .userInitiated) {
                        let adapter = FoundationJellyfinLibrary(
                            session: context.session, deviceName: deviceName,
                            load: FoundationJellyfinLibrary.signOutLoad)
                        do {
                            try await adapter.endSession()
                            return true
                        } catch { return false }
                    }
                }
                let notice = Task { [weak self] in
                    let confirmed = await revoke.value
                    guard let self, self.accountEpoch == epoch, self.library == nil else { return }
                    self.signOutServerResult = confirmed
                    self.updateSignOutNotice()
                }
                self.isolation?.taskStarted(notice)
            } catch {
                self.signOutCleanupError = "Sign-out did not finish. Try cleanup again."
            }
        }
        durableSignOutFinalization = task
        isolation?.taskStarted(task)
    }

    func signOut() {
        if sameAccountCommitInProgress {
            deferredSignOut = true
            return
        }
        if let transactions = accountTransactions {
            beginDurableSignOut(transactions)
        } else {
            signOutLegacy()
        }
    }

    private func signOutLegacy() {
        if sameAccountCommitInProgress {
            deferredSignOut = true
            return
        }
        let isolation = isolation
        guard let activeLibrary = library else { return }
        let session = activeLibrary.session
        let cleanupScope = activeLibrary.catalogAccountIdentity
        player?.stop()
        if let stop = player?.sessionTask { isolation?.taskStarted(stop) }
        let deviceName = FoundationClientDeviceName.current
        let attempt = FoundationSignOutPolicy.begin {
            if let isolation { return isolation.revoke(session) }
            // Keep the captured session until this bounded attempt completes.
            return Task.detached(priority: .userInitiated) {
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
            FoundationPinStorage.removeStoredPins(
                for: cleanupScope, defaults: isolation?.storage.defaults ?? .standard)
        }
        isolation?.revocationStarted(attempt.revocation)
        guard attempt.localCleared else {
            credentialError =
                "Sign-out failed here. Saved pins remain on this device. "
                + "Jellyfin may have ended the session."
            return
        }
        continueSignOut(
            session: session, cleanupScope: cleanupScope,
            pinsCleared: attempt.pinsCleared, legacyRevocation: attempt.revocation)
    }

    private func continueSignOut(
        session: FoundationSession, cleanupScope: String, pinsCleared: Bool,
        legacyRevocation: Task<Bool, Never>?
    ) {
        let isolation = isolation
        if legacyRevocation == nil {
            player?.stop()
            if let stop = player?.sessionTask { isolation?.taskStarted(stop) }
        }
        invalidateAccountReadiness()
        let epoch = accountEpoch
        let catalogRetirement = retireCatalogOwners()
        let retiringCache = library?.artworkCache
        let retiringPages = library?.catalogPageCache
        let retiringDownloads = downloads
        retiredDownloadOwner = retiringDownloads
        retiredDownloadCleanupPending = true
        retiringDownloads?.invalidate()
        connectivity?.invalidate()
        connectivity = nil
        policySubscriptions.removeAll()
        currentRetainedArtworkIdentity = nil
        downloads = nil
        let progressID = beginCleanupProgress()
        playbackSessionSubscription = nil
        let retired = RetiredAccountCleanup(scope: cleanupScope, pins: pinsCleared)
        retiredAccountCleanup = retired
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
        signOutCleanupFailures = []
        signOutCleanupError = nil
        signOutServerResult = nil
        signOutPinsCleared = pinsCleared
        signOutPlaybackCleared = false
        let cleanup = Task { [weak self] in
            guard let self else { return }
            defer {
                if Task.isCancelled, self.retiredAccountCleanup?.id == retired.id {
                    let message = FoundationDownloadAccountError.cleanupPending.errorDescription
                    self.credentialError = message
                    self.signOutCleanupError = message
                }
                self.finishCleanupProgress(progressID)
            }
            if let drain = self.retiredActionDrain {
                #if FOUNDATION_ISOLATED_TEST_HOST
                    self.isolatedActionDrainStarted?()
                #endif
                await drain.value
            }
            await catalogRetirement?.value
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let pinsCleared =
                legacyRevocation != nil
                ? pinsCleared
                : FoundationPinStorage.removeStoredPins(
                    for: cleanupScope, defaults: isolation?.storage.defaults ?? .standard)
            guard self.ownsRetiredCleanup(retired.id) else { return }
            await self.widgetRetirement?.value
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let widgetsCleared = await self.widgetStorage.clear(scope: cleanupScope)
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let playbackSessionsCleared = await FoundationPlaybackSessionStore.clearScope(
                cleanupScope,
                root: isolation?.storage.playback ?? FoundationPlaybackSessionStore.defaultRoot)
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let librarySelectionsCleared = await FoundationMusicLibraryStore.clearScope(
                cleanupScope,
                root: isolation?.storage.selections ?? FoundationMusicLibraryStore.defaultRoot)
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let artworkInvalidated = await retiringCache?.invalidate(removeDisk: false) ?? true
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let pagesInvalidated = await retiringPages?.invalidate(removeDisk: false) ?? true
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let cacheScope = FoundationArtworkCache.digest(cleanupScope)
            let artworkCleared: Bool
            if artworkInvalidated {
                artworkCleared = await FoundationArtworkCache.clearStoredScope(
                    cacheScope, root: isolation?.storage.artwork)
            } else {
                artworkCleared = false
            }
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let pagesCleared: Bool
            if pagesInvalidated {
                pagesCleared = await FoundationCatalogPageCache.clearStoredScope(
                    cacheScope, root: isolation?.storage.pages)
            } else {
                pagesCleared = false
            }
            guard self.ownsRetiredCleanup(retired.id) else { return }
            let downloadsCleared: Bool
            if let retiringDownloads {
                downloadsCleared = await retiringDownloads.clearAccount(
                    waitForPlayback: true, requireOrdinaryFiles: true,
                    nativeRecovery: self.retiredNativeRecovery(
                        owner: retiringDownloads, cleanupID: retired.id),
                    mayContinue: { [weak self] in
                        self?.ownsRetiredCleanup(retired.id) == true
                            && self?.backgroundDownloadEvents.isEmpty == true
                    })
            } else {
                downloadsCleared = false
            }
            guard self.ownsRetiredCleanup(retired.id) else { return }
            var result = retired
            result.pins = pinsCleared
            result.playback = playbackSessionsCleared
            result.widgets = widgetsCleared
            result.selections = librarySelectionsCleared
            result.artwork = artworkCleared
            result.pages = pagesCleared
            result.downloads = downloadsCleared
            self.publishRetiredCleanup(result)
            self.finishCleanupProgress(progressID)
            if let legacyRevocation {
                let serverAccepted = await legacyRevocation.value
                guard self.accountEpoch == epoch, self.library == nil else { return }
                self.signOutServerResult = serverAccepted
                self.updateSignOutNotice()
            }
        }
        signOutCleanupTask = cleanup
        isolation?.taskStarted(cleanup)
    }

    func dismissAccountAlertAfterUpdate() {
        let dismissedError = credentialError
        let dismissedErrorGeneration = credentialErrorGeneration
        let dismissedCleanupError = signOutCleanupError
        let dismissedCleanupErrorGeneration = signOutCleanupErrorGeneration
        let dismissedNotice = signOutNotice
        let dismissedNoticeGeneration = signOutNoticeGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let dismissedError, self.credentialErrorGeneration == dismissedErrorGeneration,
                self.credentialError == dismissedError
            {
                self.credentialError = nil
            }
            if let dismissedCleanupError,
                self.signOutCleanupErrorGeneration == dismissedCleanupErrorGeneration,
                self.signOutCleanupError == dismissedCleanupError
            {
                self.signOutCleanupError = nil
            }
            if let dismissedNotice, self.signOutNoticeGeneration == dismissedNoticeGeneration,
                self.signOutNotice == dismissedNotice
            {
                self.signOutNotice = nil
            }
        }
    }
}

struct FoundationRootView: View {
    @ObservedObject var model: FoundationAppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var introductionHistory = FoundationIntroductionHistory.shared
    @State private var introductionBlocked = false

    private var accountAlertRequested: Bool {
        model.credentialError != nil || model.signOutCleanupError != nil
            || model.signOutNotice != nil
    }

    private var automaticIntroductionAllowed: Bool {
        #if DEBUG
            !FoundationAppRuntime.isTesting
        #else
            true
        #endif
    }

    private var readyForAutomaticIntroduction: Bool {
        automaticIntroductionAllowed && !model.isPreparingCaches && model.cachesReady
            && !model.requiresSignIn && !model.isCleaningDownloads
            && model.library != nil && model.player != nil && model.actions != nil
            && model.primaryGenres != nil && model.currentArtwork != nil
            && model.downloads != nil && model.connectivity != nil
    }

    var accountAlertPresented: Binding<Bool> {
        Binding(
            get: { accountAlertRequested && !introductionHistory.automaticPresentationActive },
            set: {
                if !$0 && !introductionHistory.automaticPresentationActive {
                    model.dismissAccountAlertAfterUpdate()
                }
            }
        )
    }

    var body: some View {
        Group {
            if model.isCleaningDownloads {
                FoundationAccountCleanupProgress(takingLonger: model.cleanupTakingLonger)
            } else if model.isStartingDurableSignOut || model.isFinalizingDurableSignOut {
                ProgressView("Signing out…")
            } else if model.coldNativeTakingLonger {
                VStack(spacing: 12) {
                    Text(
                        "Sign-out is taking longer than expected. If this continues, contact support."
                    )
                    ProgressView()
                }
            } else if model.isColdNativeRecovering || model.isResumingPendingSignOut {
                ProgressView("Sign-out didn’t finish. Resuming cleanup…")
            } else if model.isCheckingPendingSignOut {
                ProgressView("Checking sign-out…")
            } else if model.isPreparingCaches {
                ProgressView("Preparing library…")
            } else if let message = model.accountInspectionMessage {
                VStack(spacing: 12) {
                    Text(message)
                    if !model.uncertainSignOutRequiresRestart {
                        Button("Try Again") { model.retryAccountInspection() }
                    }
                }
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
            } else {
                FoundationSignInView(model: model)
            }
        }
        .onPreferenceChange(FoundationIntroductionBlockerPreferenceKey.self) {
            introductionBlocked = $0
        }
        .modifier(
            FoundationAutomaticIntroductionPresentation(
                isReady: readyForAutomaticIntroduction, hasOtherPresentation: introductionBlocked,
                hasAccountAlert: accountAlertRequested,
                catalogScope: model.library?.catalogScopeID ?? "", sync: model.actions?.pinSync,
                preferences: model.playbackPreferences, controller: model.handoff)
        )
        .modifier(
            FoundationHandoffPresentation(
                controller: model.handoff,
                accountAlert:
                    accountAlertRequested || introductionHistory.automaticPresentationActive)
        )
        .environment(\.foundationHandoff, model.handoff)
        .task(id: scenePhase) {
            // A background-session launch must not bootstrap a catalog or acquisition.
            // Explicit Siri/Handoff entry points retain their own readiness admission.
            await model.prepareForScene(isActive: scenePhase == .active)
        }
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
                model.handoff.reassertCurrentActivityAfterForeground()
                model.refreshWidgetPresentation()
                model.playbackPreferences.refresh()
                model.downloads?.reconcilePlaylists()
                Task { await model.preparePrimaryGenresIfNeeded() }
            }
        }
        .alert(
            model.signOutNotice == nil ? "Account" : "Sign-out",
            isPresented: accountAlertPresented
        ) {
            Button("OK") { model.dismissAccountAlertAfterUpdate() }
        } message: {
            let cleanupError =
                model.signOutCleanupError == model.credentialError ? nil : model.signOutCleanupError
            Text(
                [model.credentialError, cleanupError, model.signOutNotice]
                    .compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}

struct FoundationAccountCleanupProgress: View {
    let takingLonger: Bool

    var body: some View {
        VStack(spacing: 12) {
            ProgressView("Removing local account data…")
            if takingLonger {
                Text(
                    "Cleanup is taking longer. Keep VelaCanto open while it runs. Sign-in remains unavailable during cleanup."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .accessibilityIdentifier("account-cleanup-progress")
    }
}

struct FoundationSignInView: View {
    typealias Acceptance = @MainActor () async throws -> Void
    private let authenticate: @MainActor (URL, String, String) async throws -> Acceptance
    private let confirmUpgrade: @MainActor (UUID) throws -> Void
    private let cancelUpgrade: @MainActor () -> Void
    private let signOutCurrentAccount: (@MainActor () -> Void)?
    @State private var upgradeTicket: UUID?
    @State private var confirmsSignOut = false

    init(model: FoundationAppModel) {
        let signOut: (@MainActor () -> Void)?
        if model.library == nil {
            signOut = nil
        } else {
            signOut = { model.signOut() }
        }
        self.init(
            authenticate: { url, username, password in
                try await model.prepareSignIn {
                    try await FoundationJellyfinLibrary.signIn(
                        serverURL: url, username: username, password: password,
                        deviceName: FoundationClientDeviceName.current)
                }
            }, confirmUpgrade: { try model.confirmCredentialUpgrade($0) },
            cancelUpgrade: { model.cancelCredentialUpgrade() },
            signOutCurrentAccount: signOut)
        #if os(macOS)
            _address = State(initialValue: model.library?.session.serverURL.absoluteString ?? "")
        #endif
    }

    init(
        authenticate: @escaping @MainActor (URL, String, String) async throws -> Acceptance,
        confirmUpgrade: @escaping @MainActor (UUID) throws -> Void = { _ in
            throw CancellationError()
        },
        cancelUpgrade: @escaping @MainActor () -> Void = {},
        signOutCurrentAccount: (@MainActor () -> Void)? = nil
    ) {
        self.authenticate = authenticate
        self.confirmUpgrade = confirmUpgrade
        self.cancelUpgrade = cancelUpgrade
        self.signOutCurrentAccount = signOutCurrentAccount
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
                        try await accept()
                        try Task.checkCancellation()
                        guard signingIn, attempt == owner else { return }
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
                        } else if let credentialReadError = error as? FoundationCredentialReadError
                        {
                            errorMessage = credentialReadError.errorDescription
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
                    "Sign out of your current account?", isPresented: $confirmsSignOut
                ) {
                    Button("Sign Out", role: .destructive) { signOutCurrentAccount?() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Signing out attempts to remove this account’s local downloads, pins, and saved playback information. You’ll be told if cleanup fails."
                    )
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
                        "Downloads, pins, playback history and settings belong to a different server address or account. Retry with the previous address and account to keep them, or remove local data. Your server library stays unchanged."
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
                if signOutCurrentAccount != nil && !signingIn {
                    Button("Sign out of current account", role: .destructive) {
                        confirmsSignOut = true
                    }
                    .accessibilityIdentifier("sign-in-sign-out-current-account")
                }
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

    static func clearScope(_ scope: String, root: URL = defaultRoot) async -> Bool {
        await FoundationScopedAccountRemoval.removeAsync(root: root, scope: scope)
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
