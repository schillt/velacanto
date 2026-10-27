import SwiftUI

/// Geometry needed to retain an existing end position when bottom chrome expands.
struct FoundationScrollEndGeometry: Equatable {
    let contentSize: CGSize
    let containerSize: CGSize
    let contentOffsetY: CGFloat
    let insetTop: CGFloat
    let insetBottom: CGFloat
    let visibleMaxY: CGFloat

    var unobscuredBottom: CGFloat { visibleMaxY - insetBottom }
}

extension FoundationScrollEndGeometry {
    init(_ geometry: ScrollGeometry) {
        contentSize = geometry.contentSize
        containerSize = geometry.containerSize
        contentOffsetY = geometry.contentOffset.y
        insetTop = geometry.contentInsets.top
        insetBottom = geometry.contentInsets.bottom
        visibleMaxY = geometry.visibleRect.maxY
    }
}

enum FoundationScrollEndPreservation {
    static func targetY(
        from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
        phase: ScrollPhase, displayScale: CGFloat
    ) -> CGFloat? {
        let pixel = 1 / max(1, displayScale)
        // Native chrome can shrink the viewport before publishing its larger bottom
        // inset. Require measured end loss, without assuming those callbacks are atomic.
        guard phase == .idle,
            previous.contentSize == current.contentSize,
            previous.containerSize.width == current.containerSize.width,
            previous.insetTop == current.insetTop,
            abs(previous.contentOffsetY - current.contentOffsetY) <= pixel,
            previous.contentSize.height > previous.containerSize.height + pixel,
            previous.contentOffsetY + previous.insetTop > pixel,
            abs(previous.contentSize.height - previous.unobscuredBottom) <= pixel,
            current.insetBottom >= previous.insetBottom,
            previous.containerSize.height - current.containerSize.height > pixel,
            current.contentSize.height - current.unobscuredBottom > pixel
        else { return nil }
        // A concrete point is clamped by SwiftUI without retaining a bottom edge anchor
        // that would also follow later independently published content.
        return current.contentSize.height
    }
}

/// View-owned, nonobservable event owner; geometry observations do not redraw Home.
@MainActor
final class FoundationScrollEndTracker {
    private(set) var phase = ScrollPhase.idle
    private var lastGeometry: FoundationScrollEndGeometry?
    private var candidate: EndCandidate?
    private var gestureMayPreserveEnd = false
    private var reachedEnd = false

    private struct EndCandidate {
        let original: FoundationScrollEndGeometry
        let endOffset: CGFloat

        func stillApplies(to current: FoundationScrollEndGeometry, pixel: CGFloat) -> Bool {
            original.contentSize == current.contentSize
                && original.containerSize.width == current.containerSize.width
                && original.insetTop == current.insetTop
                && current.insetBottom >= original.insetBottom
                && original.containerSize.height - current.containerSize.height > pixel
                && current.contentOffsetY >= endOffset - pixel
        }

        func isNativeOldEndClamp(
            from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
            pixel: CGFloat
        ) -> Bool {
            // Native chrome can clamp the original overshoot to the old end while
            // the finger still advances. Recognize only that measured landing;
            // a later reverse or a move below the old end retains user ownership.
            guard previous.containerSize == current.containerSize,
                previous.contentOffsetY > endOffset + pixel,
                abs(current.contentOffsetY - endOffset) <= pixel,
                targetY(at: current, pixel: pixel) != nil
            else { return false }
            if previous.insetBottom == current.insetBottom,
                abs(previous.contentOffsetY - original.contentOffsetY) <= pixel
            {
                return true
            }
            // A split native inset update can first land at the clear expanded
            // end, then clamp back to the compact end as that inset disappears.
            let insetDrop = previous.insetBottom - current.insetBottom
            let shrink = original.containerSize.height - current.containerSize.height
            return abs(previous.unobscuredBottom - previous.contentSize.height) <= pixel
                && abs(insetDrop - shrink) <= pixel
                && abs(previous.contentOffsetY - current.contentOffsetY - insetDrop) <= pixel
        }

        func targetY(at current: FoundationScrollEndGeometry, pixel: CGFloat) -> CGFloat? {
            let loss = current.contentSize.height - current.unobscuredBottom
            let shrink = original.containerSize.height - current.containerSize.height
            guard stillApplies(to: current, pixel: pixel), loss > pixel, loss <= shrink + pixel
            else { return nil }
            return current.contentSize.height
        }
    }

