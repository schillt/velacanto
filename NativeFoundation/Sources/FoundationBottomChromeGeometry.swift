import Observation
import SwiftUI

enum FoundationBottomChromePlacement: Equatable {
    case normal, minimized, unknown
}

struct FoundationBottomChromeMeasurement: Equatable {
    let placement: FoundationBottomChromePlacement
    let frame: CGRect
    let host: CGRect?
}

/// The host is the TabView background extended through the bottom container safe
/// area. It is outside Home's content padding; all frames belong to this root.
enum FoundationBottomChromeLayout {
    static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
    }

    /// The offered frame is measured outside the constrained ScrollView. No
    /// scroll inset or content offset participates in this layout boundary.
    static func viewportHeight(
        offered: CGRect?, host: CGRect?, accessory: FoundationBottomChromeMeasurement?,
        hasQueue: Bool, displayScale: CGFloat
    ) -> CGFloat? {
        guard hasQueue, let offered, valid(offered), let host, valid(host),
            let accessory, accessory.host == host, accessory.placement != .unknown,
            valid(accessory.frame), displayScale.isFinite, displayScale > 0
        else { return nil }
        let pixel = 1 / max(1, displayScale)
        guard offered.minX >= host.minX - pixel, offered.maxX <= host.maxX + pixel,
            offered.minY >= host.minY - pixel, offered.maxY <= host.maxY + pixel,
            accessory.frame.minX >= host.minX - pixel,
            accessory.frame.maxX <= host.maxX + pixel,
            accessory.frame.minY >= host.minY,
            accessory.frame.maxY <= host.maxY + pixel
        else { return nil }
        let height = min(offered.maxY, accessory.frame.minY) - offered.minY
        return height > 0 && height.isFinite ? height : nil
    }

    static func clearance(
        host: CGRect?, accessory: FoundationBottomChromeMeasurement?,
        nativeBottomInset: CGFloat?, displayScale: CGFloat
    ) -> CGFloat {
        guard let host, valid(host), let accessory, accessory.host == host,
            accessory.placement != .unknown, valid(accessory.frame),
            let nativeBottomInset, nativeBottomInset.isFinite, nativeBottomInset >= 0,
            displayScale.isFinite, displayScale > 0
        else { return 0 }
        let pixel = 1 / max(1, displayScale)
        let frame = accessory.frame
        guard frame.minX >= host.minX - pixel, frame.maxX <= host.maxX + pixel,
            frame.minY >= host.minY, frame.maxY <= host.maxY + pixel
        else { return 0 }
        // Native scroll insets already reserve part of the bottom region. Add only
        // the missing extent INSIDE content, so it cannot feed into this inset.
        let missing = max(0, host.maxY - frame.minY - nativeBottomInset)
        return ceil(missing * max(1, displayScale)) / max(1, displayScale)
    }
}

@Observable @MainActor
final class FoundationBottomChromeGeometry {
    private(set) var host: CGRect?
    private(set) var accessory: FoundationBottomChromeMeasurement?
    private(set) var hasAccessory = false

    func setHost(_ frame: CGRect) {
        let value = FoundationBottomChromeLayout.valid(frame) ? frame : nil
        guard host != value else { return }
        host = value
        accessory = nil
    }

    func setAccessory(_ value: FoundationBottomChromeMeasurement) {
        guard hasAccessory, value.host == host else { return }
        accessory = value
    }

    func setEnabled(_ value: Bool) {
        hasAccessory = value
        if !value { accessory = nil }
    }

    func clearance(
        nativeBottomInset: CGFloat?, displayScale: CGFloat, isRelatedSheet: Bool = false
    ) -> CGFloat {
        guard hasAccessory, !isRelatedSheet else { return 0 }
        return FoundationBottomChromeLayout.clearance(
            host: host, accessory: accessory,
            nativeBottomInset: nativeBottomInset, displayScale: displayScale)
    }
}

private struct FoundationBottomChromeGeometryKey: EnvironmentKey {
    static let defaultValue: FoundationBottomChromeGeometry? = nil
}

extension EnvironmentValues {
    var foundationBottomChromeGeometry: FoundationBottomChromeGeometry? {
        get { self[FoundationBottomChromeGeometryKey.self] }
        set { self[FoundationBottomChromeGeometryKey.self] = newValue }
    }
}

