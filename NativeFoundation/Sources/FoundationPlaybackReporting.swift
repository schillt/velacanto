import Foundation

/// A playback occurrence is distinct from both a catalog item and a queue occurrence
/// (repeat-one starts a new occurrence). Contains no URL, credential, or persisted history.
struct FoundationPlaybackReport: Sendable, Equatable {
    enum Kind: Sendable { case start, progress, stop }
    let kind: Kind
    let occurrenceID: UUID
    let itemID: String
    let position: Double
    let paused: Bool
    var source: FoundationPlaybackSource? = nil
}

/// One account's best-effort reporting. Audio never awaits this owner. One request is
/// in flight, at most 32 events wait, and each admitted start reserves its stop slot.
/// Overload drops whole new occurrences; it never queues a stop without its start.
@MainActor
final class FoundationPlaybackReporting {
    static let maximumPending = 32
    private let send: @Sendable (FoundationPlaybackReport) async throws -> Void
    private let now: () -> TimeInterval
    private var current: (id: UUID, itemID: String, source: FoundationPlaybackSource?)?
    private var lastProgress: TimeInterval = 0
    private var lastPaused = false
    private(set) var pending: [FoundationPlaybackReport] = []
    private(set) var task: Task<Void, Never>?
    private var active = true
    private var generation: UInt = 0

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        send: @escaping @Sendable (FoundationPlaybackReport) async throws -> Void
    ) {
        self.now = now
        self.send = send
    }

    func begin(itemID: String, position: Double, source: FoundationPlaybackSource? = nil) {
        guard active, current == nil, pending.count <= Self.maximumPending - 2 else { return }
        current = (UUID(), itemID, source)
        lastProgress = now()
        lastPaused = false
        append(.start, position: position, paused: false)
    }

    func progress(position: Double, paused: Bool, seek: Bool = false) {
        guard active, let current else { return }
        let instant = now()
        guard seek || paused != lastPaused || (!paused && instant - lastProgress >= 10) else {
            return
        }
        lastProgress = instant
        lastPaused = paused
        // Coalesce unsent state for this occurrence, retaining lifecycle order.
        pending.removeAll { $0.kind == .progress && $0.occurrenceID == current.id }
        guard pending.count < Self.maximumPending - 1 else { return }
        append(.progress, position: position, paused: paused)
    }

    func stop(position: Double) {
        guard active, let current else { return }
        pending.removeAll { $0.kind == .progress && $0.occurrenceID == current.id }
        append(.stop, position: position, paused: true)
        self.current = nil
    }

    func invalidate() {
        active = false
        cancelPending()
    }

    /// Going offline discards unsent work; reconnecting never replays it.
    func cancelPending() {
        generation &+= 1
        current = nil
        pending.removeAll()
        task?.cancel()
    }

    private func append(_ kind: FoundationPlaybackReport.Kind, position: Double, paused: Bool) {
        guard let current else { return }
        pending.append(
            .init(
                kind: kind, occurrenceID: current.id, itemID: current.itemID,
                position: position.isFinite ? max(0, position) : 0, paused: paused,
                source: current.source))
        startWorker()
    }

    private func startWorker() {
        guard active, !pending.isEmpty, task == nil else { return }
        let owner = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.startWorker()
            }
            while self.active, self.generation == owner, !Task.isCancelled, !self.pending.isEmpty {
                let event = self.pending.removeFirst()
                do { try await self.send(event) } catch {
                    // Best effort, no retry or persisted replay. Later events remain independent.
                }
            }
        }
    }
}

/// Best-effort HLS session cleanup, independent of audio and listening reports.
/// Operations must use a finite transport timeout. Never retains more than one
/// active operation and 32 pending operations; it does not retry dropped work.
actor FoundationHLSCleanup {
    static let maximumPending = 32
    static let maximumPendingAge: TimeInterval = 10

    private struct Job: Sendable {
        let key: String
        let admitted: TimeInterval
        let operation: @Sendable () async -> Void
    }

    private let now: @Sendable () -> TimeInterval
    private var pending: [Job] = []
    private var activeKey: String?
    private(set) var overflowDrops = 0
    private(set) var expiredDrops = 0
    private(set) var task: Task<Void, Never>?
    var pendingCount: Int { pending.count }

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func enqueue(key: String, operation: @escaping @Sendable () async -> Void) {
        discardExpired()
        guard activeKey != key, !pending.contains(where: { $0.key == key }) else { return }
        guard task != nil else {
            start(Job(key: key, admitted: now(), operation: operation))
            return
        }
        guard pending.count < Self.maximumPending else {
            overflowDrops += 1
            #if DEBUG
                FoundationJournal.shared.record("player.hls.cleanup event=dropped reason=capacity")
            #endif
            return
        }
        pending.append(Job(key: key, admitted: now(), operation: operation))
    }

    private func discardExpired() {
        let instant = now()
        let previous = pending.count
        pending.removeAll { instant - $0.admitted >= Self.maximumPendingAge }
        let dropped = previous - pending.count
        if dropped > 0 {
            expiredDrops += dropped
            #if DEBUG
                FoundationJournal.shared.record(
                    "player.hls.cleanup event=dropped reason=expired count=\(dropped)")
            #endif
        }
    }

    private func start(_ job: Job) {
        activeKey = job.key
        task = Task {
            await job.operation()
            self.completed()
        }
    }

    private func completed() {
        activeKey = nil
        task = nil
        discardExpired()
        guard !pending.isEmpty else { return }
        start(pending.removeFirst())
    }
}

/// Owns one exact server job, distinct from queue and listening occurrences.
/// Releasing a native resource never waits for the cleanup request to finish.
actor FoundationHLSLease {
    private let owner: FoundationHLSCleanup
    private let key: String
    private var operation: (@Sendable () async -> Void)?

    init(
        owner: FoundationHLSCleanup, key: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        self.owner = owner
        self.key = key
        self.operation = operation
    }

    func release() async {
        guard let operation else { return }
        self.operation = nil
        await owner.enqueue(key: key, operation: operation)
    }
}