    func phaseChanged(
        to current: ScrollPhase, geometry: FoundationScrollEndGeometry, displayScale: CGFloat
    ) -> CGFloat? {
        let previousPhase = phase
        phase = current
        if current == .tracking
            || (current == .interacting && previousPhase != .tracking
                && previousPhase != .interacting)
        {
            #if DEBUG && os(iOS)
                diagnostic(.newInteraction, current: geometry, displayScale: displayScale)
            #endif
            clearIntent()
            gestureMayPreserveEnd = true
        }
        if current == .animating {
            #if DEBUG && os(iOS)
                diagnostic(.programmaticAnimation, current: geometry, displayScale: displayScale)
            #endif
            clearIntent()
            lastGeometry = geometry
            return nil
        }
        if previousPhase == .animating, current == .idle {
            #if DEBUG && os(iOS)
                diagnostic(.programmaticIdle, current: geometry, displayScale: displayScale)
            #endif
            clearIntent()
            lastGeometry = geometry
            return nil
        }
        if current == .idle, previousPhase == .decelerating,
            candidate == nil, gestureMayPreserveEnd, reachedEnd, let previous = lastGeometry
        {
            // The phase callback may expose the resize before its geometry callback.
            candidate = candidateForResize(
                from: previous, to: geometry, pixel: 1 / max(1, displayScale))
            #if DEBUG && os(iOS)
                diagnostic(
                    candidate == nil
                        ? candidateRejection(
                            from: previous, to: geometry, displayScale: displayScale)
                        : .candidateArmed,
                    previous: previous, current: geometry, displayScale: displayScale)
            #endif
        }
        let target = observe(geometry, previous: geometry, displayScale: displayScale)
        if current == .idle { clearIntent() }
        return target
    }

    func geometryChanged(
        from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
        displayScale: CGFloat
    ) -> CGFloat? {
        observe(current, previous: previous, displayScale: displayScale)
    }

    private func observe(
        _ current: FoundationScrollEndGeometry, previous fallback: FoundationScrollEndGeometry,
        displayScale: CGFloat
    ) -> CGFloat? {
        // Both callbacks publish geometry. Remember the latest observation so a later
        // geometry callback cannot replay a resize already consumed by the idle callback.
        let previous = lastGeometry ?? fallback
        lastGeometry = current
        let pixel = 1 / max(1, displayScale)
        guard previous.contentSize == current.contentSize,
            previous.containerSize.width == current.containerSize.width,
            previous.insetTop == current.insetTop
        else {
            #if DEBUG && os(iOS)
                diagnostic(
                    previous.contentSize != current.contentSize
                        ? .contentChanged
                        : previous.containerSize.width != current.containerSize.width
                            ? .widthChanged : .topChanged,
                    previous: previous, current: current, displayScale: displayScale)
            #endif
            clearIntent()
            return nil
        }
        var nativeResizeClamp = false
        if phase == .interacting, candidate == nil, gestureMayPreserveEnd, reachedEnd,
            current.contentOffsetY < previous.contentOffsetY - pixel,
            previous.unobscuredBottom - previous.contentSize.height > pixel,
            abs(current.unobscuredBottom - current.contentSize.height) <= pixel,
            let resized = candidateForResize(from: previous, to: current, pixel: pixel)
        {
            // Resize and offset clamping may arrive together. Retain the compact
            // baseline only for the measured landing exactly at the new end.
            candidate = resized
            nativeResizeClamp = true
            #if DEBUG && os(iOS)
                diagnostic(
                    .candidateArmed, previous: previous, current: current,
                    displayScale: displayScale)
            #endif
        }
        if phase == .interacting, current.contentOffsetY < previous.contentOffsetY - pixel,
            !nativeResizeClamp,
            candidate?.isNativeOldEndClamp(from: previous, to: current, pixel: pixel) != true
        {
            #if DEBUG && os(iOS)
                diagnostic(
                    .interactingReverse, previous: previous, current: current,
                    displayScale: displayScale)
            #endif
            // A live reverse drag relinquishes this gesture's end intent. Spring
            // reversal during deceleration is not a new user decision.
            clearIntent()
            return nil
        }
        if let candidate, !candidate.stillApplies(to: current, pixel: pixel) {
            #if DEBUG && os(iOS)
                diagnostic(
                    .pendingInvalidated, previous: previous, current: current,
                    displayScale: displayScale)
            #endif
            clearIntent()
            return nil
        }
        if phase == .idle {
            if let pending = candidate {
                #if DEBUG && os(iOS)
                    let proposed = pending.targetY(at: current, pixel: pixel)
                    diagnostic(
                        proposed == nil ? .idleCandidateRejected : .idleCandidateConsumed,
                        previous: previous, current: current, displayScale: displayScale,
                        target: proposed)
                #endif
                clearIntent()
                return pending.targetY(at: current, pixel: pixel)
            }
            let target = FoundationScrollEndPreservation.targetY(
                from: previous, to: current, phase: phase, displayScale: displayScale)
            #if DEBUG && os(iOS)
                diagnostic(
                    target == nil ? .idleDirectRejected : .idleDirectTarget,
                    previous: previous, current: current, displayScale: displayScale, target: target
                )
            #endif
            return target
        }
        guard gestureMayPreserveEnd, phase == .interacting || phase == .decelerating else {
            #if DEBUG && os(iOS)
                diagnostic(
                    gestureMayPreserveEnd ? .inactivePhase : .gestureRelinquished,
                    previous: previous, current: current, displayScale: displayScale)
            #endif
            return nil
        }
        reachedEnd = reachedEnd || atEnd(previous, pixel: pixel) || atEnd(current, pixel: pixel)
        if candidate == nil, reachedEnd {
            candidate = candidateForResize(from: previous, to: current, pixel: pixel)
            #if DEBUG && os(iOS)
                let reason: FoundationHomeReboundReason =
                    candidate != nil
                    ? .candidateArmed
                    : candidateRejection(from: previous, to: current, displayScale: displayScale)
                diagnostic(reason, previous: previous, current: current, displayScale: displayScale)
            #endif
        } else {
            #if DEBUG && os(iOS)
                diagnostic(
                    candidate == nil ? .noPriorEnd : .candidateRetained,
                    previous: previous, current: current, displayScale: displayScale)
            #endif
        }
        return nil
    }

