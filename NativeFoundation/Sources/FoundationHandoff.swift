import Combine
import Foundation

#if os(iOS)
    import UIKit
#endif

/// One account-owned native activity and one incoming/outgoing transfer. This owner
/// never creates a player or transfers account credentials or delivery locations.
@MainActor
final class FoundationHandoffController: NSObject, ObservableObject, NSUserActivityDelegate {
    typealias Resolve = @MainActor (FoundationItem) async throws -> FoundationItem
    typealias Navigate = @MainActor (FoundationItem) -> Void

    struct Pending: Identifiable {
        let payload: FoundationHandoffPayload
        let selectedItem: FoundationItem
        let context: UUID
        let intent: UUID
        var id: UUID { payload.header.id }
    }

    private struct Context {
        let id = UUID()
        let scope: String
        let resolve: Resolve
        let navigate: Navigate
    }

    private struct SourceTransfer {
        let header: FoundationHandoffPayload.Header
        let context: UUID
        let intent: UUID
        let playerGeneration: UInt64
        let occurrence: UUID?
        let wasPlaying: Bool
        enum Phase: Equatable { case offered, authorized, writingPosition, awaitingStart }
        var phase: Phase = .offered
        var positionNonce: UUID?
        var sent = false
    }

    private struct AwaitedControl {
        let reply: FoundationHandoffControl.Kind
        let nonce: UUID
        let occurrence: UUID
        let request: UUID
        let context: UUID
        let intent: UUID
        let continuation: AsyncThrowingStream<FoundationHandoffControl, Error>.Continuation
    }

    @Published private(set) var pending: Pending?
    @Published var notice: String?
    @Published private(set) var presentationOwner: UUID?
    func claimPresentation(_ owner: UUID) {
        if presentationOwner == nil { presentationOwner = owner }
    }
    func releasePresentation(_ owner: UUID) {
        if presentationOwner == owner { presentationOwner = nil }
    }
    struct BrowseRequest: Identifiable {
        let id = UUID()
        let item: FoundationItem
    }
    @Published private(set) var browseRequest: BrowseRequest?

    func takeBrowseRequest() -> FoundationItem? {
        let item = browseRequest?.item
        browseRequest = nil
        return item
    }
    func requestBrowse(_ item: FoundationItem) { browseRequest = .init(item: item) }
    private(set) var activity: NSUserActivity?
    private var header: FoundationHandoffPayload.Header?
    private var context: Context?
    private weak var player: FoundationPlayer?
    private var intent = UUID()
    private var navigationIntent = UUID()
    private var applying = false
    private var subscriptions = Set<AnyCancellable>()
    private var publicationTask: Task<Void, Never>?
    private var browse: (owner: UUID, destination: FoundationHandoffPayload.Destination)?
    private var outgoing: FoundationHandoffStreamExchange?
    private var sourceTransfer: SourceTransfer?
    private var encodingTask: Task<Void, Never>?
    private var incoming: FoundationHandoffStreamExchange?
    private var incomingActivity: NSUserActivity?
    private var incomingID: UUID?
    private var incomingHeader: FoundationHandoffPayload.Header?
    private var incomingReady = false
    private var requestSent = false
    private var receivingTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var acknowledgement: AnyCancellable?
    private var acceptanceTask: Task<Void, Never>?
    private var awaitedControl: AwaitedControl?
    private var payloadReceived = false
    private var appliedPositionNonce: UUID?
    private var appliedGeneration: UInt64?
    private var appliedIntent: UUID?
    private var consumed: [UUID: TimeInterval] = [:]
    private let publish: @MainActor (NSUserActivity) -> Void
    private let requestStreams:
        @MainActor (
            NSUserActivity, @escaping @Sendable (InputStream?, OutputStream?, Error?) -> Void
        ) -> Void

