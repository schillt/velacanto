import SwiftUI

struct FoundationHomeGeometryEvent: Equatable {
    let content: CGSize
    let container: CGSize
    let offset: CGPoint
    let top: CGFloat
    let bottom: CGFloat

    init(_ value: ScrollGeometry) {
        content = value.contentSize
        container = value.containerSize
        offset = value.contentOffset
        top = value.contentInsets.top
        bottom = value.contentInsets.bottom
    }
}

struct FoundationHomeNativeEndSample: Equatable {
    let content: CGSize
    let bounds: CGSize
    let frame: CGRect
    let offsetY: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    var endY: CGFloat { max(-top, content.height - bounds.height + bottom) }
    var isValid: Bool {
        FoundationBottomChromeLayout.valid(frame)
            && content.width > 0 && content.height > 0 && bounds.width > 0 && bounds.height > 0
            && [content.width, content.height, bounds.width, bounds.height, offsetY, top, bottom]
                .allSatisfy(\.isFinite)
            && endY.isFinite
    }
}

struct FoundationHomeIdleEndRequest {
    enum Validation: Equatable { case invalid, alreadyAtEnd, apply }
    let sample: FoundationHomeNativeEndSample
    let chrome: FoundationBottomChromeMeasurement
    let revision: UInt64
    let pixel: CGFloat
    let retainedY: CGFloat
    let compensatedY: CGFloat
    let contentClearance: CGFloat?

    init(
        sample: FoundationHomeNativeEndSample, chrome: FoundationBottomChromeMeasurement,
        revision: UInt64, pixel: CGFloat, retainedY: CGFloat, compensatedY: CGFloat,
        contentClearance: CGFloat? = nil
    ) {
        self.sample = sample
        self.chrome = chrome
        self.revision = revision
        self.pixel = pixel
        self.retainedY = retainedY
        self.compensatedY = compensatedY
        self.contentClearance = contentClearance
    }

    var targetY: CGFloat { sample.endY }

    func validate(
        _ current: FoundationHomeNativeEndSample, chrome: FoundationBottomChromeMeasurement?,
        revision: UInt64, idle: Bool, pixel: CGFloat, contentClearance: CGFloat? = nil
    ) -> Validation {
        guard idle, current.isValid, chrome == self.chrome, revision == self.revision,
            contentClearance == self.contentClearance,
            pixel == self.pixel, current.content == sample.content,
            current.bounds == sample.bounds, current.frame == sample.frame,
            current.top == sample.top, current.bottom == sample.bottom
        else { return .invalid }
        if abs(current.offsetY - targetY) <= pixel { return .alreadyAtEnd }
        guard
            abs(current.offsetY - retainedY) <= pixel
                || abs(current.offsetY - compensatedY) <= pixel
        else { return .invalid }
        return .apply
    }
}

/// One idle chrome transition. No gesture trajectory, deadline or retained edge anchor.
struct FoundationHomeIdleEndDecision {
    private struct Baseline {
        let sample: FoundationHomeNativeEndSample
        let chrome: FoundationBottomChromeMeasurement
        let revision: UInt64
        let contentClearance: CGFloat?
    }
    private var baseline: Baseline?

    mutating func cancel() { baseline = nil }

