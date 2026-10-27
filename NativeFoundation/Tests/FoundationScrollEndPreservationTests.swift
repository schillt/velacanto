import SwiftUI
import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationScrollEndPreservationTests: XCTestCase {
    func testDevice221ResizeAndNewEndClampThenInsetAndOldEndClampWaitForIdle() {
        // Captured gestures6 and9 differ in overshoot but share both native clamps.
        for (overshoot, forward): (CGFloat, CGFloat) in [
            (1_618.6666666666667, 1_693), (1_596.3333333333333, 1_639.6666666666667),
        ] {
            let tracker = FoundationScrollEndTracker()
            let compact = device220Geometry(offset: 1_529, containerHeight: 623)
            let overshot = device220Geometry(offset: overshoot, containerHeight: 623)
            let newEnd = device221NewEnd()
            let oldEnd = device220Geometry(offset: 1_529)
            XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: compact, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: compact, to: overshot, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: overshot, to: newEnd, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: newEnd, to: oldEnd, displayScale: 3))
            let continued = device220Geometry(offset: forward)
            XCTAssertNil(tracker.geometryChanged(from: oldEnd, to: continued, displayScale: 3))
            XCTAssertNil(
                tracker.phaseChanged(to: .decelerating, geometry: continued, displayScale: 3))
            // Each vector retains that gesture's captured sampled rebound.
            var previous = continued
            let offsets: [CGFloat] =
                forward == 1_693
                ? [
                    1_763, 1_762.6666666666667, 1_738, 1_704.6666666666667, 1_671,
                    1_640.6666666666667, 1_615, 1_594.3333333333333, 1_578,
                    1_565.3333333333333, 1_556, 1_548.6666666666667, 1_543.3333333333333,
                    1_539.3333333333333, 1_536.6666666666667, 1_534.3333333333333,
                    1_533, 1_531.6666666666667, 1_531, 1_530.3333333333333, 1_530,
                    1_529.6666666666667, 1_529,
                ]
                : [
                    1_646.3333333333333, 1_727, 1_742.6666666666667, 1_727.3333333333333,
                    1_699.3333333333333, 1_668.3333333333333, 1_639.6666666666667, 1_615,
                    1_594.6666666666667, 1_578.6666666666667, 1_566, 1_556.3333333333333,
                    1_549, 1_543.6666666666667, 1_539.6666666666667, 1_536.6666666666667,
                    1_534.6666666666667, 1_533, 1_532, 1_531, 1_530.3333333333333,
                    1_530, 1_529.6666666666667, 1_529,
                ]
            for offset in offsets {
                let current = device220Geometry(offset: offset)
                XCTAssertNil(tracker.geometryChanged(from: previous, to: current, displayScale: 3))
                previous = current
            }
            XCTAssertEqual(previous.unobscuredBottom, 2_202)
            XCTAssertEqual(
                tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3), 2_258)
            XCTAssertNil(tracker.geometryChanged(from: previous, to: oldEnd, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3))
        }
    }

    func testDevice221GenuineUpwardGestureStillOwnsPosition() {
        let tracker = FoundationScrollEndTracker()
        var previous = device220Geometry(offset: 1_529)
        XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: previous, displayScale: 3))
        // Actual retained gesture7 moves away from the occluded end without resize.
        for offset: CGFloat in [
            1_508.3333333333333, 1_487, 1_432.6666666666667, 1_403.6666666666667,
            1_393, 1_388, 1_384, 1_382, 1_381.6666666666667,
        ] {
            let current = device220Geometry(offset: offset)
            XCTAssertNil(tracker.geometryChanged(from: previous, to: current, displayScale: 3))
            previous = current
        }
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: previous, displayScale: 3))
    }

    func testResizeReverseMustLandExactlyAtNewEndToRetainIntent() {
        for offset: CGFloat in [1_584, 1_586] {
            let tracker = FoundationScrollEndTracker()
            let compact = device220Geometry(offset: 1_529, containerHeight: 623)
            let overshot = device220Geometry(offset: 1_596.3333333333333, containerHeight: 623)
            let nearNewEnd = geometry(
                offset: offset, contentHeight: 2_258, containerHeight: 567,
                bottom: 139, top: 106, width: 375)
            XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: compact, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: compact, to: overshot, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: overshot, to: nearNewEnd, displayScale: 3))
            let oldEnd = device220Geometry(offset: 1_529)
            XCTAssertNil(tracker.geometryChanged(from: nearNewEnd, to: oldEnd, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3))
        }
    }

    func testSplitInsetClampRequiresSameViewportExactOldEndAndMatchingInsetDrop() {
        for changed in [
            device220Geometry(offset: 1_528.5), device220Geometry(offset: 1_530),
            geometry(
                offset: 1_529, contentHeight: 2_258, containerHeight: 567,
                bottom: 100, top: 106, width: 375),
            device220Geometry(offset: 1_529, containerHeight: 568),
        ] {
            let tracker = device221FirstClampTracker()
            XCTAssertNil(
                tracker.geometryChanged(from: device221NewEnd(), to: changed, displayScale: 3))
            let oldEnd = device220Geometry(offset: 1_529)
            XCTAssertNil(tracker.geometryChanged(from: changed, to: oldEnd, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3))
        }
    }

    func testFirstNativeClampDoesNotSurviveNewTouchOrContentPublication() {
        for phase: ScrollPhase in [.tracking, .animating] {
            let tracker = device221FirstClampTracker()
            XCTAssertNil(
                tracker.phaseChanged(to: phase, geometry: device221NewEnd(), displayScale: 3))
            let oldEnd = device220Geometry(offset: 1_529)
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3))
        }
        let tracker = device221FirstClampTracker()
        let changed = geometry(
            offset: 1_585, contentHeight: 2_300, containerHeight: 567,
            bottom: 139, top: 106, width: 375)
        XCTAssertNil(
            tracker.geometryChanged(from: device221NewEnd(), to: changed, displayScale: 3))
        let oldEnd = device220Geometry(offset: 1_529)
        XCTAssertNil(tracker.geometryChanged(from: changed, to: oldEnd, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: oldEnd, displayScale: 3))
    }

    private func device221FirstClampTracker() -> FoundationScrollEndTracker {
        let tracker = FoundationScrollEndTracker()
        let compact = device220Geometry(offset: 1_529, containerHeight: 623)
        let overshot = device220Geometry(offset: 1_596.3333333333333, containerHeight: 623)
        XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: compact, displayScale: 3))
        XCTAssertNil(tracker.geometryChanged(from: compact, to: overshot, displayScale: 3))
        XCTAssertNil(
            tracker.geometryChanged(from: overshot, to: device221NewEnd(), displayScale: 3))
        return tracker
    }

    private func device221NewEnd() -> FoundationScrollEndGeometry {
        geometry(
            offset: 1_585, contentHeight: 2_258, containerHeight: 567,
            bottom: 139, top: 106, width: 375)
    }

    func testDevice220InteractingOldEndClampPreservesPendingResizeUntilIdleOnce() {
        let tracker = device220PendingTracker()
        var previous = device220Geometry(offset: 1_553.3333333333333)
        // The native resize clamps to the OLD compact end while the finger still
        // advances; the following forward samples prove this was not an away drag.
        for offset: CGFloat in [1_529, 1_563.3333333333333, 1_642.6666666666667] {
            let current = device220Geometry(offset: offset)
            XCTAssertNil(tracker.geometryChanged(from: previous, to: current, displayScale: 3))
            previous = current
        }
        XCTAssertNil(tracker.phaseChanged(to: .decelerating, geometry: previous, displayScale: 3))
        for offset: CGFloat in [
            1_695.3333333333333, 1_735, 1_761.6666666666667, 1_749.3333333333333,
            1_720.3333333333333, 1_687, 1_655, 1_627.3333333333333,
            1_604.3333333333333, 1_586, 1_571.3333333333333, 1_560.3333333333333,
            1_552.3333333333333, 1_546, 1_541.3333333333333, 1_538,
            1_535.3333333333333, 1_533.6666666666667, 1_532.3333333333333,
            1_531.3333333333333, 1_530.6666666666667, 1_530, 1_529.6666666666667, 1_529,
        ] {
            let current = device220Geometry(offset: offset)
            XCTAssertNil(tracker.geometryChanged(from: previous, to: current, displayScale: 3))
            previous = current
        }
        XCTAssertEqual(previous.unobscuredBottom, 2_202)
        XCTAssertEqual(tracker.phaseChanged(to: .idle, geometry: previous, displayScale: 3), 2_258)
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: previous, displayScale: 3))
        let corrected = device220Geometry(offset: 1_585)
        XCTAssertEqual(corrected.unobscuredBottom, 2_258)
        XCTAssertNil(tracker.geometryChanged(from: previous, to: corrected, displayScale: 3))
    }

    func testInteractingReverseOutsideCapturedOldEndClampStillCancels() {
        // A reverse to either side of the exact old end is not the native clamp.
        for offset: CGFloat in [1_528.5, 1_530, 1_540] {
            let tracker = device220PendingTracker()
            let before = device220Geometry(offset: 1_553.3333333333333)
            let reversed = device220Geometry(offset: offset)
            XCTAssertNil(tracker.geometryChanged(from: before, to: reversed, displayScale: 3))
            let forward = device220Geometry(offset: 1_642.6666666666667)
            XCTAssertNil(tracker.geometryChanged(from: reversed, to: forward, displayScale: 3))
            XCTAssertNil(
                tracker.phaseChanged(to: .decelerating, geometry: forward, displayScale: 3))
            XCTAssertNil(
                tracker.phaseChanged(
                    to: .idle, geometry: device220Geometry(offset: 1_529), displayScale: 3))
        }
    }

    func testAcceptedOldEndClampDoesNotHideSubsequentUserReverse() {
        let tracker = device220PendingTracker()
        let before = device220Geometry(offset: 1_553.3333333333333)
        let clamped = device220Geometry(offset: 1_529)
        XCTAssertNil(tracker.geometryChanged(from: before, to: clamped, displayScale: 3))
        let away = device220Geometry(offset: 1_528)
        XCTAssertNil(tracker.geometryChanged(from: clamped, to: away, displayScale: 3))
        let forward = device220Geometry(offset: 1_642.6666666666667)
        XCTAssertNil(tracker.geometryChanged(from: away, to: forward, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .decelerating, geometry: forward, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: clamped, displayScale: 3))
    }

    func testLaterReverseToOldEndDoesNotReuseInitialClampException() {
        let tracker = device220PendingTracker()
        let resized = device220Geometry(offset: 1_553.3333333333333)
        let forward = device220Geometry(offset: 1_563.3333333333333)
        XCTAssertNil(tracker.geometryChanged(from: resized, to: forward, displayScale: 3))
        let reversed = device220Geometry(offset: 1_529)
        XCTAssertNil(tracker.geometryChanged(from: forward, to: reversed, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .decelerating, geometry: reversed, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: reversed, displayScale: 3))
    }

    func testOldEndClampDoesNotOverrideChangedContentOrLayout() {
        for changed in [
            geometry(
                offset: 1_529, contentHeight: 2_300, containerHeight: 567, top: 106, width: 375),
            geometry(
                offset: 1_529, contentHeight: 2_258, containerHeight: 567, top: 107, width: 375),
            geometry(
                offset: 1_529, contentHeight: 2_258, containerHeight: 567, top: 106, width: 376),
            geometry(
                offset: 1_529, contentHeight: 2_258, containerHeight: 568, top: 106, width: 375),
        ] {
            let tracker = device220PendingTracker()
            let before = device220Geometry(offset: 1_553.3333333333333)
            XCTAssertNil(tracker.geometryChanged(from: before, to: changed, displayScale: 3))
            let restored = device220Geometry(offset: 1_529)
            XCTAssertNil(tracker.geometryChanged(from: changed, to: restored, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: restored, displayScale: 3))
        }
    }

    private func device220PendingTracker() -> FoundationScrollEndTracker {
        let tracker = FoundationScrollEndTracker()
        let start = device220Geometry(offset: 1_509.6666666666667, containerHeight: 623)
        let overshot = device220Geometry(offset: 1_553.3333333333333, containerHeight: 623)
        let resized = device220Geometry(offset: 1_553.3333333333333)
        XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: start, displayScale: 3))
        XCTAssertNil(tracker.geometryChanged(from: start, to: overshot, displayScale: 3))
        XCTAssertNil(tracker.geometryChanged(from: overshot, to: resized, displayScale: 3))
        return tracker
    }

    private func device220Geometry(
        offset: CGFloat, containerHeight: CGFloat = 567
    ) -> FoundationScrollEndGeometry {
        geometry(
            offset: offset, contentHeight: 2_258, containerHeight: containerHeight,
            bottom: 83, top: 106, width: 375)
    }

    func testNonIdleResizeIsReconciledAtIdleWithoutAnotherGeometryCallback() {
        let tracker = FoundationScrollEndTracker()
        XCTAssertNil(
            tracker.phaseChanged(to: .interacting, geometry: geometry(offset: 289), displayScale: 3)
        )
        XCTAssertNil(
            tracker.phaseChanged(
                to: .decelerating, geometry: geometry(offset: 426), displayScale: 3))
        XCTAssertNil(
            tracker.geometryChanged(
                from: geometry(offset: 426),
                to: geometry(offset: 400, containerHeight: 573), displayScale: 3))
        // No further geometry callback occurs after the native viewport change.
        XCTAssertEqual(
            tracker.phaseChanged(
                to: .idle, geometry: geometry(containerHeight: 573, bottom: 139), displayScale: 3),
            1_064)
    }

    func testIdleContextFirstResizeWithReboundDriftDoesNotReplayLaterGeometry() {
        let tracker = deceleratingTracker()
        let final = geometry(containerHeight: 573, bottom: 139)
        XCTAssertEqual(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3), 1_064)
        XCTAssertNil(
            tracker.geometryChanged(from: geometry(offset: 426), to: final, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3))
        let corrected = geometry(offset: 435, containerHeight: 573, bottom: 139)
        XCTAssertNil(tracker.geometryChanged(from: final, to: corrected, displayScale: 3))
        XCTAssertNil(
            tracker.geometryChanged(
                from: corrected,
                to: geometry(offset: 435, contentHeight: 1_210, containerHeight: 573, bottom: 139),
                displayScale: 3))
    }

    func testPendingSplitInsetsConsumeOnceInEitherCallbackOrder() {
        for geometryFirst in [true, false] {
            let tracker = pendingTracker()
            let before = geometry(offset: 400, containerHeight: 573)
            let final = geometry(containerHeight: 573, bottom: 139)
            if geometryFirst {
                XCTAssertNil(tracker.geometryChanged(from: before, to: final, displayScale: 3))
            }
            XCTAssertEqual(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3), 1_064)
            XCTAssertNil(tracker.geometryChanged(from: before, to: final, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3))
        }
    }

    func testViewportShrinkWhileOvershootingWaitsForReboundToSettle() {
        let tracker = deceleratingTracker(overshoot: 549)
        let resized = geometry(offset: 530, containerHeight: 573)
        XCTAssertGreaterThan(resized.unobscuredBottom, resized.contentSize.height)
        XCTAssertNil(
            tracker.geometryChanged(from: geometry(offset: 549), to: resized, displayScale: 3))
        XCTAssertEqual(
            tracker.phaseChanged(
                to: .idle, geometry: geometry(containerHeight: 573, bottom: 139), displayScale: 3),
            1_064)
    }

    func testInteractingReverseInvalidatesWholeGestureWithoutRearming() {
        let tracker = FoundationScrollEndTracker()
        XCTAssertNil(
            tracker.phaseChanged(to: .interacting, geometry: geometry(offset: 426), displayScale: 3)
        )
        let resized = geometry(offset: 440, containerHeight: 573)
        XCTAssertNil(
            tracker.geometryChanged(from: geometry(offset: 426), to: resized, displayScale: 3))
        let reversed = geometry(offset: 420, containerHeight: 573)
        XCTAssertNil(tracker.geometryChanged(from: resized, to: reversed, displayScale: 3))
        let overshotAgain = geometry(offset: 500, containerHeight: 550, bottom: 162)
        XCTAssertNil(tracker.geometryChanged(from: reversed, to: overshotAgain, displayScale: 3))
        XCTAssertNil(
            tracker.phaseChanged(to: .decelerating, geometry: overshotAgain, displayScale: 3))
        XCTAssertNil(
            tracker.phaseChanged(
                to: .idle, geometry: geometry(containerHeight: 550, bottom: 162), displayScale: 3))
    }

    func testFreshInteractionOrProgrammaticAnimationCancelsPendingEnd() {
        for next: ScrollPhase in [.tracking, .interacting, .animating] {
            let tracker = pendingTracker()
            XCTAssertNil(
                tracker.phaseChanged(
                    to: next, geometry: geometry(offset: 400, containerHeight: 573), displayScale: 3
                ))
            let final = geometry(containerHeight: 573, bottom: 139)
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: geometry(), to: final, displayScale: 3))
        }
    }

    func testChangedThenRestoredContentOrLayoutCannotRevivePendingEnd() {
        for changed in [
            geometry(contentHeight: 1_210, containerHeight: 573, bottom: 139),
            geometry(containerHeight: 573, bottom: 139, containerWidth: 430),
            geometry(containerHeight: 573, bottom: 139, top: 80),
            geometry(),
        ] {
            let tracker = pendingTracker()
            let before = geometry(offset: 400, containerHeight: 573)
            let restored = geometry(containerHeight: 573, bottom: 139)
            XCTAssertNil(tracker.geometryChanged(from: before, to: changed, displayScale: 3))
            XCTAssertNil(tracker.geometryChanged(from: changed, to: restored, displayScale: 3))
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: restored, displayScale: 3))
        }
    }

    func testIdleLossMustBeBoundedByViewportShrinkAndStillNeedCorrection() {
        for final in [
            geometry(containerHeight: 573, bottom: 139, visibleMaxY: 1_103),
            geometry(offset: 435, containerHeight: 573, bottom: 139),
            geometry(offset: 300, containerHeight: 573, bottom: 139),
        ] {
            let tracker = pendingTracker()
            XCTAssertNil(tracker.phaseChanged(to: .idle, geometry: final, displayScale: 3))
        }
    }

    func testResizeBeforeFirstEndDoesNotInventGestureEndOwnership() {
        let tracker = FoundationScrollEndTracker()
        let before = geometry(offset: 100)
        XCTAssertNil(tracker.phaseChanged(to: .interacting, geometry: before, displayScale: 3))
        let resized = geometry(offset: 200, containerHeight: 573)
        XCTAssertNil(tracker.geometryChanged(from: before, to: resized, displayScale: 3))
        let firstEnd = geometry(offset: 500, containerHeight: 573)
        XCTAssertNil(tracker.geometryChanged(from: resized, to: firstEnd, displayScale: 3))
        XCTAssertNil(tracker.phaseChanged(to: .decelerating, geometry: firstEnd, displayScale: 3))
        XCTAssertNil(
            tracker.phaseChanged(
                to: .idle, geometry: geometry(containerHeight: 573, bottom: 139), displayScale: 3))
    }

    func testCapturedNativeExpansionPreservesOnlyExistingEnd() {
        let compact = geometry()
        let expanded = geometry(containerHeight: 573, bottom: 139)
        XCTAssertEqual(compact.unobscuredBottom, 1_064)
        XCTAssertEqual(expanded.unobscuredBottom, 1_008)
        XCTAssertEqual(target(compact, expanded), 1_064)
        XCTAssertNil(target(expanded, compact), "Collapsing chrome must not force a new position")
    }

    func testCapturedSplitViewportThenInsetUpdatesRequestOnePointCorrection() {
        let compact = geometry()
        let resized = geometry(containerHeight: 573)
        XCTAssertEqual(resized.unobscuredBottom, 1_008)
        // Native callbacks first shrink the viewport with the old bottom inset.
        XCTAssertEqual(target(compact, resized), 1_064)
        let insetUpdated = geometry(containerHeight: 573, bottom: 139)
        XCTAssertNil(target(resized, insetUpdated), "The second native update must not repeat work")
        let corrected = geometry(offset: 435, containerHeight: 573)
        let correctedInset = geometry(offset: 435, containerHeight: 573, bottom: 139)
        XCTAssertEqual(correctedInset.unobscuredBottom, 1_064)
        XCTAssertNil(target(corrected, correctedInset))
    }

    func testInitialTopMiddleAndNonScrollableContentDoNotJump() {
        for offset: CGFloat in [-56, 0, 100, 233] {
            XCTAssertNil(
                target(
                    geometry(offset: offset),
                    geometry(offset: offset, containerHeight: 573, bottom: 139)))
        }
        XCTAssertNil(
            target(
                geometry(offset: -56, contentHeight: 500),
                geometry(offset: -56, contentHeight: 500, containerHeight: 573, bottom: 139)))
    }

    func testIndependentContentPublicationAndOtherLayoutChangesDoNotAnchor() {
        let compact = geometry()
        XCTAssertNil(
            target(compact, geometry(contentHeight: 1_210, containerHeight: 573, bottom: 139)))
        XCTAssertNil(
            target(compact, geometry(contentHeight: 918, containerHeight: 573, bottom: 139)))
        XCTAssertNil(target(compact, geometry(containerHeight: 573, bottom: 139, width: 430)))
        XCTAssertNil(target(compact, geometry(containerHeight: 573, bottom: 139, top: 80)))
        XCTAssertNil(target(compact, geometry(offset: 300, containerHeight: 573, bottom: 139)))
        XCTAssertNil(target(compact, geometry(bottom: 139)))
        XCTAssertNil(target(compact, geometry(containerHeight: 573, bottom: 82)))
    }

    func testUserAndProgrammaticScrollingOwnTheirPosition() {
        for phase: ScrollPhase in [.tracking, .interacting, .decelerating, .animating] {
            XCTAssertNil(
                FoundationScrollEndPreservation.targetY(
                    from: geometry(), to: geometry(containerHeight: 573, bottom: 139),
                    phase: phase, displayScale: 3))
        }
    }

    func testDisplayPixelToleranceDoesNotTurnNearEndIntoBottomAnchoring() {
        let expanded = geometry(containerHeight: 573, bottom: 139)
        XCTAssertNotNil(target(geometry(offset: 378.8), expanded))
        XCTAssertNil(target(geometry(offset: 378.5), expanded))
        XCTAssertNil(target(geometry(), geometry(containerHeight: 628.8, bottom: 83.2)))
    }

    private func target(
        _ previous: FoundationScrollEndGeometry, _ current: FoundationScrollEndGeometry
    ) -> CGFloat? {
        FoundationScrollEndPreservation.targetY(
            from: previous, to: current, phase: .idle, displayScale: 3)
    }

    private func deceleratingTracker(overshoot: CGFloat = 426) -> FoundationScrollEndTracker {
        let tracker = FoundationScrollEndTracker()
        XCTAssertNil(
            tracker.phaseChanged(to: .interacting, geometry: geometry(offset: 289), displayScale: 3)
        )
        XCTAssertNil(
            tracker.phaseChanged(
                to: .decelerating, geometry: geometry(offset: overshoot), displayScale: 3))
        return tracker
    }

    private func pendingTracker() -> FoundationScrollEndTracker {
        let tracker = deceleratingTracker()
        XCTAssertNil(
            tracker.geometryChanged(
                from: geometry(offset: 426),
                to: geometry(offset: 400, containerHeight: 573), displayScale: 3))
        return tracker
    }

    private func geometry(
        offset: CGFloat = 379, contentHeight: CGFloat = 1_064,
        containerHeight: CGFloat = 629, bottom: CGFloat = 83, top: CGFloat = 56,
        width: CGFloat = 402, containerWidth: CGFloat? = nil, visibleMaxY: CGFloat? = nil
    ) -> FoundationScrollEndGeometry {
        // Captured live geometry includes both inset regions in visibleRect. The
        // public ScrollGeometry initializer does not reproduce that native snapshot.
        FoundationScrollEndGeometry(
            contentSize: CGSize(width: width, height: contentHeight),
            containerSize: CGSize(width: containerWidth ?? width, height: containerHeight),
            contentOffsetY: offset, insetTop: top, insetBottom: bottom,
            visibleMaxY: visibleMaxY ?? offset + containerHeight + top + bottom)
    }
}
