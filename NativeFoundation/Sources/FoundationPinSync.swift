import CloudKit
import Combine
import Foundation

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum FoundationPinSyncConfiguration {
    static let developmentContainerIdentifier = "iCloud.com.chameleonenterprise.velacanto"

    /// Ordinary builds leave the setting empty. Never construct a default or
    /// unintended CloudKit container from an empty/unexpanded build setting.
    static func containerIdentifier(_ configured: String?) -> String? {
        configured == developmentContainerIdentifier ? configured : nil
    }
}

/// Optional account-owned work. The pin owner remains the only writer of visible pins.
@MainActor
final class FoundationPinSync: ObservableObject {
    nonisolated static let storagePrefix = "Velacanto.Foundation.PinSync.v1."
    struct Journal: Codable {
        var state: FoundationPinSyncState?
        var account: String?
        let device: UUID
        var enabled: Bool
        // A failed journal mutation must never permit cloud state to overwrite newer local pins.
        // Optional preserves decoding of journals written before this recovery marker existed.
        var needsRecovery: Bool? = nil
        var recoveryBaseline: [FoundationPinSyncState.Identity]? = nil
        // Local per-library presentation history; never part of the cloud payload.
        var promptHandled: Bool? = nil
    }
    @Published private(set) var enabled = false
    @Published private(set) var isSyncing = false
    @Published private(set) var message: String
    @Published private(set) var offersOptIn = false
    let available: Bool
    private let scope: String
    private let defaults: UserDefaults
    typealias Exchange =
        @Sendable (
            String, FoundationPinSyncState?, [FoundationPinSyncState.Identity], UUID, String?, Bool
        ) async throws -> FoundationPinSyncCloud.Result
    typealias IsCurrent = @MainActor @Sendable () -> Bool
    typealias Apply =
        @MainActor ([FoundationPinSyncState.Identity], @escaping IsCurrent) async throws -> Void
    private let exchangeCloud: Exchange?
    typealias AccountAvailable = @Sendable () async throws -> Bool
    private let accountAvailable: AccountAvailable?
    private var checkedPrompt = false
    private var promptAccountStable = true
    @Published private var promptOwner: UUID?
    private var journal: Journal
    private(set) var task: Task<Void, Never>?
    private var generation = UUID()
    private var revision: UInt = 0
    private var active = true
    private var accountObservation: NSObjectProtocol?
    private var foregroundObservation: NSObjectProtocol?
    private let currentPins: () -> [FoundationPinSyncState.Identity]
    private let apply: Apply
    private var localProjection: [FoundationPinSyncState.Identity]

    init(
        scope: String, containerIdentifier: String?, defaults: UserDefaults = .standard,
        exchange: Exchange? = nil,
        accountAvailable: AccountAvailable? = nil,
        currentPins: @escaping () -> [FoundationPinSyncState.Identity],
        apply: @escaping Apply
    ) {
        self.scope = scope
        self.defaults = defaults
        self.currentPins = currentPins
        self.apply = apply
        localProjection = currentPins()
        available = containerIdentifier != nil || exchange != nil
        if let exchange {
            exchangeCloud = exchange
            self.accountAvailable = accountAvailable
        } else if let containerIdentifier {
            let cloud = FoundationPinSyncCloud(containerIdentifier: containerIdentifier)
            self.accountAvailable = accountAvailable ?? { try await cloud.accountAvailable() }
            exchangeCloud = { scope, local, initial, device, account, erase in
                try await cloud.exchange(
                    scope: scope, local: local, initial: initial, device: device,
                    expectedAccount: account, erase: erase)
            }
        } else {
            exchangeCloud = nil
            self.accountAvailable = accountAvailable
        }
        message =
            !available
            ? "iCloud pin sync is unavailable in this build. Your pins stay on this device."
            : "Off. Pins stay on this device."
        let data = defaults.data(forKey: Self.storagePrefix + scope)
        journal =
            data.flatMap { try? JSONDecoder().decode(Journal.self, from: $0) }
            ?? Journal(device: UUID(), enabled: false)
        // Consent is scoped to this authorized library. An account-change notification
        // revokes this lifetime; re-enabling requires an explicit action.
        enabled = available && journal.enabled && journal.needsRecovery != true
        if journal.needsRecovery == true {
            message =
                "Sync is paused to protect unsynced local pins. Keep using local pins, or undo unsynced edits until they fit the sync limits before enabling again."
        }
        accountObservation = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            _ = MainActor.assumeIsolated { self?.accountChanged() }
        }
        #if os(iOS)
            let activation = UIApplication.didBecomeActiveNotification
        #else
            let activation = NSApplication.didBecomeActiveNotification
        #endif
        foregroundObservation = NotificationCenter.default.addObserver(
            forName: activation, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        if enabled { refresh() }
    }

