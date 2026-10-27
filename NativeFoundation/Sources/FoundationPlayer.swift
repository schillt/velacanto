import AVFoundation
import Combine
import Foundation

/// Delivery intent and server identity, separate from a queue occurrence. Never log identifiers.
struct FoundationPlaybackSource: Sendable, Equatable {
    enum Delivery: String, Sendable { case unknown, localFile, directPreferred, hlsAAC, hlsCopy }
    let delivery: Delivery
    var mediaSourceID: String? = nil
    var serverSessionID: String? = nil
}

/// A native URL, delivery description and resource-specific retirement action.
struct FoundationPlaybackResource: Sendable {
    let url: URL
    let source: FoundationPlaybackSource
    let release: @Sendable () async -> Void

    init(
        url: URL, source: FoundationPlaybackSource? = nil,
        release: @escaping @Sendable () async -> Void = {}
    ) {
        self.url = url
        self.source = source ?? .init(delivery: url.isFileURL ? .localFile : .unknown)
        self.release = release
    }
}

struct FoundationQueueEntry: Identifiable, Equatable, Sendable {
    let id: UUID

    init(id: UUID = UUID(), item: FoundationItem) {
        self.id = id
        self.item = item
    }
    let item: FoundationItem
}

@MainActor
final class FoundationPlayer: ObservableObject {
    enum State: String { case idle, loading, paused, waiting, playing, failed, ended }
    enum QueuePosition { case next, last }
    enum RepeatMode: String, Codable, CaseIterable { case off, all, one }

    @Published private(set) var shuffleEnabled = false
    @Published private(set) var repeatMode: RepeatMode = .off
    let sessionChanged = PassthroughSubject<Void, Never>()

    var history: [FoundationQueueEntry] { selectedIndex.map { Array(queue.prefix($0)) } ?? [] }
    var upcoming: [FoundationQueueEntry] {
        selectedIndex.map { Array(queue.dropFirst($0 + 1)) } ?? queue
    }
    var canAdvance: Bool { !upcoming.isEmpty || (repeatMode == .all && !queue.isEmpty) }

