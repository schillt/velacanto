// iOS presentation ownership only. Reuses existing player/artwork/account owners.
import Foundation

// Cross-platform policy: no UIKit/controller/model ownership, directly testable.
enum FoundationPlayerArtworkTransitionDecision: Equatable {
    enum Fallback: Equatable {
        case reduceMotion, missingArtwork, differentIdentity, unavailableGeometry, offscreenSource
    }
    case morph(compact: CGRect, expanded: CGRect)
    case fade(Fallback)

    static func resolve(
        artworkIdentity: String?, compactIdentity: String?, expandedIdentity: String?,
        compactRect: CGRect?, expandedRect: CGRect?, containerBounds: CGRect,
        reduceMotion: Bool
    ) -> Self {
        if reduceMotion { return .fade(.reduceMotion) }
        guard let artworkIdentity, !artworkIdentity.isEmpty else { return .fade(.missingArtwork) }
        guard artworkIdentity == compactIdentity, artworkIdentity == expandedIdentity else {
            return .fade(.differentIdentity)
        }
        guard let compactRect, let expandedRect, usable(compactRect), usable(expandedRect),
            usable(containerBounds), containerBounds.intersects(expandedRect)
        else { return .fade(.unavailableGeometry) }
        guard containerBounds.contains(compactRect) else { return .fade(.offscreenSource) }
        return .morph(compact: compactRect, expanded: expandedRect)
    }

    private static func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.width > 0 && rect.height > 0
            && [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }
}

// The glass surface uses measured bar geometry; artwork resolution is independent.
enum FoundationPlayerSurfaceTransitionDecision: Equatable {
    case expand(compact: CGRect, expanded: CGRect)
    case fade

    static func resolve(compact: CGRect?, expanded: CGRect, reduceMotion: Bool) -> Self {
        guard !reduceMotion, let compact,
            [
                compact.minX, compact.minY, compact.width, compact.height,
                expanded.minX, expanded.minY, expanded.width, expanded.height,
            ].allSatisfy(\.isFinite),
            compact.width > 0, compact.height > 0, expanded.width > 0, expanded.height > 0,
            expanded.contains(compact)
        else { return .fade }
        return .expand(compact: compact, expanded: expanded)
    }
}

