#if os(iOS)
    import Combine
    import Intents
    import UIKit

    @MainActor
    enum FoundationSiriAuthorization {
        static var isAuthorized: Bool {
            FoundationSiriStartupAuthorization.nativeAccessAllowed
                && INPreferences.siriAuthorizationStatus() == .authorized
        }
        static let didChange = Notification.Name("FoundationSiriAuthorizationDidChange")
    }

    /// App-wide permission history is independent of account and playback lifetimes.
    @MainActor
    final class FoundationSiriStartupAuthorization {
        static let requestedKey = "FoundationSiriAuthorizationRequested"
        static let shared = FoundationSiriStartupAuthorization(
            defaults: .standard, status: { INPreferences.siriAuthorizationStatus() },
            request: { completion in
                INPreferences.requestSiriAuthorization { status in
                    Task { @MainActor in completion(status) }
                }
            },
            notify: {
                NotificationCenter.default.post(
                    name: FoundationSiriAuthorization.didChange, object: nil)
            },
            requestsAllowed: { nativeAccessAllowed })

        static var nativeAccessAllowed: Bool {
            #if targetEnvironment(simulator)
                // Simulator signing does not provide the Siri entitlement.
                return false
            #else
                return NSClassFromString("XCTestCase") == nil
                    && ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            #endif
        }

        private let defaults: UserDefaults
        private let status: () -> INSiriAuthorizationStatus
        private let request:
            (@escaping @MainActor @Sendable (INSiriAuthorizationStatus) -> Void) -> Void
        private let notify: () -> Void
        private let requestsAllowed: () -> Bool
        private var lastStatus: INSiriAuthorizationStatus

        init(
            defaults: UserDefaults, status: @escaping () -> INSiriAuthorizationStatus,
            request:
                @escaping (@escaping @MainActor @Sendable (INSiriAuthorizationStatus) -> Void) ->
                Void,
            notify: @escaping () -> Void, requestsAllowed: @escaping () -> Bool = { true }
        ) {
            self.defaults = defaults
            self.status = status
            self.request = request
            self.notify = notify
            self.requestsAllowed = requestsAllowed
            lastStatus = requestsAllowed() ? status() : .notDetermined
        }

        func foreground(isActive: Bool, canPrompt: Bool = true) {
            guard isActive, requestsAllowed() else { return }
            let currentStatus = status()
            publishChange(currentStatus)
            guard canPrompt, currentStatus == .notDetermined,
                !defaults.bool(forKey: Self.requestedKey)
            else { return }
            // Claim before requesting: scene re-entry and an indeterminate callback cannot reprompt.
            // The OS status, rather than this history marker, always determines authorization.
            defaults.set(true, forKey: Self.requestedKey)
            request { [weak self] _ in
                guard let self, self.requestsAllowed() else { return }
                self.publishChange(self.status())
            }
        }

        private func publishChange(_ status: INSiriAuthorizationStatus) {
            guard status != lastStatus else { return }
            lastStatus = status
            notify()
        }
    }

    /// Narrow Siri input policy. Provider IDs from a prior account are never trusted as playback IDs.
    struct FoundationSiriRequest {
        let query: String
        let kind: FoundationItem.Kind?
        let artist: String?
        let album: String?
        let shuffled: Bool
        let resume: Bool

        init?(intent: INPlayMediaIntent) {
            guard intent.playbackQueueLocation == .unknown || intent.playbackQueueLocation == .now,
                intent.playbackSpeed == nil || intent.playbackSpeed == 1,
                intent.playbackRepeatMode == .unknown || intent.playbackRepeatMode == .none,
                (intent.mediaItems?.count ?? 0) <= 1
            else { return nil }
            let search = intent.mediaSearch
            let media = intent.mediaItems?.first ?? intent.mediaContainer
            let type = search?.mediaType ?? media?.type ?? .unknown
            switch type {
            case .song: kind = .track
            case .album: kind = .album
            case .artist: kind = .artist
            case .playlist: kind = .playlist
            case .unknown, .music:
                if Self.term(search?.mediaName) == nil, Self.term(media?.title) == nil {
                    kind =
                        Self.term(search?.albumName) != nil
                        ? .album
                        : Self.term(search?.artistName) != nil ? .artist : nil
                } else {
                    kind = nil
                }
            default: return nil
            }
            artist = Self.term(search?.artistName)
            album = Self.term(search?.albumName)
            query =
                Self.term(search?.mediaName) ?? Self.term(media?.title)
                ?? (kind == .album ? album : nil) ?? (kind == .artist ? artist : nil) ?? ""
            shuffled = intent.playShuffled ?? false
            resume = intent.resumePlayback == true && query.isEmpty
            guard resume || !FoundationSearchResolver.normalize(query).isEmpty, query.count <= 256
            else { return nil }
        }

        static func term(_ value: String?) -> String? {
            guard let value else { return nil }
            let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= 256,
                !term.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else { return nil }
            return term
        }

        static func equal(_ lhs: String, _ rhs: String) -> Bool {
            let lhs = FoundationSearchResolver.normalize(lhs)
            let rhs = FoundationSearchResolver.normalize(rhs)
            return !lhs.isEmpty && lhs == rhs
        }

        func matchingItems(in items: [FoundationItem]) -> [FoundationItem] {
            let matches = items.filter { item in
                guard [.track, .album, .artist, .playlist].contains(item.kind),
                    kind == nil || kind == item.kind, Self.equal(item.title, query)
                else { return false }
                if let artist, item.kind != .artist,
                    !Self.equal(item.artist?.title ?? item.subtitle, artist)
                {
                    return false
                }
                if let album, item.kind == .track,
                    !Self.equal(item.album?.title ?? "", album)
                {
                    return false
                }
                return true
            }
            // The same provider item can appear in direct and related projections.
            var seen: Set<String> = []
            let unique = matches.filter { seen.insert($0.kind.rawValue + ":" + $0.id).inserted }
            return unique
        }

        func uniqueMatch(in items: [FoundationItem]) -> FoundationItem? {
            let matches = matchingItems(in: items)
            return matches.count == 1 ? matches[0] : nil
        }
    }

    /// Explicit Siri Play needs direct candidates, never browsing relationships or discovery.
    @MainActor
    enum FoundationSiriCatalog {
        enum Outcome: String {
            case unique, ambiguous, empty, kindMismatch, titleMismatch, artistMismatch,
                albumMismatch, incomplete, tooMany
        }
        enum Prompt { case accept, confirm, choose, refine, missing }
        private struct DirectPage: Sendable {
            let kind: FoundationItem.Kind
            let page: FoundationPage?
            let failure: FoundationLibraryError?
        }
        struct Snapshot {
            let matches: [FoundationItem]
            let outcome: Outcome
            let candidateCount: Int
            let kindCount: Int
            let titleCount: Int
            let artistCount: Int
            let albumCount: Int
            let failedKindCount: Int
            var offeredMatches: [FoundationItem] { Array(matches.prefix(5)) }
            var prompt: Prompt {
                if matches.isEmpty { return outcome == .incomplete ? .refine : .missing }
                if matches.count > 1 { return .choose }
                return outcome == .unique ? .accept : .confirm
            }
        }

        static func resolve(
            request: FoundationSiriRequest, library: any FoundationLibrary,
            localOnly: Bool, localItems: [FoundationItem] = [],
            project: ([FoundationItem]) -> [FoundationItem] = { $0 }
        ) async throws -> Snapshot {
            try Task.checkCancellation()
            if localOnly {
                return match(request: request, items: project(localItems), incomplete: false)
            }
            let kinds = request.kind.map { [$0] } ?? [.track, .album, .artist, .playlist]
            let reads = try await FoundationRequestIntent.$isPlayback.withValue(true) {
                try await withThrowingTaskGroup(of: DirectPage.self) { group in
                    for kind in kinds {
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let page = try await library.search(
                                    query: request.query, kind: kind, startIndex: 0, limit: 50)
                                guard page.nextStartIndex == nil || page.nextStartIndex! > 0 else {
                                    throw FoundationLibraryError.invalidResponse
                                }
                                return DirectPage(kind: kind, page: page, failure: nil)
                            } catch {
                                try Task.checkCancellation()
                                if error is CancellationError
                                    || FoundationLibraryError.category(error) == .cancelled
                                {
                                    throw CancellationError()
                                }
                                return DirectPage(
                                    kind: kind, page: nil,
                                    failure: FoundationLibraryError.category(error))
                            }
                        }
                    }
                    var reads: [FoundationItem.Kind: DirectPage] = [:]
                    for try await read in group { reads[read.kind] = read }
                    return kinds.compactMap { reads[$0] }
                }
            }
            try Task.checkCancellation()
            let pages = reads.compactMap(\.page)
            guard !pages.isEmpty else { throw reads.compactMap(\.failure).first ?? .unavailable }
            let failedKinds = reads.filter { $0.failure != nil }.count
            let incomplete =
                failedKinds > 0
                || pages.contains { $0.nextStartIndex != nil || $0.items.count > 50 }
            return match(
                request: request, items: project(pages.flatMap { Array($0.items.prefix(50)) }),
                incomplete: incomplete, failedKinds: failedKinds)
        }

        static func match(
            request: FoundationSiriRequest, items: [FoundationItem], incomplete: Bool,
            failedKinds: Int = 0
        )
            -> Snapshot
        {
            let kinds = items.filter {
                [.track, .album, .artist, .playlist].contains($0.kind)
                    && (request.kind == nil || request.kind == $0.kind)
            }
            let titles = kinds.filter { FoundationSiriRequest.equal($0.title, request.query) }
            let artists = titles.filter { item in
                guard let artist = request.artist, item.kind != .artist else { return true }
                return FoundationSiriRequest.equal(item.artist?.title ?? item.subtitle, artist)
            }
            let albums = artists.filter { item in
                guard let album = request.album, item.kind == .track else { return true }
                return FoundationSiriRequest.equal(item.album?.title ?? "", album)
            }
            let matches = request.matchingItems(in: albums)
            let outcome: Outcome
            if incomplete {
                outcome = .incomplete
            } else if matches.count > 5 {
                outcome = .tooMany
            } else if matches.count > 1 {
                outcome = .ambiguous
            } else if matches.count == 1 {
                outcome = .unique
            } else if items.isEmpty {
                outcome = .empty
            } else if kinds.isEmpty {
                outcome = .kindMismatch
            } else if titles.isEmpty {
                outcome = .titleMismatch
            } else if artists.isEmpty {
                outcome = .artistMismatch
            } else {
                outcome = .albumMismatch
            }
            return Snapshot(
                matches: matches, outcome: outcome, candidateCount: items.count,
                kindCount: kinds.count, titleCount: titles.count, artistCount: artists.count,
                albumCount: albums.count, failedKindCount: failedKinds)
        }
    }

    extension FoundationCarPlayApplicationDelegate {
        func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
            intent is INPlayMediaIntent ? FoundationSiriPlayback.shared : nil
        }

        func application(
            _ application: UIApplication, handle intent: INIntent,
            completionHandler: @escaping (INIntentResponse) -> Void
        ) {
            guard let intent = intent as? INPlayMediaIntent else {
                completionHandler(
                    INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }
            FoundationSiriPlayback.shared.handle(intent: intent) { completionHandler($0) }
        }
    }

    /// Observes existing player intent/session ownership, not native buffering state.
    @MainActor
    final class FoundationSiriCommandGuard {
        private(set) var isCurrent = true
        private var subscriptions: Set<AnyCancellable> = []
        private let onChange: () -> Void

        init(player: FoundationPlayer, onChange: @escaping () -> Void) {
            self.onChange = onChange
            player.sessionChanged.sink { [weak self] in self?.invalidate() }
                .store(in: &subscriptions)
            player.$wantsPlayback.dropFirst().sink { [weak self] _ in
                self?.invalidate()
            }.store(in: &subscriptions)
        }

        /// The caller's own selection may now change these same publishers.
        func disarm() { subscriptions.removeAll() }

        private func invalidate() {
            guard isCurrent else { return }
            isCurrent = false
            disarm()
            onChange()
        }
    }

    /// A single short-lived resolution, not a catalog cache or a provider-ID authority.
    @MainActor
    struct FoundationSiriResolvedMedia {
        static let identifierPrefix = "velacanto-resolution:"
        let identifier: String
        let resolutionID: UUID
        let commandGuard: FoundationSiriCommandGuard?
        let item: FoundationItem
        weak var player: FoundationPlayer?
        weak var actions: FoundationLibraryActions?
        let scope: String
        let localOnly: Bool
        let createdAt: Date

        init(
            item: FoundationItem, player: FoundationPlayer, actions: FoundationLibraryActions,
            scope: String, localOnly: Bool, now: Date = Date(),
            resolutionID: UUID = UUID(), commandGuard: FoundationSiriCommandGuard? = nil
        ) {
            identifier = Self.identifierPrefix + UUID().uuidString
            self.resolutionID = resolutionID
            self.commandGuard = commandGuard
            self.item = item
            self.player = player
            self.actions = actions
            self.scope = scope
            self.localOnly = localOnly
            createdAt = now
        }

        func isCurrent(
            player: FoundationPlayer, actions: FoundationLibraryActions,
            scope: String, localOnly: Bool, now: Date = Date()
        ) -> Bool {
            let age = now.timeIntervalSince(createdAt)
            return commandGuard?.isCurrent != false
                && self.player === player && self.actions === actions && self.scope == scope
                && self.localOnly == localOnly && age >= 0 && age < 60
        }

        func accepts(
            identifier: String, player: FoundationPlayer, actions: FoundationLibraryActions,
            scope: String, localOnly: Bool, now: Date = Date()
        ) -> Bool {
            self.identifier == identifier
                && isCurrent(
                    player: player, actions: actions,
                    scope: scope, localOnly: localOnly, now: now)
        }

        var mediaItem: INMediaItem {
            let type: INMediaItemType
            switch item.kind {
            case .track: type = .song
            case .album: type = .album
            case .artist: type = .artist
            case .playlist: type = .playlist
            case .genre: type = .genre
            }
            return INMediaItem(
                identifier: identifier, title: item.title, type: type, artwork: nil,
                artist: item.artist?.title ?? (item.kind == .artist ? item.title : item.subtitle))
        }
    }

    /// One cancellable handoff into the account-owned player. No speech capture or second player.
    @MainActor
    final class FoundationSiriPlayback: NSObject, @preconcurrency INPlayMediaIntentHandling {
        static let shared = FoundationSiriPlayback()
        private let authorized: () -> Bool
        init(authorized: @escaping () -> Bool = { FoundationSiriAuthorization.isAuthorized }) {
            self.authorized = authorized
            super.init()
        }

        private var resolutionTask: Task<Void, Never>?
        private var resolutionID: UUID?
        private var resolutionCompletion: (([INPlayMediaMediaItemResolutionResult]) -> Void)?
        private var resolvedChoices: [String: FoundationSiriResolvedMedia] = [:]
        private var task: Task<Void, Never>?
        private var requestID: UUID?
        private var completion: ((INPlayMediaIntentResponse) -> Void)?
        private var subscriptions: Set<AnyCancellable> = []
        private var cancelCollection: (() -> Void)?
        private var commandGuard: FoundationSiriCommandGuard?

        /// Required by SiriKit even though the Objective-C protocol marks it optional.
        /// Modern iOS routes resolution here via application(_:handlerFor:); the extension
        /// never receives credentials or manufactures a successful catalog match.
        func resolveMediaItems(
            for intent: INPlayMediaIntent,
            with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
        ) {
            if let token = Self.resolutionToken(intent) {
                let model = FoundationAppRuntime.model
                guard authorized(), let selected = resolvedChoices[token],
                    let player = model.player, let actions = model.actions,
                    let library = model.browseLibrary,
                    selected.accepts(
                        identifier: token, player: player, actions: actions,
                        scope: library.catalogScopeID,
                        localOnly: model.connectivity?.localOnly ?? true)
                else {
                    cancel()
                    completion([.unsupported()])
                    return
                }
                resolvedChoices = [token: selected]
                Self.trace(stage: "resolve", outcome: "choice-selected")
                completion([.success(with: selected.mediaItem)])
                return
            }
            cancel()
            Self.trace(stage: "resolve", outcome: "started")
            guard authorized() else {
                completion([.unsupported(forReason: .loginRequired)])
                return
            }
            guard let request = FoundationSiriRequest(intent: intent) else {
                let hasName =
                    intent.mediaSearch?.mediaName != nil
                    || intent.mediaSearch?.artistName != nil || intent.mediaSearch?.albumName != nil
                    || intent.mediaItems?.first?.title != nil || intent.mediaContainer?.title != nil
                Self.trace(stage: "resolve", outcome: hasName ? "unsupported" : "needs-value")
                completion(
                    hasName ? [.unsupported(forReason: .unsupportedMediaType)] : [.needsValue()])
                return
            }
            if request.resume {
                completion([.notRequired()])
                return
            }
            let id = UUID()
            resolutionID = id
            resolutionCompletion = completion
            resolutionTask = Task { [weak self] in
                guard let self else { return }
                let model = FoundationAppRuntime.model
                guard await model.ensureReady() == .ready, !Task.isCancelled,
                    let library = model.browseLibrary, let player = model.player,
                    let actions = model.actions
                else {
                    self.finishResolution(id, results: [.unsupported(forReason: .loginRequired)])
                    return
                }
                let localOnly = model.connectivity?.localOnly ?? true
                let scope = library.catalogScopeID
                let isCurrent = {
                    model.player === player && model.actions === actions
                        && model.browseLibrary?.catalogScopeID == scope
                        && (model.connectivity?.localOnly ?? true) == localOnly
                }
                for publisher in [
                    model.objectWillChange.eraseToAnyPublisher(),
                    model.connectivity?.objectWillChange.eraseToAnyPublisher(),
                ].compactMap({ $0 }) {
                    publisher.sink { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self,
                                self.resolutionID == id
                                    || self.resolvedChoices.values.contains(where: {
                                        $0.resolutionID == id
                                    }),
                                !isCurrent()
                            else { return }
                            self.cancel()
                        }
                    }.store(in: &self.subscriptions)
                }
                self.commandGuard = FoundationSiriCommandGuard(player: player) { [weak self] in
                    self?.cancel()
                }
                do {
                    let snapshot = try await FoundationSiriCatalog.resolve(
                        request: request,
                        library: library, localOnly: localOnly,
                        localItems: localOnly ? model.downloads?.localCatalogItems() ?? [] : [],
                        project: { actions.visibleTracks($0) })
                    try Task.checkCancellation()
                    guard self.resolutionID == id, isCurrent() else { return }
                    Self.trace(snapshot)
                    guard !snapshot.offeredMatches.isEmpty else {
                        self.finishResolution(
                            id,
                            results: snapshot.prompt == .refine ? [.needsValue()] : [.unsupported()]
                        )
                        return
                    }
                    let choices = snapshot.offeredMatches.map { item in
                        FoundationSiriResolvedMedia(
                            item: item, player: player, actions: actions,
                            scope: scope, localOnly: localOnly, resolutionID: id,
                            commandGuard: self.commandGuard)
                    }
                    let result: INPlayMediaMediaItemResolutionResult
                    switch snapshot.prompt {
                    case .accept: result = .success(with: choices[0].mediaItem)
                    case .confirm: result = .confirmationRequired(with: choices[0].mediaItem)
                    case .choose: result = .disambiguation(with: choices.map(\.mediaItem))
                    case .refine, .missing: result = .needsValue()
                    }
                    self.finishResolution(id, results: [result], resolved: choices)
                } catch {
                    self.finishResolution(
                        id, results: [.unsupported(forReason: .serviceUnavailable)])
                }
            }
        }

        private func finishResolution(
            _ id: UUID, results: [INPlayMediaMediaItemResolutionResult],
            resolved: [FoundationSiriResolvedMedia] = []
        ) {
            guard resolutionID == id else { return }
            let callback = resolutionCompletion
            resolutionCompletion = nil
            resolutionID = nil
            resolutionTask = nil
            if resolved.isEmpty {
                subscriptions.removeAll()
                commandGuard?.disarm()
                commandGuard = nil
            }
            resolvedChoices = Dictionary(uniqueKeysWithValues: resolved.map { ($0.identifier, $0) })
            Self.trace(
                stage: "resolve",
                outcome: resolved.isEmpty
                    ? "returned" : resolved.count == 1 ? "matched" : "disambiguation")
            callback?(results)
        }

        func handle(
            intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void
        ) {
            let resolutionToken = Self.resolutionToken(intent)
            let resolution = resolutionToken.flatMap { resolvedChoices[$0] }
            let inheritedGuard = resolutionToken == nil ? nil : resolution?.commandGuard
            cancel(preserving: inheritedGuard)
            self.commandGuard = inheritedGuard
            Self.trace(stage: "handle", outcome: "started")
            guard authorized() else {
                cancel()
                completion(
                    INPlayMediaIntentResponse(code: .failureRequiringAppLaunch, userActivity: nil))
                return
            }
            guard let request = FoundationSiriRequest(intent: intent) else {
                cancel()
                completion(
                    INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
                return
            }
            let id = UUID()
            requestID = id
            self.completion = completion
            task = Task { [weak self] in
                guard let self else { return }
                let model = FoundationAppRuntime.model
                guard await model.ensureReady() == .ready, !Task.isCancelled,
                    let library = model.browseLibrary, let player = model.player,
                    let actions = model.actions, !actions.isQueueLoading
                else {
                    self.finish(id, code: .failureRequiringAppLaunch)
                    return
                }
                let localOnly = model.connectivity?.localOnly ?? true
                let downloads = model.downloads
                let isCurrent = {
                    model.player === player && model.actions === actions
                        && model.browseLibrary?.catalogScopeID == library.catalogScopeID
                        && model.browseLibrary?.session.serverURL == library.session.serverURL
                        && model.browseLibrary?.session.userID == library.session.userID
                        && model.browseLibrary?.session.accessToken == library.session.accessToken
                        && model.browseLibrary?.session.deviceID == library.session.deviceID
                        && (model.connectivity?.localOnly ?? true) == localOnly
                }
                model.objectWillChange.sink { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id, !isCurrent() else { return }
                        self.cancel()
                    }
                }.store(in: &self.subscriptions)
                model.connectivity?.objectWillChange.sink { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id, !isCurrent() else { return }
                        self.cancel()
                    }
                }.store(in: &self.subscriptions)
                let commandGuard =
                    inheritedGuard
                    ?? FoundationSiriCommandGuard(player: player) { [weak self] in
                        self?.cancel()
                    }
                self.commandGuard = commandGuard
                guard commandGuard.isCurrent else {
                    self.finish(id, code: .failure)
                    return
                }
                do {
                    if request.resume {
                        guard player.selectedEntryID != nil else {
                            self.finish(id, code: .failureNoUnplayedContent)
                            return
                        }
                        commandGuard.disarm()
                        player.play()
                        NotificationCenter.default.post(
                            name: Self.didRequestPlayback, object: player)
                        self.finish(
                            id,
                            code: player.state == .failed
                                ? .failure : player.state == .playing ? .success : .inProgress)
                        return
                    }
                    let item: FoundationItem
                    if let resolutionToken {
                        guard let resolution,
                            resolution.accepts(
                                identifier: resolutionToken,
                                player: player, actions: actions,
                                scope: library.catalogScopeID, localOnly: localOnly)
                        else {
                            self.finish(id, code: .failure)
                            return
                        }
                        item = resolution.item
                    } else {
                        let snapshot = try await FoundationSiriCatalog.resolve(
                            request: request,
                            library: library, localOnly: localOnly,
                            localItems: localOnly ? downloads?.localCatalogItems() ?? [] : [],
                            project: { actions.visibleTracks($0) })
                        try Task.checkCancellation()
                        Self.trace(snapshot)
                        guard snapshot.outcome == .unique, let match = snapshot.matches.first else {
                            self.finish(id, code: .failure)
                            return
                        }
                        item = match
                    }
                    guard self.requestID == id, isCurrent(), !actions.isQueueLoading else {
                        self.finish(id, code: .failure)
                        return
                    }
                    if item.kind == .track {
                        guard !localOnly || downloads?.isReady(item) == true else {
                            self.finish(id, code: .failure)
                            return
                        }
                        commandGuard.disarm()
                        player.setQueue([item], selectedIndex: 0)
                    } else if localOnly {
                        let ready = actions.collectionTracks(
                            downloads?.browseTracks(for: item) ?? [], for: item)
                        guard !ready.isEmpty,
                            ready.count <= FoundationLibraryActions.maximumCollectionTracks
                        else {
                            self.finish(id, code: .failure)
                            return
                        }
                        commandGuard.disarm()
                        player.setQueue(
                            request.shuffled ? ready.shuffled() : ready, selectedIndex: 0)
                    } else {
                        self.cancelCollection = { actions.cancelQueueAdditionOwned(by: id) }
                        let priorSelection = player.selectedEntryID
                        actions.play(
                            item, shuffled: request.shuffled, library: library, player: player,
                            owner: id,
                            shouldCommit: { [weak self] in
                                guard let self, self.requestID == id, isCurrent(),
                                    commandGuard.isCurrent
                                else { return false }
                                commandGuard.disarm()
                                return true
                            })
                        let preparation = actions.queueTask
                        await preparation?.value
                        try Task.checkCancellation()
                        guard preparation?.isCancelled != true else {
                            self.finish(id, code: .failure)
                            return
                        }
                        guard isCurrent(), player.selectedEntryID != priorSelection,
                            actions.queueErrorMessage == nil, actions.queueNotice == nil
                        else {
                            self.finish(id, code: .failure)
                            return
                        }
                    }
                    guard self.requestID == id, isCurrent() else { return }
                    NotificationCenter.default.post(name: Self.didRequestPlayback, object: player)
                    self.finish(
                        id,
                        code: player.state == .failed
                            ? .failure : player.state == .playing ? .success : .inProgress)
                } catch {
                    self.finish(id, code: .failure)
                }
            }
        }

        static let didRequestPlayback = Notification.Name("FoundationSiriDidRequestPlayback")

        private func finish(_ id: UUID, code: INPlayMediaIntentResponseCode) {
            guard requestID == id else { return }
            let callback = completion
            completion = nil
            requestID = nil
            subscriptions.removeAll()
            commandGuard?.disarm()
            commandGuard = nil
            cancelCollection?()
            cancelCollection = nil
            task = nil
            Self.trace(
                stage: "handle",
                outcome: code == .success ? "playing" : code == .inProgress ? "accepted" : "failed")
            callback?(INPlayMediaIntentResponse(code: code, userActivity: nil))
        }

        private func cancel(preserving guardToKeep: FoundationSiriCommandGuard? = nil) {
            resolutionTask?.cancel()
            if let resolutionID {
                finishResolution(
                    resolutionID, results: [.unsupported(forReason: .serviceUnavailable)])
            }
            resolvedChoices.removeAll()
            task?.cancel()
            if let requestID { finish(requestID, code: .failure) }
            subscriptions.removeAll()
            if commandGuard !== guardToKeep {
                commandGuard?.disarm()
                commandGuard = nil
            }
        }

        private static func resolutionToken(_ intent: INPlayMediaIntent) -> String? {
            let value = intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier
            return value.flatMap {
                $0.hasPrefix(FoundationSiriResolvedMedia.identifierPrefix) ? $0 : nil
            }
        }

        private static func trace(_ snapshot: FoundationSiriCatalog.Snapshot) {
            #if DEBUG
                FoundationTrace.event(
                    "player.siri stage=match outcome=\(snapshot.outcome.rawValue) candidates=\(snapshot.candidateCount) kind=\(snapshot.kindCount) title=\(snapshot.titleCount) artist=\(snapshot.artistCount) album=\(snapshot.albumCount) matches=\(snapshot.matches.count) failed=\(snapshot.failedKindCount)"
                )
            #endif
        }

        private static func trace(stage: String, outcome: String) {
            #if DEBUG
                FoundationTrace.event("player.siri stage=\(stage) outcome=\(outcome)")
            #endif
        }
    }
#endif
