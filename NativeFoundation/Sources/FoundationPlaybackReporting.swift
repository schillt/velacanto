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
}

/// One account's best-effort reporting. Audio never awaits this owner. One request is
/// in flight, at most 32 events wait, and each admitted start reserves its stop slot.
/// Overload drops whole new occurrences; it never queues a stop without its start.
@MainActor
final class FoundationPlaybackReporting {
    static let maximumPending = 32
    private let send: @Sendable (FoundationPlaybackReport) async throws -> Void
    private let now: () -> TimeInterval
    private var current: (id: UUID, itemID: String)?
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

    func begin(itemID: String, position: Double) {
        guard active, current == nil, pending.count <= Self.maximumPending - 2 else { return }
        current = (UUID(), itemID)
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
                position: position.isFinite ? max(0, position) : 0, paused: paused))
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