    /// The native observer invokes this synchronously on its declared main queue.
    /// Capture generation before enqueueing so a queued notification cannot outlive
    /// retirement or supersede a later consent decision.
    @discardableResult
    func accountChanged() -> Task<Void, Never> {
        let token = generation
        return Task { @MainActor [weak self] in
            guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
            self.promptAccountStable = false
            self.setEnabled(false, recordsDecision: false)
            if self.journal.needsRecovery != true {
                self.journal.state = nil
                self.journal.account = nil
            }
            // A capacity pause retains its old association and intent; switching
            // iCloud accounts cannot silently clear the recovery requirement.
            try? self.save()
            self.message =
                "iCloud account changed. Pins remain local; review before enabling sync again."
        }
    }

    private func save() throws {
        let data = try JSONEncoder().encode(journal)
        let key = Self.storagePrefix + scope
        defaults.set(data, forKey: key)
        guard defaults.data(forKey: key) == data else {
            throw FoundationPinSyncState.Failure.invalid
        }
    }

    private var canOfferOptIn: Bool {
        active && promptAccountStable && available && !enabled && journal.enabled == false
            && journal.account == nil && journal.needsRecovery != true
            && journal.promptHandled != true
    }

    /// One status check on foreground appearance; no pin or user-record read before consent.
    func prepareOptInPrompt() async {
        guard canOfferOptIn, !checkedPrompt, let accountAvailable else { return }
        checkedPrompt = true
        let token = generation
        let ready = (try? await accountAvailable()) == true
        guard canOfferOptIn, generation == token else { return }
        // A disappearing root may cancel its status callback. The next explicit
        // appearance can check again; no task or timer retries in the background.
        guard !Task.isCancelled else {
            checkedPrompt = false
            return
        }
        offersOptIn = ready
    }

    /// Presentation ownership is memory-only. Only an explicit choice records a decision.
    func claimOptInPrompt(owner: UUID) -> Bool {
        guard canOfferOptIn, offersOptIn, promptOwner == nil else { return false }
        promptOwner = owner
        return true
    }

    func ownsOptInPrompt(_ owner: UUID) -> Bool {
        canOfferOptIn && offersOptIn && promptOwner == owner
    }

    func releaseOptInPrompt(owner: UUID) {
        if promptOwner == owner { promptOwner = nil }
    }

    func respondToOptInPrompt(owner: UUID, enable: Bool) {
        guard ownsOptInPrompt(owner) else { return }
        setEnabled(enable)
    }

    func setEnabled(_ value: Bool, recordsDecision: Bool = true) {
        guard active, !value || available else { return }
        if value, journal.needsRecovery == true {
            message =
                "Sync is paused to protect unsynced local pins. Keep using local pins, or undo unsynced edits until they fit the sync limits before enabling again."
            return
        }
        generation = UUID()
        if recordsDecision { journal.promptHandled = true }
        offersOptIn = false
        promptOwner = nil
        task?.cancel()
        task = nil
        isSyncing = false
        enabled = value
        journal.enabled = value
        do {
            try save()
            message =
                value ? "Waiting to sync…" : "Off. Local pins kept; cloud pins remain in iCloud."
            if value { refresh() }
        } catch {
            enabled = false
            message = "Sync preferences could not be saved. Pins remain local."
        }
    }