    private func atEnd(_ geometry: FoundationScrollEndGeometry, pixel: CGFloat) -> Bool {
        geometry.contentSize.height > geometry.containerSize.height + pixel
            && geometry.contentOffsetY + geometry.insetTop > pixel
            && geometry.unobscuredBottom >= geometry.contentSize.height - pixel
    }

    private func candidateForResize(
        from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
        pixel: CGFloat
    ) -> EndCandidate? {
        guard atEnd(previous, pixel: pixel), previous.contentSize == current.contentSize,
            previous.containerSize.width == current.containerSize.width,
            previous.insetTop == current.insetTop,
            previous.containerSize.height - current.containerSize.height > pixel,
            current.insetBottom >= previous.insetBottom
        else { return nil }
        let endOffset =
            previous.contentOffsetY
            - max(0, previous.unobscuredBottom - previous.contentSize.height)
        let pending = EndCandidate(original: previous, endOffset: endOffset)
        return pending.stillApplies(to: current, pixel: pixel) ? pending : nil
    }

    private func clearIntent() {
        candidate = nil
        reachedEnd = false
        gestureMayPreserveEnd = false
    }

    #if DEBUG && os(iOS)
        // Explanation only: the controller's existing guard remains the decision owner.
        private func candidateRejection(
            from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
            displayScale: CGFloat
        ) -> FoundationHomeReboundReason {
            let pixel = 1 / max(1, displayScale)
            if !atEnd(previous, pixel: pixel) { return .noPriorEnd }
            if previous.contentSize != current.contentSize { return .contentChanged }
            if previous.containerSize.width != current.containerSize.width { return .widthChanged }
            if previous.insetTop != current.insetTop { return .topChanged }
            if previous.containerSize.height - current.containerSize.height <= pixel {
                return .viewportNotShrunk
            }
            if current.insetBottom < previous.insetBottom { return .bottomInsetDecreased }
            return .candidateOffsetRejected
        }

        private func diagnostic(
            _ reason: FoundationHomeReboundReason, previous: FoundationScrollEndGeometry? = nil,
            current: FoundationScrollEndGeometry, displayScale: CGFloat, target: CGFloat? = nil
        ) {
            guard let recorder = FoundationHomeReboundDiagnostic.shared else { return }
            var facts: [String: Double] = [
                "hasCandidate": candidate == nil ? 0 : 1,
                "reachedEnd": reachedEnd ? 1 : 0,
                "gestureMayPreserveEnd": gestureMayPreserveEnd ? 1 : 0,
                "displayScale": Double(displayScale),
                "currentEndLoss": Double(current.contentSize.height - current.unobscuredBottom),
            ]
            if let candidate {
                facts["candidateEndOffset"] = Double(candidate.endOffset)
                facts["candidateOriginalHeight"] = Double(candidate.original.containerSize.height)
                facts["candidateOriginalBottom"] = Double(candidate.original.insetBottom)
                facts["candidateViewportLoss"] = Double(
                    candidate.original.containerSize.height - current.containerSize.height)
            }
            recorder.tracker(
                reason, phase: phase, previous: previous ?? lastGeometry, current: current,
                facts: facts, target: target)
        }
    #endif
}

extension View {
    @ViewBuilder func foundationPreserveEndOnBottomChromeExpansion() -> some View {
        #if os(iOS)
            modifier(FoundationScrollEndPreservationModifier())
        #else
            self
        #endif
    }
}