#if os(iOS)
    struct FoundationBottomChromeHostProbe: ViewModifier {
        let geometry: FoundationBottomChromeGeometry
        let hasAccessory: Bool

        func body(content: Content) -> some View {
            content
                .environment(\.foundationBottomChromeGeometry, geometry)
                .background {
                    GeometryReader { _ in
                        Color.clear
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .global)
                            } action: {
                                geometry.setHost($0)
                            }
                    }
                    .ignoresSafeArea(.container, edges: .bottom)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onChange(of: hasAccessory, initial: true) { _, value in
                    geometry.setEnabled(value)
                }
        }
    }

    struct FoundationBottomChromeAccessoryProbe: ViewModifier {
        let geometry: FoundationBottomChromeGeometry
        let placement: TabViewBottomAccessoryPlacement?

        private var value: FoundationBottomChromePlacement {
            placement == .inline ? .minimized : placement == .expanded ? .normal : .unknown
        }

        func body(content: Content) -> some View {
            content.background {
                GeometryReader { proxy in
                    Color.clear
                        // Re-read after host resize or queue appearance as well as
                        // accessory movement, even if its frame happens to be equal.
                        .onChange(
                            of: FoundationBottomChromeMeasurement(
                                placement: value, frame: proxy.frame(in: .global),
                                host: geometry.host),
                            initial: true
                        ) { _, measurement in
                            geometry.setAccessory(measurement)
                        }
                        .onChange(of: geometry.hasAccessory) { _, enabled in
                            if enabled {
                                geometry.setAccessory(
                                    .init(
                                        placement: value, frame: proxy.frame(in: .global),
                                        host: geometry.host))
                            }
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
#endif

/// Extra extent belongs to scroll CONTENT, never to the viewport or a painted bar.
private struct FoundationBottomChromeContentClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var foundationBottomChromeContentClearance: CGFloat {
        get { self[FoundationBottomChromeContentClearanceKey.self] }
        set { self[FoundationBottomChromeContentClearanceKey.self] = newValue }
    }
}

private struct FoundationBottomChromeScrollClearance: ViewModifier {
    @Environment(\.foundationBottomChromeGeometry) private var chrome
    @Environment(\.foundationRelatedItemSheet) private var relatedSheet
    @Environment(\.displayScale) private var displayScale
    @State private var nativeBottomInset: CGFloat?
    var isList = false

    private var clearance: CGFloat {
        chrome?.clearance(
            nativeBottomInset: nativeBottomInset, displayScale: displayScale,
            isRelatedSheet: relatedSheet) ?? 0
    }

    @ViewBuilder private func scrollContent(_ content: Content) -> some View {
        if isList {
            content.modifier(FoundationBottomChromeListContentMargin(clearance: clearance))
        } else {
            content
        }
    }

    func body(content: Content) -> some View {
        #if os(iOS)
            scrollContent(content)
                // A nested owner replaces this absolute value; extents never add.
                .environment(
                    \.foundationBottomChromeContentClearance,
                    isList ? 0 : clearance
                )
                .onScrollGeometryChange(for: CGFloat.self) {
                    $0.contentInsets.bottom
                } action: {
                    _, value in
                    // contentMargins contributes to the observed content inset.
                    // Remove exactly the applied margin before resolving missing
                    // chrome extent, so repeated geometry updates cannot accumulate it.
                    let base = value - (isList ? clearance : 0)
                    nativeBottomInset = base.isFinite && base >= 0 ? base : nil
                }
                #if DEBUG && targetEnvironment(simulator)
                    .modifier(
                        FoundationChromeUIScrollProbe(
                            clearance: chrome?.clearance(
                                nativeBottomInset: nativeBottomInset, displayScale: displayScale,
                                isRelatedSheet: relatedSheet) ?? 0,
                            nativeBottomInset: nativeBottomInset))
                #endif
        #else
            content
        #endif
    }
}

private struct FoundationBottomChromeEndPadding: ViewModifier {
    @Environment(\.foundationBottomChromeContentClearance) private var clearance
    func body(content: Content) -> some View {
        content.padding(.bottom, clearance)
    }
}

/// Native scroll-content margins reserve exact extent without a synthetic List
/// row, whose parent-owned minimum height would enlarge small clearances.
struct FoundationBottomChromeListContentMargin: ViewModifier {
    let clearance: CGFloat
    func body(content: Content) -> some View {
        content.contentMargins(.bottom, clearance, for: .scrollContent)
    }
}

extension View {
    func foundationBottomChromeScrollClearance() -> some View {
        modifier(FoundationBottomChromeScrollClearance())
    }
    func foundationBottomChromeListClearance() -> some View {
        modifier(FoundationBottomChromeScrollClearance(isList: true))
    }
    func foundationBottomChromeEndPadding() -> some View {
        modifier(FoundationBottomChromeEndPadding())
    }
}
