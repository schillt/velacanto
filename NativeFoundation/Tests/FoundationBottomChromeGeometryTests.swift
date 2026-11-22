import SwiftUI
import XCTest

@testable import VelacantoFoundation

#if os(iOS)
    import UIKit
#endif

@MainActor
final class FoundationBottomChromeGeometryTests: XCTestCase {
    // Contract fixture: host includes the bottom container safe area. Its812
    // bottom is synthetic until the next device trace measures that host edge.
    private let host = CGRect(x: 0, y: 0, width: 375, height: 812)
    private let normal = CGRect(x: 21, y: 669, width: 333, height: 56)
    private let minimized = CGRect(x: 90, y: 675, width: 195, height: 44)

    func testViewportBoundsFollowActualAccessoryTopWithoutInsetCompensation() {
        let available = CGRect(x: 0, y: 162, width: 375, height: 650)
        XCTAssertEqual(viewport(available, normal), 507)
        XCTAssertEqual(viewport(available, minimized, placement: .minimized), 513)
        // Native83/139 insets intentionally are not inputs to this new policy.
        XCTAssertEqual(available.minY + viewport(available, normal)!, normal.minY)
    }

    func testViewportIntersectionDoesNotExtendBeyondOfferedFrame() {
        let shorter = CGRect(x: 0, y: 162, width: 375, height: 400)
        XCTAssertEqual(viewport(shorter, normal), 400)
        XCTAssertNil(viewport(CGRect(x: 0, y: 700, width: 375, height: 112), normal))
    }

    func testViewportMissingQueueMeasurementsAndInvalidFramesUseNormalLayout() {
        let available = CGRect(x: 0, y: 162, width: 375, height: 650)
        XCTAssertNil(viewport(available, normal, hasQueue: false))
        XCTAssertNil(viewport(available, normal, placement: .unknown))
        for offered in [CGRect.zero, .null, .infinite, CGRect(x: 0, y: 0, width: 900, height: 812)]
        {
            XCTAssertNil(viewport(offered, normal))
        }
        XCTAssertNil(
            FoundationBottomChromeLayout.viewportHeight(
                offered: available, host: host, accessory: nil, hasQueue: true, displayScale: 3))
        XCTAssertNil(
            FoundationBottomChromeLayout.viewportHeight(
                offered: available, host: nil, accessory: measurement(normal),
                hasQueue: true, displayScale: 3))
        XCTAssertNil(
            FoundationBottomChromeLayout.viewportHeight(
                offered: available, host: host, accessory: measurement(normal),
                hasQueue: true, displayScale: 0))
    }

    func testViewportRejectsStaleRotatedAndOutOfHostChrome() {
        let available = CGRect(x: 0, y: 162, width: 375, height: 650)
        let rotated = CGRect(x: 0, y: 0, width: 812, height: 375)
        XCTAssertNil(
            FoundationBottomChromeLayout.viewportHeight(
                offered: available, host: rotated, accessory: measurement(normal),
                hasQueue: true, displayScale: 3))
        XCTAssertNil(viewport(available, normal.offsetBy(dx: 400, dy: 0)))
        XCTAssertNil(viewport(available, normal.offsetBy(dx: 0, dy: 200)))
    }

    func testViewportUsesLocalFrameForDifferentWindowAndLargerText() {
        let shiftedHost = host.offsetBy(dx: 100, dy: 200)
        let available = CGRect(x: 100, y: 362, width: 375, height: 650)
        let largerChrome = CGRect(x: 121, y: 840, width: 333, height: 75)
        XCTAssertEqual(
            FoundationBottomChromeLayout.viewportHeight(
                offered: available, host: shiftedHost,
                accessory: .init(placement: .normal, frame: largerChrome, host: shiftedHost),
                hasQueue: true, displayScale: 3), 478)
    }

    private func viewport(
        _ offered: CGRect, _ frame: CGRect,
        placement: FoundationBottomChromePlacement = .normal, hasQueue: Bool = true
    ) -> CGFloat? {
        FoundationBottomChromeLayout.viewportHeight(
            offered: offered, host: host, accessory: measurement(frame, placement: placement),
            hasQueue: hasQueue, displayScale: 3)
    }

