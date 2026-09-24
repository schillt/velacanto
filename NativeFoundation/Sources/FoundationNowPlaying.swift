import AVFoundation
import Combine
import Foundation
import NowPlaying
import Observation

#if os(iOS)
    import UIKit
#endif

/// Account-owned system presentation. Commands operate the existing player; this owner never loads media.
@MainActor @Observable
final class FoundationNowPlaying: MediaSessionRepresentable {
    enum Command {
        case play, pause, toggle, next, previous
        case seek(Double)
    }
    struct Availability: Equatable {
        var play = false
        var pause = false
        var next = false
        var previous = false
        var seek = false
    }

    let id = UUID().uuidString
    private(set) var content: (any MediaContentRepresentable)?
    private(set) var playbackSnapshot: MediaPlaybackSnapshot?
    private(set) var availability = Availability()
    private(set) var entryID: UUID?
    @ObservationIgnored private let player: FoundationPlayer
    @ObservationIgnored private let artwork: FoundationCurrentArtwork?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private weak var session: MediaSession<FoundationNowPlaying>?
    @ObservationIgnored private(set) var updateTask: Task<Void, Never>?
    @ObservationIgnored private(set) var primacyTask: Task<Void, Never>?
    @ObservationIgnored private let applicationPrimacyRequest: (() async throws -> Void)?
    @ObservationIgnored private var applicationPrimacyAttempted = false
    @ObservationIgnored private var systemPrimacyAttempted = false
    @ObservationIgnored private var isLive = true