    init(
        publish: @escaping @MainActor (NSUserActivity) -> Void = { $0.becomeCurrent() },
        requestStreams:
            @escaping @MainActor (
                NSUserActivity, @escaping @Sendable (InputStream?, OutputStream?, Error?) -> Void
            ) -> Void = { activity, completion in
                activity.getContinuationStreams(completionHandler: completion)
            }
    ) {
        self.publish = publish
        self.requestStreams = requestStreams
    }

    func configure(
        scope: String, player: FoundationPlayer,
        resolve: @escaping Resolve, navigate: @escaping Navigate
    ) {
        // Initial cold restoration can finish while a native incoming pair is waiting.
        // An existing account context, however, must retire all of its work first.
        if context != nil { invalidate() }
        context = .init(scope: scope, resolve: resolve, navigate: navigate)
        self.player = player
        player.sessionChanged.sink { [weak self] in self?.intentChanged() }
            .store(in: &subscriptions)
        player.playbackPositionChanged.sink { [weak self] in self?.intentChanged() }
            .store(in: &subscriptions)
        player.playbackCommandReceived.sink { [weak self] in self?.intentChanged() }
            .store(in: &subscriptions)
        player.$wantsPlayback.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.intentChanged()
        }.store(in: &subscriptions)
        publishActivity()
    }

    func invalidate() {
        context = nil
        player = nil
        subscriptions.removeAll()
        publicationTask?.cancel()
        publicationTask = nil
        activity?.invalidate()
        activity?.delegate = nil
        activity = nil
        header = nil
        browse = nil
        retireOutgoing()
        retireIncoming()
        consumed.removeAll()
        notice = nil
        browseRequest = nil
        presentationOwner = nil
        intent = UUID()
        navigationIntent = UUID()
    }

    func beginBrowse(_ item: FoundationItem, owner: UUID) {
        let destination = FoundationHandoffPayload.Destination(id: item.id, kind: item.kind)
        guard destination.isValid else { return }
        browse = (owner, destination)
        publishActivity()
    }

    func endBrowse(owner: UUID) {
        guard browse?.owner == owner else { return }
        browse = nil
        publishActivity()
    }

    /// Explicit navigation supersedes an incoming browse operation. Merely mounting
    /// a restored detail view does not discard a cold-start Handoff request.
    func navigationChangedByUser() {
        browseRequest = nil
        navigationIntent = UUID()
        if incomingHeader?.kind == .browse { retireIncoming() }
        if sourceTransfer?.header.kind == .browse { retireOutgoing() }
    }

    /// Called synchronously from the application-delegate continuation callback.
    /// Native streams open before waiting for account startup; no queue bytes are
    /// requested until the receiving device's own authorization has been restored.
    @discardableResult
    func receive(_ activity: NSUserActivity, prepare: @escaping @MainActor () async -> Bool) -> Bool
    {
        guard activity.activityType == FoundationHandoffPayload.activityType else { return false }
        do {
            guard let data = activity.userInfo?[FoundationHandoffPayload.userInfoKey] as? Data
            else {
                throw FoundationHandoffError.invalid
            }
            let offered = try FoundationHandoffPayload.Header.decode(data)
            // Freshness is established again by the live source's response. A paused
            // current activity need not advertise timers just to refresh a timestamp.
            try offered.validate(scope: offered.scope, now: offered.createdAt)
            pruneReceipts()
            if consumed[offered.id] != nil || incomingHeader?.id == offered.id { return true }
            retireIncoming()
            guard consumed.count < 128 else { throw FoundationHandoffError.unavailable }
            let request = UUID()
            incomingID = request
            incomingHeader = offered
            incomingActivity = activity
            notice = nil
            requestStreams(activity) { [weak self] input, output, _ in
                let pair = input.flatMap { input in
                    output.map { FoundationHandoffNativeStreams(input: input, output: $0) }
                }
                Task { @MainActor [weak self] in
                    guard let self, self.incomingID == request else {
                        pair?.input.close()
                        pair?.output.close()
                        return
                    }
                    guard let pair else {
                        self.incomingFailed(.unavailable, request: request)
                        return
                    }
                    let exchange = FoundationHandoffStreamExchange(
                        streams: pair, maximumIncomingMessages: 3,
                        message: { [weak self] data in self?.received(data, request: request) },
                        failure: { [weak self] error in
                            self?.incomingFailed(error, request: request)
                        })
                    self.incoming = exchange
                    exchange.open()
                    self.requestIfReady()
                }
            }
            preparationTask = Task { [weak self] in
                let ready = await prepare()
                guard !Task.isCancelled, let self, self.incomingID == request else { return }
                guard ready, let context = self.context, context.scope == offered.scope else {
                    self.incomingFailed(.differentAccount, request: request)
                    return
                }
                self.incomingReady = true
                self.requestIfReady()
            }
        } catch {
            notice = (error as? FoundationHandoffError ?? .invalid).errorDescription
        }
        return true
    }

    func acceptPending() {
        guard let pending, let context, context.id == pending.context,
            intent == pending.intent, pending.payload.session != nil,
            acceptanceTask == nil
        else {
            dismissPending()
            notice = FoundationHandoffError.changed.errorDescription
            return
        }
        do {
            if pending.payload.session?.wasPlaying == true {
                try incoming?.requirePeerUntilNativeStart()
            }
            let replies = try beginControl(
                .authorize, reply: .authorized,
                pending: pending, expectedIntent: pending.intent)
            self.pending = nil
            acceptanceTask = Task { [weak self] in
                do {
                    var iterator = replies.makeAsyncIterator()
                    guard try await iterator.next() != nil else {
                        throw FoundationHandoffError.interrupted
                    }
                    try Task.checkCancellation()
                    guard let self, self.context?.id == pending.context,
                        self.intent == pending.intent, self.incomingHeader?.id == pending.id
                    else { return }
                    self.acceptanceTask = nil
                    self.applyAuthorized(pending)
                } catch {
                    guard !Task.isCancelled, let self, let request = self.incomingID else { return }
                    self.incomingFailed(
                        error as? FoundationHandoffError ?? .interrupted, request: request)
                }
            }
        } catch {
            if let request = incomingID {
                incomingFailed(error as? FoundationHandoffError ?? .interrupted, request: request)
            }
        }
    }

    private func applyAuthorized(_ pending: Pending) {
        guard let player, let session = pending.payload.session else { return }
        var entries = session.entries.map(\.entry)
        guard let index = entries.firstIndex(where: { $0.id == session.selected }) else {
            dismissPending()
            return
        }
        entries[index] = .init(id: session.selected, item: pending.selectedItem)
        let mode = FoundationPlayer.RepeatMode(rawValue: session.repeatMode.rawValue) ?? .off
        let snapshot = FoundationPlaybackSnapshot(
            entries: entries, selectedEntryID: session.selected,
            shuffleEnabled: session.shuffle, repeatMode: mode,
            visibleEntryIDs: session.visibleOccurrences)
        consume(pending.id)
        retireOutgoing()
        let acceptedIntent = UUID()
        intent = acceptedIntent
        applying = true
        let accepted = player.continueSession(
            snapshot, position: session.position, wasPlaying: session.wasPlaying,
            finalPosition: { [weak self] in
                guard
                    let replies = try self?.beginControl(
                        .position, reply: .positionValue, pending: pending,
                        expectedIntent: acceptedIntent)
                else { throw FoundationHandoffError.interrupted }
                var iterator = replies.makeAsyncIterator()
                guard let reply = try await iterator.next(), let seconds = reply.seconds else {
                    throw FoundationHandoffError.interrupted
                }
                try Task.checkCancellation()
                return seconds
            })
        applying = false
        guard accepted else {
            retireIncoming()
            notice = FoundationHandoffError.invalid.errorDescription
            return
        }
        appliedGeneration = player.continuationGeneration
        appliedIntent = intent
        publishActivity()
        guard session.wasPlaying else {
            retireIncoming()
            return
        }
        acknowledgement = player.$state.sink { [weak self] state in
            guard state == .playing else { return }
            Task { @MainActor [weak self] in self?.acknowledgeNativeStart() }
        }
    }

    private func beginControl(
        _ kind: FoundationHandoffControl.Kind, reply: FoundationHandoffControl.Kind,
        pending: Pending, expectedIntent: UUID
    ) throws -> AsyncThrowingStream<FoundationHandoffControl, Error> {
        guard let incoming, let incomingID, let context,
            incomingHeader?.id == pending.id, context.id == pending.context,
            intent == expectedIntent, awaitedControl == nil,
            let occurrence = pending.payload.session?.selected
        else { throw FoundationHandoffError.changed }
        let nonce = UUID()
        var continuation: AsyncThrowingStream<FoundationHandoffControl, Error>.Continuation!
        let replies = AsyncThrowingStream<FoundationHandoffControl, Error>(
            bufferingPolicy: .bufferingOldest(1)
        ) {
            continuation = $0
        }
        awaitedControl = .init(
            reply: reply, nonce: nonce, occurrence: occurrence,
            request: incomingID, context: context.id, intent: expectedIntent,
            continuation: continuation)
        do {
            try incoming.expectAcknowledgement()
            try incoming.send(
                FoundationHandoffControl(
                    kind: kind, transfer: pending.id, occurrence: occurrence, nonce: nonce
                ).encoded())
        } catch {
            awaitedControl = nil
            continuation.finish(throwing: error)
            throw error
        }
        return replies
    }

    func dismissPending() {
        if let pending { consume(pending.id) }
        retireIncoming()
    }

    private func requestIfReady() {
        guard incomingReady, !requestSent, let incoming, let incomingHeader,
            let context, context.scope == incomingHeader.scope
        else { return }
        do {
            try incoming.send(incomingHeader.encoded())
            requestSent = true
        } catch {
            if let request = incomingID { incomingFailed(.invalid, request: request) }
        }
    }

    private func received(_ data: Data, request: UUID) {
        guard incomingID == request, let offered = incomingHeader, let context else { return }
        if let expected = awaitedControl {
            do {
                let reply = try FoundationHandoffControl.decode(data)
                guard expected.request == request, context.id == expected.context,
                    intent == expected.intent, reply.kind == expected.reply,
                    reply.transfer == offered.id, reply.occurrence == expected.occurrence,
                    reply.nonce == expected.nonce
                else { throw FoundationHandoffError.changed }
                awaitedControl = nil
                if reply.kind == .positionValue { appliedPositionNonce = reply.nonce }
                expected.continuation.yield(reply)
                expected.continuation.finish()
            } catch {
                incomingFailed(error as? FoundationHandoffError ?? .invalid, request: request)
            }
            return
        }
        guard !payloadReceived else {
            incomingFailed(.invalid, request: request)
            return
        }
        payloadReceived = true
        incoming?.extendLifetime(to: 120)
        let expectedIntent = offered.kind == .browse ? navigationIntent : intent
        let contextID = context.id
        let expectedScope = context.scope
        receivingTask = Task { [weak self] in
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    let value = try FoundationHandoffPayload.decode(data)
                    try value.validate(
                        scope: expectedScope, now: Date().timeIntervalSince1970, expected: offered)
                    return value
                }.value
                try Task.checkCancellation()
                guard let self, self.incomingID == request, self.context?.id == contextID,
                    self.currentIntent(for: offered.kind) == expectedIntent
                else { return }
                let stub: FoundationItem
                if let session = payload.session,
                    let track = session.entries.first(where: { $0.occurrence == session.selected })
                {
                    stub = track.entry.item
                } else if let destination = payload.destination {
                    stub = .init(
                        id: destination.id, title: "Music", subtitle: "", kind: destination.kind,
                        duration: nil)
                } else {
                    throw FoundationHandoffError.invalid
                }
                let resolved = try await context.resolve(stub)
                try Task.checkCancellation()
                guard self.incomingID == request, self.context?.id == contextID,
                    self.currentIntent(for: offered.kind) == expectedIntent
                else { return }
                guard resolved.id == stub.id, resolved.kind == stub.kind else {
                    throw FoundationHandoffError.unavailable
                }
                if payload.header.kind == .browse {
                    self.consume(payload.header.id)
                    self.retireIncoming()
                    self.applying = true
                    context.navigate(resolved)
                    self.applying = false
                } else {
                    self.pending = .init(
                        payload: payload, selectedItem: resolved,
                        context: contextID, intent: expectedIntent)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.incomingFailed(
                    error as? FoundationHandoffError ?? .unavailable, request: request)
            }
        }
    }

    private func acknowledgeNativeStart() {
        guard let player, let generation = appliedGeneration, let appliedIntent,
            appliedIntent == intent, let transfer = incomingHeader,
            let occurrence = player.selectedEntryID,
            player.isNativeContinuationPlaying(generation: generation, occurrence: occurrence),
            let incoming, let positionNonce = appliedPositionNonce
        else { return }
        do {
            incoming.nativePlaybackStarted()
            acknowledgement?.cancel()
            acknowledgement = nil
            incoming.didSend = { [weak self] in self?.retireIncoming() }
            try incoming.send(
                FoundationHandoffAcknowledgement(
                    transfer: transfer.id, occurrence: occurrence, nonce: positionNonce
                )
                .encoded())
        } catch {
            if let request = incomingID { incomingFailed(.interrupted, request: request) }
        }
    }

    private func incomingFailed(_ error: FoundationHandoffError, request: UUID) {
        guard incomingID == request else { return }
        let hadApplied = appliedGeneration != nil
        retireIncoming()
        notice =
            hadApplied
            ? "Your queue was restored here. The other device may still be playing."
            : error.errorDescription
    }

    private func retireIncoming() {
        let cancelledGeneration = appliedGeneration
        let cancelledPlayer = player
        let waiting = awaitedControl
        awaitedControl = nil
        waiting?.continuation.finish(throwing: FoundationHandoffError.interrupted)
        acceptanceTask?.cancel()
        acceptanceTask = nil
        if let incomingHeader { consume(incomingHeader.id) }
        preparationTask?.cancel()
        receivingTask?.cancel()
        acknowledgement?.cancel()
        preparationTask = nil
        receivingTask = nil
        acknowledgement = nil
        incoming?.close()
        incoming = nil
        incomingActivity = nil
        incomingID = nil
        incomingHeader = nil
        incomingReady = false
        requestSent = false
        pending = nil
        appliedGeneration = nil
        appliedIntent = nil
        appliedPositionNonce = nil
        payloadReceived = false
        if let cancelledGeneration {
            cancelledPlayer?.cancelPendingContinuation(generation: cancelledGeneration)
        }
    }

    private func intentChanged() {
        guard !applying else { return }
        intent = UUID()
        navigationIntent = UUID()
        if let pending { consume(pending.id) }
        retireIncoming()
        retireOutgoing()
        publicationTask?.cancel()
        publicationTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.publishActivity()
        }
    }

    private func currentSession() -> FoundationHandoffPayload.Session? {
        guard let player, let selected = player.selectedEntryID,
            !player.persistedQueue.isEmpty,
            player.persistedQueue.count <= FoundationHandoffPayload.maximumEntries,
            player.persistedQueue.allSatisfy({ $0.item.kind == .track })
        else { return nil }
        return .init(
            entries: player.persistedQueue.map(FoundationHandoffPayload.Track.init),
            selected: selected, position: player.elapsed, shuffle: player.shuffleEnabled,
            repeatMode: .init(rawValue: player.repeatMode.rawValue) ?? .off,
            wasPlaying: player.wantsPlayback, visibleOccurrences: player.queue.map(\.id))
    }

    private var sourceDevice: FoundationHandoffPayload.SourceDevice? {
        #if os(macOS)
            .mac
        #elseif os(iOS)
            UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        #else
            nil
        #endif
    }

    private var advertisedKind: FoundationHandoffPayload.Kind? {
        let session = currentSession()
        if session?.isValid == true, session?.wasPlaying == true { return .playback }
        if browse != nil { return .browse }
        return session?.isValid == true ? .playback : nil
    }

    private func publishActivity() {
        guard let context, let kind = advertisedKind else {
            activity?.invalidate()
            activity?.delegate = nil
            activity = nil
            header = nil
            return
        }
        let value = FoundationHandoffPayload.Header(
            scope: context.scope, kind: kind, sourceDevice: sourceDevice)
        guard let data = try? value.encoded() else { return }
        let activity: NSUserActivity
        if outgoing != nil, let current = self.activity {
            // Keep an in-flight native stream's activity alive while rotating the
            // separately advertised nonce or changing the visible browse activity.
            activity = current
        } else {
            self.activity?.invalidate()
            self.activity?.delegate = nil
            activity = NSUserActivity(activityType: FoundationHandoffPayload.activityType)
        }
        activity.title = "Continue VelaCanto"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        #if os(iOS)
            activity.isEligibleForPrediction = false
        #endif
        activity.supportsContinuationStreams = true
        activity.userInfo = [FoundationHandoffPayload.userInfoKey: data]
        activity.requiredUserInfoKeys = [FoundationHandoffPayload.userInfoKey]
        activity.needsSave = true
        activity.delegate = self
        self.activity = activity
        header = value
        publish(activity)
    }

    nonisolated func userActivity(
        _ userActivity: NSUserActivity, didReceive inputStream: InputStream,
        outputStream: OutputStream
    ) {
        let identity = ObjectIdentifier(userActivity)
        let pair = FoundationHandoffNativeStreams(input: inputStream, output: outputStream)
        Task { @MainActor [weak self] in
            guard let self, self.activity.map(ObjectIdentifier.init) == identity,
                self.outgoing == nil
            else {
                pair.input.close()
                pair.output.close()
                return
            }
            let exchange = FoundationHandoffStreamExchange(
                streams: pair, maximumIncomingBytes: FoundationHandoffPayload.maximumHeaderBytes,
                maximumOutgoingMessages: 3,
                message: { [weak self] data in self?.sourceMessage(data) },
                failure: { [weak self] _ in self?.retireOutgoing() })
            self.outgoing = exchange
            exchange.open()
        }
    }

    private func sourceMessage(_ data: Data) {
        guard let outgoing, let context, let player else {
            retireOutgoing()
            return
        }
        do {
            if var transfer = sourceTransfer {
                guard transfer.sent, context.id == transfer.context,
                    intent == transfer.intent,
                    player.continuationGeneration == transfer.playerGeneration,
                    player.selectedEntryID == transfer.occurrence,
                    let occurrence = transfer.occurrence
                else { throw FoundationHandoffError.changed }
                switch transfer.phase {
                case .offered, .authorized:
                    let command = try FoundationHandoffControl.decode(data)
                    guard command.transfer == transfer.header.id, command.occurrence == occurrence
                    else {
                        throw FoundationHandoffError.changed
                    }
                    if transfer.phase == .offered {
                        guard command.kind == .authorize else {
                            throw FoundationHandoffError.invalid
                        }
                        transfer.phase = .authorized
                        sourceTransfer = transfer
                        try outgoing.expectAcknowledgement()
                        try outgoing.send(
                            FoundationHandoffControl(
                                kind: .authorized, transfer: transfer.header.id,
                                occurrence: occurrence, nonce: command.nonce
                            ).encoded())
                    } else {
                        guard command.kind == .position, transfer.wasPlaying, player.wantsPlayback
                        else {
                            throw FoundationHandoffError.changed
                        }
                        let seconds = try player.nativeContinuationPosition(
                            generation: transfer.playerGeneration, occurrence: occurrence)
                        transfer.phase = .writingPosition
                        transfer.positionNonce = command.nonce
                        sourceTransfer = transfer
                        try outgoing.expectAcknowledgement()
                        let transferID = transfer.header.id
                        outgoing.didSend = { [weak self] in
                            guard self?.sourceTransfer?.header.id == transferID,
                                self?.sourceTransfer?.positionNonce == command.nonce
                            else { return }
                            self?.sourceTransfer?.phase = .awaitingStart
                        }
                        try outgoing.send(
                            FoundationHandoffControl(
                                kind: .positionValue, transfer: transfer.header.id,
                                occurrence: occurrence, nonce: command.nonce, seconds: seconds
                            ).encoded())
                    }
                case .awaitingStart:
                    let ack = try FoundationHandoffAcknowledgement.decode(data)
                    guard ack.transfer == transfer.header.id, ack.occurrence == occurrence,
                        ack.nonce == transfer.positionNonce, transfer.wasPlaying,
                        player.wantsPlayback
                    else { throw FoundationHandoffError.changed }
                    retireOutgoing()
                    player.setQueue([], selectedIndex: 0)
                    player.stop()
                case .writingPosition:
                    throw FoundationHandoffError.invalid
                }
                return
            }
            let requested = try FoundationHandoffPayload.Header.decode(data)
            try requested.validate(scope: context.scope, now: requested.createdAt)
            guard let header, requested.id == header.id, requested.scope == context.scope,
                requested.kind == header.kind, requested.kind == advertisedKind
            else { throw FoundationHandoffError.changed }
            let currentHeader = FoundationHandoffPayload.Header(
                id: header.id, scope: context.scope, kind: header.kind,
                sourceDevice: header.sourceDevice)
            let session = header.kind == .playback ? currentSession() : nil
            let payload = FoundationHandoffPayload(
                header: currentHeader, session: session,
                destination: header.kind == .browse ? browse?.destination : nil)
            try payload.validate(scope: context.scope, now: Date().timeIntervalSince1970)
            let transfer = SourceTransfer(
                header: currentHeader, context: context.id,
                intent: intent, playerGeneration: player.continuationGeneration,
                occurrence: session?.selected, wasPlaying: session?.wasPlaying == true)
            sourceTransfer = transfer
            try outgoing.expectAcknowledgement()
            encodingTask = Task { [weak self] in
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try payload.encoded()
                    }.value
                    try Task.checkCancellation()
                    guard let self, self.sourceTransfer?.header.id == transfer.header.id,
                        self.context?.id == transfer.context, self.intent == transfer.intent
                    else { return }
                    outgoing.didSend = { [weak self] in
                        guard let self, self.sourceTransfer?.header.id == transfer.header.id else {
                            return
                        }
                        self.sourceTransfer?.sent = true
                        // Rotate only the advertisement. The active transfer retains its
                        // immutable nonce and original intent until acknowledgement.
                        self.publishActivity()
                    }
                    try outgoing.send(data)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.retireOutgoing()
                }
            }
        } catch { retireOutgoing() }
    }

    private func retireOutgoing() {
        let wasOpen = outgoing != nil
        encodingTask?.cancel()
        encodingTask = nil
        outgoing?.close()
        outgoing = nil
        sourceTransfer = nil
        // Every served or failed native exchange retires its advertisement nonce.
        // Explicit subsequent Handoff can request a fresh transfer without retrying
        // the old request or weakening receiver replay protection.
        if wasOpen { publishActivity() }
    }

    private func pruneReceipts() {
        let oldest = Date().timeIntervalSince1970 - FoundationHandoffPayload.maximumAge
        consumed = consumed.filter { $0.value >= oldest }
    }

    private func currentIntent(for kind: FoundationHandoffPayload.Kind) -> UUID {
        kind == .browse ? navigationIntent : intent
    }

    private func consume(_ id: UUID) {
        pruneReceipts()
        consumed[id] = Date().timeIntervalSince1970
    }
}
