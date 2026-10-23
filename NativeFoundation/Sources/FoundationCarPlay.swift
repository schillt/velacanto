#if os(iOS)
    import CarPlay
    import Combine
    import UIKit

    /// Routes CarPlay without recycling SwiftUI's phone-scene delegate proxy.
    @MainActor
    final class FoundationCarPlayApplicationDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            Self.sceneConfiguration(for: connectingSceneSession.configuration)
        }

        static func sceneConfiguration(
            for sessionConfiguration: UISceneConfiguration
        ) -> UISceneConfiguration {
            let role = sessionConfiguration.role
            let configuration = UISceneConfiguration(
                name: role == .carTemplateApplication ? "CarPlay" : nil, sessionRole: role)
            guard role == .carTemplateApplication else { return configuration }
            configuration.sceneClass = CPTemplateApplicationScene.self
            configuration.delegateClass = FoundationCarPlaySceneDelegate.self
            return configuration
        }
    }

    /// Native templates project the phone-owned catalog and playback session.
    @MainActor
    final class FoundationCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
        CPInterfaceControllerDelegate, CPNowPlayingTemplateObserver, CPSearchTemplateDelegate,
        CPTabBarTemplateDelegate, CPSessionConfigurationDelegate
    {
        private typealias Route = FoundationCarPlayCatalog.Route

        private struct Context {
            let library: FoundationJellyfinLibrary
            let player: FoundationPlayer
            let actions: FoundationLibraryActions
            let downloads: FoundationDownloads?
            let localOnly: Bool
            let generation: Int
        }

        private struct ArtworkRequest {
            let item: FoundationItem
            let size: CGSize
            let apply: (UIImage) -> Void
        }

        final class SearchResponse {
            private var completion: (([CPListItem]) -> Void)?

            init(_ completion: @escaping ([CPListItem]) -> Void) {
                self.completion = completion
            }

            func finish(_ items: [CPListItem]) {
                let callback = completion
                completion = nil
                callback?(items)
            }
        }

        private var interfaceController: CPInterfaceController?
        private var sessionConfiguration: CPSessionConfiguration?
        private var context: Context?
        private var generation = 0
        private var startupTask: Task<Void, Never>?
        private var rootTask: Task<Void, Never>?
        private var playTask: Task<Void, Never>?
        private var playRequestID: UUID?
        private var playbackRevision = 0
        private var reconcileTask: Task<Void, Never>?
        private var searchTask: Task<Void, Never>?
        private var searchResponse: SearchResponse?
        private var searchTemplate: CPSearchTemplate?
        private var rootSearchTemplate: CPListTemplate?
        private var searchOptionsTemplate: CPListTemplate?
        private var searchOrigin: CPTemplate?
        private var lastContentTab: CPTemplate?
        private var searchContext: Context?
        private var searchQueryID = UUID()
        private var searchQuery = ""
        private var searchSnapshot: FoundationCarPlayCatalog.SearchSnapshot?
        private var requestedSearchResultsID: UUID?
        private var subscriptions: Set<AnyCancellable> = []
        private var sessionSubscription: AnyCancellable?
        private var pinSubscription: AnyCancellable?
        private var policySubscription: AnyCancellable?
        private var visibilitySubscription: AnyCancellable?
        private var visibilityTask: Task<Void, Never>?
        private var rootShelfProjection: (() -> Void)?
        private var playbackErrorSubscription: AnyCancellable?
        private var pageTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var artworkTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
        private var rowArtwork: [ObjectIdentifier: [ArtworkRequest]] = [:]
        private var pinArtwork: [ObjectIdentifier: [ArtworkRequest]] = [:]
        private var bodySections: [ObjectIdentifier: [CPListSection]] = [:]
        private var pinnedSections: [ObjectIdentifier: [CPListSection]] = [:]
        private var pinEligibleLists: Set<ObjectIdentifier> = []
        private var cachedProjections: [ObjectIdentifier: () -> Void] = [:]
        private var sectionOffsets: [ObjectIdentifier: Int] = [:]
        private var projectionIDs: [ObjectIdentifier: UUID] = [:]
        private var isReprojecting = false
        private var lists: [ObjectIdentifier: CPListTemplate] = [:]
        private var isNavigating = false
        private let collectionOwner = UUID()
        private var queueTemplate: CPListTemplate?
        private var queueOffset = 0

        func templateApplicationScene(
            _ scene: CPTemplateApplicationScene, didConnect controller: CPInterfaceController
        ) {
            disconnect()
            interfaceController = controller
            sessionConfiguration = CPSessionConfiguration(delegate: self)
            controller.delegate = self
            CPNowPlayingTemplate.shared.add(self)
            FoundationAppRuntime.model.objectWillChange.sink { [weak self] in
                self?.scheduleReconciliation()
            }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: FoundationSiriPlayback.didRequestPlayback)
                .sink { [weak self] notification in
                    guard let self, let context = self.context, self.isCurrent(context),
                        let player = notification.object as? FoundationPlayer,
                        player === context.player
                    else { return }
                    self.showNowPlaying(context)
                }.store(in: &subscriptions)
            NotificationCenter.default.publisher(for: FoundationSiriAuthorization.didChange)
                .sink { [weak self] _ in
                    guard let self, let context = self.context, self.isCurrent(context) else {
                        return
                    }
                    self.reprojectCaches(context)
                }.store(in: &subscriptions)
            prepare()
        }

        func templateApplicationScene(
            _ scene: CPTemplateApplicationScene,
            didDisconnectInterfaceController controller: CPInterfaceController
        ) {
            guard interfaceController === controller else { return }
            disconnect()
        }

        private func disconnect() {
            cancelWork()
            reconcileTask?.cancel()
            reconcileTask = nil
            subscriptions.removeAll()
            interfaceController?.delegate = nil
            interfaceController = nil
            sessionConfiguration = nil
            CPNowPlayingTemplate.shared.remove(self)
        }

        private func cancelWork() {
            generation += 1
            if interfaceController?.presentedTemplate != nil {
                interfaceController?.dismissTemplate(animated: false, completion: { _, _ in })
            }
            context?.actions.cancelQueueAdditionOwned(by: collectionOwner)
            context = nil
            startupTask?.cancel()
            rootTask?.cancel()
            playTask?.cancel()
            startupTask = nil
            rootTask = nil
            playTask = nil
            playRequestID = nil
            sessionSubscription = nil
            pinSubscription = nil
            policySubscription = nil
            visibilitySubscription = nil
            visibilityTask?.cancel()
            visibilityTask = nil
            rootShelfProjection = nil
            playbackErrorSubscription = nil
            searchResponse?.finish([])
            searchResponse = nil
            searchTask?.cancel()
            searchTask = nil
            searchTemplate?.delegate = nil
            searchTemplate = nil
            searchContext = nil
            rootSearchTemplate = nil
            searchOptionsTemplate = nil
            searchOrigin = nil
            lastContentTab = nil
            searchQueryID = UUID()
            searchQuery = ""
            searchSnapshot = nil
            requestedSearchResultsID = nil
            for task in pageTasks.values { task.cancel() }
            for task in artworkTasks.values { task.cancel() }
            pageTasks.removeAll()
            artworkTasks.removeAll()
            rowArtwork.removeAll()
            pinArtwork.removeAll()
            bodySections.removeAll()
            pinnedSections.removeAll()
            pinEligibleLists.removeAll()
            sectionOffsets.removeAll()
            cachedProjections.removeAll()
            projectionIDs.removeAll()
            lists.removeAll()
            queueTemplate = nil
            isNavigating = false
            CPNowPlayingTemplate.shared.isUpNextButtonEnabled = false
            CPNowPlayingTemplate.shared.updateNowPlayingButtons([])
        }

        private func scheduleReconciliation() {
            guard reconcileTask == nil else { return }
            reconcileTask = Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconcileTask = nil
                guard self.interfaceController != nil else { return }
                guard self.startupTask == nil else { return }
                let model = FoundationAppRuntime.model
                if let context = self.context,
                    model.player === context.player, model.actions === context.actions,
                    model.browseLibrary?.catalogScopeID == context.library.catalogScopeID,
                    (model.connectivity?.localOnly ?? true) == context.localOnly
                {
                    return
                }
                self.prepare()
            }
        }

        private func prepare() {
            guard interfaceController != nil else { return }
            cancelWork()
            let epoch = generation
            setRoot(status("Preparing Library", message: "Your listening session is loading."))
            let model = FoundationAppRuntime.model
            startupTask = Task { [weak self] in
                let readiness = await model.ensureReady()
                guard let self, !Task.isCancelled, self.generation == epoch,
                    self.interfaceController != nil
                else { return }
                self.startupTask = nil
                guard readiness == .ready, let library = model.browseLibrary,
                    let player = model.player, let actions = model.actions
                else {
                    self.setRoot(
                        self.status(
                            readiness == .signedOut ? "Sign-In Required" : "Library Unavailable",
                            message: readiness == .signedOut
                                ? "No signed-in listening account is available."
                                : "Your listening library is not ready."))
                    return
                }
                let context = Context(
                    library: library, player: player, actions: actions, downloads: model.downloads,
                    localOnly: model.connectivity?.localOnly ?? true, generation: epoch)
                self.context = context
                self.policySubscription = model.connectivity?.objectWillChange.sink { [weak self] in
                    self?.scheduleReconciliation()
                }
                self.configureNowPlaying(context)
                self.sessionSubscription = player.sessionChanged.sink { [weak self] in
                    guard let self, self.isCurrent(context) else { return }
                    self.playbackRevision += 1
                    self.configureNowPlaying(context)
                    self.updateQueue(context)
                }
                self.playbackErrorSubscription = player.$errorMessage.compactMap { $0 }
                    .removeDuplicates().sink { [weak self] message in
                        guard let self, self.isCurrent(context) else { return }
                        self.showMessage(message)
                    }
                self.pinSubscription = actions.$pins.dropFirst().sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.isCurrent(context) else { return }
                        for template in self.lists.values where template !== self.queueTemplate {
                            self.installPins(template, context: context)
                        }
                        if let visible = self.visibleList {
                            self.startArtwork(visible, context: context)
                        }
                    }
                }
                self.visibilitySubscription = actions.$trackVisibilityRevision.dropFirst().sink {
                    [weak self] _ in
                    guard let self, self.visibilityTask == nil else { return }
                    self.visibilityTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.visibilityTask = nil
                        guard !Task.isCancelled, self.isCurrent(context) else { return }
                        self.reprojectCaches(context)
                    }
                }
                self.installRoots(context)
            }
        }

        private func isCurrent(_ context: Context) -> Bool {
            let model = FoundationAppRuntime.model
            return interfaceController != nil && generation == context.generation
                && model.player === context.player && model.actions === context.actions
                && model.browseLibrary?.catalogScopeID == context.library.catalogScopeID
                && (model.connectivity?.localOnly ?? true) == context.localOnly
        }

        private func status(_ title: String, message: String) -> CPListTemplate {
            let template = CPListTemplate(title: "VelaCanto", sections: [])
            template.emptyViewTitleVariants = [title]
            template.emptyViewSubtitleVariants = [message]
            return template
        }

        private func setRoot(_ template: CPTemplate) {
            let epoch = generation
            interfaceController?.setRootTemplate(template, animated: false) {
                [weak self] success, _ in
                guard let self, self.generation == epoch else { return }
                if !success { self.showMessage("The requested screen is unavailable.") }
            }
        }

        private func installRoots(_ context: Context) {
            let home = makeList("Home", context: context)
            home.tabTitle = "Home"
            home.tabImage = symbol("house.fill")
            let new = makeList("New", context: context)
            new.tabTitle = "New"
            new.tabImage = symbol("sparkles")
            let library = makeList("Library", context: context)
            library.tabTitle = "Library"
            library.tabImage = symbol("music.note.house.fill")
            let search = makeList("Search", context: context, includesPins: false)
            search.tabSystemItem = .search
            rootSearchTemplate = search
            configureSearchOptions(search, context: context)
            lastContentTab = library
            let templates = Array(
                [home, new, library, search].prefix(CPTabBarTemplate.maximumTabCount))
            let tabs = CPTabBarTemplate(templates: templates)
            tabs.delegate = self
            if templates.contains(where: { $0 === library }) { tabs.select(library) }
            self.setBodySections([CPListSection(items: [libraryControls(context)])], for: library)
            setRoot(tabs)
            rootTask = Task { [weak self, weak home, weak new, weak library] in
                do {
                    let snapshot = try await FoundationCarPlayCatalog.snapshot(
                        library: context.library, downloads: context.downloads,
                        localOnly: context.localOnly)
                    guard let self, !Task.isCancelled, self.isCurrent(context) else { return }
                    context.actions.observeTrackCopies(
                        snapshot.recentlyPlayed + snapshot.favorites + snapshot.recentMusic
                            + snapshot.mostPlayedAlbums)
                    self.rootShelfProjection = { [weak self, weak home, weak new, weak library] in
                        guard let self, let home, let new, let library, self.isCurrent(context)
                        else { return }
                        for template in [home, new, library] {
                            self.rowArtwork[ObjectIdentifier(template)] = []
                        }
                        self.setBodySections(
                            [
                                self.shelfSection(
                                    snapshot.recentlyPlayed, heading: "Recently Played", in: home,
                                    failure: snapshot.errors[.recentlyPlayed], context: context),
                                self.shelfSection(
                                    snapshot.favorites, heading: "Favorites", in: home,
                                    failure: snapshot.errors[.favorites], context: context),
                            ], for: home)
                        self.installShelf(
                            snapshot.recentMusic, heading: "Recently Added", in: new,
                            failure: snapshot.errors[.recentMusic], context: context)
                        let shelf = self.shelf(
                            snapshot.mostPlayedAlbums, heading: "Most Played Albums",
                            template: library, context: context)
                        self.setBodySections(
                            self.boundedSections([
                                CPListSection(items: [self.libraryControls(context)]),
                                CPListSection(
                                    items: shelf.isEmpty
                                        ? [
                                            self.information(
                                                snapshot.errors[.mostPlayedAlbums]?.errorDescription
                                                    ?? "No listening history is available.")
                                        ]
                                        : shelf),
                            ]), for: library)
                    }
                    self.rootShelfProjection?()
                    if let visible = self.visibleList {
                        self.startArtwork(visible, context: context)
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.isCurrent(context) else { return }
                    for template in [home, new].compactMap({ $0 }) {
                        template.emptyViewTitleVariants = ["Library Unavailable"]
                        template.emptyViewSubtitleVariants = [
                            FoundationLibraryError.category(error).errorDescription
                                ?? "Try again later."
                        ]
                        self.applySections(template)
                    }
                }
            }
        }

        private func makeList(
            _ title: String, context: Context, includesPins: Bool = true
        ) -> CPListTemplate {
            let template = CPListTemplate(title: title, sections: [])
            let id = ObjectIdentifier(template)
            lists[id] = template
            bodySections[id] = []
            if includesPins { pinEligibleLists.insert(id) }
            template.emptyViewTitleVariants = ["Loading"]
            template.emptyViewSubtitleVariants = ["Your music is loading."]
            template.trailingNavigationBarButtons = [searchBarButton(context)]
            if includesPins { installPins(template, context: context) }
            return template
        }

        private func installPins(_ template: CPListTemplate, context: Context) {
            let id = ObjectIdentifier(template)
            artworkTasks[id]?.cancel()
            artworkTasks[id] = nil
            pinArtwork[id] = []
            guard pinEligibleLists.contains(id) else { return }
            let pins = Array(context.actions.pins.prefix(max(0, CPMaximumNumberOfGridImages)))
            let elements = pins.map { item in
                let element = CPListImageRowItemImageGridElement(
                    image: placeholder(
                        item, size: CPListImageRowItemImageGridElement.maximumImageSize),
                    imageShape: .roundedRectangle, title: item.title, accessorySymbolName: nil)
                pinArtwork[id, default: []].append(
                    ArtworkRequest(
                        item: item, size: CPListImageRowItemImageGridElement.maximumImageSize,
                        apply: { [weak element] image in element?.image = image }))
                return element
            }
            if pins.isEmpty {
                pinnedSections[id] = []
            } else {
                let row = CPListImageRowItem(
                    text: "Pinned", imageGridElements: elements, allowsMultipleLines: true)
                row.handler = { [weak self, weak template] _, completion in
                    defer { completion() }
                    guard let self, let template, self.isCurrent(context), self.isRetained(template)
                    else { return }
                    self.openSnapshot(context.actions.pins, title: "Pinned", context: context)
                }
                row.listImageRowHandler = { [weak self, weak template] _, index, completion in
                    defer { completion() }
                    guard let self, let template, self.isCurrent(context),
                        self.isRetained(template),
                        pins.indices.contains(index)
                    else { return }
                    self.openPinned(pins[index], context: context)
                }
                pinnedSections[id] = [CPListSection(items: [row])]
            }
            template.headerGridButtons = []
            applySections(template)
        }

        private func libraryControls(_ context: Context) -> CPListImageRowItem {
            let routes: [(String, String, Route?)] = [
                ("Playlists", "music.note.list", .playlists),
                ("Favorites", "heart.fill", .favorites),
                ("Downloads", "arrow.down.circle.fill", .downloads),
                ("Your Media", "square.stack.fill", nil),
            ]
            let elements = routes.map {
                CPListImageRowItemCondensedElement(
                    image: Self.libraryCategorySymbol(
                        $0.1, traits: interfaceController?.carTraitCollection ?? .current),
                    imageShape: .roundedRectangle, title: $0.0,
                    subtitle: nil, accessorySymbolName: nil)
            }
            let row = CPListImageRowItem(
                text: nil, condensedElements: elements, allowsMultipleLines: true)
            row.listImageRowHandler = { [weak self] _, index, completion in
                defer { completion() }
                guard let self, self.isCurrent(context), routes.indices.contains(index) else {
                    return
                }
                if let route = routes[index].2 {
                    self.openRoute(route, title: routes[index].0, context: context)
                } else {
                    self.openIndex(title: "Your Media", context: context)
                }
            }
            return row
        }

        private func openIndex(title: String, context: Context) {
            let template = makeList(title, context: context)
            renderIndex(offset: 0, in: template, context: context)
            push(template, context: context)
        }

        private func renderIndex(offset: Int, in template: CPListTemplate, context: Context) {
            let projection = UUID()
            projectionIDs[ObjectIdentifier(template)] = projection
            cachedProjections[ObjectIdentifier(template)] = { [weak self, weak template] in
                guard let self, let template, self.isCurrent(context), self.isRetained(template)
                else { return }
                self.renderIndex(offset: offset, in: template, context: context)
            }
            let routes: [(String, String, Route)] = [
                ("Albums", "square.stack.fill", .albums), ("Artists", "person.fill", .artists),
                ("Songs", "music.note", .songs), ("Genres", "guitars.fill", .genres),
                ("Playlists", "music.note.list", .playlists),
            ]
            let maximum = bodyCapacity(template)
            let remaining = max(0, routes.count - offset)
            let more = remaining > maximum
            let count = min(remaining, max(0, maximum - (more && maximum > 1 ? 1 : 0)))
            var rows = routes.dropFirst(offset).prefix(count).map { name, image, route in
                let row = CPListItem(text: name, detailText: nil, image: navigationSymbol(image))
                row.handler = { [weak self, weak template] _, completion in
                    defer { completion() }
                    guard let self, let template, self.isCurrent(context),
                        self.isRetained(template),
                        self.projectionIDs[ObjectIdentifier(template)] == projection
                    else { return }
                    self.openRoute(route, title: name, context: context)
                }
                return row
            }
            let next = offset + count
            var continuation: (() -> Void)?
            if more, next > offset {
                continuation = { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context), self.isRetained(template)
                    else { return }
                    guard self.projectionIDs[ObjectIdentifier(template)] == projection else {
                        return
                    }
                    self.renderIndex(offset: next, in: template, context: context)
                }
                if maximum > 1 {
                    let row = CPListItem(text: "More", detailText: "More media categories")
                    row.handler = { _, completion in
                        defer { completion() }
                        continuation?()
                    }
                    rows.append(row)
                }
            }
            setMoreNavigation(maximum == 1 ? continuation : nil, in: template, context: context)
            self.setBodySections([CPListSection(items: rows)], for: template)
        }

        private func searchBarButton(_ context: Context) -> CPBarButton {
            CPBarButton(image: symbol("magnifyingglass")) { [weak self] _ in
                guard let self, self.isCurrent(context) else { return }
                self.openSearch(context)
            }
        }

        private func setMoreNavigation(
            _ continuation: (() -> Void)?, in template: CPListTemplate, context: Context
        ) {
            var buttons = [searchBarButton(context)]
            if let continuation {
                let projection = projectionIDs[ObjectIdentifier(template)]
                buttons.append(
                    CPBarButton(title: "More") { [weak self, weak template] _ in
                        guard let self, let template, self.isCurrent(context),
                            self.isRetained(template),
                            self.projectionIDs[ObjectIdentifier(template)] == projection
                        else { return }
                        continuation()
                    })
            }
            template.trailingNavigationBarButtons = buttons
        }

        /// Native controls remain usable without a provider lookup, including at zero list capacity.
        static func configureSearchOptions(
            _ template: CPListTemplate, keyboardLimited: Bool, siriAuthorized: Bool,
            typeSearch: @escaping () -> Void, close: @escaping () -> Void
        ) {
            template.assistantCellConfiguration =
                siriAuthorized
                ? CPAssistantCellConfiguration(
                    position: .top, visibility: .always, assistantAction: .playMedia)
                : nil
            let closeButton: CPBarButton
            if let image = UIImage(systemName: "chevron.backward") {
                closeButton = CPBarButton(image: image) { _ in close() }
            } else {
                closeButton = CPBarButton(title: "Back") { _ in close() }
            }
            closeButton.accessibilityLabel = "Back"
            template.leadingNavigationBarButtons = []
            template.backButton = closeButton
            template.trailingNavigationBarButtons = []
            let row = CPListItem(
                text: "Type to Search", detailText: "Find music in your library",
                image: UIImage(systemName: "keyboard"))
            row.handler = { _, completion in
                defer { completion() }
                typeSearch()
            }
            var rows = keyboardLimited ? [] : [row]
            if !siriAuthorized {
                let guidance = CPListItem(
                    text: "Enable Siri on iPhone", detailText: "Open VelaCanto Profile & Settings.")
                guidance.isEnabled = false
                rows.append(guidance)
            }
            template.updateSections(
                CPListTemplate.maximumItemCount == 0 || CPListTemplate.maximumSectionCount == 0
                    ? []
                    : [CPListSection(items: Array(rows.prefix(CPListTemplate.maximumItemCount)))])
            template.emptyViewTitleVariants = [
                keyboardLimited ? "Use Siri to Find Music" : "Search Music"
            ]
            template.emptyViewSubtitleVariants = [
                keyboardLimited
                    ? "Typing is unavailable on this display right now."
                    : "Ask Siri to play music, or type a search."
            ]
        }

        /// Identity is essential: returning from search never rebuilds or resets a browse route.
        static func searchReturnTarget(
            origin: CPTemplate?, lastContentTab: CPTemplate?,
            stack: [CPTemplate], tabs: [CPTemplate]
        ) -> CPTemplate? {
            if let origin,
                stack.contains(where: { $0 === origin })
                    || tabs.contains(where: { $0 === origin })
            {
                return origin
            }
            if let lastContentTab, tabs.contains(where: { $0 === lastContentTab }) {
                return lastContentTab
            }
            return tabs.first ?? stack.first
        }

        private var keyboardLimited: Bool {
            sessionConfiguration?.limitedUserInterfaces.contains(.keyboard) ?? true
        }

        private func configureSearchOptions(_ template: CPListTemplate, context: Context) {
            Self.configureSearchOptions(
                template, keyboardLimited: keyboardLimited,
                siriAuthorized: FoundationSiriAuthorization.isAuthorized,
                typeSearch: { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.visibleList === template, !self.keyboardLimited
                    else { return }
                    self.searchOptionsTemplate = template
                    if template === self.rootSearchTemplate {
                        self.searchOrigin = self.lastContentTab
                    }
                    self.openKeyboardSearch(context)
                },
                close: { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.visibleList === template
                    else { return }
                    if template === self.rootSearchTemplate {
                        self.searchOrigin = self.lastContentTab
                    }
                    self.closeSearch(context)
                })
        }

        private func openSearch(_ context: Context) {
            guard isCurrent(context), let controller = interfaceController, !isNavigating else {
                return
            }
            if let existing = searchOptionsTemplate, isRetained(existing),
                existing !== rootSearchTemplate
                    || (controller.rootTemplate as? CPTabBarTemplate)?.selectedTemplate === existing
            {
                if visibleList === existing { return }
                returnFromSearch(to: existing, context: context)
                return
            }
            let template = makeList("Search", context: context, includesPins: false)
            configureSearchOptions(template, context: context)
            let origin = controller.topTemplate
            push(template, context: context) { [weak self] success in
                guard let self, success, self.isCurrent(context) else { return }
                self.searchOptionsTemplate = template
                self.searchOrigin = origin
            }
        }

        private func closeSearch(_ context: Context) {
            guard isCurrent(context), let controller = interfaceController else { return }
            let tabs = (controller.rootTemplate as? CPTabBarTemplate)?.templates ?? []
            guard
                let target = Self.searchReturnTarget(
                    origin: searchOrigin, lastContentTab: lastContentTab,
                    stack: controller.templates, tabs: tabs)
            else { return }
            returnFromSearch(to: target, context: context)
        }

        enum SearchReturnStep: Equatable { case done, selectTab, popToRoot, popOne, unavailable }

        /// A tab-bar container is not a legal pop(to:) destination. Use the native
        /// root operation for tabs, and single-level pops for retained browse pages.
        static func searchReturnStep(
            target: CPTemplate, root: CPTemplate, top: CPTemplate?,
            stack: [CPTemplate], tabs: [CPTemplate]
        ) -> SearchReturnStep {
            if tabs.contains(where: { $0 === target }) {
                return top === root || tabs.contains(where: { $0 === top }) || stack.count <= 1
                    ? .selectTab : .popToRoot
            }
            if top === target { return .done }
            guard stack.contains(where: { $0 === target }), stack.count > 1 else {
                return .unavailable
            }
            return .popOne
        }

        private func returnFromSearch(to target: CPTemplate, context: Context) {
            guard isCurrent(context), let controller = interfaceController, !isNavigating else {
                return
            }
            isNavigating = true
            returnFromSearch(
                to: target, context: context, controller: controller,
                remainingPops: controller.templates.count)
        }

        private func returnFromSearch(
            to target: CPTemplate, context: Context, controller: CPInterfaceController,
            remainingPops: Int
        ) {
            guard isCurrent(context), interfaceController === controller else { return }
            let tabs = controller.rootTemplate as? CPTabBarTemplate
            let step = Self.searchReturnStep(
                target: target, root: controller.rootTemplate, top: controller.topTemplate,
                stack: controller.templates, tabs: tabs?.templates ?? [])
            switch step {
            case .done, .selectTab:
                if step == .selectTab { tabs?.select(target) }
                isNavigating = false
                pruneRetiredTemplates()
            case .unavailable:
                isNavigating = false
                showMessage("The previous screen is unavailable.")
            case .popToRoot, .popOne:
                guard remainingPops > 0 else {
                    isNavigating = false
                    return
                }
                let completion: (Bool, Error?) -> Void = { [weak self] success, _ in
                    guard let self, self.isCurrent(context),
                        self.interfaceController === controller
                    else { return }
                    guard success else {
                        self.isNavigating = false
                        self.showMessage("The previous screen is unavailable.")
                        return
                    }
                    self.returnFromSearch(
                        to: target, context: context, controller: controller,
                        remainingPops: remainingPops - 1)
                }
                if step == .popToRoot {
                    controller.popToRootTemplate(animated: true, completion: completion)
                } else {
                    controller.popTemplate(animated: true, completion: completion)
                }
            }
        }

        private func openKeyboardSearch(_ context: Context) {
            guard isCurrent(context), !keyboardLimited else { return }
            if let template = searchTemplate, isRetained(template) {
                returnFromSearch(to: template, context: context)
                return
            }
            let template = CPSearchTemplate()
            template.delegate = self
            // Set ownership before the push: CarPlay can ask for initial rows during presentation.
            searchTemplate = template
            searchContext = context
            push(template, context: context) { [weak self] success in
                guard let self, self.isCurrent(context) else {
                    template.delegate = nil
                    return
                }
                if !success, self.searchTemplate === template { self.clearSearchOwnership() }
                if success, self.keyboardLimited, let options = self.searchOptionsTemplate,
                    self.isRetained(options)
                {
                    self.returnFromSearch(to: options, context: context)
                }
            }
        }

        static func searchRows(_ items: [CPListItem], budget: Int) -> [CPListItem] {
            guard budget > 0 else { return [] }
            // CPSearchTemplate owns its native Cancel/X and search-field layout.
            return Array(items.prefix(budget))
        }

        func searchTemplate(
            _ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
            completionHandler: @escaping ([CPListItem]) -> Void
        ) {
            guard self.searchTemplate === searchTemplate, let context = searchContext,
                isCurrent(context), interfaceController?.topTemplate === searchTemplate
            else {
                completionHandler([])
                return
            }
            searchQueryID = UUID()
            let queryID = searchQueryID
            searchSnapshot = nil
            requestedSearchResultsID = nil
            searchResponse?.finish([])
            searchTask?.cancel()
            let searchID = ObjectIdentifier(searchTemplate)
            artworkTasks[searchID]?.cancel()
            artworkTasks[searchID] = nil
            rowArtwork[searchID] = []
            let response = SearchResponse { [weak self] items in
                guard let self, self.searchTemplate === searchTemplate,
                    self.isCurrent(context)
                else {
                    completionHandler([])
                    return
                }
                completionHandler(Self.searchRows(items, budget: self.nativeItemBudget))
            }
            searchResponse = response
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            searchQuery = query
            guard !query.isEmpty else {
                searchSnapshot = .init(items: [], partialFailure: nil)
                response.finish([])
                return
            }
            searchTask = Task { [weak self] in
                defer { response.finish([]) }
                do {
                    let snapshot = try await FoundationCarPlayCatalog.search(
                        query: query, library: context.library, downloads: context.downloads,
                        localOnly: context.localOnly)
                    guard let self, !Task.isCancelled, self.isCurrent(context),
                        self.searchTemplate === searchTemplate,
                        self.searchResponse === response, self.searchQueryID == queryID,
                        self.isRetained(searchTemplate)
                    else { return }
                    context.actions.observeTrackCopies(snapshot.items)
                    self.searchSnapshot = snapshot
                    let limit = self.nativeItemBudget
                    let reserve = snapshot.partialFailure == nil ? 0 : 1
                    var rows = self.projected(snapshot.items, context: context).prefix(
                        max(0, limit - reserve)
                    ).map { item in
                        let row = CPListItem(
                            text: item.title, detailText: item.subtitle,
                            image: self.placeholder(item, size: CPListItem.maximumImageSize))
                        row.userInfo = item
                        self.rowArtwork[searchID, default: []].append(
                            ArtworkRequest(
                                item: item, size: CPListItem.maximumImageSize,
                                apply: { [weak row] image in row?.setImage(image) }))
                        return row
                    }
                    if let failure = snapshot.partialFailure, limit > 0 {
                        let status = CPListItem(
                            text: snapshot.items.isEmpty
                                ? "Search Unavailable" : "Some Results Unavailable",
                            detailText: failure.errorDescription)
                        status.isEnabled = false
                        rows.append(status)
                    }
                    response.finish(rows)
                    self.startArtwork(searchTemplate, context: context)
                    if self.requestedSearchResultsID == queryID {
                        self.showSearchResults(context: context, queryID: queryID)
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.isCurrent(context),
                        self.searchResponse === response, self.searchQueryID == queryID
                    else { return }
                    self.searchSnapshot = .init(
                        items: [], partialFailure: FoundationLibraryError.category(error))
                    let row = CPListItem(
                        text: "Search Unavailable",
                        detailText: FoundationLibraryError.category(error).errorDescription)
                    row.isEnabled = false
                    response.finish(self.nativeItemBudget > 0 ? [row] : [])
                    if self.requestedSearchResultsID == queryID {
                        self.showSearchResults(context: context, queryID: queryID)
                    }
                }
            }
        }

        func searchTemplate(
            _ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
            completionHandler: @escaping () -> Void
        ) {
            defer { completionHandler() }
            guard self.searchTemplate === searchTemplate, let context = searchContext,
                isCurrent(context), interfaceController?.topTemplate === searchTemplate
            else { return }
            guard let media = item.userInfo as? FoundationItem else { return }
            open(media, context: context)
        }

        func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
            guard self.searchTemplate === searchTemplate, let context = searchContext,
                isCurrent(context), interfaceController?.topTemplate === searchTemplate,
                !isNavigating
            else { return }
            requestedSearchResultsID = searchQueryID
            if searchSnapshot == nil, searchTask == nil {
                searchSnapshot = .init(items: [], partialFailure: nil)
            }
            if searchSnapshot != nil {
                showSearchResults(context: context, queryID: searchQueryID)
            }
        }

        /// Use the current query's snapshot; the keyboard action never issues a second lookup.
        private func showSearchResults(context: Context, queryID: UUID) {
            guard isCurrent(context), searchQueryID == queryID,
                requestedSearchResultsID == queryID, let snapshot = searchSnapshot,
                let searchTemplate, interfaceController?.topTemplate === searchTemplate
            else { return }
            requestedSearchResultsID = nil
            let template = makeList("Search Results", context: context)
            template.backButton =
                CPBarButton(image: symbol("chevron.backward")) { [weak self, weak template] _ in
                    guard let self, let template, self.isCurrent(context),
                        self.visibleList === template
                    else { return }
                    self.closeSearch(context)
                }
            template.backButton?.accessibilityLabel = "Back"
            renderSearchResults(
                snapshot, offset: 0, in: template, context: context, queryID: queryID)
            push(template, context: context)
        }

        private func renderSearchResults(
            _ snapshot: FoundationCarPlayCatalog.SearchSnapshot, offset: Int,
            in template: CPListTemplate, context: Context, queryID: UUID
        ) {
            guard isCurrent(context), searchQueryID == queryID else { return }
            let id = ObjectIdentifier(template)
            let projection = UUID()
            projectionIDs[id] = projection
            cachedProjections[id] = { [weak self, weak template] in
                guard let self, let template, self.isCurrent(context), self.isRetained(template),
                    self.searchQueryID == queryID
                else { return }
                self.renderSearchResults(
                    snapshot, offset: offset, in: template,
                    context: context, queryID: queryID)
            }
            artworkTasks[id]?.cancel()
            rowArtwork[id] = []
            let items = Array(snapshot.items.prefix(40))
            let maximum = bodyCapacity(template)
            let statusCount =
                snapshot.partialFailure != nil
                    && (maximum >= 3 || items.isEmpty && maximum > 0) ? 1 : 0
            let available = max(0, maximum - statusCount)
            let remaining = max(0, items.count - offset)
            let needsMore = remaining > available
            let count = min(remaining, max(0, available - (needsMore && available > 1 ? 1 : 0)))
            let shown = projected(Array(items.dropFirst(offset).prefix(count)), context: context)
            var rows = shown.map { mediaRow($0, template: template, context: context) }
            let failureTitle = items.isEmpty ? "Search Unavailable" : "Some Results Unavailable"
            if let failure = snapshot.partialFailure, statusCount > 0 {
                let status = CPListItem(text: failureTitle, detailText: failure.errorDescription)
                status.isEnabled = false
                rows.append(status)
            }
            let next = offset + count
            var continuation: (() -> Void)?
            if needsMore, next > offset {
                continuation = { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.searchQueryID == queryID, self.isRetained(template),
                        self.projectionIDs[ObjectIdentifier(template)] == projection
                    else { return }
                    self.renderSearchResults(
                        snapshot, offset: next, in: template,
                        context: context, queryID: queryID)
                    self.startArtwork(template, context: context)
                }
                if available > 1 {
                    let more = CPListItem(text: "More", detailText: "Next page of search results")
                    more.handler = { _, completion in
                        defer { completion() }
                        continuation?()
                    }
                    rows.append(more)
                }
            }
            setMoreNavigation(available == 1 ? continuation : nil, in: template, context: context)
            self.setBodySections(
                [
                    CPListSection(
                        items: rows,
                        header: snapshot.partialFailure != nil && statusCount == 0
                            ? failureTitle : nil,
                        sectionIndexTitle: nil)
                ], for: template)
            template.emptyViewTitleVariants = [
                snapshot.partialFailure != nil && items.isEmpty
                    ? "Search Unavailable"
                    : searchQuery.isEmpty ? "Enter a Search" : "No Matches"
            ]
            template.emptyViewSubtitleVariants = [
                snapshot.partialFailure?.errorDescription
                    ?? (searchQuery.isEmpty
                        ? "Enter a search term to find music." : "No matching music is available.")
            ]
            applySections(template)
        }

        private func installShelf(
            _ items: [FoundationItem], heading: String, in template: CPListTemplate,
            failure: FoundationLibraryError?, context: Context
        ) {
            let rows = shelf(items, heading: heading, template: template, context: context)
            self.setBodySections([CPListSection(items: rows)], for: template)
            if rows.isEmpty {
                template.emptyViewTitleVariants = [failure == nil ? "No Items" : "Unavailable"]
                template.emptyViewSubtitleVariants = [
                    failure?.errorDescription ?? "There is no music to show here."
                ]
            }
            applySections(template)
        }

        private func shelfSection(
            _ items: [FoundationItem], heading: String, in template: CPListTemplate,
            failure: FoundationLibraryError?, context: Context
        ) -> CPListSection {
            let rows = shelf(items, heading: heading, template: template, context: context)
            if !rows.isEmpty { return CPListSection(items: rows) }
            let message = CPListItem(
                text: heading, detailText: failure?.errorDescription ?? "No music is available.")
            message.isEnabled = false
            return CPListSection(items: [message])
        }

        private func shelf(
            _ items: [FoundationItem], heading: String, template: CPListTemplate, context: Context
        ) -> [CPListImageRowItem] {
            let snapshot = Array(projected(items, context: context).prefix(12))
            let shown = Array(snapshot.prefix(min(4, max(0, CPMaximumNumberOfGridImages))))
            guard !shown.isEmpty else { return [] }
            let elements = shown.map { item in
                let element = CPListImageRowItemImageGridElement(
                    image: placeholder(
                        item, size: CPListImageRowItemImageGridElement.maximumImageSize),
                    imageShape: .roundedRectangle, title: item.title, accessorySymbolName: nil)
                rowArtwork[ObjectIdentifier(template), default: []].append(
                    ArtworkRequest(
                        item: item, size: CPListImageRowItemImageGridElement.maximumImageSize,
                        apply: { [weak element] image in element?.image = image }))
                return element
            }
            let row = CPListImageRowItem(
                text: heading, imageGridElements: elements, allowsMultipleLines: true)
            row.handler = { [weak self, weak template] _, completion in
                defer { completion() }
                guard let self, let template, self.isCurrent(context), self.isRetained(template)
                else { return }
                self.openSnapshot(snapshot, title: heading, context: context)
            }
            row.listImageRowHandler = { [weak self, weak template] _, index, completion in
                defer { completion() }
                guard let self, let template, self.isCurrent(context), self.isRetained(template),
                    shown.indices.contains(index)
                else { return }
                self.open(shown[index], context: context)
            }
            return [row]
        }

        private func openSnapshot(
            _ items: [FoundationItem], title: String, context: Context
        ) {
            guard isCurrent(context) else { return }
            let template = makeList(title, context: context)
            renderSnapshot(items, offset: 0, in: template, context: context)
            push(template, context: context)
        }

        private func renderSnapshot(
            _ items: [FoundationItem], offset: Int, in template: CPListTemplate, context: Context
        ) {
            guard isCurrent(context) else { return }
            let id = ObjectIdentifier(template)
            let projection = UUID()
            projectionIDs[id] = projection
            cachedProjections[id] = { [weak self, weak template] in
                guard let self, let template, self.isCurrent(context), self.isRetained(template)
                else { return }
                self.renderSnapshot(items, offset: offset, in: template, context: context)
            }
            artworkTasks[id]?.cancel()
            rowArtwork[id] = []
            let maximum = bodyCapacity(template)
            let remaining = max(0, items.count - offset)
            let needsMore = remaining > maximum
            let count = min(remaining, max(0, maximum - (needsMore && maximum > 1 ? 1 : 0)))
            let shown = projected(Array(items.dropFirst(offset).prefix(count)), context: context)
            var rows = shown.map { mediaRow($0, template: template, context: context) }
            let next = offset + count
            var continuation: (() -> Void)?
            if needsMore, next > offset {
                continuation = { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.isRetained(template),
                        self.projectionIDs[ObjectIdentifier(template)] == projection
                    else { return }
                    self.renderSnapshot(items, offset: next, in: template, context: context)
                    self.startArtwork(template, context: context)
                }
                if maximum > 1 {
                    let more = CPListItem(text: "More", detailText: "Next page of music")
                    more.handler = { _, completion in
                        defer { completion() }
                        continuation?()
                    }
                    rows.append(more)
                }
            }
            setMoreNavigation(maximum == 1 ? continuation : nil, in: template, context: context)
            template.emptyViewTitleVariants = ["No Items"]
            template.emptyViewSubtitleVariants = ["There is no music to show here."]
            setBodySections([CPListSection(items: rows)], for: template)
        }

        private func open(_ item: FoundationItem, context: Context) {
            guard isCurrent(context) else { return }
            switch item.kind {
            case .track: playTrack(item, context: context)
            case .genre: openRoute(.genre(item), title: item.title, context: context)
            case .artist: openRoute(.artistAlbums(item), title: item.title, context: context)
            case .album, .playlist:
                openRoute(.collection(item), title: item.title, context: context)
            }
        }

        private func openPinned(_ item: FoundationItem, context: Context) {
            guard isCurrent(context), let controller = interfaceController else { return }
            if item.kind == .track || controller.templates.count <= 1 {
                open(item, context: context)
                return
            }
            guard !isNavigating else { return }
            isNavigating = true
            controller.popToRootTemplate(animated: false) { [weak self] success, _ in
                guard let self, self.isCurrent(context) else { return }
                self.isNavigating = false
                if success {
                    self.pruneRetiredTemplates()
                    self.open(item, context: context)
                } else {
                    self.showMessage("The pinned collection is unavailable.")
                }
            }
        }

        private func openRoute(_ route: Route, title: String, context: Context) {
            guard isCurrent(context) else { return }
            let template = makeList(title, context: context)
            template.emptyViewTitleVariants = ["Loading"]
            template.emptyViewSubtitleVariants = ["Your music is loading."]
            let playableCollection: FoundationItem?
            switch route {
            case .collection(let item), .artistAlbums(let item): playableCollection = item
            default: playableCollection = nil
            }
            if let item = playableCollection {
                template.leadingNavigationBarButtons = [
                    CPBarButton(title: context.localOnly ? "Play Downloads" : "Play") {
                        [weak self] _ in
                        self?.playCollection(item, shuffled: false, context: context)
                    },
                    CPBarButton(title: "Shuffle") { [weak self] _ in
                        self?.playCollection(item, shuffled: true, context: context)
                    },
                ]
            }
            push(template, context: context) { [weak self] success in
                guard let self, success, self.isCurrent(context) else { return }
                self.loadPage(route, offset: 0, template: template, context: context)
            }
        }

        private func loadPage(
            _ route: Route, offset: Int, template: CPListTemplate, context: Context
        ) {
            let id = ObjectIdentifier(template)
            cachedProjections[id] = nil
            projectionIDs[id] = nil
            setMoreNavigation(nil, in: template, context: context)
            pageTasks[id]?.cancel()
            artworkTasks[id]?.cancel()
            rowArtwork[id] = []
            pageTasks[id] = Task { [weak self, weak template] in
                do {
                    let page = try await FoundationCarPlayCatalog.page(
                        route: route, startIndex: offset, library: context.library,
                        downloads: context.downloads, localOnly: context.localOnly)
                    guard let self, let template, !Task.isCancelled, self.isCurrent(context),
                        self.isRetained(template)
                    else { return }
                    context.actions.observeTrackCopies(
                        page.items, albumID: self.albumID(for: route))
                    self.renderPage(
                        page, route: route, offset: offset, template: template, context: context)
                } catch {
                    guard let self, let template, !Task.isCancelled, self.isCurrent(context),
                        self.isRetained(template)
                    else { return }
                    let retry = CPListItem(text: "Try Again", detailText: nil)
                    retry.handler = { [weak self, weak template] _, completion in
                        defer { completion() }
                        guard let self, let template, self.isCurrent(context),
                            self.isRetained(template)
                        else { return }
                        self.loadPage(route, offset: offset, template: template, context: context)
                    }
                    self.setBodySections(
                        [
                            CPListSection(
                                items: [retry],
                                header: FoundationLibraryError.category(error).errorDescription,
                                sectionIndexTitle: nil)
                        ], for: template)
                }
            }
        }

        private func renderPage(
            _ page: FoundationPage, route: Route, offset: Int,
            template: CPListTemplate, context: Context
        ) {
            let id = ObjectIdentifier(template)
            let projection = UUID()
            projectionIDs[id] = projection
            cachedProjections[id] = { [weak self, weak template] in
                guard let self, let template, self.isCurrent(context), self.isRetained(template)
                else { return }
                self.renderPage(
                    page, route: route, offset: offset, template: template, context: context)
            }
            artworkTasks[id]?.cancel()
            rowArtwork[id] = []
            let maximum = self.bodyCapacity(template)
            let needsMore = page.nextStartIndex != nil || page.items.count > maximum
            let count = min(page.items.count, max(0, maximum - (needsMore && maximum > 1 ? 1 : 0)))
            let shown = projected(
                Array(page.items.prefix(count)), context: context, albumID: albumID(for: route))
            var rows = shown.map { self.mediaRow($0, template: template, context: context) }
            let next = page.items.count > count ? offset + count : page.nextStartIndex
            var continuation: (() -> Void)?
            if let next, next > offset {
                continuation = { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.isRetained(template),
                        self.projectionIDs[ObjectIdentifier(template)] == projection
                    else { return }
                    self.loadPage(route, offset: next, template: template, context: context)
                }
            }
            if maximum > 1, let continuation {
                let more = CPListItem(text: "More", detailText: "Next page of music")
                more.handler = { _, completion in
                    defer { completion() }
                    continuation()
                }
                rows.append(more)
            }
            setMoreNavigation(maximum == 1 ? continuation : nil, in: template, context: context)
            if route == .favorites {
                let kinds: [FoundationItem.Kind] = [
                    .playlist, .album, .track, .artist, .genre,
                ]
                let names = ["Playlists", "Albums", "Songs", "Artists", "Genres"]
                var sections: [CPListSection] = []
                for (kind, name) in zip(kinds, names) {
                    let entries = shown.enumerated().filter { $0.element.kind == kind }
                        .map { rows[$0.offset] }
                    if !entries.isEmpty {
                        sections.append(
                            CPListSection(
                                items: entries, header: name, sectionIndexTitle: nil))
                    }
                }
                if rows.count > shown.count {
                    sections.append(CPListSection(items: [rows[rows.count - 1]]))
                }
                if sections.count <= CPListTemplate.maximumSectionCount {
                    self.setBodySections(sections, for: template)
                } else {
                    self.setBodySections([CPListSection(items: rows)], for: template)
                }
            } else {
                self.setBodySections([CPListSection(items: rows)], for: template)
            }
            template.emptyViewTitleVariants = ["No Items"]
            template.emptyViewSubtitleVariants = [
                context.localOnly
                    ? "No ready downloaded music is available." : "No music is available."
            ]
            self.applySections(template)
            if !isReprojecting { self.startArtwork(template, context: context) }
        }

        private func albumID(for route: Route) -> String? {
            if case .collection(let item) = route, item.kind == .album { return item.id }
            return nil
        }

        private func projected(
            _ items: [FoundationItem], context: Context, albumID: String? = nil
        ) -> [FoundationItem] {
            context.actions.visibleTracks(
                items, albumID: albumID,
                isAvailable: { !context.localOnly || context.downloads?.isReady($0) == true })
        }

        private func mediaRow(
            _ item: FoundationItem, template: CPListTemplate, context: Context
        ) -> CPListItem {
            let row = CPListItem(
                text: item.title, detailText: item.subtitle,
                image: placeholder(item, size: CPListItem.maximumImageSize))
            rowArtwork[ObjectIdentifier(template), default: []].append(
                ArtworkRequest(
                    item: item, size: CPListItem.maximumImageSize,
                    apply: { [weak row] image in row?.setImage(image) }))
            row.handler = { [weak self, weak template] _, completion in
                defer { completion() }
                guard let self, let template, self.isCurrent(context), self.isRetained(template)
                else { return }
                self.open(item, context: context)
            }
            return row
        }

        private func playTrack(_ item: FoundationItem, context: Context) {
            guard isCurrent(context) else { return }
            guard !context.localOnly || context.downloads?.isReady(item) == true else {
                showMessage("This song is not ready on this device.")
                return
            }
            context.actions.cancelQueueAdditionOwned(by: collectionOwner)
            playTask?.cancel()
            playRequestID = nil
            context.player.setQueue([item], selectedIndex: 0)
            showNowPlaying(context)
        }

        private func playCollection(
            _ item: FoundationItem, shuffled: Bool, context: Context
        ) {
            guard isCurrent(context) else { return }
            guard !context.actions.isQueueLoading || playRequestID != nil else {
                showMessage("A collection is already loading.")
                return
            }
            if context.localOnly {
                let ready = context.actions.collectionTracks(
                    context.downloads?.browseTracks(for: item) ?? [], for: item)
                guard !ready.isEmpty else {
                    showMessage("No ready downloaded songs are available.")
                    return
                }
                guard ready.count <= FoundationLibraryActions.maximumCollectionTracks else {
                    showMessage("This collection is too large. Choose a smaller collection.")
                    return
                }
                context.player.setQueue(shuffled ? ready.shuffled() : ready, selectedIndex: 0)
                showNowPlaying(context)
                return
            }
            context.actions.cancelQueueAdditionOwned(by: collectionOwner)
            let previous = context.actions.queueTask
            playTask?.cancel()
            let request = UUID()
            playRequestID = request
            let revision = playbackRevision
            playTask = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.isCurrent(context),
                    self.playRequestID == request
                else { return }
                defer {
                    if self.playRequestID == request {
                        self.playRequestID = nil
                        self.playTask = nil
                    }
                }
                guard self.playbackRevision == revision, !context.actions.isQueueLoading else {
                    self.showMessage(
                        "Playback changed while music was loading. Select again to play.")
                    return
                }
                context.actions.play(
                    item, shuffled: shuffled, library: context.library,
                    player: context.player, owner: self.collectionOwner)
                await context.actions.queueTask?.value
                guard !Task.isCancelled, self.isCurrent(context), self.playRequestID == request
                else { return }
                if let message = context.actions.queueErrorMessage ?? context.actions.queueNotice {
                    self.showMessage(message)
                } else {
                    self.showNowPlaying(context)
                }
            }
        }

        private func configureNowPlaying(_ context: Context) {
            let template = CPNowPlayingTemplate.shared
            template.allowsMiniPlayer = true
            template.isUpNextButtonEnabled = false
            template.isAlbumArtistButtonEnabled = false
            let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
                guard let self, self.isCurrent(context) else { return }
                context.player.setShuffle(!context.player.shuffleEnabled)
            }
            let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
                guard let self, self.isCurrent(context) else { return }
                let modes = FoundationPlayer.RepeatMode.allCases
                let index = modes.firstIndex(of: context.player.repeatMode) ?? 0
                context.player.setRepeat(modes[(index + 1) % modes.count])
            }
            shuffle.isEnabled = !context.player.queue.isEmpty
            repeatButton.isEnabled = !context.player.queue.isEmpty
            let queue = CPNowPlayingImageButton(image: symbol("list.bullet")) { [weak self] _ in
                self?.routeToQueue(context)
            }
            queue.accessibilityLabel = "View queue"
            queue.isEnabled = !context.player.queue.isEmpty
            let search = CPNowPlayingImageButton(image: symbol("magnifyingglass")) {
                [weak self] _ in
                guard let self, self.isCurrent(context) else { return }
                self.openSearch(context)
            }
            search.accessibilityLabel = "Search music"
            template.updateNowPlayingButtons([shuffle, repeatButton, queue, search])
        }

        private func showNowPlaying(_ context: Context) {
            guard isCurrent(context), let controller = interfaceController else { return }
            if controller.topTemplate === CPNowPlayingTemplate.shared { return }
            if controller.templates.count >= 4 {
                returnToPlaybackRoot(context)
                return
            }
            push(CPNowPlayingTemplate.shared, context: context)
        }

        /// Reserve space for both native Now Playing and its Up Next list at deep browse routes.
        private func returnToPlaybackRoot(
            _ context: Context, completion: @escaping (Bool) -> Void = { _ in }
        ) {
            guard isCurrent(context), let controller = interfaceController, !isNavigating else {
                completion(false)
                return
            }
            isNavigating = true
            controller.popToRootTemplate(animated: false) { [weak self] success, _ in
                guard let self, self.isCurrent(context) else {
                    completion(false)
                    return
                }
                self.isNavigating = false
                guard success else {
                    completion(false)
                    self.showMessage("The playback screen is unavailable.")
                    return
                }
                self.pruneRetiredTemplates()
                self.push(CPNowPlayingTemplate.shared, context: context, completion: completion)
            }
        }

        nonisolated func nowPlayingTemplateUpNextButtonTapped(
            _ nowPlayingTemplate: CPNowPlayingTemplate
        ) {
            Task { @MainActor [weak self] in
                guard let self, let context = self.context, self.isCurrent(context) else { return }
                self.routeToQueue(context)
            }
        }

        private func routeToQueue(_ context: Context) {
            guard isCurrent(context) else { return }
            if (interfaceController?.templates.count ?? 0) >= 5 {
                returnToPlaybackRoot(context) { [weak self] success in
                    if success { self?.openQueue(context) }
                }
                return
            }
            openQueue(context)
        }

        private func openQueue(_ context: Context) {
            guard isCurrent(context) else { return }
            if let template = self.queueTemplate, self.isRetained(template) { return }
            let template = self.makeList("Up Next", context: context, includesPins: false)
            // Playback queue retains the native layout; browsing headers are not added here.
            template.headerGridButtons = []
            self.pinArtwork[ObjectIdentifier(template)] = []
            self.queueTemplate = template
            self.queueOffset = 0
            self.updateQueue(context)
            self.push(template, context: context)
        }

        private func updateQueue(_ context: Context) {
            guard let template = queueTemplate, isCurrent(context) else { return }
            let start =
                context.player.queue.firstIndex {
                    $0.id == context.player.selectedEntryID
                } ?? 0
            let entries = Array(context.player.queue.dropFirst(start))
            if queueOffset >= entries.count { queueOffset = 0 }
            let maximum = nativeItemBudget
            let projection = UUID()
            projectionIDs[ObjectIdentifier(template)] = projection
            let remaining = max(0, entries.count - queueOffset)
            let needsMore = remaining > maximum
            let count = min(remaining, max(0, maximum - (needsMore && maximum > 1 ? 1 : 0)))
            let shown = Array(entries.dropFirst(queueOffset).prefix(count))
            rowArtwork[ObjectIdentifier(template)] = []
            let rows = shown.map { entry in
                let row = CPListItem(text: entry.item.title, detailText: entry.item.subtitle)
                row.isPlaying = entry.id == context.player.selectedEntryID
                row.handler = { [weak self] _, completion in
                    defer { completion() }
                    guard let self, self.isCurrent(context),
                        context.player.queue.contains(where: { $0.id == entry.id })
                    else { return }
                    context.player.select(entry.id)
                }
                return row
            }
            var bounded = rows
            let next = queueOffset + count
            var continuation: (() -> Void)?
            if next < entries.count, next > queueOffset {
                continuation = { [weak self, weak template] in
                    guard let self, let template, self.isCurrent(context),
                        self.isRetained(template),
                        self.projectionIDs[ObjectIdentifier(template)] == projection
                    else { return }
                    self.queueOffset = next
                    self.updateQueue(context)
                }
                if maximum > 1 {
                    let more = CPListItem(text: "More", detailText: "Next page of the queue")
                    more.handler = { _, completion in
                        defer { completion() }
                        continuation?()
                    }
                    bounded.append(more)
                }
            }
            setMoreNavigation(maximum == 1 ? continuation : nil, in: template, context: context)
            self.setBodySections([CPListSection(items: bounded)], for: template)
            template.emptyViewTitleVariants = ["Queue Empty"]
            applySections(template)
        }

        private func push(
            _ template: CPTemplate, context: Context,
            completion: @escaping (Bool) -> Void = { _ in }
        ) {
            guard isCurrent(context), let controller = interfaceController, !isNavigating,
                controller.templates.count < 5
            else {
                discardUnretained(template)
                completion(false)
                if isCurrent(context) { showMessage("Return to the previous screen to continue.") }
                return
            }
            isNavigating = true
            controller.pushTemplate(template, animated: true) { [weak self] success, _ in
                guard let self, self.isCurrent(context), self.interfaceController === controller
                else {
                    completion(false)
                    return
                }
                self.isNavigating = false
                if !success { self.discardUnretained(template) }
                completion(success)
                if !success { self.showMessage("The requested screen is unavailable.") }
            }
        }

        private func showMessage(_ message: String) {
            guard let controller = interfaceController, controller.presentedTemplate == nil else {
                return
            }
            let epoch = generation
            let action = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
                guard let self, self.generation == epoch else { return }
                self.dismissModal()
            }
            controller.presentTemplate(
                CPAlertTemplate(titleVariants: [message], actions: [action]), animated: true,
                completion: { _, _ in })
        }

        private func dismissModal() {
            interfaceController?.dismissTemplate(animated: true, completion: { _, _ in })
        }

        private func information(_ text: String) -> CPListItem {
            let row = CPListItem(text: text, detailText: nil)
            row.isEnabled = false
            return row
        }

        private func boundedSections(_ sections: [CPListSection]) -> [CPListSection] {
            guard sections.count <= CPListTemplate.maximumSectionCount else {
                return [
                    CPListSection(
                        items: Array(
                            sections.flatMap(\.items).prefix(
                                nativeItemBudget)))
                ]
            }
            return sections
        }

        private func bodyCapacity(_ template: CPListTemplate) -> Int {
            // Reserve the native pins row even when currently empty, so adding a pin
            // cannot hide an already-visible page continuation.
            let reserve =
                nativeItemBudget >= 4 && pinEligibleLists.contains(ObjectIdentifier(template))
                ? 1 : 0
            return max(0, nativeItemBudget - reserve)
        }

        private var nativeItemBudget: Int {
            // Owner-selected compact presentation budget; a vehicle may impose a smaller limit.
            max(0, min(12, CPListTemplate.maximumItemCount))
        }

        private func setBodySections(_ sections: [CPListSection], for template: CPListTemplate) {
            bodySections[ObjectIdentifier(template)] = sections
            sectionOffsets[ObjectIdentifier(template)] = 0
            applySections(template)
        }

        /// Every update composes the shared pins with the retained body before enforcing native limits.
        private func applySections(_ template: CPListTemplate) {
            let id = ObjectIdentifier(template)
            let pins = nativeItemBudget >= 4 ? (pinnedSections[id] ?? []) : []
            var body = bodySections[id] ?? []
            if !pins.isEmpty, body.allSatisfy({ $0.items.isEmpty }) {
                let message = CPListItem(
                    text: template.emptyViewTitleVariants.first ?? "No Items",
                    detailText: template.emptyViewSubtitleVariants.first)
                message.isEnabled = false
                body = [CPListSection(items: [message])]
            }
            if cachedProjections[id] == nil, queueTemplate !== template,
                let context, isCurrent(context)
            {
                // Root shelves/status rows are already cached native rows. Repage those rows
                // too when a vehicle changes its list limit; do not refetch their catalogs.
                let capacity = bodyCapacity(template)
                let total = body.reduce(0) { $0 + $1.items.count }
                let offset = min(sectionOffsets[id] ?? 0, max(0, total - 1))
                let remaining = max(0, total - offset)
                let needsMore = remaining > capacity
                let count = min(remaining, max(0, capacity - (needsMore && capacity > 1 ? 1 : 0)))
                var skip = offset
                var take = count
                var paged: [CPListSection] = []
                for section in body {
                    let skipped = min(skip, section.items.count)
                    skip -= skipped
                    let items = Array(section.items.dropFirst(skipped).prefix(take))
                    take -= items.count
                    if !items.isEmpty {
                        paged.append(
                            CPListSection(
                                items: items, header: section.header,
                                sectionIndexTitle: section.sectionIndexTitle))
                    }
                }
                let next = offset + count
                var continuation: (() -> Void)?
                if needsMore, next > offset {
                    continuation = { [weak self, weak template] in
                        guard let self, let template, self.isCurrent(context),
                            self.isRetained(template),
                            (self.sectionOffsets[ObjectIdentifier(template)] ?? 0) == offset
                        else { return }
                        self.sectionOffsets[ObjectIdentifier(template)] = next
                        self.applySections(template)
                        self.startArtwork(template, context: context)
                    }
                    if capacity > 1 {
                        let more = CPListItem(text: "More", detailText: "More browsing options")
                        more.handler = { _, completion in
                            defer { completion() }
                            continuation?()
                        }
                        paged.append(CPListSection(items: [more]))
                    }
                }
                setMoreNavigation(
                    capacity == 1 ? continuation : nil, in: template, context: context)
                body = paged
            }
            var remaining = nativeItemBudget
            var sections: [CPListSection] = []
            for section in pins + body {
                let items = Array(section.items.prefix(remaining))
                guard !items.isEmpty else { continue }
                sections.append(
                    CPListSection(
                        items: items, header: section.header,
                        sectionIndexTitle: section.sectionIndexTitle))
                remaining -= items.count
            }
            if nativeItemBudget == 0 {
                template.emptyViewTitleVariants = ["Browsing Limited"]
                template.emptyViewSubtitleVariants = [
                    "This display currently limits browsing items."
                ]
                template.updateSections([])
            } else if CPListTemplate.maximumSectionCount == 0 {
                template.updateSections([])
            } else {
                template.updateSections(boundedSections(sections))
            }
        }

        private var visibleList: CPListTemplate? {
            if let top = interfaceController?.topTemplate as? CPListTemplate { return top }
            return (interfaceController?.topTemplate as? CPTabBarTemplate)?.selectedTemplate
                as? CPListTemplate
        }

        func sessionConfiguration(
            _ configuration: CPSessionConfiguration,
            limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
        ) {
            guard sessionConfiguration === configuration, let context, isCurrent(context),
                !isReprojecting
            else { return }
            reprojectCaches(context)
            if limitedUserInterfaces.contains(.keyboard), let searchTemplate,
                interfaceController?.topTemplate === searchTemplate, let searchOptionsTemplate,
                isRetained(searchOptionsTemplate)
            {
                // A vehicle restriction is authoritative; never infer motion or start Siri automatically.
                returnFromSearch(to: searchOptionsTemplate, context: context)
            }
        }

        private func reprojectCaches(_ context: Context) {
            guard isCurrent(context), !isReprojecting else { return }
            pruneRetiredTemplates()
            isReprojecting = true
            rootShelfProjection?()
            // Copy first: renderers replace their cached projection as they update native rows.
            let projections = Array(cachedProjections.values)
            for render in projections { render() }
            for template in Array(lists.values) where isRetained(template) {
                applySections(template)
            }
            updateQueue(context)
            if let rootSearchTemplate {
                configureSearchOptions(rootSearchTemplate, context: context)
            }
            if let searchOptionsTemplate, searchOptionsTemplate !== rootSearchTemplate,
                isRetained(searchOptionsTemplate)
            {
                configureSearchOptions(searchOptionsTemplate, context: context)
            }
            isReprojecting = false
            if let visible = visibleList {
                // This notification changes presentation only; never start a provider artwork read.
                startArtwork(visible, context: context, allowsNetwork: false)
            }
        }

        func tabBarTemplate(
            _ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate
        ) {
            guard let context, isCurrent(context),
                interfaceController?.rootTemplate === tabBarTemplate
            else { return }
            if selectedTemplate !== rootSearchTemplate {
                lastContentTab = selectedTemplate
            } else {
                searchOptionsTemplate = rootSearchTemplate
                searchOrigin = lastContentTab
            }
            for (id, task) in artworkTasks where id != ObjectIdentifier(selectedTemplate) {
                task.cancel()
                artworkTasks[id] = nil
            }
            if let list = selectedTemplate as? CPListTemplate {
                startArtwork(list, context: context)
            }
        }

        private func isRetained(_ template: CPTemplate) -> Bool {
            guard let controller = interfaceController else { return false }
            if controller.templates.contains(where: { $0 === template }) { return true }
            return (controller.rootTemplate as? CPTabBarTemplate)?.templates.contains(
                where: { $0 === template }) == true
        }

        private func discardUnretained(_ template: CPTemplate) {
            guard !isRetained(template) else { return }
            let id = ObjectIdentifier(template)
            pageTasks[id]?.cancel()
            pageTasks[id] = nil
            artworkTasks[id]?.cancel()
            artworkTasks[id] = nil
            rowArtwork[id] = nil
            pinArtwork[id] = nil
            bodySections[id] = nil
            pinnedSections[id] = nil
            pinEligibleLists.remove(id)
            cachedProjections[id] = nil
            projectionIDs[id] = nil
            sectionOffsets[id] = nil
            lists[id] = nil
            if queueTemplate === template { queueTemplate = nil }
            if searchOptionsTemplate === template {
                searchOptionsTemplate = nil
                searchOrigin = nil
            }
        }

        private func pruneRetiredTemplates() {
            for template in Array(lists.values) where !isRetained(template) {
                discardUnretained(template)
            }
            if let searchTemplate, !isRetained(searchTemplate) { clearSearchOwnership() }
        }

        private func clearSearchOwnership() {
            if let searchTemplate {
                let id = ObjectIdentifier(searchTemplate)
                artworkTasks[id]?.cancel()
                artworkTasks[id] = nil
                rowArtwork[id] = nil
                searchTemplate.delegate = nil
            }
            searchResponse?.finish([])
            searchResponse = nil
            searchTask?.cancel()
            searchTask = nil
            searchTemplate = nil
            searchContext = nil
            searchSnapshot = nil
            requestedSearchResultsID = nil
            searchQuery = ""
            searchQueryID = UUID()
        }

        func templateDidAppear(_ template: CPTemplate, animated: Bool) {
            guard let context, isCurrent(context) else { return }
            if template === searchTemplate, keyboardLimited, let searchOptionsTemplate,
                isRetained(searchOptionsTemplate)
            {
                returnFromSearch(to: searchOptionsTemplate, context: context)
                return
            }
            if let list = template as? CPListTemplate {
                startArtwork(list, context: context)
            } else if let list = visibleList {
                startArtwork(list, context: context)
            }
        }

        func templateDidDisappear(_ template: CPTemplate, animated: Bool) {
            let id = ObjectIdentifier(template)
            artworkTasks[id]?.cancel()
            artworkTasks[id] = nil
            if searchTemplate === template {
                requestedSearchResultsID = nil
                searchResponse?.finish([])
                searchResponse = nil
                searchTask?.cancel()
                searchTask = nil
            }
            guard !isRetained(template) else { return }
            if searchTemplate === template {
                clearSearchOwnership()
            }
            discardUnretained(template)
        }

        private func startArtwork(
            _ template: CPTemplate, context: Context, allowsNetwork: Bool = true
        ) {
            let allowRemote = allowsNetwork && !isReprojecting
            let id = ObjectIdentifier(template)
            for (other, task) in artworkTasks where other != id {
                task.cancel()
                artworkTasks[other] = nil
            }
            artworkTasks[id]?.cancel()
            let requests = Array(
                ((pinArtwork[id] ?? []) + (rowArtwork[id] ?? [])).prefix(
                    max(0, CPMaximumNumberOfGridImages) + 40))
            artworkTasks[id] = Task { [weak self] in
                for request in requests {
                    guard let self, !Task.isCancelled, self.isCurrent(context),
                        self.isRetained(template)
                    else { return }
                    let scale = max(
                        1, self.interfaceController?.carTraitCollection.displayScale ?? 2)
                    let pixels = min(
                        640, max(1, Int(max(request.size.width, request.size.height) * scale)))
                    let retained = await context.downloads?.retainedArtwork(for: request.item)
                    guard !Task.isCancelled, self.isCurrent(context), self.isRetained(template)
                    else { return }
                    let result: FoundationCurrentArtwork.Result?
                    if let retained {
                        result = await Task.detached(priority: .utility) {
                            FoundationCurrentArtwork.decode(retained, maximumPixels: pixels)
                        }.value
                    } else {
                        result = try? await context.library.artworkResult(
                            for: request.item, size: pixels,
                            allowsNetwork: !context.localOnly && allowRemote)
                    }
                    guard !Task.isCancelled, self.isCurrent(context), self.isRetained(template),
                        let result
                    else { continue }
                    let source = UIImage(cgImage: result.image, scale: scale, orientation: .up)
                    request.apply(self.clipped(source, size: request.size, scale: scale))
                }
            }
        }

        private func symbol(_ name: String) -> UIImage {
            UIImage(systemName: name) ?? UIImage()
        }

        /// Condensed Library tiles resize artwork to the element's expected canvas.
        /// Render the symbol at that size rather than stretching its intrinsic raster.
        static func libraryCategorySymbol(_ name: String, traits: UITraitCollection) -> UIImage {
            let size = CPListImageRowItemCondensedElement.maximumImageSize
            let configuration = UIImage.SymbolConfiguration(
                pointSize: min(size.width, size.height) * 0.6, weight: .regular)
            let source = UIImage(systemName: name, withConfiguration: configuration) ?? UIImage()
            return insetNavigationImage(source, size: size, traits: traits)
        }

        static func insetNavigationImage(
            _ source: UIImage, size: CGSize, traits: UITraitCollection
        ) -> UIImage {
            guard size.width > 0, size.height > 0,
                source.size.width > 0, source.size.height > 0
            else { return source }
            let scale = max(1, traits.displayScale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let available = CGRect(origin: .zero, size: size).insetBy(
                dx: size.width * 0.2, dy: size.height * 0.2)
            let factor = min(
                available.width / source.size.width, available.height / source.size.height)
            let fitted = CGSize(
                width: source.size.width * factor, height: source.size.height * factor)
            let rect = CGRect(
                x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                width: fitted.width, height: fitted.height)
            let asset = UIImageAsset()
            for style in [UIUserInterfaceStyle.light, .dark] {
                let variantTraits = UITraitCollection { value in
                    value.userInterfaceStyle = style
                    value.displayScale = scale
                }
                let foreground = UIColor.label.resolvedColor(with: variantTraits)
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    source.withTintColor(foreground, renderingMode: .alwaysOriginal).draw(in: rect)
                }
                asset.register(image, with: variantTraits)
            }
            return asset.image(with: traits)
        }

        /// List/grid images are rendered as original artwork by CarPlay, so register
        /// semantic foreground variants instead of relying on system-template tinting.
        private func navigationSymbol(_ name: String) -> UIImage {
            let source = symbol(name)
            guard source.size.width > 0, source.size.height > 0 else { return source }
            let scale = max(1, interfaceController?.carTraitCollection.displayScale ?? 2)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let asset = UIImageAsset()
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection { traits in
                    traits.userInterfaceStyle = style
                    traits.displayScale = scale
                }
                let foreground = UIColor.label.resolvedColor(with: traits)
                let variant = UIGraphicsImageRenderer(size: source.size, format: format).image {
                    _ in
                    source.withTintColor(foreground, renderingMode: .alwaysOriginal)
                        .draw(in: CGRect(origin: .zero, size: source.size))
                }
                asset.register(variant, with: traits)
            }
            return asset.image(with: interfaceController?.carTraitCollection ?? .current)
        }

        private func placeholder(_ item: FoundationItem, size: CGSize) -> UIImage {
            let image = symbol(item.kind == .artist ? "person.fill" : "music.note")
            let scale = max(1, interfaceController?.carTraitCollection.displayScale ?? 2)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let asset = UIImageAsset()
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection { traits in
                    traits.userInterfaceStyle = style
                    traits.displayScale = scale
                }
                traits.performAsCurrent {
                    let variant = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                        UIColor.secondarySystemBackground.setFill()
                        UIRectFill(CGRect(origin: .zero, size: size))
                        image.withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal).draw(
                            in: CGRect(
                                x: size.width * 0.25, y: size.height * 0.25,
                                width: size.width * 0.5, height: size.height * 0.5))
                    }
                    asset.register(variant, with: traits)
                }
            }
            return asset.image(with: interfaceController?.carTraitCollection ?? .current)
        }

        private func clipped(_ image: UIImage, size: CGSize, scale: CGFloat) -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                guard image.size.width > 0, image.size.height > 0 else { return }
                let factor = max(size.width / image.size.width, size.height / image.size.height)
                let width = image.size.width * factor
                let height = image.size.height * factor
                image.draw(
                    in: CGRect(
                        x: (size.width - width) / 2, y: (size.height - height) / 2,
                        width: width, height: height))
            }
        }
    }
#endif
