import SwiftUI
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import UIKit
#endif

final class FoundationHomeIdleEndPreservationTests: XCTestCase {
    private let host = CGRect(x: 0, y: 106, width: 402, height: 768)
    private var compact: FoundationBottomChromeMeasurement {
        .init(
            placement: .minimized, frame: CGRect(x: 90, y: 800, width: 220, height: 44), host: host)
    }
    private var expanded: FoundationBottomChromeMeasurement {
        .init(placement: .normal, frame: CGRect(x: 21, y: 731, width: 360, height: 56), host: host)
    }
    private func sample(
        height: CGFloat = 768, bottom: CGFloat = 74, offset: CGFloat = 370.3333333333333,
        contentHeight: CGFloat = 1064.3333333333333, width: CGFloat = 402, top: CGFloat = 56
    ) -> FoundationHomeNativeEndSample {
        .init(
            content: CGSize(width: width, height: contentHeight),
            bounds: CGSize(width: width, height: height),
            frame: CGRect(x: 0, y: 106, width: width, height: height),
            offsetY: offset, top: top, bottom: bottom)
    }
    private func seed() -> FoundationHomeIdleEndDecision {
        var policy = FoundationHomeIdleEndDecision()
        XCTAssertNil(
            policy.observe(sample(), chrome: compact, revision: 1, idle: true, pixel: 1 / 3))
        return policy
    }
    private func observe(
        _ policy: inout FoundationHomeIdleEndDecision, _ value: FoundationHomeNativeEndSample,
        chrome: FoundationBottomChromeMeasurement? = nil, revision: UInt64 = 1, idle: Bool = true
    ) -> CGFloat? {
        policy.observe(
            value, chrome: chrome ?? expanded, revision: revision, idle: idle, pixel: 1 / 3)?
            .targetY
    }

    private func seedContentClearance() -> FoundationHomeIdleEndDecision {
        var policy = FoundationHomeIdleEndDecision()
        XCTAssertNil(
            policy.observe(
                sample(), chrome: compact, revision: 1, idle: true, pixel: 1 / 3,
                contentClearance: 0))
        return policy
    }

    private var expandedContentSample: FoundationHomeNativeEndSample {
        sample(contentHeight: 1133.3333333333333)
    }

    func testContentExtentPreservesFullNativeViewportAndEndThroughExpansion() {
        var policy = seedContentClearance()
        let request = policy.observe(
            expandedContentSample, chrome: expanded, revision: 1, idle: true,
            pixel: 1 / 3, contentClearance: 69)
        XCTAssertNotNil(request)
        XCTAssertEqual(request?.targetY ?? 0, 439.33333333333326, accuracy: 0.001)
        XCTAssertEqual(request?.sample.frame, sample().frame)
        XCTAssertGreaterThan(expandedContentSample.frame.maxY, expanded.frame.minY)
        XCTAssertEqual(
            request?.validate(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69), .apply)
        XCTAssertNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
    }

    func testContentExtentWaitsForMeasuredSpacerWithoutConsumingEnd() {
        var policy = seedContentClearance()
        XCTAssertNil(
            policy.observe(
                sample(), chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 0))
        XCTAssertNil(
            policy.observe(
                sample(), chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
        XCTAssertNotNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
    }

    func testContentExtentRejectsUnrelatedGrowthAndNewNaturalRevision() {
        var policy = seedContentClearance()
        XCTAssertNil(
            policy.observe(
                sample(contentHeight: 1200), chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
        XCTAssertNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
        policy = seedContentClearance()
        XCTAssertNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 2, idle: true,
                pixel: 1 / 3, contentClearance: 69))
    }

    func testContentExtentNeverPullsDeliberateUpwardScrollingBackToEnd() {
        var policy = seedContentClearance()
        XCTAssertNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 1, idle: false,
                pixel: 1 / 3, contentClearance: 69))
        XCTAssertNil(
            policy.observe(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 69))
    }

    func testContentExtentRequestRejectsChangedClearanceBeforeDeferredApply() {
        var policy = seedContentClearance()
        let request = policy.observe(
            expandedContentSample, chrome: expanded, revision: 1, idle: true,
            pixel: 1 / 3, contentClearance: 69)
        XCTAssertEqual(
            request?.validate(
                expandedContentSample, chrome: expanded, revision: 1, idle: true,
                pixel: 1 / 3, contentClearance: 68), .invalid)
    }

    func testNativeInsetCompensationAndContentExtentAreNotDoubleApplied() {
        var policy = seedContentClearance()
        let native = sample(bottom: 143, offset: 439.33333333333326)
        let request = policy.observe(
            native, chrome: expanded, revision: 1, idle: true, pixel: 1 / 3,
            contentClearance: 0)
        XCTAssertEqual(
            request?.validate(
                native, chrome: expanded, revision: 1, idle: true, pixel: 1 / 3,
                contentClearance: 0), .alreadyAtEnd)
    }

