import AVFoundation
import Combine
import Foundation

struct FoundationQueueEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let item: FoundationItem
}

@MainActor
final class FoundationPlayer: ObservableObject {
    enum State: String { case idle, loading, paused, waiting, playing, failed, ended }
    enum QueuePosition { case next, last }

    @Published private(set) var queue: [FoundationQueueEntry] = []
    @Published private(set) var selectedEntryID: UUID?
    @Published private(set) var state: State = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0

    // Internal access lets tests await the exact selection, including an obsolete task.
    private(set) var selectionTask: Task<Void, Never>?
    private(set) var nativePlayer = AVPlayer()
    private var generation: UInt64 = 0
    private let resolve: @Sendable (FoundationItem) async throws -> URL
    private let makeItem: (URL) -> AVPlayerItem
    private let activateSession: () throws -> Void
    private let deactivateSession: () -> Void
    private let startPlayback: (AVPlayer) -> Void
    private var isStartingPlayback = false
    private var rejectionDuringStart = false
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    @Published private(set) var wantsPlayback = false

    convenience init(
        library: any FoundationLibrary,
        makeItem: @escaping (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) }
    ) {
        self.init(resolve: { try await library.playbackURL(for: $0) }, makeItem: makeItem)
    }

    init(
        resolve: @escaping @Sendable (FoundationItem) async throws -> URL,
        makeItem: @escaping (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
        activateSession: @escaping () throws -> Void = {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
            #endif
        },
        deactivateSession: @escaping () -> Void = {
            #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(
                    false, options: .notifyOthersOnDeactivation)
            #endif
        },
        startPlayback: @escaping (AVPlayer) -> Void = { $0.play() }
    ) {
        self.resolve = resolve
        self.makeItem = makeItem
        self.activateSession = activateSession
        self.startPlayback = startPlayback
        self.deactivateSession = deactivateSession
        observations = [
            nativePlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNativeState() }
            },
            nativePlayer.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refreshNativeState() }
            },
        ]
        timeObserver = nativePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshTime() }
        }
        notifications.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in self?.didReachEnd(item) }
            })
        notifications.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let item = notification.object as? AVPlayerItem else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.nativePlayer.currentItem === item else { return }
                    self.fail(.nativeEnd, error: item.error)
                }
            })
        notifications.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: nativePlayer, queue: .main
            ) { [weak self] notification in
                guard
                    let value = notification.userInfo?[AVPlayer.rateDidChangeReasonKey] as? String,
                    AVPlayer.RateDidChangeReason(rawValue: value) == .setRateFailed
                else { return }
                // Reconcile at delivery; a deferred callback must not clear a newer Play command.
                MainActor.assumeIsolated { self?.reconcileRejectedStart() }
            })
        #if os(iOS)
            notifications.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.didBecomeInactiveNotification,
                    object: AVAudioSession.sharedInstance(), queue: .main
                ) { [weak self] notification in
                    guard
                        let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                            as? AVAudioSession.DeactivationContext
                    else { return }
                    // Handle main-queue delivery here, without deferring a pause past a newer command.
                    MainActor.assumeIsolated {
                        self?.didDeactivateAudioSession(source: context.source)
                    }
                })
        #endif
    }

    isolated deinit {
        selectionTask?.cancel()
        if let timeObserver { nativePlayer.removeTimeObserver(timeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        nativePlayer.pause()
        nativePlayer.currentItem?.asset.cancelLoading()
        nativePlayer.replaceCurrentItem(with: nil)
    }

    func setQueue(_ items: [FoundationItem], selectedIndex: Int) {
        #if DEBUG
            recordSnapshot("command.setQueue")
        #endif
        discardSelection()
        queue = items.map { FoundationQueueEntry(item: $0) }
        selectedEntryID = nil
        state = .idle
        guard queue.indices.contains(selectedIndex) else { return }
        select(queue[selectedIndex].id)
    }

    /// Extend the queue without replacing the selected occurrence or native item.
    func enqueue(_ items: [FoundationItem], position: QueuePosition) {
        guard !items.isEmpty, items.allSatisfy({ $0.kind == .track }) else { return }
        let entries = items.map { FoundationQueueEntry(item: $0) }
        let insertion = position == .next ? selectedIndex.map { $0 + 1 } ?? 0 : queue.endIndex
        queue.insert(contentsOf: entries, at: insertion)
        if selectedEntryID == nil { select(entries[0].id) }
    }

    /// Move this occurrence, preserving duplicate tracks and the current native selection.
    func moveQueuedEntry(_ id: UUID, position: QueuePosition) {
        guard id != selectedEntryID, let index = queue.firstIndex(where: { $0.id == id }) else {
            return
        }
        var updated = queue
        let entry = updated.remove(at: index)
        let currentIndex = updated.firstIndex { $0.id == selectedEntryID }
        let insertion = position == .next ? currentIndex.map { $0 + 1 } ?? 0 : updated.endIndex
        updated.insert(entry, at: insertion)
        queue = updated
    }

    func select(_ id: UUID) {
        guard let entry = queue.first(where: { $0.id == id }) else { return }
        discardSelection()
        selectedEntryID = id
        wantsPlayback = true
        state = .loading
        let selectionGeneration = generation
        let resolve = resolve
        #if DEBUG
            recordSnapshot("selection.started")
        #endif
        selectionTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let url = try await resolve(entry.item)
                try Task.checkCancellation()
                guard let self, self.generation == selectionGeneration else { return }
                let item = self.makeItem(url)
                self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refreshNativeState() }
                }
                self.nativePlayer.replaceCurrentItem(with: item)
                #if DEBUG
                    self.recordSnapshot("item.installed")
                #endif
                self.selectionTask = nil
                if self.wantsPlayback { self.play() } else { self.refreshNativeState() }
            } catch {
                guard let self, self.generation == selectionGeneration else { return }
                self.selectionTask = nil
                self.fail(.resolution, error: error)
            }
        }
    }

    func next() {
        #if DEBUG
            recordSnapshot("command.next")
        #endif
        guard let index = selectedIndex, queue.indices.contains(index + 1) else { return }
        select(queue[index + 1].id)
    }

    func previous() {
        #if DEBUG
            recordSnapshot("command.previous")
        #endif
        guard let index = selectedIndex else { return }
        let position = nativePlayer.currentTime().seconds
        if position.isFinite, position > 3 {
            seek(to: 0, entryID: queue[index].id)
        } else if index > 0 {
            select(queue[index - 1].id)
        }
    }

    func togglePlayback() {
        #if DEBUG
            recordSnapshot("command.toggle")
        #endif
        if wantsPlayback { pause() } else { play() }
    }

    /// A completed user scrub applies only to the occurrence that began the gesture.
    func seek(to seconds: Double, entryID: UUID) {
        guard entryID == selectedEntryID, seconds.isFinite, duration > 0,
            nativePlayer.currentItem?.status == .readyToPlay
        else { return }
        let target = CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600)
        #if DEBUG
            let direction =
                target.seconds < nativePlayer.currentTime().seconds ? "backward" : "forward"
            let seekGeneration = generation
            FoundationTrace.event("seek.request direction=\(direction)")
            nativePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
                [weak self] finished in
                Task { @MainActor in
                    guard let self else { return }
                    let current =
                        self.selectedEntryID == entryID && self.generation == seekGeneration
                    let reached =
                        current && abs(self.nativePlayer.currentTime().seconds - target.seconds) < 1
                    FoundationTrace.event(
                        "seek.complete direction=\(direction) finished=\(finished ? 1 : 0) current=\(current ? 1 : 0) reached=\(reached ? 1 : 0)"
                    )
                }
            }
        #else
            nativePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        #endif
    }

    func stop() {
        discardSelection()
        state = .idle
        #if DEBUG
            recordSnapshot("command.stop")
        #endif
        deactivateSession()
    }

    private var selectedIndex: Int? { queue.firstIndex { $0.id == selectedEntryID } }

    /// Requests playback explicitly, retaining the current occurrence when native start was rejected.
    /// Repeated commands during an active start do not reactivate the session or replace the item.
    func play() {
        #if DEBUG
            recordSnapshot("command.play")
        #endif
        if state == .failed, let selectedEntryID {
            select(selectedEntryID)
            return
        }
        guard nativePlayer.currentItem != nil else {
            if selectionTask != nil {
                wantsPlayback = true
                state = .loading
            } else if let selectedEntryID {
                select(selectedEntryID)
            }
            return
        }
        // Ended items restart through the same explicit selection path.
        if state == .ended, let selectedEntryID {
            select(selectedEntryID)
            return
        }
        if wantsPlayback, nativePlayer.rate > 0 { return }
        do {
            try activateSession()
            wantsPlayback = true
            isStartingPlayback = true
            rejectionDuringStart = false
            startPlayback(nativePlayer)
            isStartingPlayback = false
            if rejectionDuringStart {
                rejectionDuringStart = false
                reconcileRejectedStart()
            }
            refreshNativeState()
        } catch { fail(.audioSession, error: error) }
    }

    #if os(iOS)
        /// Applies system inactivity in notification order through the existing pause operation.
        /// App-requested deactivation is already handled by stop; resumption never starts audio automatically.
        func didDeactivateAudioSession(source: AVAudioSession.DeactivationSource) {
            guard source == .system else { return }
            pause()
        }
    #endif

    /// Cancels playback intent, including a pending resolution, without discarding the occurrence.
    /// A later explicit Play may resume the same item; inactivity never resumes it automatically.
    func pause() {
        #if DEBUG
            recordSnapshot("command.pause")
        #endif
        wantsPlayback = false
        nativePlayer.pause()
        refreshNativeState()
    }

    /// Only an explicit native rejection can end a pending start; transient paused readiness cannot.
    /// Consult current native state so a delayed notification cannot interrupt an already active start.
    private func reconcileRejectedStart() {
        // Native start may deliver an earlier rate notification reentrantly. Inspect its final state.
        if isStartingPlayback {
            rejectionDuringStart = true
            return
        }
        guard wantsPlayback, nativePlayer.currentItem != nil,
            nativePlayer.currentItem?.status != .failed,
            nativePlayer.timeControlStatus == .paused, nativePlayer.rate == 0,
            state != .failed, state != .ended
        else { return }
        wantsPlayback = false
        refreshNativeState()
        #if DEBUG
            recordSnapshot("start.rejected")
        #endif
    }

    private func discardSelection() {
        generation &+= 1
        #if DEBUG
            recordSnapshot("discard.cancelRequested")
        #endif
        selectionTask?.cancel()
        selectionTask = nil
        wantsPlayback = false
        itemObservation = nil
        nativePlayer.pause()
        let oldItem = nativePlayer.currentItem
        nativePlayer.replaceCurrentItem(with: nil)
        oldItem?.cancelPendingSeeks()
        oldItem?.asset.cancelLoading()
        elapsed = 0
        duration = 0
        errorMessage = nil
    }

    private func refreshNativeState() {
        #if DEBUG
            defer { recordSnapshot("native.observed") }
        #endif
        guard state != .failed, state != .ended else { return }
        guard let item = nativePlayer.currentItem else {
            state = selectionTask == nil ? .idle : (wantsPlayback ? .loading : .paused)
            return
        }
        if nativePlayer.status == .failed {
            fail(.nativePlayer, error: nativePlayer.error)
            return
        }
        if item.status == .failed {
            fail(.nativeItem, error: item.error)
            return
        }
        switch nativePlayer.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .waiting
        case .paused: state = item.status == .unknown && wantsPlayback ? .loading : .paused
        @unknown default: state = .paused
        }
        refreshTime()
    }

    private func refreshTime() {
        let seconds = nativePlayer.currentTime().seconds
        let length = nativePlayer.currentItem?.duration.seconds ?? 0
        elapsed = seconds.isFinite ? max(0, seconds) : 0
        duration = length.isFinite ? max(0, length) : 0
    }

    // Native callback identity is the only end-of-item seam; no simulated transport state.
    func didReachEnd(_ item: AVPlayerItem) {
        guard nativePlayer.currentItem === item, state != .failed else { return }
        #if DEBUG
            recordSnapshot("item.ended")
        #endif
        if let index = selectedIndex, queue.indices.contains(index + 1) {
            next()
        } else {
            wantsPlayback = false
            nativePlayer.pause()
            state = .ended
            refreshTime()
        }
    }

    private enum FailureCategory: String {
        case resolution, audioSession, nativePlayer, nativeItem, nativeEnd
    }

    private func fail(_ category: FailureCategory, error: Error?) {
        wantsPlayback = false
        nativePlayer.pause()
        state = .failed
        errorMessage = "Playback failed. Select a track to try again."
        #if DEBUG
            let errorKind: String
            if let error = error as? URLError {
                switch error.code {
                case .cancelled: errorKind = "cancelled"
                case .timedOut: errorKind = "timeout"
                case .networkConnectionLost, .notConnectedToInternet: errorKind = "connectivity"
                case .secureConnectionFailed, .serverCertificateUntrusted: errorKind = "security"
                default: errorKind = "networkOther"
                }
            } else {
                errorKind = error == nil ? "unavailable" : "other"
            }
            recordSnapshot("failure." + category.rawValue + "." + errorKind)
        #endif
    }

    #if DEBUG
        private func recordSnapshot(_ event: String) {
            let itemStatus: String
            switch nativePlayer.currentItem?.status {
            case .unknown?: itemStatus = "unknown"
            case .readyToPlay?: itemStatus = "ready"
            case .failed?: itemStatus = "failed"
            case nil: itemStatus = "none"
            @unknown default: itemStatus = "other"
            }
            let control: String
            switch nativePlayer.timeControlStatus {
            case .paused: control = "paused"
            case .waitingToPlayAtSpecifiedRate: control = "waiting"
            case .playing: control = "playing"
            @unknown default: control = "other"
            }
            let reason: String
            switch nativePlayer.reasonForWaitingToPlay {
            case .evaluatingBufferingRate?: reason = "evaluatingBuffer"
            case .toMinimizeStalls?: reason = "minimizeStalls"
            case .noItemToPlay?: reason = "noItem"
            case nil: reason = "none"
            default: reason = "other"
            }
            FoundationJournal.shared.record(
                "player.\(event) generation=\(generation) state=\(state.rawValue) "
                    + "item=\(itemStatus) control=\(control) wait=\(reason) intent=\(wantsPlayback ? 1 : 0)"
            )
        }
    #endif

}