    func testActualAccessoryTopAndNativeInsetDetermineMissingExtent() {
        // Accessory/viewport dimensions and83→139 inset changes were captured;
        // merely intersecting the567pt SwiftUI viewport would reserve only4pt.
        XCTAssertEqual(reserve(normal, inset: 83), 60)
        XCTAssertEqual(reserve(minimized, inset: 83, placement: .minimized), 54)
        XCTAssertEqual(reserve(normal, inset: 139), 4)
        XCTAssertEqual(reserve(normal, inset: 83), 60)
    }

    func testNativeInsetAlreadyCoveringChromeRequiresNoExtraSpace() {
        XCTAssertEqual(reserve(normal, inset: 143), 0)
        XCTAssertEqual(reserve(normal, inset: 160), 0)
    }

    func testMeasuredZeroInsetIsDistinctFromMissingMeasurement() {
        XCTAssertEqual(reserve(normal, inset: 0), 143)
        XCTAssertEqual(reserve(normal, inset: nil), 0)
    }

    func testUnmeasuredUnknownAndInvalidInputsDoNotReserve() {
        XCTAssertEqual(reserve(normal, inset: 83, placement: .unknown), 0)
        XCTAssertEqual(reserve(.zero, inset: 83), 0)
        XCTAssertEqual(reserve(.null, inset: 83), 0)
        XCTAssertEqual(reserve(.infinite, inset: 83), 0)
        XCTAssertEqual(reserve(normal, inset: .nan), 0)
        XCTAssertEqual(reserve(normal, inset: -.infinity), 0)
        XCTAssertEqual(reserve(normal, inset: -1), 0)
        XCTAssertEqual(
            FoundationBottomChromeLayout.clearance(
                host: nil, accessory: nil, nativeBottomInset: 83, displayScale: 3), 0)
        XCTAssertEqual(
            FoundationBottomChromeLayout.clearance(
                host: host, accessory: measurement(normal), nativeBottomInset: 83,
                displayScale: .nan), 0)
    }

    func testFramesOutsideHostOrFromDifferentHostAreRejected() {
        XCTAssertEqual(reserve(CGRect(x: 400, y: 669, width: 100, height: 56), inset: 83), 0)
        XCTAssertEqual(reserve(CGRect(x: 21, y: 800, width: 333, height: 56), inset: 83), 0)
        XCTAssertEqual(reserve(CGRect(x: 21, y: -10, width: 333, height: 56), inset: 83), 0)
        let otherHost = CGRect(x: 0, y: 0, width: 812, height: 375)
        XCTAssertEqual(
            FoundationBottomChromeLayout.clearance(
                host: otherHost, accessory: measurement(normal), nativeBottomInset: 83,
                displayScale: 3), 0)
    }