#if os(iOS)
    import Combine
    import SwiftUI
    import UIKit

    private struct FoundationPlayerArtworkPresentationKey: EnvironmentKey {
        static let defaultValue: FoundationPlayerArtworkPresentationModel? = nil
    }
    private struct FoundationClosePlayerKey: EnvironmentKey {
        static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
    }
    extension EnvironmentValues {
        var foundationPlayerArtworkPresentation: FoundationPlayerArtworkPresentationModel? {
            get { self[FoundationPlayerArtworkPresentationKey.self] }
            set { self[FoundationPlayerArtworkPresentationKey.self] = newValue }
        }
        // Read ONLY in main PlayerView. Related sheets keep their own native dismiss.
        var foundationClosePlayer: (@MainActor @Sendable () -> Void)? {
            get { self[FoundationClosePlayerKey.self] }
            set { self[FoundationClosePlayerKey.self] = newValue }
        }
    }

    @MainActor
    final class FoundationPlayerArtworkPresentationModel: ObservableObject {
        enum Role { case compact, expanded }

        struct Artwork {
            let identity: String
            let imageID: UUID
            let image: CGImage
            // A decode revision is intentionally not a transition identity.
            init(identity: String, result: FoundationCurrentArtwork.Result) {
                self.identity = identity
                imageID = result.id
                image = result.image
            }
        }

        private struct Anchor {
            weak var view: UIView?
            let token: UUID
            let identity: String
            let cornerRadius: CGFloat
        }

        @Published private(set) var hiddenArtworkIdentity: String?
        #if DEBUG && targetEnvironment(simulator)
            @Published private(set) var transitionSummary =
                "morph 0; fade 0; cancelled 0; completed 0; glass 0; intermediate 0"
            private var glassCount = 0
            private var intermediateCount = 0
            private var morphCount = 0
            private var fadeCount = 0
            private var cancelledCount = 0
            private var completedCount = 0

            private func publishTransitionSummary() {
                transitionSummary =
                    "morph \(morphCount); fade \(fadeCount); cancelled \(cancelledCount); completed \(completedCount); glass \(glassCount); intermediate \(intermediateCount)"
            }

            fileprivate func recordIntermediateSurface(
                _ frame: CGRect, compact: CGRect, expanded: CGRect
            ) {
                guard frame.height > compact.height + 1, frame.height < expanded.height - 1,
                    frame.width >= compact.width, frame.width <= expanded.width + 1
                else { return }
                intermediateCount += 1
                publishTransitionSummary()
            }

            fileprivate func recordCompletion(cancelled: Bool) {
                if cancelled { cancelledCount &+= 1 } else { completedCount &+= 1 }
                publishTransitionSummary()
            }
        #endif
        @Published fileprivate(set) var isPlayerPresented = false
        @Published fileprivate(set) var isSurfaceTransitioning = false
        var artwork: () -> Artwork? = { nil }
        var reduceMotion = false
        var reduceTransparency = false
        private weak var compactSurface: UIView?
        private var surfaceToken: UUID?
        private var surfaceIdentity: String?
        var allowsInteractiveDismissal = true
        var interactiveDismissalHeaderOnly = false
        private var compact: Anchor?
        private var expanded: Anchor?
        private var generation: UInt = 0
        private var activeAnimator: FoundationPlayerArtworkAnimator?
        fileprivate weak var host: FoundationPlayerArtworkHost?

        func hidesArtwork(identity: String?) -> Bool {
            identity != nil && hiddenArtworkIdentity == identity
        }

        fileprivate func register(
            _ view: UIView, token: UUID, role: Role, identity: String, cornerRadius: CGFloat
        ) {
            let anchor = Anchor(
                view: view, token: token, identity: identity, cornerRadius: cornerRadius)
            switch role {
            case .compact: compact = anchor
            case .expanded: expanded = anchor
            }
        }

        fileprivate func unregister(token: UUID, role: Role) {
            switch role {
            case .compact: if compact?.token == token { compact = nil }
            case .expanded: if expanded?.token == token { expanded = nil }
            }
        }

        fileprivate func registerSurface(_ view: UIView, token: UUID, identity: String) {
            compactSurface = view
            surfaceToken = token
            surfaceIdentity = identity
        }

        fileprivate func unregisterSurface(token: UUID) {
            guard surfaceToken == token else { return }
            compactSurface = nil
            surfaceToken = nil
            surfaceIdentity = nil
        }

        fileprivate func surfaceRect(in container: UIView) -> CGRect? {
            guard let source = compactSurface, let window = container.window,
                source.window === window
            else { return nil }
            let rect = source.convert(source.bounds, to: container)
            guard
                case .expand = FoundationPlayerSurfaceTransitionDecision.resolve(
                    compact: rect, expanded: container.bounds, reduceMotion: reduceMotion)
            else { return nil }
            return rect
        }

        fileprivate struct Endpoints {
            let artwork: Artwork
            let compactRect: CGRect
            let expandedRect: CGRect
            let compactRadius: CGFloat
            let expandedRadius: CGFloat
        }

        fileprivate func endpoints(in container: UIView) -> Endpoints? {
            guard !reduceMotion, let artwork = artwork(),
                let compact, let expanded,
                compact.identity == artwork.identity, expanded.identity == artwork.identity,
                let source = compact.view, let destination = expanded.view,
                let window = container.window,
                source.window === window, destination.window === window
            else { return nil }
            let sourceRect = source.convert(source.bounds, to: container)
            let destinationRect = destination.convert(destination.bounds, to: container)
            guard
                case .morph = FoundationPlayerArtworkTransitionDecision.resolve(
                    artworkIdentity: artwork.identity, compactIdentity: compact.identity,
                    expandedIdentity: expanded.identity, compactRect: sourceRect,
                    expandedRect: destinationRect, containerBounds: container.bounds,
                    reduceMotion: reduceMotion)
            else { return nil }
            return Endpoints(
                artwork: artwork, compactRect: sourceRect, expandedRect: destinationRect,
                compactRadius: compact.cornerRadius, expandedRadius: expanded.cornerRadius)
        }

        fileprivate func mayBeginPan(at location: CGPoint, in view: UIView) -> Bool {
            guard allowsInteractiveDismissal, let host,
                !host.hasPresentedContent, !host.isBeingPresented, !host.isBeingDismissed
            else { return false }
            // Header dismissal never depends on artwork attachment. Queue playback can
            // replace the hidden artwork anchor while a different album is resolving.
            if location.y <= view.safeAreaInsets.top + 64 { return true }
            guard !interactiveDismissalHeaderOnly else { return false }
            if let artView = expanded?.view, artView.window === view.window {
                return artView.convert(artView.bounds, to: view).contains(location)
            }
            // Playback/artwork replacement must not turn the player into an undismissable
            // surface. Control/scroll hit testing still excludes interactive chrome.
            return location.y < view.bounds.height * 0.65
        }

        fileprivate func beginAnimation(
            _ animator: FoundationPlayerArtworkAnimator,
            identity: String?, glass: Bool
        ) -> UInt {
            generation &+= 1
            activeAnimator = animator
            hiddenArtworkIdentity = identity
            isSurfaceTransitioning = glass
            #if DEBUG && targetEnvironment(simulator)
                if identity != nil { morphCount &+= 1 } else { fadeCount &+= 1 }
                if glass { glassCount &+= 1 }
                publishTransitionSummary()
            #endif
            return generation
        }

        fileprivate func endAnimation(generation: UInt) {
            guard generation == self.generation else { return }
            hiddenArtworkIdentity = nil
            isSurfaceTransitioning = false
            activeAnimator = nil
        }

        fileprivate func retireArtwork(generation: UInt) {
            guard generation == self.generation else { return }
            hiddenArtworkIdentity = nil
        }

        // Invoke on selection/art identity changes. A resolution upgrade with the
        // same canonical identity + result.id keeps the bounded transition image.
        func artworkSelectionChanged() {
            activeAnimator?.retireSnapshotIfIdentityChanged()
        }

        func dismiss() {
            guard let host, !host.hasPresentedContent else { return }
            host.requestProgrammaticDismissal()
        }

        fileprivate func retirePresentation(of host: FoundationPlayerArtworkHost) {
            guard self.host === host else { return }
            generation &+= 1
            activeAnimator?.invalidate()
            activeAnimator = nil
            hiddenArtworkIdentity = nil
            isSurfaceTransitioning = false
            self.host = nil
            isPlayerPresented = false
        }

        func invalidate() {
            generation &+= 1
            activeAnimator?.invalidate()
            activeAnimator = nil
            hiddenArtworkIdentity = nil
            isPlayerPresented = false
            isSurfaceTransitioning = false
            compact = nil
            expanded = nil
            compactSurface = nil
            surfaceToken = nil
            surfaceIdentity = nil
            artwork = { nil }
            host = nil
        }
    }

    // Geometry registration is explicit, not an inspection of private SwiftUI views.
    // This probe is an inert OVERLAY in the existing exact artwork frame.
    struct FoundationPlayerArtworkAnchor: UIViewRepresentable {
        let model: FoundationPlayerArtworkPresentationModel
        let role: FoundationPlayerArtworkPresentationModel.Role
        let identity: String?
        var cornerRadius: CGFloat = 0

        @MainActor final class Coordinator {
            let token = UUID()
            var unregister: (() -> Void)?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            return view
        }

        func updateUIView(_ view: UIView, context: Context) {
            context.coordinator.unregister?()
            guard let identity else {
                context.coordinator.unregister = nil
                return
            }
            #if DEBUG && targetEnvironment(simulator)
                if role == .expanded,
                    ProcessInfo.processInfo.arguments.contains("-fixtureDetachedPlayerArtwork")
                {
                    context.coordinator.unregister = nil
                    return
                }
            #endif
            let token = context.coordinator.token
            model.register(
                view, token: token, role: role, identity: identity,
                cornerRadius: cornerRadius)
            context.coordinator.unregister = { [weak model] in
                model?.unregister(token: token, role: role)
            }
        }

        static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
            coordinator.unregister?()
            coordinator.unregister = nil
        }
    }

    extension View {
        func foundationPlayerArtworkRegistration(
            role: FoundationPlayerArtworkPresentationModel.Role, identity: String?,
            cornerRadius: CGFloat = 0
        ) -> some View {
            modifier(
                FoundationPlayerArtworkRegistration(
                    role: role, identity: identity, cornerRadius: cornerRadius))
        }
    }

    private struct FoundationPlayerArtworkRegistration: ViewModifier {
        let role: FoundationPlayerArtworkPresentationModel.Role
        let identity: String?
        let cornerRadius: CGFloat
        @Environment(\.foundationPlayerArtworkPresentation) private var model

        @ViewBuilder func body(content: Content) -> some View {
            if let model {
                FoundationRegisteredPlayerArtwork(
                    model: model, role: role,
                    identity: identity, cornerRadius: cornerRadius, content: content)
            } else {
                content
            }
        }
    }

    private struct FoundationRegisteredPlayerArtwork<Content: View>: View {
        @ObservedObject var model: FoundationPlayerArtworkPresentationModel
        let role: FoundationPlayerArtworkPresentationModel.Role
        let identity: String?
        let cornerRadius: CGFloat
        let content: Content

        var body: some View {
            content
                .overlay {
                    FoundationPlayerArtworkAnchor(
                        model: model, role: role,
                        identity: identity, cornerRadius: cornerRadius
                    )
                    .allowsHitTesting(false).accessibilityHidden(true)
                }
                // Parent supplies exact final image frame. Probe remains layout-bound
                // even while the live image rendering is hidden for the snapshot.
                .opacity(model.hidesArtwork(identity: identity) ? 0 : 1)
        }
    }

    // Native navigation views can receive taps through a SwiftUI-only accessory.
    // Keep SwiftUI's existing appearance/accessibility, with native controls owning
    // the same three touch regions above the native navigation view.
    struct FoundationMiniPlayerTouchLayer: UIViewRepresentable {
        let showsNext: Bool
        let allowsToggle: Bool
        let allowsNext: Bool
        let onOpen: @MainActor @Sendable () -> Void
        let onToggle: @MainActor @Sendable () -> Void
        let onNext: @MainActor @Sendable () -> Void

        func makeUIView(context: Context) -> TouchView { TouchView() }
        func updateUIView(_ view: TouchView, context: Context) {
            view.onOpen = onOpen
            view.onToggle = onToggle
            view.onNext = onNext
            view.showsNext = showsNext
            view.toggle.isEnabled = allowsToggle
            view.nextButton.isEnabled = allowsNext
            view.semanticContentAttribute =
                context.environment.layoutDirection == .rightToLeft
                ? .forceRightToLeft : .forceLeftToRight
            view.setNeedsLayout()
        }
        static func dismantleUIView(_ view: TouchView, coordinator: ()) {
            view.onOpen = {}
            view.onToggle = {}
            view.onNext = {}
        }

        @MainActor final class TouchView: UIView {
            let open = UIButton(type: .custom)
            let toggle = UIButton(type: .custom)
            let nextButton = UIButton(type: .custom)
            var showsNext = true
            var onOpen: @MainActor @Sendable () -> Void = {}
            var onToggle: @MainActor @Sendable () -> Void = {}
            var onNext: @MainActor @Sendable () -> Void = {}

            init() {
                super.init(frame: .zero)
                backgroundColor = .clear
                accessibilityElementsHidden = true
                for button in [open, toggle, nextButton] { addSubview(button) }
                open.addAction(UIAction { [weak self] _ in self?.onOpen() }, for: .touchUpInside)
                toggle.addAction(
                    UIAction { [weak self] _ in self?.onToggle() }, for: .touchUpInside)
                nextButton.addAction(
                    UIAction { [weak self] _ in self?.onNext() }, for: .touchUpInside)
            }
            required init?(coder: NSCoder) { fatalError("Not implemented") }
            override func layoutSubviews() {
                super.layoutSubviews()
                let y = (bounds.height - 44) / 2
                let toggleX = bounds.width - 54 - (showsNext ? 54 : 0)
                var frames = [
                    CGRect(x: 10, y: 0, width: max(0, toggleX - 20), height: bounds.height),
                    CGRect(x: toggleX, y: y, width: 44, height: 44),
                    CGRect(x: bounds.width - 54, y: y, width: 44, height: 44),
                ]
                if effectiveUserInterfaceLayoutDirection == .rightToLeft {
                    frames = frames.map {
                        CGRect(
                            x: bounds.width - $0.maxX, y: $0.minY, width: $0.width,
                            height: $0.height)
                    }
                }
                for (button, frame) in zip([open, toggle, nextButton], frames) {
                    button.frame = frame
                }
                nextButton.isHidden = !showsNext
            }
        }
    }

    struct FoundationPlayerSurfaceAnchor: UIViewRepresentable {
        let model: FoundationPlayerArtworkPresentationModel
        let identity: String?
        let reduceTransparency: Bool
        @MainActor final class Coordinator {
            let token = UUID()
            weak var model: FoundationPlayerArtworkPresentationModel?
            var reduceTransparency: Bool?
        }
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIView(context: Context) -> UIView {
            // The tab accessory supplies the native glass. This view only measures
            // its current placement; adding another effect doubles the material.
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            return view
        }
        func updateUIView(_ view: UIView, context: Context) {
            context.coordinator.model?.unregisterSurface(token: context.coordinator.token)
            context.coordinator.model = model
            if let identity {
                model.registerSurface(view, token: context.coordinator.token, identity: identity)
            }
        }
        static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
            coordinator.model?.unregisterSurface(token: coordinator.token)
        }
    }

    private struct FoundationPlayerSurfaceRegistration: ViewModifier {
        let identity: String?
        @Environment(\.foundationPlayerArtworkPresentation) private var model
        @Environment(\.foundationReduceTransparency) private var reduceTransparency
        @ViewBuilder func body(content: Content) -> some View {
            if let model {
                FoundationRegisteredPlayerSurface(
                    model: model, identity: identity,
                    reduceTransparency: reduceTransparency, content: content)
            } else {
                content.background(.regularMaterial, in: Capsule())
            }
        }
    }

    private struct FoundationRegisteredPlayerSurface<Content: View>: View {
        @ObservedObject var model: FoundationPlayerArtworkPresentationModel
        let identity: String?
        let reduceTransparency: Bool
        let content: Content
        var body: some View {
            content.background {
                FoundationPlayerSurfaceAnchor(
                    model: model, identity: identity, reduceTransparency: reduceTransparency
                )
                .allowsHitTesting(false).accessibilityHidden(true)
            }
            // Keep compact chrome underneath the transitioning surface so it emerges
            // continuously on collapse. The artwork has its own shared-image handoff.
            .allowsHitTesting(!model.isSurfaceTransitioning)
            .accessibilityHidden(model.isSurfaceTransitioning)
        }
    }

    extension View {
        func foundationPlayerSurfaceRegistration(identity: String?) -> some View {
            modifier(FoundationPlayerSurfaceRegistration(identity: identity))
        }
    }

    // Caller's content MUST already contain explicit environment forwarding.
    // This controller boundary cannot inherit EnvironmentObjects by closure capture.
    struct FoundationPlayerArtworkFullscreen: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        let model: FoundationPlayerArtworkPresentationModel
        let content: AnyView
        let inheritedEnvironment: EnvironmentValues
        let contentContextID: String
        let artwork: () -> FoundationPlayerArtworkPresentationModel.Artwork?
        let reduceMotion: Bool
        let reduceTransparency: Bool

        func makeUIViewController(context: Context) -> FoundationPlayerArtworkPresenter {
            FoundationPlayerArtworkPresenter(model: model)
        }

        func updateUIViewController(
            _ controller: FoundationPlayerArtworkPresenter, context: Context
        ) {
            let binding = $isPresented
            model.artwork = artwork
            model.reduceMotion = reduceMotion
            model.reduceTransparency = reduceTransparency
            controller.requestedPresentation = isPresented
            // Apply inherited custom context and player overrides in ONE value.
            // A nested environment(\.self, oldValue) must not erase the new close action.
            var playerEnvironment = inheritedEnvironment
            playerEnvironment.foundationPlayerArtworkPresentation = model
            playerEnvironment.foundationClosePlayer = { [weak model] in model?.dismiss() }
            controller.updatePlayerContent(
                AnyView(
                    content
                        .environment(\.self, playerEnvironment)
                        .environmentObject(model)), contextID: contentContextID)
            controller.onDismissed = { binding.wrappedValue = false }
            controller.queueReconcile()
        }

        static func dismantleUIViewController(
            _ controller: FoundationPlayerArtworkPresenter,
            coordinator: ()
        ) {
            controller.tearDown()
        }
    }

    @MainActor
    final class FoundationPlayerArtworkPresenter: UIViewController {
        let model: FoundationPlayerArtworkPresentationModel
        var requestedPresentation = false {
            didSet { if oldValue != requestedPresentation { requestGeneration &+= 1 } }
        }
        private var requestGeneration: UInt = 0
        private var dismissalRequestGeneration: UInt?
        private var playerContent = AnyView(EmptyView())
        private var contentContextID: String?
        private var playerHost: FoundationPlayerArtworkHost?
        private var tornDown = false
        private var reconcileScheduled = false
        var onDismissed: () -> Void = {}

        init(model: FoundationPlayerArtworkPresentationModel) {
            self.model = model
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("Not implemented") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            reconcile()
        }

        func updatePlayerContent(_ content: AnyView, contextID: String) {
            playerContent = content
            guard contentContextID != contextID else { return }
            contentContextID = contextID
            // PlayerView observes playback itself. Replacing the hosting root on every
            // playback tick tears through native gestures, menus and artwork registration.
            // Rehost only when inherited presentation context actually changes.
            playerHost?.rootView = content
        }

        func queueReconcile() {
            guard !reconcileScheduled, !tornDown else { return }
            reconcileScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reconcileScheduled = false
                self.reconcile()
            }
        }

        func reconcile() {
            guard !tornDown else { return }
            model.artworkSelectionChanged()
            if let host = playerHost {
                if !requestedPresentation, !host.isBeingDismissed,
                    !host.isBeingPresented, !host.hasPresentedContent
                {
                    host.dismissPlayer(animated: !model.reduceMotion)
                }
                return
            }
            // Fullscreen removes the source view from its window after opening.
            // Only a NEW presentation requires attachment; existing host updates do not.
            guard viewIfLoaded?.window != nil, requestedPresentation,
                presentedViewController == nil, model.host == nil
            else {
                return
            }
            let host = FoundationPlayerArtworkHost(rootView: playerContent, model: model)
            host.requestProgrammaticDismissal = { [weak self] in
                guard let self, !self.tornDown else { return }
                self.requestedPresentation = false
                self.onDismissed()
                self.queueReconcile()
            }
            host.willBeginDismissal = { [weak self] in
                self?.dismissalRequestGeneration = self?.requestGeneration
            }
            host.didCompleteDismissal = { [weak self, weak host] in
                guard let self, self.playerHost === host else { return }
                self.playerHost = nil
                if self.model.host === host {
                    self.model.host = nil
                    self.model.isPlayerPresented = false
                }
                // A later true request during dismissal means reopen; don't erase it.
                if !self.requestedPresentation
                    || self.dismissalRequestGeneration == self.requestGeneration
                {
                    // Consume the interactive dismissal before the queued reconcile.
                    // SwiftUI publishes the binding later; leaving this true can
                    // immediately create a new player over the restored mini bar.
                    self.requestedPresentation = false
                    self.onDismissed()
                }
                self.dismissalRequestGeneration = nil
                self.queueReconcile()
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
            playerHost = host
            model.host = host
            model.isPlayerPresented = true
            present(host, animated: !model.reduceMotion) { [weak self, weak host] in
                guard let self, !self.tornDown, self.playerHost === host else {
                    host?.dismiss(animated: false)
                    return
                }
                // Refresh inherited accessibility context once UIKit attaches the full-screen
                // host. Without this refresh visible controls remain absent from VoiceOver.
                host?.rootView = self.playerContent
                UIAccessibility.post(notification: .screenChanged, argument: nil)
                // Close requests received during presentation must be applied now.
                self.reconcile()
            }
        }

        func tearDown() {
            tornDown = true
            // This model can be shared with Home's cover. Child-presenter teardown
            // must not invalidate another presenter or clear all account anchors.
            playerHost?.didCompleteDismissal = {}
            playerHost?.willBeginDismissal = {}
            playerHost?.requestProgrammaticDismissal = {}
            if let playerHost { model.retirePresentation(of: playerHost) }
            playerHost?.dismiss(animated: false)
            playerHost = nil
            onDismissed = {}
        }
    }

    @MainActor
    final class FoundationPlayerArtworkHost: UIViewController,
        UIViewControllerTransitioningDelegate, UIGestureRecognizerDelegate
    {
        let model: FoundationPlayerArtworkPresentationModel
        private let contentHost: UIHostingController<AnyView>
        var rootView: AnyView {
            get { contentHost.rootView }
            set { contentHost.rootView = newValue }
        }
        var hasPresentedContent: Bool {
            presentedViewController != nil || contentHost.presentedViewController != nil
        }
        override var childForStatusBarStyle: UIViewController? { contentHost }
        override var childForStatusBarHidden: UIViewController? { contentHost }
        var didCompleteDismissal: () -> Void = {}
        var willBeginDismissal: () -> Void = {}
        var requestProgrammaticDismissal: () -> Void = {}
        private var interaction: UIPercentDrivenInteractiveTransition?
        private var animator: FoundationPlayerArtworkAnimator?
        private lazy var pan = UIPanGestureRecognizer(
            target: self, action: #selector(handlePan(_:)))
        private lazy var edgePan: UIScreenEdgePanGestureRecognizer = {
            let gesture = UIScreenEdgePanGestureRecognizer(
                target: self, action: #selector(handlePan(_:)))
            gesture.edges = .left
            return gesture
        }()

        init(rootView: AnyView, model: FoundationPlayerArtworkPresentationModel) {
            self.model = model
            contentHost = UIHostingController(rootView: rootView)
            super.init(nibName: nil, bundle: nil)
            modalPresentationStyle = .fullScreen
            transitioningDelegate = self
        }
        required init?(coder: NSCoder) { fatalError("Not implemented") }

        override func loadView() {
            // UIKit owns the transition mask; the hosting root stays SwiftUI-owned.
            view = UIView()
            view.backgroundColor = .clear
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(contentHost)
            contentHost.view.backgroundColor = .clear
            contentHost.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(contentHost.view)
            NSLayoutConstraint.activate([
                contentHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                contentHost.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                contentHost.view.topAnchor.constraint(equalTo: view.topAnchor),
                contentHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            contentHost.didMove(toParent: self)
            view.accessibilityViewIsModal = true
            pan.delegate = self
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            edgePan.delegate = self
            edgePan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(edgePan)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            interaction = nil
            animator = nil
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Nested sheet presentation must not count as root dismissal.
            if isBeingDismissed || (presentingViewController == nil && !isBeingPresented) {
                interaction = nil
                animator = nil
                didCompleteDismissal()
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === edgePan {
                let velocity = edgePan.velocity(in: view)
                return model.allowsInteractiveDismissal && !hasPresentedContent
                    && !isBeingPresented && !isBeingDismissed
                    && velocity.x > 0 && velocity.x > abs(velocity.y)
            }
            guard gestureRecognizer === pan,
                model.mayBeginPan(at: pan.location(in: view), in: view)
            else { return false }
            let velocity = pan.velocity(in: view)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            if gestureRecognizer === edgePan { return true }
            // The grabber is also a button. Let a downward pan begin on that
            // header while keeping queue rows, sliders and other controls native.
            if touch.location(in: view).y <= view.safeAreaInsets.top + 64 { return true }
            var touched = touch.view
            while let candidate = touched, candidate !== view {
                if candidate is UIControl || candidate is UIScrollView { return false }
                touched = candidate.superview
            }
            return true
        }

        func dismissPlayer(animated: Bool) {
            guard !isBeingDismissed, !hasPresentedContent else { return }
            willBeginDismissal()
            dismiss(animated: animated)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard !hasPresentedContent else {
                interaction?.cancel()
                interaction = nil
                return
            }
            let isEdge = gesture === edgePan
            let distance = max(1, isEdge ? view.bounds.width : view.bounds.height * 0.55)
            let translation = gesture.translation(in: view)
            let progress = min(1, max(0, (isEdge ? translation.x : translation.y) / distance))
            switch gesture.state {
            case .began:
                let interaction = UIPercentDrivenInteractiveTransition()
                interaction.completionCurve = .easeOut
                self.interaction = interaction
                dismissPlayer(animated: true)
            case .changed:
                interaction?.update(progress)
            case .ended:
                let velocity = gesture.velocity(in: view)
                if progress > 0.35 || (isEdge ? velocity.x : velocity.y) > 900 {
                    interaction?.finish()
                } else {
                    interaction?.cancel()
                }
            case .cancelled, .failed:
                interaction?.cancel()
            default: break
            }
        }

        func animationController(
            forPresented presented: UIViewController,
            presenting: UIViewController, source: UIViewController
        )
            -> (any UIViewControllerAnimatedTransitioning)?
        {
            let animator = FoundationPlayerArtworkAnimator(model: model, presenting: true)
            self.animator = animator
            return animator
        }

        func animationController(forDismissed dismissed: UIViewController)
            -> (any UIViewControllerAnimatedTransitioning)?
        {
            let animator = FoundationPlayerArtworkAnimator(model: model, presenting: false)
            self.animator = animator
            return animator
        }

        func interactionControllerForDismissal(
            using animator: any UIViewControllerAnimatedTransitioning
        )
            -> (any UIViewControllerInteractiveTransitioning)?
        { interaction }
    }

    // UIView alpha blends a full-white source mask into the destination's existing
    // feather. No independent CAAnimation clock: percent-driven animator scrubs it.
    @MainActor
    private final class FoundationPlayerArtworkSnapshot: UIImageView {
        let expandedMask = FoundationPlayerArtworkMask()
        override init(image: UIImage?) {
            super.init(image: image)
            mask = expandedMask
        }
        required init?(coder: NSCoder) { fatalError("Not implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            expandedMask.frame = bounds
            expandedMask.layoutIfNeeded()
        }
    }

    @MainActor
    private final class FoundationPlayerArtworkMask: UIView {
        let blend = UIView()
        private let gradient = FoundationPlayerArtworkGradientMask()
        init() {
            super.init(frame: .zero)
            backgroundColor = .clear
            addSubview(gradient)
            blend.backgroundColor = .white
            addSubview(blend)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { fatalError("Not implemented") }
        override func layoutSubviews() {
            super.layoutSubviews()
            gradient.frame = bounds
            blend.frame = bounds
        }
    }

    @MainActor
    private final class FoundationPlayerArtworkGradientMask: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }
        init() {
            super.init(frame: .zero)
            let gradient = layer as! CAGradientLayer
            gradient.colors = [1.0, 1.0, 0.82, 0.35, 0.07, 0.0].map {
                UIColor.white.withAlphaComponent($0).cgColor
            }
            gradient.locations = [0, 0.84, 0.90, 0.96, 0.99, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
        required init?(coder: NSCoder) { fatalError("Not implemented") }
    }

    @MainActor
    final class FoundationPlayerArtworkAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        private weak var model: FoundationPlayerArtworkPresentationModel?
        private let presenting: Bool
        private var propertyAnimator: UIViewPropertyAnimator?
        private weak var snapshot: FoundationPlayerArtworkSnapshot?
        private var snapshotIdentity: String?
        private var snapshotImageID: UUID?
        private var generation: UInt?

        init(model: FoundationPlayerArtworkPresentationModel, presenting: Bool) {
            self.model = model
            self.presenting = presenting
        }

        func transitionDuration(using context: (any UIViewControllerContextTransitioning)?)
            -> TimeInterval
        {
            #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("-fixtureHoldPlayerGlass") {
                    return 1.2
                }
            #endif
            return model?.reduceMotion == true ? 0.18 : 0.5
        }

        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            interruptibleAnimator(using: context).startAnimation()
        }

        func interruptibleAnimator(using context: any UIViewControllerContextTransitioning)
            -> any UIViewImplicitlyAnimating
        {
            if let propertyAnimator { return propertyAnimator }
            let container = context.containerView
            guard let from = context.viewController(forKey: .from),
                let to = context.viewController(forKey: .to)
            else {
                let fallback = UIViewPropertyAnimator(duration: 0, curve: .linear)
                fallback.addCompletion { _ in context.completeTransition(false) }
                propertyAnimator = fallback
                return fallback
            }
            let playerView = presenting ? to.view! : from.view!
            if presenting {
                to.view.frame = context.finalFrame(for: to)
                container.addSubview(to.view)
            } else if to.view.superview == nil {
                to.view.frame = context.finalFrame(for: to)
                container.insertSubview(to.view, belowSubview: from.view)
            }
            playerView.layoutIfNeeded()
            container.layoutIfNeeded()
            let endpoints = model?.endpoints(in: container)
            let surfaceRect = model?.surfaceRect(in: container)
            let originalMask = playerView.mask
            let reveal = UIView()
            reveal.backgroundColor = .white
            reveal.isUserInteractionEnabled = false
            reveal.isAccessibilityElement = false
            let glass: UIView?
            let nativeGlass: UIVisualEffectView?
            if let surfaceRect {
                // The native effect itself changes bounds and corner geometry. A fixed
                // full-screen effect clipped by a moving wrapper only moves its colors.
                let surface: UIView
                if model?.reduceTransparency == true {
                    nativeGlass = nil
                    surface = UIView()
                    surface.backgroundColor = UIColor.systemBackground.resolvedColor(
                        with: UITraitCollection(userInterfaceStyle: .dark))
                } else {
                    let effect = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
                    // Native corners follow the changing bounds throughout the morph.
                    // Assigning a destination corner configuration inside the animation
                    // snaps it immediately, producing a square card mid-transition.
                    effect.cornerConfiguration = .capsule(maximumRadius: surfaceRect.height / 2)
                    effect.isUserInteractionEnabled = false
                    effect.isAccessibilityElement = false
                    surface = effect
                    nativeGlass = effect
                }
                surface.isUserInteractionEnabled = false
                surface.isAccessibilityElement = false
                surface.clipsToBounds = nativeGlass == nil
                surface.layer.cornerCurve = .continuous
                surface.frame = presenting ? surfaceRect : container.bounds
                if nativeGlass == nil {
                    surface.layer.cornerRadius = presenting ? surfaceRect.height / 2 : 0
                }
                // Keep the transition material present behind the revealed player.
                // The system owns the resting accessory glass beneath this container.
                container.insertSubview(surface, belowSubview: playerView)
                glass = surface
                reveal.frame =
                    presenting
                    ? container.convert(surfaceRect, to: playerView) : playerView.bounds
                reveal.layer.cornerRadius = presenting ? surfaceRect.height / 2 : 0
                reveal.layer.cornerCurve = .continuous
                playerView.mask = reveal
            } else {
                glass = nil
                nativeGlass = nil
            }
            let imageView: FoundationPlayerArtworkSnapshot?
            if let endpoints {
                let image = FoundationPlayerArtworkSnapshot(
                    image: UIImage(cgImage: endpoints.artwork.image))
                image.expandedMask.blend.alpha = presenting ? 1 : 0
                image.contentMode = .scaleAspectFill
                image.clipsToBounds = true
                image.isUserInteractionEnabled = false
                image.isAccessibilityElement = false
                image.frame = presenting ? endpoints.compactRect : endpoints.expandedRect
                image.layer.cornerRadius =
                    presenting ? endpoints.compactRadius : endpoints.expandedRadius
                container.addSubview(image)
                image.layoutIfNeeded()
                imageView = image
                snapshot = image
                snapshotIdentity = endpoints.artwork.identity
                snapshotImageID = endpoints.artwork.imageID
            } else {
                imageView = nil
            }
            generation = model?.beginAnimation(
                self, identity: endpoints?.artwork.identity, glass: surfaceRect != nil)
            playerView.alpha = presenting ? 0 : 1
            // Reveal the existing final layout through the expanding bar surface.
            // One interruptible UIKit animator coordinates glass, chrome and artwork.
            let animator = UIViewPropertyAnimator(
                duration: transitionDuration(using: context),
                dampingRatio: 0.9)
            animator.addAnimations { [presenting] in
                playerView.alpha = presenting ? 1 : 0
                // Hand material back to the resting native surfaces before completion,
                // rather than removing an opaque glass layer on the final frame.
                glass?.alpha = 0
                if let surfaceRect, let glass {
                    glass.frame = presenting ? container.bounds : surfaceRect
                    if nativeGlass == nil {
                        glass.layer.cornerRadius = presenting ? 0 : surfaceRect.height / 2
                    }
                    reveal.frame =
                        presenting
                        ? playerView.bounds : container.convert(surfaceRect, to: playerView)
                    reveal.layer.cornerRadius = presenting ? 0 : surfaceRect.height / 2
                }
                if let endpoints, let imageView {
                    imageView.frame = presenting ? endpoints.expandedRect : endpoints.compactRect
                    imageView.layer.cornerRadius =
                        presenting
                        ? endpoints.expandedRadius : endpoints.compactRadius
                    imageView.expandedMask.blend.alpha = presenting ? 0 : 1
                    // Includes UIView-backed mask geometry in the same scrub-able animator.
                    imageView.layoutIfNeeded()
                }
            }
            animator.addCompletion { [presenting, weak self, weak imageView, weak glass] _ in
                let success = !context.transitionWasCancelled
                // Restore a retained player only. A successful dismissal must remain
                // hidden and clipped until UIKit removes the outgoing container.
                if presenting || !success {
                    playerView.alpha = 1
                    playerView.mask = originalMask
                }
                glass?.removeFromSuperview()
                if let self, let generation = self.generation {
                    #if DEBUG && targetEnvironment(simulator)
                        self.model?.recordCompletion(cancelled: !success)
                    #endif
                    self.model?.endAnimation(generation: generation)
                    self.snapshot = nil
                    self.propertyAnimator = nil
                }
                if !success && self?.presenting == true { to.view.removeFromSuperview() }
                context.completeTransition(success)
                // Let SwiftUI publish live artwork restoration before dropping the inert overlay.
                DispatchQueue.main.async { [weak imageView] in imageView?.removeFromSuperview() }
            }
            propertyAnimator = animator
            #if DEBUG && targetEnvironment(simulator)
                if let glass, let surfaceRect {
                    // Observe rendered intermediate geometry without pausing UIKit's
                    // animation clock (which prevents XCTest from becoming idle).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        [weak self, weak glass] in
                        guard let self, self.propertyAnimator === animator,
                            let frame = glass?.layer.presentation()?.frame
                        else { return }
                        self.model?.recordIntermediateSurface(
                            frame, compact: surfaceRect, expanded: container.bounds)
                    }
                }
            #endif
            return animator
        }

        func retireSnapshotIfIdentityChanged() {
            guard let snapshot else { return }
            guard let artwork = model?.artwork(),
                artwork.identity == snapshotIdentity, artwork.imageID == snapshotImageID
            else {
                snapshot.isHidden = true
                // The glass has its own lifetime. A skip retires only stale artwork;
                // completion/cancellation still owns source-glass restoration.
                if let generation { model?.retireArtwork(generation: generation) }
                return
            }
        }

        func invalidate() {
            snapshot?.removeFromSuperview()
            snapshot = nil
            model = nil
            // Let UIKit finish lifecycle/binding cleanup; don't stop its animator
            // without also completing its transition context.
        }
    }
#endif

#if os(iOS)
    /// Native movement is restricted to the queue handle; rows keep their own actions.
    struct FoundationQueueReorderList<Row: View>: UIViewRepresentable {
        let history: [FoundationQueueEntry]
        let current: FoundationQueueEntry?
        let upcoming: [FoundationQueueEntry]
        let move: (UUID, UUID?) -> Void
        let row: (FoundationQueueEntry, Bool) -> Row

        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

        func makeUIView(context: Context) -> UICollectionView {
            let coordinator = context.coordinator
            let layout = UICollectionViewCompositionalLayout {
                [weak coordinator] section, environment in
                var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
                configuration.backgroundColor = .clear
                configuration.showsSeparators = true
                configuration.separatorConfiguration.color = .white.withAlphaComponent(0.12)
                configuration.headerMode =
                    section == 2 || coordinator?.sections[section].isEmpty == false
                    ? .supplementary : .none
                let listSection = NSCollectionLayoutSection.list(
                    using: configuration, layoutEnvironment: environment)
                // Section insets reduce each row's width; scroll-view horizontal
                // content insets would add overflow beyond the visible viewport.
                listSection.contentInsets.leading = 16
                listSection.contentInsets.trailing = 16
                return listSection
            }
            let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
            view.backgroundColor = .clear
            view.overrideUserInterfaceStyle = .dark
            view.alwaysBounceVertical = true
            view.alwaysBounceHorizontal = false
            view.isDirectionalLockEnabled = true
            view.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
            view.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "queue-row")
            view.register(
                QueueHeader.self,
                forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                withReuseIdentifier: "queue-header")
            view.dataSource = coordinator
            view.delegate = coordinator
            let gesture = UILongPressGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.handleMovement(_:)))
            gesture.minimumPressDuration = 0.25
            gesture.delegate = coordinator
            view.addGestureRecognizer(gesture)
            coordinator.collectionView = view
            return view
        }

        func updateUIView(_ view: UICollectionView, context: Context) {
            let coordinator = context.coordinator
            let incoming = [history, current.map { [$0] } ?? [], upcoming]
            coordinator.parent = self
            guard incoming != coordinator.sections else { return }
            // A playback advance, removal, or shuffle invalidates this drag's boundaries.
            coordinator.cancelMovement()
            coordinator.sections = incoming
            view.reloadData()
            view.collectionViewLayout.invalidateLayout()
        }

        static func dismantleUIView(_ view: UICollectionView, coordinator: Coordinator) {
            coordinator.cancelMovement()
            view.delegate = nil
            view.dataSource = nil
        }

        final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegate,
            UIGestureRecognizerDelegate
        {
            var parent: FoundationQueueReorderList
            var sections: [[FoundationQueueEntry]]
            weak var collectionView: UICollectionView?
            private var movingID: UUID?
            private var dragMembership: [[UUID]]?
            private var fingerOffset = CGPoint.zero
            private weak var movingCell: UICollectionViewCell?

            init(parent: FoundationQueueReorderList) {
                self.parent = parent
                sections = [parent.history, parent.current.map { [$0] } ?? [], parent.upcoming]
            }

            func numberOfSections(in collectionView: UICollectionView) -> Int { 3 }

            func collectionView(
                _ collectionView: UICollectionView, numberOfItemsInSection section: Int
            )
                -> Int
            {
                sections[section].count
            }

            func collectionView(
                _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
            )
                -> UICollectionViewCell
            {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: "queue-row", for: indexPath)
                cell.backgroundConfiguration = .clear()
                cell.backgroundView = nil
                cell.contentConfiguration = UIHostingConfiguration {
                    parent.row(sections[indexPath.section][indexPath.item], indexPath.section == 2)
                        .environment(\.colorScheme, .dark)
                        .foregroundStyle(.white)
                        .tint(.white)
                }.margins(.all, 0)
                return cell
            }

            func collectionView(
                _ collectionView: UICollectionView,
                viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
            ) -> UICollectionReusableView {
                let header = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind, withReuseIdentifier: "queue-header", for: indexPath)
                if let header = header as? QueueHeader {
                    header.label.text = ["History", "Now Playing", "Up Next"][indexPath.section]
                }
                return header
            }

            func collectionView(
                _ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath
            )
                -> Bool
            {
                indexPath.section == 2
            }

            func collectionView(
                _ collectionView: UICollectionView,
                targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                atCurrentIndexPath currentIndexPath: IndexPath,
                toProposedIndexPath proposedIndexPath: IndexPath
            ) -> IndexPath {
                guard proposedIndexPath.section == 2 else { return currentIndexPath }
                return proposedIndexPath
            }

            func collectionView(
                _ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath,
                to destinationIndexPath: IndexPath
            ) {
                guard sourceIndexPath.section == 2, destinationIndexPath.section == 2,
                    sections.map({ $0.map(\.id) }) == dragMembership,
                    sections[2].indices.contains(sourceIndexPath.item),
                    sections[2].indices.contains(destinationIndexPath.item),
                    sections[2][sourceIndexPath.item].id == movingID
                else { return }
                let entry = sections[2].remove(at: sourceIndexPath.item)
                sections[2].insert(entry, at: destinationIndexPath.item)
                let next = destinationIndexPath.item + 1
                let boundary = next < sections[2].count ? sections[2][next].id : nil
                clearMovementAppearance()
                parent.move(entry.id, boundary)
            }

            func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                guard let collectionView else { return false }
                let point = gestureRecognizer.location(in: collectionView)
                guard let path = collectionView.indexPathForItem(at: point), path.section == 2,
                    let frame = collectionView.layoutAttributesForItem(at: path)?.frame
                else { return false }
                return point.x >= frame.maxX - 56 && frame.contains(point)
            }

            @objc func handleMovement(_ gesture: UILongPressGestureRecognizer) {
                guard let collectionView else { return }
                let point = gesture.location(in: collectionView)
                switch gesture.state {
                case .began:
                    guard let path = collectionView.indexPathForItem(at: point), path.section == 2,
                        let cell = collectionView.cellForItem(at: path)
                    else { return }
                    movingID = sections[2][path.item].id
                    dragMembership = sections.map { $0.map(\.id) }
                    fingerOffset = CGPoint(x: cell.center.x - point.x, y: cell.center.y - point.y)
                    movingCell = cell
                    let glass = UIVisualEffectView(
                        effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                    glass.layer.cornerRadius = 16
                    glass.clipsToBounds = true
                    cell.backgroundConfiguration = nil
                    cell.backgroundView = glass
                    cell.layoutIfNeeded()
                    guard collectionView.beginInteractiveMovementForItem(at: path) else {
                        clearMovementAppearance()
                        return
                    }
                case .changed:
                    guard movingID != nil else { return }
                    collectionView.updateInteractiveMovementTargetPosition(
                        CGPoint(x: point.x + fingerOffset.x, y: point.y + fingerOffset.y))
                case .ended:
                    guard movingID != nil else { return }
                    collectionView.endInteractiveMovement()
                    clearMovementAppearance(clearIdentity: false)
                case .cancelled, .failed:
                    cancelMovement()
                default:
                    break
                }
            }

            func cancelMovement() {
                guard movingID != nil else { return }
                collectionView?.cancelInteractiveMovement()
                clearMovementAppearance()
            }

            private func clearMovementAppearance(clearIdentity: Bool = true) {
                movingCell?.backgroundView = nil
                movingCell?.backgroundConfiguration = .clear()
                movingCell = nil
                if clearIdentity {
                    movingID = nil
                    dragMembership = nil
                }
            }
        }

        final class QueueHeader: UICollectionReusableView {
            let label = UILabel()

            override init(frame: CGRect) {
                super.init(frame: frame)
                label.font = .preferredFont(forTextStyle: .headline)
                label.adjustsFontForContentSizeCategory = true
                label.textColor = .secondaryLabel
                label.accessibilityTraits.insert(.header)
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                    label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
                    label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                    label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
                ])
            }

            required init?(coder: NSCoder) { nil }
        }
    }
#endif