    func testCapturedRetainedOldEndProducesOneCurrentNativeEnd() {
        var policy = seed()
        XCTAssertEqual(observe(&policy, sample(height: 625, bottom: 0)), 439.33333333333326)
    }

    func testCapturedNativeInsetCompensationIsAnExactAlternative() {
        var policy = seed()
        let compensated = sample(height: 625, bottom: 0, offset: 296.3333333333333)
        XCTAssertEqual(observe(&policy, compensated), 439.33333333333326)
    }

    func testChromeCallbackBeforeNativeLayoutWaitsWithoutConsuming() {
        var policy = seed()
        XCTAssertNil(observe(&policy, sample()))
        XCTAssertEqual(observe(&policy, sample(height: 625, bottom: 0)), 439.33333333333326)
    }

    func testNativeLayoutBeforeChromeCallbackWaitsWithoutConsuming() {
        var policy = seed()
        let value = sample(height: 625, bottom: 0, offset: 296.3333333333333)
        XCTAssertNil(observe(&policy, value, chrome: compact))
        XCTAssertEqual(observe(&policy, value), 439.33333333333326)
    }

    func testNonIdleInteractionCancelsPendingRatherThanDeferringIt() {
        var policy = seed()
        XCTAssertNil(observe(&policy, sample()))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0), idle: false))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
    }

    func testContentRevisionWidthAndTopChangesCancel() {
        for changed in [
            sample(height: 625, bottom: 0, contentHeight: 1200),
            sample(height: 625, bottom: 0, width: 430),
            sample(height: 625, bottom: 0, top: 60),
        ] {
            var policy = seed()
            XCTAssertNil(observe(&policy, changed))
            XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
        }
        var policy = seed()
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0), revision: 2))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0), revision: 3))
    }

    func testUserAwayOffsetsAreNotTreatedAsAnAllowedInterval() {
        for offset in [CGFloat(0), 297.3333333333333, 369.3333333333333, 400] {
            var policy = seed()
            XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0, offset: offset)))
            XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
        }
    }

    func testInitialTopAndMissingChromeDoNotAcquireEndOwnership() {
        var policy = FoundationHomeIdleEndDecision()
        XCTAssertNil(observe(&policy, sample(offset: -56), chrome: compact))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
        policy = seed()
        XCTAssertNil(policy.observe(sample(), chrome: nil, revision: 1, idle: true, pixel: 1 / 3))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
    }

    func testCorrectionIsConsumedBeforeReentrantAndLaterEvents() {
        var policy = seed()
        XCTAssertNotNil(observe(&policy, sample(height: 625, bottom: 0)))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
        let corrected = sample(height: 625, bottom: 0, offset: 439.33333333333326)
        XCTAssertNil(observe(&policy, corrected))
        XCTAssertNil(observe(&policy, corrected))
    }

    func testFreshUserTrackingAndExplicitCancellationReleaseEndOwnership() {
        var policy = seed()
        policy.cancel()
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0)))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0, offset: 200), idle: false))
        XCTAssertNil(observe(&policy, sample(height: 625, bottom: 0, offset: 200)))
    }

    #if os(iOS)
        @MainActor private final class Queue {
            var operations: [FoundationHomeIdleEndPreserver.Operation] = []
            func runOne() throws {
                let operation = try XCTUnwrap(operations.first)
                operations.removeFirst()
                operation()
            }
        }

        @MainActor private func withAttachedOwner(
            _ body: (UIScrollView, FoundationHomeIdleEndPreserver, Queue) throws -> Void
        ) throws {
            let scene = try XCTUnwrap(
                UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                    .first { $0.activationState == .foregroundActive })
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 402, height: 900)
            let controller = UIViewController()
            window.rootViewController = controller
            window.isHidden = false
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            let scroll = UIScrollView(frame: CGRect(x: 0, y: 106, width: 402, height: 768))
            scroll.contentInsetAdjustmentBehavior = .never
            scroll.contentSize = CGSize(width: 402, height: 1064.3333333333333)
            scroll.contentInset = UIEdgeInsets(top: 56, left: 0, bottom: 74, right: 0)
            scroll.contentOffset = CGPoint(x: 0, y: 370.3333333333333)
            controller.view.addSubview(scroll)
            let queue = Queue()
            let owner = FoundationHomeIdleEndPreserver(enqueue: { queue.operations.append($0) })
            let bridge = FoundationHomeIdleEndView(owner: owner)
            scroll.addSubview(bridge)
            owner.configure(chrome: compact, revision: 1, displayScale: 3, enabled: true)
            owner.observe()
            XCTAssertTrue(scroll.window === window)
            try body(scroll, owner, queue)
        }

        @MainActor private func queueTransition(
            _ scroll: UIScrollView, _ owner: FoundationHomeIdleEndPreserver, _ queue: Queue
        ) {
            scroll.frame.size.height = 625
            scroll.contentInset.bottom = 0
            scroll.contentOffset.y = 296.3333333333333
            owner.configure(chrome: expanded, revision: 1, displayScale: 3, enabled: true)
            owner.observe()
            XCTAssertEqual(queue.operations.count, 1)
            XCTAssertEqual(owner.correctionCount, 0, "No synchronous setter is allowed")
            XCTAssertEqual(scroll.contentOffset.y, 296.3333333333333, accuracy: 1 / 3)
        }

        @MainActor func testQueuedAttachedCorrectionUsesRestoredOffsetAndNeverRetries() throws {
            try withAttachedOwner { scroll, owner, queue in
                queueTransition(scroll, owner, queue)
                // Replay the subsequent framework restoration before queued execution.
                scroll.contentOffset.y = 370.3333333333333
                owner.observe()
                XCTAssertEqual(queue.operations.count, 1)
                try queue.runOne()
                XCTAssertEqual(scroll.contentOffset.y, 439.33333333333326, accuracy: 1 / 3)
                XCTAssertEqual(owner.correctionCount, 1)
                XCTAssertFalse(scroll.isDragging || scroll.isTracking || scroll.isDecelerating)
                // If the framework wins again, the prototype must not chain a retry.
                scroll.contentOffset.y = 370.3333333333333
                owner.observe()
                XCTAssertEqual(owner.correctionCount, 1)
                XCTAssertTrue(queue.operations.isEmpty)
                XCTAssertEqual(scroll.contentOffset.y, 370.3333333333333, accuracy: 1 / 3)
            }
        }

        @MainActor func testQueuedCorrectionCancelsAcrossEveryNonIdlePhase() throws {
            for phase in [ScrollPhase.tracking, .interacting, .decelerating, .animating] {
                try withAttachedOwner { scroll, owner, queue in
                    queueTransition(scroll, owner, queue)
                    owner.phaseChanged(phase)
                    owner.phaseChanged(.idle)
                    try queue.runOne()
                    XCTAssertEqual(owner.correctionCount, 0)
                    XCTAssertTrue(queue.operations.isEmpty)
                }
            }
        }

        @MainActor func testQueuedCorrectionRevalidatesGeometryAndContentWithoutCallback() throws {
            let mutations: [(UIScrollView) -> Void] = [
                { $0.frame.size.height -= 1 },
                { $0.contentSize.height += 100 },
                { $0.contentInset.top += 1 },
                { $0.frame.origin.y += 1 },
            ]
            for mutate in mutations {
                try withAttachedOwner { scroll, owner, queue in
                    queueTransition(scroll, owner, queue)
                    mutate(scroll)
                    // No observe callback: execution itself must detect invalidity.
                    try queue.runOne()
                    XCTAssertEqual(owner.correctionCount, 0)
                    XCTAssertTrue(queue.operations.isEmpty)
                }
            }
        }

        @MainActor func testQueuedCorrectionRejectsNewAwayPositionWithoutCallback() throws {
            try withAttachedOwner { scroll, owner, queue in
                queueTransition(scroll, owner, queue)
                scroll.contentOffset.y = 200
                try queue.runOne()
                XCTAssertEqual(owner.correctionCount, 0)
                XCTAssertEqual(scroll.contentOffset.y, 200, accuracy: 1 / 3)
            }
        }

        @MainActor func testQueuedCorrectionCancelsRevisionScopeChromeAndScaleChanges() throws {
            for change in 0..<4 {
                try withAttachedOwner { scroll, owner, queue in
                    queueTransition(scroll, owner, queue)
                    owner.configure(
                        chrome: change == 2 ? compact : expanded,
                        revision: change == 0 ? 2 : 1,
                        displayScale: change == 3 ? 2 : 3, enabled: change != 1)
                    try queue.runOne()
                    XCTAssertEqual(owner.correctionCount, 0)
                    XCTAssertTrue(queue.operations.isEmpty)
                }
            }
        }

        @MainActor func testQueuedCorrectionIsNoopWhenFrameworkAlreadyReachedCurrentEnd() throws {
            try withAttachedOwner { scroll, owner, queue in
                queueTransition(scroll, owner, queue)
                scroll.contentOffset.y = 439.33333333333326
                owner.observe()
                try queue.runOne()
                XCTAssertEqual(owner.correctionCount, 0)
                XCTAssertEqual(scroll.contentOffset.y, 439.33333333333326, accuracy: 1 / 3)
                XCTAssertTrue(queue.operations.isEmpty)
            }
        }

        @MainActor func testQueuedCorrectionCannotMutateDetachedWindowOrReplacedScroll() throws {
            for detachWindow in [true, false] {
                try withAttachedOwner { scroll, owner, queue in
                    queueTransition(scroll, owner, queue)
                    if detachWindow {
                        scroll.removeFromSuperview()
                    } else {
                        owner.attach(UIScrollView())
                    }
                    try queue.runOne()
                    XCTAssertEqual(owner.correctionCount, 0)
                    XCTAssertTrue(queue.operations.isEmpty)
                }
            }
        }
    #endif
}