    func testRelatedHalfSheetDoesNotReserveForUnderlyingRootAccessory() {
        let owner = readyOwner()
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 60)
        XCTAssertEqual(
            owner.clearance(
                nativeBottomInset: 83, displayScale: 3, isRelatedSheet: true), 0)
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 60)
    }

    func testQueueRemovalClearsMeasurementAndReappearanceNeedsFreshFrame() {
        let owner = readyOwner()
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 60)
        owner.setEnabled(false)
        XCTAssertNil(owner.accessory)
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 0)
        owner.setEnabled(true)
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 0)
        owner.setAccessory(measurement(minimized, placement: .minimized))
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 54)
    }

    func testRotationClearsOldFrameUntilMeasuredAgainstNewHost() {
        let owner = readyOwner()
        let rotated = CGRect(x: 0, y: 0, width: 812, height: 375)
        owner.setHost(rotated)
        XCTAssertNil(owner.accessory)
        owner.setAccessory(measurement(normal))
        XCTAssertNil(owner.accessory)
        owner.setAccessory(
            .init(
                placement: .normal, frame: CGRect(x: 21, y: 280, width: 770, height: 56),
                host: rotated))
        XCTAssertEqual(owner.clearance(nativeBottomInset: 34, displayScale: 3), 61)
    }

    func testRepeatedHostObservationDoesNotDiscardValidFrame() {
        let owner = readyOwner()
        owner.setHost(host)
        XCTAssertEqual(owner.clearance(nativeBottomInset: 83, displayScale: 3), 60)
    }

    func testActualLargerTextFrameChangesClearanceWithoutFontOrHeightConstants() {
        let larger = CGRect(x: 21, y: 650, width: 333, height: 75)
        XCTAssertEqual(reserve(larger, inset: 83), 79)
        let moved = CGRect(x: 21, y: 640, width: 333, height: 75)
        XCTAssertEqual(reserve(moved, inset: 83), 89)
    }

    func testDifferentWindowOriginUsesSameLocalHostRelationship() {
        let shifted = CGRect(x: 100, y: 200, width: 375, height: 812)
        let frame = normal.offsetBy(dx: 100, dy: 200)
        XCTAssertEqual(
            FoundationBottomChromeLayout.clearance(
                host: shifted, accessory: .init(placement: .normal, frame: frame, host: shifted),
                nativeBottomInset: 83, displayScale: 3), 60)
    }

    func testNaturalEndIdentityChangesForIndependentContentPublication() {
        let before = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_064), displayScale: 3)
        let after = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_700), displayScale: 3)
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after)
    }

    func testNaturalEndIdentityRetiresOnWidthAndDisplayScaleChange() {
        let before = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_064), displayScale: 3)
        XCTAssertNotEqual(
            before,
            FoundationHomeNaturalExtent(size: CGSize(width: 430, height: 1_064), displayScale: 3))
        XCTAssertNotEqual(
            before,
            FoundationHomeNaturalExtent(size: CGSize(width: 402, height: 1_064), displayScale: 2))
    }

    func testNaturalEndIdentityQuantizesOnlyLocalPixelNoise() {
        let before = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_064), displayScale: 3)
        XCTAssertEqual(
            before,
            FoundationHomeNaturalExtent(size: CGSize(width: 402, height: 1_064.1), displayScale: 3))
        XCTAssertNotEqual(
            before,
            FoundationHomeNaturalExtent(size: CGSize(width: 402, height: 1_064.34), displayScale: 3)
        )
    }

    func testUnmeasuredOrInvalidNaturalLayoutHasNoEndIdentity() {
        for size in [
            CGSize.zero, CGSize(width: 402, height: CGFloat.nan),
            CGSize(width: 402, height: CGFloat.infinity),
            CGSize(width: 402, height: CGFloat.greatestFiniteMagnitude),
        ] {
            XCTAssertNil(FoundationHomeNaturalExtent(size: size, displayScale: 3))
        }
        XCTAssertNil(
            FoundationHomeNaturalExtent(size: CGSize(width: 402, height: 1_064), displayScale: 0))
    }

    func testNaturalExtentReturnDoesNotResurrectRemovedEndIdentity() {
        let first = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_064), displayScale: 3)
        let published = FoundationHomeNaturalExtent(
            size: CGSize(width: 402, height: 1_700), displayScale: 3)
        var state = FoundationHomeNaturalLayout()
        state.update(first)
        let original = state.revision
        state.update(first)
        XCTAssertEqual(state.revision, original, "Unchanged natural layout preserves its revision")
        state.update(published)
        XCTAssertNotEqual(state.revision, original)
        state.update(first)
        XCTAssertNotEqual(state.revision, original, "A→B→A must not reuse the earlier revision")
        let returned = state.revision
        state.update(nil)
        XCTAssertNil(state.extent)
        state.update(first)
        XCTAssertNotEqual(state.revision, returned, "Invalidity also retires an incarnation")
    }

    private func measurement(
        _ frame: CGRect, placement: FoundationBottomChromePlacement = .normal
    ) -> FoundationBottomChromeMeasurement {
        .init(placement: placement, frame: frame, host: host)
    }

    private func reserve(
        _ frame: CGRect, inset: CGFloat?, placement: FoundationBottomChromePlacement = .normal
    ) -> CGFloat {
        FoundationBottomChromeLayout.clearance(
            host: host, accessory: measurement(frame, placement: placement),
            nativeBottomInset: inset, displayScale: 3)
    }

    private func readyOwner() -> FoundationBottomChromeGeometry {
        let owner = FoundationBottomChromeGeometry()
        owner.setHost(host)
        owner.setEnabled(true)
        owner.setAccessory(measurement(normal))
        return owner
    }

    #if os(iOS)
        private static let nativeFooterMarkerTag = 0x06C071

        private struct NativeFooterMarker: UIViewRepresentable {
            func makeUIView(context: Context) -> UIView {
                let view = UIView(frame: .zero)
                view.tag = FoundationBottomChromeGeometryTests.nativeFooterMarkerTag
                view.backgroundColor = .clear
                view.isUserInteractionEnabled = false
                return view
            }
            func updateUIView(_ uiView: UIView, context: Context) {}
        }

        private struct NativeFooterRendering: View {
            let clearance: CGFloat
            var body: some View {
                List {
                    ForEach(0..<3) { index in
                        Text("Natural synthetic row \(index)").frame(minHeight: 80)
                    }
                }
                .listStyle(.plain)
                .modifier(FoundationBottomChromeListContentMargin(clearance: clearance))
            }
        }

        private func actualFooterCell(_ window: UIWindow) -> UIView? {
            guard let marker = window.viewWithTag(Self.nativeFooterMarkerTag) else { return nil }
            var parent = marker.superview
            while let view = parent {
                if view is UICollectionViewCell || view is UITableViewCell { return view }
                parent = view.superview
            }
            return nil
        }

        private func actualNativeRowHeights(_ window: UIWindow) -> [CGFloat]? {
            var queue = window.subviews
            var visited = 0
            while !queue.isEmpty, visited < 4096 {
                let view = queue.removeLast()
                visited += 1
                if let list = view as? UICollectionView {
                    list.layoutIfNeeded()
                    var heights: [CGFloat] = []
                    for section in 0..<list.numberOfSections {
                        for item in 0..<list.numberOfItems(inSection: section) {
                            guard
                                let attributes = list.layoutAttributesForItem(
                                    at: IndexPath(item: item, section: section))
                            else { return nil }
                            heights.append(attributes.frame.height)
                        }
                    }
                    if !heights.isEmpty { return heights }
                } else if let list = view as? UITableView {
                    list.layoutIfNeeded()
                    var heights: [CGFloat] = []
                    for section in 0..<list.numberOfSections {
                        for row in 0..<list.numberOfRows(inSection: section) {
                            heights.append(
                                list.rectForRow(at: IndexPath(row: row, section: section)).height)
                        }
                    }
                    if !heights.isEmpty { return heights }
                }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func checkRenderedNativeFooter(_ clearance: CGFloat) async throws {
            guard
                let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }
                )
                .first(where: { $0.activationState == .foregroundActive })
            else {
                throw XCTSkip(
                    "A foreground test-host window scene is required; no native row measurement")
            }
            let oldKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: NativeFooterRendering(clearance: 0))
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                oldKeyWindow?.makeKey()
            }
            let epsilon = 1 / max(1, window.traitCollection.displayScale)
            func nativeScroll() -> UIScrollView? {
                var queue = window.subviews
                while let view = queue.popLast() {
                    if let scroll = view as? UIScrollView,
                        scroll is UICollectionView || scroll is UITableView
                    {
                        return scroll
                    }
                    queue.append(contentsOf: view.subviews)
                }
                return nil
            }
            func observe() async throws -> (CGFloat, [CGFloat]) {
                let deadline = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < deadline {
                    window.layoutIfNeeded()
                    host.view.layoutIfNeeded()
                    if let scroll = nativeScroll(), let rows = actualNativeRowHeights(window),
                        rows.count == 3, rows.allSatisfy({ $0 >= 80 }),
                        scroll.contentSize.height > 0
                    {
                        return (
                            scroll.contentSize.height + scroll.adjustedContentInset.top
                                + scroll.adjustedContentInset.bottom, rows
                        )
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw XCTSkip("Actual native List geometry was not realized")
            }
            let baseline = try await observe()
            host.rootView = NativeFooterRendering(clearance: clearance)
            let deadline = ContinuousClock.now + .seconds(5)
            var actual = try await observe()
            while abs((actual.0 - baseline.0) - clearance) > epsilon,
                ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(10))
                actual = try await observe()
            }
            let observation = XCTAttachment(
                string:
                    "C=\(clearance);baselineExtent=\(baseline.0);actualExtent=\(actual.0);"
                    + "baselineRows=\(baseline.1);actualRows=\(actual.1)")
            observation.name = "Native owning-List scroll margin C\(clearance)"
            observation.lifetime = .keepAlways
            add(observation)
            XCTAssertEqual(
                actual.0 - baseline.0, clearance, accuracy: epsilon,
                "Actual native total scroll extent must grow by precisely the requested margin")
            XCTAssertEqual(actual.1, baseline.1, "Natural row sizing must remain unchanged")
        }

        func testRenderedNativeListFooterZeroHasNoExtraRowHeight() async throws {
            try await checkRenderedNativeFooter(0)
        }

        func testRenderedNativeListFooterTwelvePointsAvoidsNativeMinimum() async throws {
            try await checkRenderedNativeFooter(12)
        }

        func testRenderedNativeListFooterSixtyFourPointsMatchesRequestedExtent() async throws {
            try await checkRenderedNativeFooter(64)
        }
    #endif
}