#if os(iOS)
    private struct FoundationScrollEndPreservationModifier: ViewModifier {
        @Environment(\.displayScale) private var displayScale
        @State private var position = ScrollPosition(idType: Never.self)
        @State private var tracker = FoundationScrollEndTracker()
        private var phase: ScrollPhase { tracker.phase }
        #if DEBUG && targetEnvironment(simulator)
            @State private var decisions: [String] = []
            @State private var traceGesture = 0
            @State private var traceBeyondEnd = false
        #endif

        func body(content: Content) -> some View {
            content
                .scrollPosition($position)
                .onScrollPhaseChange { previous, current, context in
                    #if DEBUG
                        FoundationHomeReboundDiagnostic.shared?.phase(
                            from: previous, to: current, geometry: context.geometry)
                    #endif
                    let target = tracker.phaseChanged(
                        to: current, geometry: FoundationScrollEndGeometry(context.geometry),
                        displayScale: displayScale)
                    #if DEBUG && targetEnvironment(simulator)
                        if ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary")
                        {
                            if current == .tracking
                                || (current == .interacting && previous != .tracking)
                            {
                                traceGesture += 1
                                traceBeyondEnd = false
                            }
                            let geometry = FoundationScrollEndGeometry(context.geometry)
                            let beyondEnd =
                                geometry.unobscuredBottom - geometry.contentSize.height
                                > 1 / max(1, displayScale)
                            let record =
                                "gesture=\(traceGesture) phaseChange=\(previous)->\(current)"
                                + " beyondEnd=\(beyondEnd) target=\(String(describing: target))"
                                + " geometry=\(context.geometry)"
                            decisions = Array((decisions + [record]).suffix(12))
                        }
                    #endif
                    if let target {
                        #if DEBUG
                            FoundationHomeReboundDiagnostic.shared?.pointRequest(
                                target, phase: phase)
                        #endif
                        position.scrollTo(y: target)
                    }
                    #if DEBUG
                        FoundationHomeReboundDiagnostic.shared?.phaseFinished(current)
                    #endif
                }
                .onScrollGeometryChange(for: FoundationScrollEndGeometry.self) {
                    FoundationScrollEndGeometry($0)
                } action: { previous, current in
                    let target = tracker.geometryChanged(
                        from: previous, to: current, displayScale: displayScale)
                    #if DEBUG && targetEnvironment(simulator)
                        recordDecision(from: previous, to: current, target: target)
                    #endif
                    if let target {
                        #if DEBUG
                            FoundationHomeReboundDiagnostic.shared?.pointRequest(
                                target, phase: phase)
                        #endif
                        position.scrollTo(y: target)
                    }
                }
                #if DEBUG && targetEnvironment(simulator)
                    .overlay(alignment: .topLeading) {
                        if ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary")
                        {
                            Text("Home end preservation decisions")
                            .font(.system(size: 1))
                            .foregroundStyle(.clear)
                            .frame(width: 1, height: 1)
                            .accessibilityIdentifier("foundation-home-end-decisions")
                            .accessibilityValue(decisions.joined(separator: "\n"))
                            .allowsHitTesting(false)
                        }
                    }
                #endif
        }

        #if DEBUG && targetEnvironment(simulator)
            private func recordDecision(
                from previous: FoundationScrollEndGeometry, to current: FoundationScrollEndGeometry,
                target: CGFloat?
            ) {
                guard ProcessInfo.processInfo.arguments.contains("-fixtureHomeScrollBoundary")
                else {
                    return
                }
                let beyondEnd =
                    current.unobscuredBottom - current.contentSize.height
                    > 1 / max(1, displayScale)
                let overshootChanged = traceBeyondEnd != beyondEnd
                if overshootChanged { traceBeyondEnd = beyondEnd }
                guard
                    previous.containerSize != current.containerSize
                        || previous.insetTop != current.insetTop
                        || previous.insetBottom != current.insetBottom || target != nil
                        || overshootChanged
                else { return }
                func fields(_ geometry: FoundationScrollEndGeometry) -> String {
                    "offset=\(geometry.contentOffsetY) content=\(geometry.contentSize)"
                        + " container=\(geometry.containerSize) top=\(geometry.insetTop)"
                        + " bottom=\(geometry.insetBottom) visibleMax=\(geometry.visibleMaxY)"
                        + " unobscuredBottom=\(geometry.unobscuredBottom)"
                }
                let record =
                    "gesture=\(traceGesture) phase=\(phase) scale=\(displayScale)"
                    + " beyondEnd=\(beyondEnd) target=\(String(describing: target))"
                    + " previous[\(fields(previous))] current[\(fields(current))]"
                decisions = Array((decisions + [record]).suffix(12))
            }
        #endif
    }
#endif