    mutating func observe(
        _ sample: FoundationHomeNativeEndSample, chrome: FoundationBottomChromeMeasurement?,
        revision: UInt64, idle: Bool, pixel: CGFloat, contentClearance: CGFloat? = nil
    ) -> FoundationHomeIdleEndRequest? {
        guard idle, sample.isValid, pixel.isFinite, pixel > 0,
            let chrome, let host = chrome.host,
            FoundationBottomChromeLayout.viewportHeight(
                offered: host, host: host, accessory: chrome, hasQueue: true,
                displayScale: 1 / pixel) != nil
        else {
            cancel()
            return nil
        }
        if let contentClearance {
            guard contentClearance.isFinite, contentClearance >= 0 else {
                cancel()
                return nil
            }
            let expected = FoundationBottomChromeLayout.clearance(
                host: host, accessory: chrome, nativeBottomInset: sample.bottom,
                displayScale: 1 / pixel)
            // Geometry and the content-only spacer can arrive in either order.
            // Wait for their exact agreement; do not infer a native inset from our padding.
            guard abs(contentClearance - expected) <= pixel else { return nil }
        }
        guard let old = baseline else {
            if abs(sample.offsetY - sample.endY) <= pixel {
                baseline = .init(
                    sample: sample, chrome: chrome, revision: revision,
                    contentClearance: contentClearance)
            }
            return nil
        }
        guard old.revision == revision, old.sample.content.width == sample.content.width,
            old.sample.bounds.width == sample.bounds.width,
            old.sample.frame.origin == sample.frame.origin,
            old.sample.top == sample.top, old.chrome.host == chrome.host
        else {
            cancel()
            return nil
        }
        let paddingChanged: Bool
        if let contentClearance, let oldClearance = old.contentClearance {
            let paddingDelta = contentClearance - oldClearance
            let contentDelta = sample.content.height - old.sample.content.height
            if abs(contentDelta - paddingDelta) > pixel {
                // The new extent has not been laid out yet. Only the unchanged
                // old content is eligible to wait; unrelated catalog growth retires it.
                if abs(contentDelta) <= pixel, abs(paddingDelta) > pixel { return nil }
                cancel()
                return nil
            }
            paddingChanged = abs(paddingDelta) > pixel
        } else {
            guard contentClearance == nil, old.contentClearance == nil,
                old.sample.content == sample.content
            else {
                cancel()
                return nil
            }
            paddingChanged = false
        }
        let chromeChanged = chrome != old.chrome
        let nativeChanged =
            sample.bounds.height != old.sample.bounds.height
            || sample.bottom != old.sample.bottom || paddingChanged
        guard chromeChanged || nativeChanged else {
            if abs(sample.offsetY - sample.endY) > pixel { cancel() }
            return nil
        }
        // Either callback can arrive first. Hold only the original verified end
        // until both chrome and actual native geometry identify this transition.
        guard chromeChanged, nativeChanged else { return nil }
        if contentClearance == nil {
            // Historical constrained-viewport callers retain their strict guard.
            guard abs(sample.frame.maxY - chrome.frame.minY) <= pixel,
                abs(sample.bottom) <= pixel
            else { return nil }
        }
        // Consume before the caller mutates UIKit; reentrant layout cannot repeat.
        cancel()
        guard sample.endY > old.sample.endY + pixel else { return nil }
        let retained = abs(sample.offsetY - old.sample.endY) <= pixel
        let compensated =
            abs(
                sample.offsetY - (old.sample.endY + sample.bottom - old.sample.bottom)) <= pixel
        guard retained || compensated else { return nil }
        return .init(
            sample: sample, chrome: chrome, revision: revision, pixel: pixel,
            retainedY: old.sample.endY,
            compensatedY: old.sample.endY + sample.bottom - old.sample.bottom,
            contentClearance: contentClearance)
    }
}

