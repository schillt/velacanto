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
                "morph 0; fade 0; cancelled 0; completed 0; glass 0"
            private var glassCount = 0
            private var morphCount = 0
            private var fadeCount = 0
            private var cancelledCount = 0
            private var completedCount = 0

            private func publishTransitionSummary() {
                transitionSummary =
                    "morph \(morphCount); fade \(fadeCount); cancelled \(cancelledCount); completed \(completedCount); glass \(glassCount)"
            }

            fileprivate func recordCompletion(cancelled: Bool) {
                if cancelled { cancelledCount &+= 1 } else { completedCount &+= 1 }
                publishTransitionSummary()
            }
        #endif
        @Published fileprivate(set) var isPlayerPresented = false
        var artwork: () -> Artwork? = { nil }
        var reduceMotion = false
        var reduceTransparency = false
        private weak var compactSurface: UIView?
        private var surfaceToken: UUID?
        private var surfaceIdentity: String?
        var allowsInteractiveDismissal = true
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
                source.window === window, surfaceIdentity == expanded?.identity
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
                !host.hasPresentedContent, !host.isBeingPresented,
                !host.isBeingDismissed, let anchor = expanded, let artView = anchor.view,
                artView.window === view.window
            else { return false }
            // Lyrics, queue, scrub, nested sheet state is supplied by PlayerView.
            // Only the artwork region starts this app-owned gesture; controls stay native.
            return artView.convert(artView.bounds, to: view).contains(location)
        }

        fileprivate func beginAnimation(
            _ animator: FoundationPlayerArtworkAnimator,
            identity: String?, glass: Bool
        ) -> UInt {
            generation &+= 1
            activeAnimator = animator
            hiddenArtworkIdentity = identity
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
            activeAnimator = nil
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
            self.host = nil
            isPlayerPresented = false
        }

        func invalidate() {
            generation &+= 1
            activeAnimator?.invalidate()
            activeAnimator = nil
            hiddenArtworkIdentity = nil
            isPlayerPresented = false
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

    struct FoundationPlayerSurfaceAnchor: UIViewRepresentable {
        let model: FoundationPlayerArtworkPresentationModel
        let identity: String?
        @MainActor final class Coordinator {
            let token = UUID()
            weak var model: FoundationPlayerArtworkPresentationModel?
        }
        func makeCoordinator() -> Coordinator { Coordinator() }
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            view.backgroundColor = .clear
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
        func body(content: Content) -> some View {
            content.overlay {
                if let model {
                    FoundationPlayerSurfaceAnchor(model: model, identity: identity)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
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
            controller.playerContent = AnyView(
                content
                    .environment(\.self, playerEnvironment)
                    .environmentObject(model))
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
        var playerContent = AnyView(EmptyView())
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
                host.rootView = playerContent
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
            let distance = max(1, view.bounds.height * 0.55)
            let progress = min(1, max(0, gesture.translation(in: view).y / distance))
            switch gesture.state {
            case .began:
                let interaction = UIPercentDrivenInteractiveTransition()
                interaction.completionCurve = .easeOut
                self.interaction = interaction
                dismissPlayer(animated: true)
            case .changed:
                interaction?.update(progress)
            case .ended:
                if progress > 0.35 || gesture.velocity(in: view).y > 900 {
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
        { model?.reduceMotion == true ? 0.18 : 0.42 }

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
                // UIKit-owned clipping geometry moves with the artwork and player reveal.
                // Keep the effect's backing geometry fixed while its material changes.
                let surface = UIView()
                if model?.reduceTransparency == true {
                    nativeGlass = nil
                    surface.backgroundColor = UIColor.systemBackground.resolvedColor(
                        with: UITraitCollection(userInterfaceStyle: .dark))
                } else {
                    let effect = UIVisualEffectView(effect: nil)
                    effect.frame = CGRect(origin: .zero, size: container.bounds.size)
                    effect.cornerConfiguration = .uniformCorners(radius: .fixed(0))
                    effect.isUserInteractionEnabled = false
                    effect.isAccessibilityElement = false
                    surface.addSubview(effect)
                    nativeGlass = effect
                }
                surface.isUserInteractionEnabled = false
                surface.isAccessibilityElement = false
                surface.clipsToBounds = true
                surface.layer.cornerCurve = .continuous
                surface.frame = presenting ? surfaceRect : container.bounds
                surface.layer.cornerRadius = presenting ? surfaceRect.height / 2 : 0
                // Effect views keep alpha 1. Native material is absent at both endpoints.
                if nativeGlass == nil { surface.alpha = 0 }
                container.addSubview(surface)
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
                if let surfaceRect, let glass {
                    glass.frame = presenting ? container.bounds : surfaceRect
                    glass.layer.cornerRadius = presenting ? 0 : surfaceRect.height / 2
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
            if let glass {
                // Share the interruptible animator's clock. At either endpoint, removing
                // this surface cannot replace the native material in one visible frame.
                // Animate native material through effect, not effect-view alpha.
                let duration = animator.duration
                animator.addAnimations {
                    UIView.animateKeyframes(
                        withDuration: duration, delay: 0,
                        options: [.calculationModeLinear]
                    ) {
                        UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.2) {
                            if let nativeGlass {
                                nativeGlass.effect = UIGlassEffect(style: .regular)
                            } else {
                                glass.alpha = 1
                            }
                        }
                        UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                            if let nativeGlass {
                                nativeGlass.effect = nil
                            } else {
                                glass.alpha = 0
                            }
                        }
                    }
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
            return animator
        }

        func retireSnapshotIfIdentityChanged() {
            guard let snapshot, let artwork = model?.artwork(),
                artwork.identity == snapshotIdentity, artwork.imageID == snapshotImageID
            else {
                snapshot?.isHidden = true
                if let generation { model?.endAnimation(generation: generation) }
                return
            }
            // Same image identity/revision upgrade: retain the transition CGImage.
            _ = snapshot
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