    init(
        player: FoundationPlayer,
        artwork: FoundationCurrentArtwork? = nil,
        applicationPrimacyRequest: (() async throws -> Void)? = nil
    ) {
        self.player = player
        self.artwork = artwork
        self.applicationPrimacyRequest = applicationPrimacyRequest
        Publishers.MergeMany(
            player.$queue.map { _ in () }.eraseToAnyPublisher(),
            player.$selectedEntryID.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$state.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$wantsPlayback.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$duration.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.$isInterrupted.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            player.playbackPositionChanged.eraseToAnyPublisher()
        ).sink { [weak self] in self?.scheduleUpdate() }.store(in: &subscriptions)
        artwork?.$result.sink { [weak self] _ in self?.scheduleUpdate() }.store(in: &subscriptions)
        #if os(iOS)
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.requestPrimacyIfEligible() }
                }.store(in: &subscriptions)
        #endif
        refresh()
    }

    /// The account owner retains the session separately, avoiding a representation/session cycle.
    func attach(_ session: MediaSession<FoundationNowPlaying>) {
        guard isLive, self.session == nil else { return }
        self.session = session
        observePrimacyEligibility()
        requestPrimacyIfEligible()
    }

    /// Eligibility can arrive after the system observes newly published content.
    private func observePrimacyEligibility() {
        guard isLive, let session else { return }
        withObservationTracking {
            _ = session.canBecomeApplicationPrimary
            _ = session.isApplicationPrimary
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observePrimacyEligibility()
                self?.requestPrimacyIfEligible()
            }
        }
    }

    /// Coalesce Combine's will-change notifications, then read the completed player mutation.
    private func scheduleUpdate() {
        guard isLive, updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.updateTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        guard isLive else { return }
        // Only ended intent rearms primacy; buffering and natural handoff retain their attempt.
        if !player.wantsPlayback || player.isInterrupted {
            applicationPrimacyAttempted = false
            systemPrimacyAttempted = false
            primacyTask?.cancel()
        }
        entryID = player.selectedEntryID
        guard let index = player.queue.firstIndex(where: { $0.id == entryID }) else {
            content = nil
            playbackSnapshot = nil
            availability = Availability()
            return
        }
        let entry = player.queue[index]
        let length = player.duration > 0 ? player.duration : entry.item.duration
        let systemArtwork = artwork?.artwork(for: entry.item)
        content = MusicContent(
            id: entry.id.uuidString, songTitle: entry.item.title, artistName: entry.item.subtitle,
            albumName: entry.item.album?.title ?? "", type: .audio,
            duration: length.flatMap { $0.isFinite && $0 > 0 ? .finite($0) : nil },
            artwork: systemArtwork)
        #if DEBUG
            FoundationJournal.shared.record(
                "artwork.publication provider=\(systemArtwork == nil ? 0 : 1) result=\(artwork?.diagnosticState ?? "absent")"
            )
        #endif
        let state: MediaPlaybackSnapshot.PlaybackState
        if player.isInterrupted {
            state = .interrupted
        } else {
            switch player.state {
            case .idle, .ended, .failed: state = .stopped
            case .loading, .waiting: state = .buffering
            case .paused: state = .paused
            case .playing: state = .playing(rate: player.nativePlayer.rate)
            }
        }
        let nativeTime = player.selectionTask == nil ? player.nativePlayer.currentTime().seconds : 0
        let elapsed = nativeTime.isFinite ? max(0, nativeTime) : player.elapsed
        playbackSnapshot = MediaPlaybackSnapshot(
            state: state, elapsedTime: elapsed, timestamp: Date())
        availability = Availability(
            play: !player.wantsPlayback, pause: player.wantsPlayback,
            next: index + 1 < player.queue.count, previous: index > 0 || player.duration > 0,
            seek: player.duration > 0 && player.selectionTask == nil
                && player.nativePlayer.currentItem?.status == .readyToPlay)
        requestPrimacyIfEligible()
    }

    var commands: [MediaCommand] {
        let occurrence = entryID
        return [
            .play { [weak self] in try self?.perform(.play, entryID: occurrence) }
                .enabled(availability.play),
            .pause { [weak self] in try self?.perform(.pause, entryID: occurrence) }
                .enabled(availability.pause),
            .togglePlayPause { [weak self] in try self?.perform(.toggle, entryID: occurrence)
            }
            .enabled(availability.play || availability.pause),
            .next { [weak self] in try self?.perform(.next, entryID: occurrence) }
                .enabled(availability.next),
            .previous { [weak self] in try self?.perform(.previous, entryID: occurrence) }
                .enabled(availability.previous),
            .seekToPosition { [weak self] time in
                try self?.perform(.seek(time), entryID: occurrence)
            }.enabled(availability.seek),
        ]
    }

    /// Check live ownership and occurrence again when a queued system command reaches the main actor.
    func perform(_ command: Command, entryID: UUID?) throws {
        guard isLive, let entryID, player.selectedEntryID == entryID,
            let index = player.queue.firstIndex(where: { $0.id == entryID })
        else { throw MediaSessionError.invalidState }
        switch command {
        case .play: player.play()
        case .pause: player.pause()
        case .toggle: player.togglePlayback()
        case .next:
            guard index + 1 < player.queue.count else { throw MediaSessionError.invalidState }
            player.next()
        case .previous:
            guard index > 0 || player.duration > 0 else { throw MediaSessionError.invalidState }
            player.previous()
        case .seek(let time):
            guard time.isFinite, player.duration > 0, player.selectionTask == nil,
                player.nativePlayer.currentItem?.status == .readyToPlay
            else { throw MediaSessionError.invalidState }
            player.seek(to: time, entryID: entryID)
        }
    }

    /// Primacy is a system presentation request, never an instruction to activate audio.
    private func requestPrimacyIfEligible() {
        guard isLive, player.state == .playing, player.wantsPlayback, primacyTask == nil else {
            return
        }
        let session = session
        let application =
            !applicationPrimacyAttempted
            && (applicationPrimacyRequest != nil
                || (session?.isApplicationPrimary == false
                    && session?.canBecomeApplicationPrimary == true))
        #if os(iOS)
            let system =
                UIApplication.shared.applicationState == .active
                && session?.isSystemPrimary == false && !systemPrimacyAttempted
                && (session?.isApplicationPrimary == true || application)
        #else
            let system = false
        #endif
        guard application || system else { return }
        primacyTask = Task { [weak self, weak session] in
            defer {
                self?.primacyTask = nil
                self?.requestPrimacyIfEligible()
            }
            guard let self, self.isLive, !Task.isCancelled,
                self.player.state == .playing, self.player.wantsPlayback
            else { return }
            do {
                if application {
                    if let request = self.applicationPrimacyRequest {
                        self.applicationPrimacyAttempted = true
                        try await request()
                    } else if let session, !session.isApplicationPrimary,
                        session.canBecomeApplicationPrimary
                    {
                        self.applicationPrimacyAttempted = true
                        try await session.requestToBecomeApplicationPrimary()
                    }
                }
                guard self.isLive, !Task.isCancelled, self.player.state == .playing,
                    self.player.wantsPlayback
                else { return }
                #if os(iOS)
                    if system, let session, session.isApplicationPrimary,
                        UIApplication.shared.applicationState == .active
                    {
                        self.systemPrimacyAttempted = true
                        try await session.requestToBecomeSystemPrimary()
                    }
                #endif
            } catch {
                #if DEBUG
                    FoundationJournal.shared.record("nowPlaying.primacy outcome=unavailable")
                #endif
            }
        }
    }

    /// Disable retained command closures before the account releases its MediaSession.
    func invalidate() {
        isLive = false
        updateTask?.cancel()
        updateTask = nil
        primacyTask?.cancel()
        primacyTask = nil
        subscriptions.removeAll()
        session = nil
        content = nil
        playbackSnapshot = nil
        availability = Availability()
        entryID = nil
    }
}