#if os(iOS)
    import UIKit

    @MainActor final class FoundationHomeIdleEndPreserver {
        private weak var scroll: UIScrollView?
        private weak var window: UIWindow?
        private var decision = FoundationHomeIdleEndDecision()
        private var chrome: FoundationBottomChromeMeasurement?
        private var revision: UInt64 = 0
        private var contentClearance: CGFloat?
        private var pixel: CGFloat = 1
        private var enabled = false
        private var phase: ScrollPhase = .idle
        typealias Operation = @MainActor @Sendable () -> Void
        private let enqueue: (@escaping Operation) -> Void
        private struct Pending {
            let token: UInt64
            let request: FoundationHomeIdleEndRequest
        }
        private var pending: Pending?
        private var nextToken: UInt64 = 0
        private var scheduledCount = 0
        private(set) var correctionCount = 0

        init(
            enqueue: @escaping (@escaping Operation) -> Void = { operation in
                DispatchQueue.main.async { operation() }
            }
        ) {
            self.enqueue = enqueue
        }

        private func cancelOwnership() {
            if let pending {
                #if DEBUG
                    FoundationHomeReboundDiagnostic.shared?.nativeDeferred(
                        .cancelled, targetY: pending.request.targetY, count: scheduledCount)
                #endif
            }
            pending = nil
            decision.cancel()
        }

        #if DEBUG
            var isAtEnd: Bool {
                guard let scroll, scroll.window != nil else { return false }
                let end = max(
                    -scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height
                        + scroll.adjustedContentInset.bottom)
                return abs(scroll.contentOffset.y - end) <= pixel
            }
        #endif

        func configure(
            chrome: FoundationBottomChromeMeasurement?, revision: UInt64,
            displayScale: CGFloat, enabled: Bool, contentClearance: CGFloat? = nil
        ) {
            if self.revision != revision || !enabled || !displayScale.isFinite || displayScale <= 0
                || (pending != nil
                    && (self.chrome != chrome || self.pixel != 1 / displayScale
                        || self.contentClearance != contentClearance))
            {
                cancelOwnership()
            }
            self.chrome = chrome
            self.revision = revision
            self.contentClearance = contentClearance
            self.pixel = displayScale.isFinite && displayScale > 0 ? 1 / displayScale : 1
            self.enabled = enabled && displayScale.isFinite && displayScale > 0
        }

        func attach(_ value: UIScrollView?) {
            if scroll !== value {
                cancelOwnership()
                window = nil
            }
            scroll = value
        }

        func phaseChanged(_ value: ScrollPhase) {
            phase = value
            if value != .idle { cancelOwnership() }
            observe()
        }

        private func sample(_ scroll: UIScrollView, in window: UIWindow)
            -> FoundationHomeNativeEndSample
        {
            .init(
                content: scroll.contentSize, bounds: scroll.bounds.size,
                frame: scroll.convert(scroll.bounds, to: window),
                offsetY: scroll.contentOffset.y, top: scroll.adjustedContentInset.top,
                bottom: scroll.adjustedContentInset.bottom)
        }

        private func idle(_ scroll: UIScrollView) -> Bool {
            phase == .idle && !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating
        }

        func observe() {
            guard enabled, let scroll, let currentWindow = scroll.window else {
                cancelOwnership()
                return
            }
            if window !== currentWindow {
                cancelOwnership()
                window = currentWindow
            }
            let current = sample(scroll, in: currentWindow)
            if let pending {
                if pending.request.validate(
                    current, chrome: chrome, revision: revision, idle: idle(scroll), pixel: pixel,
                    contentClearance: contentClearance)
                    == .invalid
                {
                    cancelOwnership()
                }
                return
            }
            guard
                let request = decision.observe(
                    current, chrome: chrome, revision: revision, idle: idle(scroll), pixel: pixel,
                    contentClearance: contentClearance)
            else { return }
            nextToken &+= 1
            let token = nextToken
            pending = .init(token: token, request: request)
            scheduledCount += 1
            #if DEBUG
                FoundationHomeReboundDiagnostic.shared?.nativeDeferred(
                    .scheduled, targetY: request.targetY, count: scheduledCount)
            #endif
            // One main-queue hop exits this synchronous update. This is not an
            // after-layout guarantee; later framework overrides reject the experiment.
            enqueue { [weak self, weak scroll, weak currentWindow] in
                self?.apply(token: token, scroll: scroll, window: currentWindow)
            }
        }

        private func apply(
            token: UInt64, scroll expectedScroll: UIScrollView?, window expectedWindow: UIWindow?
        ) {
            guard let pending, pending.token == token else { return }
            guard enabled, let scroll, scroll === expectedScroll, let window,
                window === expectedWindow, scroll.window === window
            else {
                cancelOwnership()
                return
            }
            let validation = pending.request.validate(
                sample(scroll, in: window), chrome: chrome, revision: revision,
                idle: idle(scroll), pixel: pixel, contentClearance: contentClearance)
            // Consume BEFORE any public setter can trigger a reentrant callback.
            self.pending = nil
            decision.cancel()
            guard validation == .apply else {
                #if DEBUG
                    FoundationHomeReboundDiagnostic.shared?.nativeDeferred(
                        validation == .alreadyAtEnd ? .alreadyAtEnd : .cancelled,
                        targetY: pending.request.targetY, count: scheduledCount)
                #endif
                return
            }
            correctionCount += 1
            scroll.setContentOffset(
                CGPoint(x: scroll.contentOffset.x, y: pending.request.targetY), animated: false)
            #if DEBUG
                FoundationHomeReboundDiagnostic.shared?.nativeCorrection(
                    targetY: pending.request.targetY, count: correctionCount)
            #endif
        }

    }

    struct FoundationHomeIdleEndBridge: UIViewRepresentable {
        let owner: FoundationHomeIdleEndPreserver
        let chrome: FoundationBottomChromeMeasurement?
        let revision: UInt64
        let displayScale: CGFloat
        let enabled: Bool
        @Environment(\.foundationBottomChromeContentClearance) private var contentClearance

        func makeUIView(context: Context) -> FoundationHomeIdleEndView {
            FoundationHomeIdleEndView(owner: owner)
        }
        func updateUIView(_ view: FoundationHomeIdleEndView, context: Context) {
            owner.configure(
                chrome: chrome, revision: revision, displayScale: displayScale, enabled: enabled,
                contentClearance: contentClearance)
            view.connect()
            owner.observe()
        }
        static func dismantleUIView(_ view: FoundationHomeIdleEndView, coordinator: Void) {
            view.owner?.attach(nil)
        }
    }

    final class FoundationHomeIdleEndView: UIView {
        weak var owner: FoundationHomeIdleEndPreserver?
        init(owner: FoundationHomeIdleEndPreserver) {
            self.owner = owner
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }
        required init?(coder: NSCoder) { return nil }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            connect()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
            owner?.observe()
        }
        func connect() {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    owner?.attach(scroll)
                    return
                }
                ancestor = view.superview
            }
            owner?.attach(nil)
        }
    }
#endif