    /// Persists edits even during a service outage; disabled sync performs no cloud work.
    func pinsChanged() {
        guard active else { return }
        revision &+= 1
        if journal.needsRecovery == true, journal.recoveryBaseline == nil {
            message =
                "Sync remains paused because recovery history is unavailable. Your local pins are kept."
            return
        }
        if var state = journal.state {
            do {
                let current = currentPins()
                let baseline = journal.recoveryBaseline ?? localProjection
                let removed = Set(baseline).subtracting(current)
                let added = Set(current).subtracting(baseline)
                let desired =
                    current.filter { added.contains($0) || state.pins.contains($0) }
                    + state.pins.filter { !removed.contains($0) && !current.contains($0) }
                try state.edit(desired, device: journal.device)
                let wasPaused = journal.needsRecovery == true
                journal.state = state
                journal.needsRecovery = false
                journal.recoveryBaseline = nil
                try save()
                if wasPaused {
                    message =
                        "Local changes fit the sync limits again. Review before enabling sync."
                }
            } catch {
                journal.needsRecovery = true
                if journal.recoveryBaseline == nil { journal.recoveryBaseline = localProjection }
                setEnabled(false, recordsDecision: false)
                message =
                    "Local pins saved, but sync changes could not be recorded. Sync stays paused to protect unsynced pins, including after relaunch."
                return
            }
        }
        localProjection = currentPins()
        if enabled { refresh() }
    }

    func refresh() { exchange(erase: false) }
    func deleteCloudPins() { exchange(erase: true) }

    private func exchange(erase: Bool) {
        guard active, enabled, journal.needsRecovery != true,
            task == nil, let exchangeCloud
        else { return }
        let token = generation
        let startedRevision = revision
        let local = journal.state
        let initial = currentPins()
        let account = journal.account
        let device = journal.device
        let scope = scope
        isSyncing = true
        message = erase ? "Deleting cloud-saved pins…" : "Syncing pins…"
        task = Task { [weak self] in
            do {
                let result = try await exchangeCloud(scope, local, initial, device, account, erase)
                guard let self, self.active, self.enabled, self.generation == token,
                    !Task.isCancelled
                else { return }
                // Preserve local edits made while the request was suspended. A cloud erase
                // supersedes old-epoch edits; no stale-device migration runs afterward.
                var state = result.state
                if !erase, !result.reset, let pending = self.journal.state {
                    state = try state.merging(pending)
                } else if !erase, !result.reset, self.revision != startedRevision {
                    let current = self.currentPins()
                    let removed = Set(initial).subtracting(current)
                    let added = Set(current).subtracting(initial)
                    let desired =
                        current.filter { state.pins.contains($0) || added.contains($0) }
                        + state.pins.filter { !removed.contains($0) && !current.contains($0) }
                    try state.edit(desired, device: device)
                }
                self.journal.state = state
                self.journal.account = result.account
                try self.save()
                if !erase {
                    try await self.apply(state.pins) { [weak self] in
                        guard let self else { return false }
                        return self.active && self.enabled && self.generation == token
                            && self.revision == startedRevision && !Task.isCancelled
                    }
                    guard self.active, self.enabled, self.generation == token,
                        !Task.isCancelled
                    else { return }
                }
                self.localProjection = self.currentPins()
                self.message =
                    erase
                    ? "Cloud pins deleted. Local pins kept; other devices remove cloud pins on their next sync."
                    : result.reset
                        ? "Cloud pins were deleted. Old offline edits were not uploaded."
                        : "Pins synced. Missing items remain in iCloud until available in this library."
                self.task = nil
                self.isSyncing = false
                if !erase, !result.reset, self.revision != startedRevision { self.refresh() }
            } catch {
                guard let self, self.active, self.enabled, self.generation == token,
                    !Task.isCancelled
                else { return }
                self.task = nil
                self.isSyncing = false
                self.message =
                    "Pins remain local. iCloud sync did not finish; use Sync Now to retry."
            }
        }
    }

    func invalidate() {
        active = false
        offersOptIn = false
        promptOwner = nil
        generation = UUID()
        task?.cancel()
        task = nil
        isSyncing = false
        if let accountObservation { NotificationCenter.default.removeObserver(accountObservation) }
        accountObservation = nil
        if let foregroundObservation {
            NotificationCenter.default.removeObserver(foregroundObservation)
        }
        foregroundObservation = nil
    }
}