    func setShuffle(_ enabled: Bool) {
        guard enabled != shuffleEnabled else { return }
        shuffleEnabled = enabled
        if enabled {
            let prefixCount =
                selectedEntryID.flatMap { id in rawQueue.firstIndex { $0.id == id }.map { $0 + 1 } }
                ?? 0
            rawQueue =
                Array(rawQueue.prefix(prefixCount)) + rawQueue.dropFirst(prefixCount).shuffled()
        }
        sessionChanged.send()
    }

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        sessionChanged.send()
    }

    func removeUpcoming(_ id: UUID) {
        guard upcoming.contains(where: { $0.id == id }) else { return }
        continuationVisibleIDs?.remove(id)
        rawQueue.removeAll { $0.id == id }
        sessionChanged.send()
    }

    /// IDs are validated against the live upcoming region, rejecting stale drag results.
    func reorderUpcoming(_ ids: [UUID], before destination: UUID?) {
        let live = upcoming
        let sources = Set(ids)
        guard !ids.isEmpty, sources.count == ids.count,
            sources.isSubset(of: Set(live.map(\.id))),
            destination == nil || live.contains(where: { $0.id == destination }),
            destination.map({ !sources.contains($0) }) ?? true
        else { return }
        let moved = live.filter { sources.contains($0.id) }
        var remaining = live.filter { !sources.contains($0.id) }
        let insertion =
            destination.flatMap { target in remaining.firstIndex { $0.id == target } }
            ?? remaining.endIndex
        remaining.insert(contentsOf: moved, at: insertion)
        let liveIDs = Set(live.map(\.id))
        var reordered = remaining.makeIterator()
        rawQueue = rawQueue.map { liveIDs.contains($0.id) ? reordered.next()! : $0 }
        sessionChanged.send()
    }

    func restoreSession(_ snapshot: FoundationPlaybackSnapshot) {
        guard snapshot.isValid else { return }
        discardSelection()
        selectedEntryID = nil
        continuationVisibleIDs = snapshot.visibleEntryIDs.map(Set.init)
        rawQueue = snapshot.entries.map(\.entry)
        // The saved current occurrence stays selected even when an older alternative copy
        // is preferred by the browsing projection; restoration must not jump into history.
        selectedEntryID = rawQueue.first { $0.id == snapshot.selectedEntryID }?.id
        shuffleEnabled = snapshot.shuffleEnabled
        repeatMode = snapshot.repeatMode
        state = selectedEntryID == nil ? .idle : .paused
        sessionChanged.send()
    }

    /// A confirmed Handoff preserves occurrence identity and order. Paused continuation
    /// retains only a deferred position until the user explicitly requests playback.
    @discardableResult
    func continueSession(
        _ snapshot: FoundationPlaybackSnapshot, position: Double, wasPlaying: Bool,
        finalPosition: (@MainActor @Sendable () async throws -> Double)? = nil
    ) -> Bool {
        guard snapshot.isValid, let selected = snapshot.selectedEntryID,
            snapshot.entries.contains(where: { $0.id == selected }), position.isFinite,
            position >= 0, position <= Double(Int64.max / 600) - 1
        else { return false }
        restoreSession(snapshot)
        pausedContinuationPosition = (selected, position)
        refreshTime()
        if wasPlaying {
            select(
                selected, retainingEndedItem: false, initialPosition: position,
                finalPosition: finalPosition)
        }
        return true
    }

    /// Reads the native clock at the transfer boundary, not the periodically published UI time.
    func nativeContinuationPosition(generation expected: UInt64, occurrence: UUID) throws -> Double
    {
        guard generation == expected, selectedEntryID == occurrence,
            selectionTask == nil, initialContinuationSeek == nil,
            nativePlayer.currentItem?.status == .readyToPlay
        else { throw FoundationHandoffError.changed }
        let value = nativePlayer.currentTime().seconds
        guard value.isFinite, value >= 0, value <= Double(Int64.max / 600) - 1 else {
            throw FoundationHandoffError.positionUnavailable
        }
        return value
    }

    /// Retirement may cancel only this unstarted continuation, never a newer selection
    /// or playback that has already completed its readiness/seek boundary.
    func cancelPendingContinuation(generation expected: UInt64) {
        guard generation == expected,
            !(state == .playing && nativePlayer.timeControlStatus == .playing
                && nativePlayer.rate > 0),
            initialContinuationSeek?.finalPosition != nil || continuationPositionTask != nil
                || selectionTask != nil || playTask != nil || wantsPlayback
        else { return }
        nativePlayer.currentItem?.cancelPendingSeeks()
        // Use the existing generation/resource boundary. Keep an already prepared
        // native item available for the user's new explicit seek or Play command.
        discardSelection(retainingNativeItem: true)
        nativePlayer.pause()
        state = selectedEntryID == nil ? .idle : .paused
        refreshTime()
    }

    var continuationGeneration: UInt64 { generation }

    func isNativeContinuationPlaying(generation expected: UInt64, occurrence: UUID) -> Bool {
        generation == expected && selectedEntryID == occurrence && wantsPlayback
            && state == .playing && nativePlayer.timeControlStatus == .playing
            && nativePlayer.rate > 0 && nativePlayer.currentItem?.status == .readyToPlay
    }

    @Published private var rawQueue: [FoundationQueueEntry] = [] {
        didSet {
            observeTrackCopies(rawQueue.map(\.item))
            refreshTrackVisibility()
        }
    }
    private var projectTracks: ([FoundationItem]) -> [FoundationItem] = { $0 }
    private var observeTrackCopies: ([FoundationItem]) -> Void = { _ in }
    @Published private(set) var queue: [FoundationQueueEntry] = []
    var persistedQueue: [FoundationQueueEntry] { rawQueue }
    // A transferred queue keeps its own effective copy selection. Ordinary metadata
    // learning never changes this queue's visibility or the device's preferences.
    private var continuationVisibleIDs: Set<UUID>?
    var persistedVisibleEntryIDs: [UUID]? {
        continuationVisibleIDs.map { visible in
            rawQueue.filter { visible.contains($0.id) }.map(\.id)
        }
    }

    func clearContinuationVisibilityForPreferenceChange() {
        guard continuationVisibleIDs != nil else { return }
        continuationVisibleIDs = nil
        refreshTrackVisibility()
        sessionChanged.send()
    }

    func configureTrackProjection(
        project: @escaping ([FoundationItem]) -> [FoundationItem],
        observe: @escaping ([FoundationItem]) -> Void = { _ in }
    ) {
        projectTracks = project
        observeTrackCopies = observe
        observe(rawQueue.map(\.item))
        refreshTrackVisibility()
    }

    func refreshTrackVisibility() {
        let visibleIDs = continuationVisibleIDs ?? Set(projectedEntries(rawQueue).map(\.id))
        let projection = rawQueue.filter { visibleIDs.contains($0.id) || $0.id == selectedEntryID }
        if projection != queue { queue = projection }
    }

    private func projectedEntries(_ entries: [FoundationQueueEntry]) -> [FoundationQueueEntry] {
        let items = entries.map { entry in
            var item = entry.item
            item.playlistEntryID = entry.id.uuidString
            return item
        }
        let ids = Set(projectTracks(items).compactMap(\.playlistEntryID))
        return entries.filter { ids.contains($0.id.uuidString) }
    }

    private func visibleSelection(
        _ requested: FoundationQueueEntry?, in entries: [FoundationQueueEntry]
    ) -> UUID? {
        guard let requested else { return nil }
        if entries.contains(where: { $0.id == requested.id }) { return requested.id }
        guard let key = FoundationAlbumTrackPolicy.key(for: requested.item) else { return nil }
        return entries.first { FoundationAlbumTrackPolicy.key(for: $0.item) == key }?.id
    }
    @Published private(set) var selectedEntryID: UUID? {
        didSet { refreshTrackVisibility() }
    }
    @Published private(set) var state: State = .idle {
        didSet { publishPlaybackProtection() }
    }
    private var protectionRevision: UInt = 0
    private var playbackProtectionChanged: ((Bool, UInt) -> Void)?

    func observePlaybackProtection(_ changed: @escaping (Bool, UInt) -> Void) {
        playbackProtectionChanged = changed
        publishPlaybackProtection()
    }

    private func publishPlaybackProtection() {
        protectionRevision &+= 1
        let protected =
            wantsPlayback && state != .failed && state != .ended
            && (state == .loading || state == .waiting || playTask != nil)
        playbackProtectionChanged?(protected, protectionRevision)
    }

    @Published private(set) var errorMessage: String?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isInterrupted = false
    let playbackPositionChanged = PassthroughSubject<Void, Never>()
    /// Explicit commands supersede an outstanding continuation even when state
    /// already equals the requested value or a native seek has not completed.
    let playbackCommandReceived = PassthroughSubject<Void, Never>()

    // Internal access lets tests await the exact selection, including an obsolete task.
    private(set) var selectionTask: Task<Void, Never>?
    private(set) var nativePlayer = AVPlayer()
    #if os(macOS)
        /// App gain belongs to the existing player; it does not change system or route volume.
        var playerVolume: Double {
            get { Double(nativePlayer.volume) }
            set {
                guard newValue.isFinite else { return }
                let value = Float(min(max(newValue, 0), 1))
                guard value != nativePlayer.volume else { return }
                objectWillChange.send()
                nativePlayer.volume = value
            }
        }
    #endif
    private var reporting: FoundationPlaybackReporting?
    private var reportingAttempted = false
    private let reportingAllowed: @MainActor @Sendable () -> Bool

    func invalidateReporting() { reporting?.invalidate() }
    func suspendReporting() { reporting?.cancelPending() }

    private var generation: UInt64 = 0
    private var pausedContinuationPosition: (occurrence: UUID, seconds: Double)?
    private struct InitialContinuationSeek: Sendable {
        let id = UUID()
        let generation: UInt64
        let occurrence: UUID
        let seconds: Double
        var issued = false
        var finalPosition: (@MainActor @Sendable () async throws -> Double)? = nil
    }
    private var initialContinuationSeek: InitialContinuationSeek?
    private var continuationPositionTask: Task<Void, Never>?
    private let resolve: @Sendable (FoundationItem) async throws -> FoundationPlaybackResource
    private var installedResource: FoundationPlaybackResource?
    private let makeItem: (URL) -> AVPlayerItem
    private let activateSession: () async throws -> Void
    private let deactivateSession: () async throws -> Void
    private(set) var playTask: Task<Void, Never>? {
        didSet { publishPlaybackProtection() }
    }
    private(set) var sessionTask: Task<Void, Never>?
    private var playRequest: UInt64 = 0
    #if os(iOS)
        private var sessionRecommendationRevision: UInt64 = 0
        private var latestSessionRecommendation: AVAudioSession.ResumptionRecommendation?
        private var pendingSessionResumption:
            (generation: UInt64, request: UInt64, item: AVPlayerItem)?
    #endif
    // AVAudioSession is process-wide; retiring account owners must finish before a new owner activates.
    private static var lastSessionOperation: Task<Void, Never>?
    private let startPlayback: (AVPlayer) -> Void
    private let seekForContinuation:
        @MainActor (AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void) -> Void
    private var isStartingPlayback = false
    private var rejectionDuringStart = false
    private var observations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    @Published private(set) var wantsPlayback = false {
        didSet { publishPlaybackProtection() }
    }

    convenience init(
        library: any FoundationLibrary,
        resolveResource: (@Sendable (FoundationItem) async throws -> FoundationPlaybackResource)? =
            nil,
        makeItem: @escaping (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
        reportingAllowed: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.init(
            resolve: { try await library.playbackURL(for: $0) },
            resolveResource: resolveResource ?? { try await library.playbackResource(for: $0) },
            makeItem: makeItem,
            reportPlayback: { try await library.reportPlayback($0) },
            reportingAllowed: reportingAllowed)
    }

    init(
        resolve: @escaping @Sendable (FoundationItem) async throws -> URL,
        resolveResource: (@Sendable (FoundationItem) async throws -> FoundationPlaybackResource)? =
            nil,
        makeItem: @escaping (URL) -> AVPlayerItem = { AVPlayerItem(url: $0) },
        activateSession: @escaping () async throws -> Void = {
            #if os(iOS)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
                guard try await session.activate(options: []) else {
                    throw AudioSessionFailure.activationDeclined
                }
            #endif
        },
        deactivateSession: @escaping () async throws -> Void = {
            #if os(iOS)
                guard
                    try await AVAudioSession.sharedInstance().deactivate(
                        options: .notifyOthersOnDeactivation)
                else { throw AudioSessionFailure.deactivationDeclined }
            #endif
        },
        startPlayback: @escaping (AVPlayer) -> Void = { $0.play() },
        seekForContinuation:
            @escaping @MainActor (
                AVPlayer, CMTime, @escaping @Sendable (Bool) -> Void
            ) -> Void = { player, time, completion in
                player.seek(
                    to: time, toleranceBefore: .zero, toleranceAfter: .zero,
                    completionHandler: completion)
            },
        reportPlayback: (@Sendable (FoundationPlaybackReport) async throws -> Void)? = nil,
        reportingAllowed: @escaping @MainActor @Sendable () -> Bool = { true }
    ) {
        self.seekForContinuation = seekForContinuation
        self.reportingAllowed = reportingAllowed
        if let reportPlayback {
            reporting = FoundationPlaybackReporting { event in
                guard await reportingAllowed() else { return }
                try await reportPlayback(event)
            }
        }
        self.resolve = resolveResource ?? { FoundationPlaybackResource(url: try await resolve($0)) }
        self.makeItem = makeItem
        self.activateSession = activateSession
        self.startPlayback = startPlayback
        self.deactivateSession = deactivateSession
        #if os(iOS)
            // Keep music on the audio route instead of handing video playback to the receiver.
            nativePlayer.allowsExternalPlayback = false
        #endif
        nativePlayer.actionAtItemEnd = .none
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
        #if DEBUG
            notifications.append(
                NotificationCenter.default.addObserver(
                    forName: AVPlayerItem.newAccessLogEntryNotification, object: nil, queue: .main
                ) { [weak self] notification in
                    guard let item = notification.object as? AVPlayerItem else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.nativePlayer.currentItem === item else { return }
                        self.recordComparisonAccess(item, retiring: false)
                    }
                })
        #endif
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
                    guard let self, self.selectionTask == nil,
                        self.nativePlayer.currentItem === item
                    else { return }
                    self.fail(.nativeEnd, error: item.error)
                }
            })
        let rateChangeReasonKey = AVPlayer.rateDidChangeReasonKey
        notifications.append(
            NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: nativePlayer, queue: .main
            ) { [weak self] notification in
                // Only the copied String crosses into the actor; Notification.userInfo is not Sendable.
                let value = notification.userInfo?[rateChangeReasonKey] as? String
                MainActor.assumeIsolated {
                    #if DEBUG
                        self?.recordSnapshot("native.rate reason=" + Self.rateCategory(value))
                    #endif
                    guard let value,
                        AVPlayer.RateDidChangeReason(rawValue: value) == .setRateFailed
                    else { return }
                    self?.reconcileRejectedStart()
                }
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
                        #if DEBUG
                            self?.recordSnapshot(
                                "session.inactive source="
                                    + Self.deactivationCategory(context.source)
                                    + " reason="
                                    + Self.interruptionCategory(context.interruptionContext?.reason)
                            )
                        #endif
                        self?.didDeactivateAudioSession(source: context.source)
                    }
                })
            notifications.append(
                NotificationCenter.default.addObserver(
                    forName: AVAudioSession.resumptionRecommendationNotification,
                    object: AVAudioSession.sharedInstance(), queue: .main
                ) { [weak self] notification in
                    guard
                        let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                            as? AVAudioSession.ResumptionContext
                    else { return }
                    MainActor.assumeIsolated {
                        self?.didReceiveSessionResumption(context.recommendation)
                    }
                })
            #if DEBUG
                notifications.append(
                    NotificationCenter.default.addObserver(
                        forName: AVAudioSession.routeChangeNotification,
                        object: AVAudioSession.sharedInstance(), queue: .main
                    ) { [weak self] notification in
                        let raw =
                            notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                        MainActor.assumeIsolated {
                            self?.recordSnapshot("session.route reason=" + Self.routeCategory(raw))
                        }
                    })
                notifications.append(
                    NotificationCenter.default.addObserver(
                        forName: AVAudioSession.resumptionRecommendationNotification,
                        object: AVAudioSession.sharedInstance(), queue: .main
                    ) { [weak self] notification in
                        let context =
                            notification.userInfo?[AVAudioSession.resumptionContextKey]
                            as? AVAudioSession.ResumptionContext
                        MainActor.assumeIsolated {
                            self?.recordSnapshot(
                                "session.resumption recommendation="
                                    + Self.resumptionCategory(context?.recommendation))
                        }
                    })
            #endif
        #endif
    }

    isolated deinit {
        reporting?.invalidate()
        playTask?.cancel()
        selectionTask?.cancel()
        continuationPositionTask?.cancel()
        if let timeObserver { nativePlayer.removeTimeObserver(timeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        nativePlayer.pause()
        nativePlayer.currentItem?.asset.cancelLoading()
        nativePlayer.replaceCurrentItem(with: nil)
        if let resource = installedResource { Task { await resource.release() } }
    }

    func setQueue(_ items: [FoundationItem], selectedIndex: Int) {
        #if DEBUG
            recordSnapshot("command.setQueue")
        #endif
        guard items.allSatisfy({ $0.kind == .track }) else { return }
        if items.isEmpty {
            continuationVisibleIDs = nil
            discardSelection()
            selectedEntryID = nil
            rawQueue = []
            state = .idle
            sessionChanged.send()
            return
        }
        guard items.indices.contains(selectedIndex) else { return }
        // Tracks preceding the tapped row were not selected and must not become history.
        var replacements = items[selectedIndex...].map { FoundationQueueEntry(item: $0) }
        observeTrackCopies(items)
        let requested = replacements[0]
        // A canonical copy outside this suffix is not part of the new Play request.
        let selected =
            visibleSelection(requested, in: projectedEntries(replacements)) ?? requested.id
        if let index = replacements.firstIndex(where: { $0.id == selected }), index > 0 {
            // Keep alternate-copy metadata reversible without treating a hidden prefix as played.
            replacements.insert(replacements.remove(at: index), at: 0)
        }
        // A new Play replaces upcoming work, retaining the prior occurrences through current.
        // Resolve the requested occurrence within the new batch, never against old history.
        let retained =
            selectedEntryID.flatMap { id in
                rawQueue.firstIndex { $0.id == id }.map { Array(rawQueue.prefix($0 + 1)) }
            } ?? []
        if shuffleEnabled {
            let prefixCount = (replacements.firstIndex { $0.id == selected } ?? 0) + 1
            replacements =
                Array(replacements.prefix(prefixCount))
                + replacements.dropFirst(prefixCount).shuffled()
        }
        discardSelection()
        selectedEntryID = nil
        continuationVisibleIDs = nil
        rawQueue = retained + replacements
        // An old alternative copy may win the normal duplicate projection. Keep the explicitly
        // requested new occurrence visible as current before select validates its identity.
        selectedEntryID = selected
        state = .idle
        select(selected)
    }

    /// Extend the queue without replacing the selected occurrence or native item.
    func enqueue(_ items: [FoundationItem], position: QueuePosition) {
        guard !items.isEmpty, items.allSatisfy({ $0.kind == .track }) else { return }
        observeTrackCopies(items)
        let entries = projectedEntries(items.map { FoundationQueueEntry(item: $0) })
        guard !entries.isEmpty else { return }
        let insertion =
            position == .next
            ? selectedEntryID.flatMap { id in rawQueue.firstIndex { $0.id == id }.map { $0 + 1 } }
                ?? 0
            : rawQueue.endIndex
        continuationVisibleIDs?.formUnion(entries.map(\.id))
        rawQueue.insert(contentsOf: entries, at: insertion)
        if selectedEntryID == nil { select(entries[0].id) }
        sessionChanged.send()
    }

    /// Move this occurrence, preserving duplicate tracks and the current native selection.
    func moveQueuedEntry(_ id: UUID, position: QueuePosition) {
        guard upcoming.contains(where: { $0.id == id }) else { return }
        let target = position == .next ? upcoming.first(where: { $0.id != id })?.id : nil
        reorderUpcoming([id], before: target)
    }

    func select(_ id: UUID) {
        select(id, retainingEndedItem: false)
    }

    /// Natural successors replace the exhausted item directly, preserving native playback continuity.
    /// Manual selections retain their existing immediate-discard behavior.
    private func select(
        _ id: UUID, retainingEndedItem: Bool, initialPosition: Double? = nil,
        finalPosition: (@MainActor @Sendable () async throws -> Double)? = nil
    ) {
        guard let entry = queue.first(where: { $0.id == id }) else { return }
        discardSelection(retainingNativeItem: retainingEndedItem)
        isInterrupted = false
        if selectedEntryID != id { selectedEntryID = id }
        sessionChanged.send()
        wantsPlayback = true
        state = .loading
        let selectionGeneration = generation
        if let initialPosition {
            initialContinuationSeek = .init(
                generation: selectionGeneration, occurrence: id, seconds: initialPosition,
                finalPosition: finalPosition)
        }
        let resolve = resolve
        #if DEBUG
            comparisonAccessEvents = 0
            selectionStartedAt = ProcessInfo.processInfo.systemUptime
            recordSnapshot("selection.started")
        #endif
        selectionTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let resource = try await resolve(entry.item)
                guard !Task.isCancelled, let self, self.generation == selectionGeneration else {
                    await resource.release()
                    return
                }
                // No suspension between accepting the lease and installing its native item.
                // The old lease remains alive throughout a natural handoff.
                let previousResource = self.installedResource
                self.installedResource = resource
                #if DEBUG
                    self.comparisonInstalledGeneration = selectionGeneration
                #endif
                let item = self.makeItem(resource.url)
                self.itemObservation = item.observe(\.status, options: [.new]) { [weak self] _, _ in
                    Task { @MainActor [weak self] in self?.refreshNativeState() }
                }
                let previousItem = self.nativePlayer.currentItem
                self.nativePlayer.replaceCurrentItem(with: item)
                previousItem?.cancelPendingSeeks()
                previousItem?.asset.cancelLoading()
                if let previousResource { Task { await previousResource.release() } }
                #if DEBUG
                    self.recordSnapshot("item.installed")
                #endif
                self.selectionTask = nil
                if self.initialContinuationSeek != nil {
                    self.refreshNativeState()
                } else if self.wantsPlayback {
                    self.play(allowSessionResumption: true)
                } else {
                    self.refreshNativeState()
                }
            } catch {
                guard let self, self.generation == selectionGeneration else { return }
                self.selectionTask = nil
                self.fail(.resolution, error: error)
                if retainingEndedItem { self.releaseNativeItem() }
            }
        }
    }

    func next() {
        #if DEBUG
            recordSnapshot("command.next")
        #endif
        guard let index = selectedIndex else { return }
        if queue.indices.contains(index + 1) {
            select(queue[index + 1].id)
        } else if repeatMode == .all, let first = queue.first {
            select(first.id)
        }
    }

    func previous() {
        #if DEBUG
            recordSnapshot("command.previous")
        #endif
        guard let index = selectedIndex else { return }
        if selectionTask != nil {
            if index > 0 { select(queue[index - 1].id) }
            return
        }
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
        guard entryID == selectedEntryID, seconds.isFinite else { return }
        playbackCommandReceived.send()
        if let deferred = pausedContinuationPosition, deferred.occurrence == entryID,
            nativePlayer.currentItem == nil
        {
            guard seconds <= Double(Int64.max / 600) - 1 else { return }
            let requested = max(0, seconds)
            pausedContinuationPosition = (
                entryID, duration > 0 ? min(requested, duration) : requested
            )
            refreshTime()
            playbackPositionChanged.send()
            return
        }
        if let pending = initialContinuationSeek, pending.occurrence == entryID {
            guard seconds <= Double(Int64.max / 600) - 1 else { return }
            nativePlayer.currentItem?.cancelPendingSeeks()
            continuationPositionTask?.cancel()
            continuationPositionTask = nil
            initialContinuationSeek = .init(
                generation: generation, occurrence: entryID, seconds: max(0, seconds))
            refreshNativeState()
            playbackPositionChanged.send()
            return
        }
        guard entryID == selectedEntryID, seconds.isFinite, duration > 0,
            nativePlayer.currentItem?.status == .readyToPlay
        else { return }
        let target = CMTime(seconds: min(max(0, seconds), duration), preferredTimescale: 600)
        let seekGeneration = generation
        #if DEBUG
            let direction =
                target.seconds < nativePlayer.currentTime().seconds ? "backward" : "forward"
            FoundationTrace.event("seek.request direction=\(direction)")
        #endif
        nativePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            Task { @MainActor in
                guard let self, self.selectedEntryID == entryID,
                    self.generation == seekGeneration
                else { return }
                self.refreshTime()
                if finished {
                    self.reporting?.progress(
                        position: self.elapsed, paused: !self.wantsPlayback, seek: true)
                }
                self.playbackPositionChanged.send()
                #if DEBUG
                    let reached = abs(self.nativePlayer.currentTime().seconds - target.seconds) < 1
                    FoundationTrace.event(
                        "seek.complete direction=\(direction) finished=\(finished ? 1 : 0) current=1 reached=\(reached ? 1 : 0)"
                    )
                #endif
            }
        }
    }

    /// A newly selected policy must not leave an old remote asset fetching on cellular.
    /// Keep the selected queue occurrence; the next explicit Play constructs a fresh asset.
    func invalidateRemoteItemForPolicyChange() {
        guard installedResource?.url.isFileURL == false else { return }
        discardSelection()
        state = .failed
        errorMessage = "Streaming settings changed. Play again to use the new connection policy."
    }

    func stop() {
        isInterrupted = false
        discardSelection()
        state = .idle
        #if DEBUG
            recordSnapshot("command.stop")
        #endif
        let previous = Self.lastSessionOperation
        let deactivate = deactivateSession
        let stopGeneration = generation
        sessionTask = Task { [weak self] in
            await previous?.value
            do { try await deactivate() } catch {
                guard let self, self.generation == stopGeneration else { return }
                self.errorMessage = "Audio session could not be released. Try playback again."
            }
        }
        Self.lastSessionOperation = sessionTask
    }

    private var selectedIndex: Int? { queue.firstIndex { $0.id == selectedEntryID } }

    /// Requests playback explicitly, retaining the current occurrence when native start was rejected.
    /// Repeated commands during an active start do not reactivate the session or replace the item.
    func play() {
        playbackCommandReceived.send()
        play(allowSessionResumption: true)
    }

    private func play(allowSessionResumption: Bool) {
        isInterrupted = false
        #if DEBUG
            recordSnapshot("command.play")
        #endif
        if initialContinuationSeek != nil {
            wantsPlayback = true
            refreshNativeState()
            return
        }
        if state == .failed, let selectedEntryID {
            select(selectedEntryID)
            return
        }
        // During natural handoff the current native item is exhausted, not the new selection.
        if selectionTask != nil {
            wantsPlayback = true
            state = .loading
            return
        }
        guard let item = nativePlayer.currentItem else {
            if let selectedEntryID {
                let position = pausedContinuationPosition.flatMap {
                    $0.occurrence == selectedEntryID ? $0.seconds : nil
                }
                select(selectedEntryID, retainingEndedItem: false, initialPosition: position)
            }
            return
        }
        // Ended items restart through the same explicit selection path.
        if state == .ended, let selectedEntryID {
            select(selectedEntryID)
            return
        }
        if wantsPlayback, nativePlayer.rate > 0 { return }
        guard playTask == nil || playTask?.isCancelled == true else { return }
        #if os(iOS)
            pendingSessionResumption = nil
        #endif
        wantsPlayback = true
        playRequest &+= 1
        let request = playRequest
        let selectionGeneration = generation
        let previous = Self.lastSessionOperation
        let activate = activateSession
        let task = Task { [weak self] in
            #if DEBUG
                FoundationTrace.event("audioSession.previous.wait")
            #endif
            await previous?.value
            #if DEBUG
                FoundationTrace.event("audioSession.previous.completed")
            #endif
            defer {
                if self?.playRequest == request { self?.playTask = nil }
            }
            #if os(iOS)
                let recommendationRevision = self?.sessionRecommendationRevision
            #endif
            do {
                try Task.checkCancellation()
                guard self?.generation == selectionGeneration, self?.wantsPlayback == true else {
                    return
                }
                #if DEBUG
                    FoundationTrace.event("audioSession.activation.started")
                #endif
                try await activate()
                #if DEBUG
                    FoundationTrace.event("audioSession.activation.completed")
                #endif
                try Task.checkCancellation()
                guard let self, self.generation == selectionGeneration,
                    self.playRequest == request, self.wantsPlayback,
                    self.nativePlayer.currentItem === item
                else { return }
                self.isStartingPlayback = true
                self.rejectionDuringStart = false
                self.startPlayback(self.nativePlayer)
                self.isStartingPlayback = false
                if self.rejectionDuringStart {
                    self.rejectionDuringStart = false
                    self.reconcileRejectedStart()
                }
                self.refreshNativeState()
            } catch {
                guard let self, self.generation == selectionGeneration,
                    self.playRequest == request, !Task.isCancelled
                else { return }
                #if os(iOS)
                    let category = Self.sessionActivationCategory(error)
                    #if DEBUG
                        let value = error as NSError
                        let domain = Self.sessionErrorDomain(value.domain)
                        self.recordSnapshot(
                            "audioSession.activation.denied domain=\(domain) code=\(value.code) category=\(category)"
                        )
                    #endif
                    if allowSessionResumption, category != "other",
                        self.wantsPlayback, self.nativePlayer.currentItem === item
                    {
                        self.pendingSessionResumption = (selectionGeneration, request, item)
                        self.state = .waiting
                        if self.sessionRecommendationRevision != recommendationRevision,
                            let recommendation = self.latestSessionRecommendation
                        {
                            self.applySessionResumption(recommendation)
                        }
                        return
                    }
                #endif
                self.fail(.audioSession, error: error)
            }
        }
        playTask = task
        sessionTask = task
        Self.lastSessionOperation = task
    }

    private enum AudioSessionFailure: Error {
        case activationDeclined, deactivationDeclined
    }

    #if os(iOS)
        /// Only an outstanding, explicitly requested start may consume the system recommendation.
        /// A second denial is terminal; repeated notifications never form an activation loop.
        func didReceiveSessionResumption(_ recommendation: AVAudioSession.ResumptionRecommendation)
        {
            sessionRecommendationRevision &+= 1
            latestSessionRecommendation = recommendation
            applySessionResumption(recommendation)
        }

        private func applySessionResumption(
            _ recommendation: AVAudioSession.ResumptionRecommendation
        ) {
            guard let pending = pendingSessionResumption else { return }
            pendingSessionResumption = nil
            guard recommendation == .shouldResume else {
                pause()
                return
            }
            guard generation == pending.generation, playRequest == pending.request,
                wantsPlayback, nativePlayer.currentItem === pending.item,
                state != .failed, state != .ended
            else { return }
            cancelPendingPlay()
            play(allowSessionResumption: false)
        }

        static func sessionErrorDomain(_ domain: String) -> String {
            switch domain {
            case NSOSStatusErrorDomain: return "osStatus"
            case "AVAudioSessionErrorDomain": return "audioSession"
            default: return "other"
            }
        }

        static func sessionActivationCategory(_ error: Error) -> String {
            let value = error as NSError
            guard sessionErrorDomain(value.domain) != "other" else { return "other" }
            switch value.code {
            case AVAudioSession.ErrorCode.siriIsRecording.rawValue: return "siriRecording"
            case AVAudioSession.ErrorCode.insufficientPriority.rawValue: return "priority"
            case AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue: return "cannotInterrupt"
            // Siri can deny a correctly configured background start while finishing its response.
            // This preserves only the outstanding request; a fresh system recommendation must
            // authorize the one continuation. The error alone never retries activation.
            case AVAudioSession.ErrorCode.cannotStartPlaying.rawValue: return "startNotAllowed"
            default: return "other"
            }
        }

        /// Applies system inactivity in notification order through the existing pause operation.
        /// App-requested deactivation is handled by stop; ordinary interruptions never restore old intent.
        func didDeactivateAudioSession(source: AVAudioSession.DeactivationSource) {
            guard source == .system else { return }
            pause()
            isInterrupted = true
        }
    #endif

    /// Cancels playback intent, including a pending resolution, without discarding the occurrence.
    /// A later explicit Play may resume the same item; inactivity never resumes it automatically.
    func pause() {
        playbackCommandReceived.send()
        if initialContinuationSeek?.finalPosition != nil || continuationPositionTask != nil {
            cancelPendingContinuation(generation: generation)
        }
        isInterrupted = false
        #if DEBUG
            recordSnapshot("command.pause")
        #endif
        cancelPendingPlay()
        wantsPlayback = false
        nativePlayer.pause()
        refreshNativeState()
    }

    /// Only an explicit native rejection can end a pending start; transient paused readiness cannot.
    /// Consult current native state so a delayed notification cannot interrupt an already active start.
    private func reconcileRejectedStart() {
        #if os(iOS)
            guard pendingSessionResumption == nil else { return }
        #endif
        // Native start may deliver an earlier rate notification reentrantly. Inspect its final state.
        if isStartingPlayback {
            rejectionDuringStart = true
            return
        }
        guard selectionTask == nil, wantsPlayback, nativePlayer.currentItem != nil,
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

    private func cancelPendingPlay() {
        #if os(iOS)
            pendingSessionResumption = nil
        #endif
        playRequest &+= 1
        playTask?.cancel()
        playTask = nil
    }

    private func discardSelection(retainingNativeItem: Bool = false) {
        continuationPositionTask?.cancel()
        continuationPositionTask = nil
        pausedContinuationPosition = nil
        initialContinuationSeek = nil
        #if DEBUG
            if let item = nativePlayer.currentItem { recordComparisonAccess(item, retiring: true) }
        #endif
        finishReporting()
        reportingAttempted = false
        cancelPendingPlay()
        generation &+= 1
        #if DEBUG
            recordSnapshot("discard.cancelRequested")
        #endif
        selectionTask?.cancel()
        selectionTask = nil
        wantsPlayback = false
        itemObservation = nil
        if !retainingNativeItem {
            nativePlayer.pause()
            releaseNativeItem()
        }
        elapsed = 0
        duration = 0
        errorMessage = nil
    }

    private func releaseNativeItem() {
        let oldItem = nativePlayer.currentItem
        nativePlayer.replaceCurrentItem(with: nil)
        oldItem?.cancelPendingSeeks()
        oldItem?.asset.cancelLoading()
        let resource = installedResource
        installedResource = nil
        if let resource { Task { await resource.release() } }
    }

    private func refreshNativeState() {
        #if DEBUG
            defer { recordSnapshot("native.observed") }
        #endif
        guard state != .failed, state != .ended else { return }
        if selectionTask != nil {
            state = wantsPlayback ? .loading : .paused
            return
        }
        guard let item = nativePlayer.currentItem else {
            state =
                selectionTask != nil
                ? (wantsPlayback ? .loading : .paused)
                : (state == .paused && selectedEntryID != nil ? .paused : .idle)
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
        if var pending = initialContinuationSeek {
            guard pending.generation == generation, pending.occurrence == selectedEntryID else {
                initialContinuationSeek = nil
                return
            }
            state = wantsPlayback ? .loading : .paused
            guard !pending.issued, item.status == .readyToPlay else { return }
            pending.issued = true
            initialContinuationSeek = pending
            if let finalPosition = pending.finalPosition {
                let request = pending
                continuationPositionTask = Task { [weak self] in
                    do {
                        let seconds = try await finalPosition()
                        try Task.checkCancellation()
                        guard let self, self.matchesContinuation(request, item: item) else {
                            return
                        }
                        self.continuationPositionTask = nil
                        guard seconds.isFinite, seconds >= 0,
                            seconds <= Double(Int64.max / 600) - 1
                        else { throw FoundationHandoffError.positionUnavailable }
                        self.issueContinuationSeek(request, item: item, seconds: seconds)
                    } catch {
                        guard !Task.isCancelled, let self,
                            self.matchesContinuation(request, item: item)
                        else { return }
                        self.continuationPositionTask = nil
                        self.fail(.resolution, error: nil)
                        self.errorMessage =
                            FoundationHandoffError.positionUnavailable.errorDescription
                    }
                }
            } else {
                issueContinuationSeek(pending, item: item, seconds: pending.seconds)
            }
            return
        }
        #if os(iOS)
            if pendingSessionResumption != nil, wantsPlayback {
                state = .waiting
                refreshTime()
                return
            }
        #endif
        switch nativePlayer.timeControlStatus {
        case .playing: state = .playing
        case .waitingToPlayAtSpecifiedRate: state = .waiting
        case .paused: state = item.status == .unknown && wantsPlayback ? .loading : .paused
        @unknown default: state = .paused
        }
        refreshTime()
        if state == .playing, !reportingAttempted,
            let index = selectedIndex
        {
            reportingAttempted = true
            if reportingAllowed() {
                reporting?.begin(
                    itemID: queue[index].item.id, position: elapsed,
                    source: installedResource?.source)
            }
        }
        reporting?.progress(position: elapsed, paused: !wantsPlayback)
    }

    private func matchesContinuation(_ request: InitialContinuationSeek, item: AVPlayerItem) -> Bool
    {
        generation == request.generation && selectedEntryID == request.occurrence
            && initialContinuationSeek?.id == request.id && nativePlayer.currentItem === item
    }

    private func issueContinuationSeek(
        _ request: InitialContinuationSeek, item: AVPlayerItem, seconds: Double
    ) {
        guard matchesContinuation(request, item: item) else { return }
        let length = item.duration.seconds
        let target = length.isFinite && length > 0 ? min(seconds, length) : seconds
        seekForContinuation(
            nativePlayer, CMTime(seconds: target, preferredTimescale: 600)
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.matchesContinuation(request, item: item) else { return }
                self.initialContinuationSeek = nil
                self.refreshTime()
                guard finished else {
                    self.fail(.resolution, error: nil)
                    self.errorMessage = FoundationHandoffError.positionUnavailable.errorDescription
                    return
                }
                if self.wantsPlayback {
                    self.play(allowSessionResumption: true)
                } else {
                    self.refreshNativeState()
                }
            }
        }
    }

    private func finishReporting() {
        let position = nativePlayer.currentTime().seconds
        reporting?.stop(position: position.isFinite ? max(0, position) : elapsed)
    }

    private func refreshTime() {
        guard selectionTask == nil else { return }
        if nativePlayer.currentItem == nil, let deferred = pausedContinuationPosition,
            deferred.occurrence == selectedEntryID
        {
            elapsed = deferred.seconds
            let length = queue.first(where: { $0.id == deferred.occurrence })?.item.duration ?? 0
            duration = length.isFinite ? max(0, length) : 0
            return
        }
        let seconds = nativePlayer.currentTime().seconds
        let length = nativePlayer.currentItem?.duration.seconds ?? 0
        elapsed = seconds.isFinite ? max(0, seconds) : 0
        duration = length.isFinite ? max(0, length) : 0
        reporting?.progress(position: elapsed, paused: !wantsPlayback)
    }

    // Native callback identity is the only end-of-item seam; no simulated transport state.
    func didReachEnd(_ item: AVPlayerItem) {
        guard nativePlayer.currentItem === item, selectionTask == nil, state != .failed
        else { return }
        #if DEBUG
            recordSnapshot("item.ended")
        #endif
        finishReporting()
        let successor: UUID?
        if repeatMode == .one {
            successor = selectedEntryID
        } else if let index = selectedIndex, queue.indices.contains(index + 1) {
            successor = queue[index + 1].id
        } else {
            successor = repeatMode == .all ? queue.first?.id : nil
        }
        if let successor {
            let shouldPlay = wantsPlayback
            select(successor, retainingEndedItem: shouldPlay)
            if !shouldPlay { pause() }
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
        continuationPositionTask?.cancel()
        continuationPositionTask = nil
        initialContinuationSeek = nil
        pausedContinuationPosition = nil
        finishReporting()
        cancelPendingPlay()
        wantsPlayback = false
        nativePlayer.pause()
        state = .failed
        if category == .nativeItem || category == .nativePlayer || category == .nativeEnd {
            itemObservation = nil
            releaseNativeItem()
        }
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

    #if DEBUG && os(iOS)
        /// Map only documented enum cases; missing and future values never expose raw payloads.
        static func routeCategory(_ raw: UInt?) -> String {
            guard let raw, let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else {
                return "unknown"
            }
            switch reason {
            case .newDeviceAvailable: return "available"
            case .oldDeviceUnavailable: return "unavailable"
            case .categoryChange: return "category"
            case .override: return "override"
            case .wakeFromSleep: return "wake"
            case .noSuitableRouteForCategory: return "noSuitableRoute"
            case .routeConfigurationChange: return "configuration"
            default: return "unknown"
            }
        }

        static func deactivationCategory(_ source: AVAudioSession.DeactivationSource) -> String {
            switch source {
            case .app: return "app"
            case .system: return "system"
            @unknown default: return "unknown"
            }
        }

        static func interruptionCategory(_ reason: AVAudioSession.InterruptionReason?) -> String {
            guard let reason else { return "absent" }
            switch reason {
            case .default: return "default"
            case .builtInMicMuted: return "microphoneMuted"
            case .routeDisconnected: return "routeDisconnected"
            default: return "other"
            }
        }

        static func resumptionCategory(_ recommendation: AVAudioSession.ResumptionRecommendation?)
            -> String
        {
            guard let recommendation else { return "absent" }
            switch recommendation {
            case .shouldResume: return "recommended"
            case .shouldNotResume: return "notRecommended"
            @unknown default: return "unknown"
            }
        }
    #endif

    #if DEBUG
        private var selectionStartedAt: TimeInterval?
        private var comparisonAccessEvents = 0
        private var comparisonInstalledGeneration: UInt64?

        private func recordComparisonAccess(_ item: AVPlayerItem, retiring: Bool) {
            guard retiring || comparisonAccessEvents < 8 else { return }
            comparisonAccessEvents += 1
            let selectedGeneration = comparisonInstalledGeneration ?? generation
            let method = installedResource?.source.delivery.rawValue ?? "unknown"
            item.fetchAccessLog { log in
                guard let event = log?.events.last else { return }
                let observed: String
                switch event.playbackType?.uppercased() {
                case "FILE": observed = "file"
                case "VOD": observed = "vod"
                case "LIVE": observed = "live"
                default: observed = "unknown"
                }
                FoundationJournal.shared.record(
                    "player.comparison.access generation=\(selectedGeneration) requestedDelivery=\(method) "
                        + "retiring=\(retiring ? 1 : 0) observedType=\(observed) "
                        + "bytes=\(event.numberOfBytesTransferred) requests=\(event.numberOfMediaRequests) "
                        + "stalls=\(event.numberOfStalls)")
            }
        }

        static func rateCategory(_ raw: String?) -> String {
            guard let raw else { return "absent" }
            switch AVPlayer.RateDidChangeReason(rawValue: raw) {
            case .setRateCalled: return "requested"
            case .setRateFailed: return "rejected"
            case .audioSessionInterrupted: return "interrupted"
            case .appBackgrounded: return "backgrounded"
            case .playheadReachedLiveEdge: return "liveEdge"
            case .reversePlaybackReachedStartOfSeekableRange: return "seekableStart"
            default: return "other"
            }
        }

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
            let selectionMs =
                selectionStartedAt.map {
                    Int((ProcessInfo.processInfo.systemUptime - $0) * 1000)
                } ?? -1
            let delivery = installedResource?.source.delivery.rawValue ?? "unresolved"
            FoundationJournal.shared.record(
                "player.\(event) generation=\(generation) state=\(state.rawValue) "
                    + "item=\(itemStatus) control=\(control) wait=\(reason) intent=\(wantsPlayback ? 1 : 0) "
                    + "selectionMs=\(selectionMs) requestedDelivery=\(delivery)"
            )
        }
    #endif

}

/// Account-owned metadata only: no credentials, origins, media URLs or playback position.
struct FoundationPlaybackSnapshot: Codable {
    struct Reference: Codable {
        let id: String
        let title: String
        let primaryImageTag: String?
        init(_ value: FoundationItemReference) {
            id = value.id
            title = value.title
            primaryImageTag = value.primaryImageTag
        }
        var reference: FoundationItemReference {
            FoundationItemReference(id: id, title: title, primaryImageTag: primaryImageTag)
        }
    }
    struct Entry: Codable {
        let id: UUID
        let itemID: String
        let title: String
        let subtitle: String
        let duration: Double?
        let primaryImageTag: String?
        let album: Reference?
        let artist: Reference?
        let genres: [Reference]
        let isFavorite: Bool?
        let playCount: Int
        var trackNumber: Int? = nil
        var discNumber: Int? = nil

        init(_ entry: FoundationQueueEntry) {
            id = entry.id
            itemID = entry.item.id
            title = entry.item.title
            subtitle = entry.item.subtitle
            duration = entry.item.duration
            primaryImageTag = entry.item.primaryImageTag
            album = entry.item.album.map(Reference.init)
            artist = entry.item.artist.map(Reference.init)
            genres = entry.item.genres.map(Reference.init)
            isFavorite = entry.item.isFavorite
            playCount = entry.item.playCount
            trackNumber = entry.item.trackNumber
            discNumber = entry.item.discNumber
        }

        var entry: FoundationQueueEntry {
            FoundationQueueEntry(
                id: id,
                item: FoundationItem(
                    id: itemID, title: title, subtitle: subtitle, kind: .track,
                    duration: duration, primaryImageTag: primaryImageTag, isFavorite: isFavorite,
                    album: album?.reference, artist: artist?.reference,
                    genres: genres.map(\.reference), playCount: playCount,
                    trackNumber: trackNumber, discNumber: discNumber))
        }
    }
    let version: Int
    let entries: [Entry]
    let selectedEntryID: UUID?
    let shuffleEnabled: Bool
    let repeatMode: FoundationPlayer.RepeatMode
    let visibleEntryIDs: [UUID]?

    @MainActor init(player: FoundationPlayer) {
        version = 1
        entries = player.persistedQueue.map(Entry.init)
        selectedEntryID = player.selectedEntryID
        shuffleEnabled = player.shuffleEnabled
        repeatMode = player.repeatMode
        visibleEntryIDs = player.persistedVisibleEntryIDs
    }

    init(
        entries: [FoundationQueueEntry], selectedEntryID: UUID, shuffleEnabled: Bool,
        repeatMode: FoundationPlayer.RepeatMode, visibleEntryIDs: [UUID]? = nil
    ) {
        version = 1
        self.entries = entries.map(Entry.init)
        self.selectedEntryID = selectedEntryID
        self.shuffleEnabled = shuffleEnabled
        self.repeatMode = repeatMode
        self.visibleEntryIDs = visibleEntryIDs
    }

    var isValid: Bool {
        version == 1 && Set(entries.map(\.id)).count == entries.count
            && (selectedEntryID == nil || entries.contains { $0.id == selectedEntryID })
            && validVisibility
    }

    private var validVisibility: Bool {
        guard let visibleEntryIDs else { return true }
        let visible = Set(visibleEntryIDs)
        return visible.count == visibleEntryIDs.count
            && entries.filter { visible.contains($0.id) }.map(\.id) == visibleEntryIDs
            && (selectedEntryID.map { visible.contains($0) } ?? true)
    }
}
