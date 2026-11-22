#if os(macOS)
    import AppKit
    import SwiftUI
    import XCTest

    @testable import VelacantoFoundation

    @MainActor
    extension FoundationPresentationTests {
        func testOverviewSheetResetsImmersiveForegroundAndNativeBarAppearance() async throws {
            for scheme in [ColorScheme.light, .dark] {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                // Match the actual immersive host's native and preferred dark appearance while
                // requesting each semantic browsing scheme for the reading sheet.
                let parentAppearance: NSAppearance.Name = .darkAqua
                window.appearance = NSAppearance(named: parentAppearance)
                let beganSheet = expectation(
                    for: NSPredicate { _, _ in
                        MainActor.assumeIsolated {
                            guard let sheet = window.attachedSheet, let content = sheet.contentView
                            else { return false }
                            return sheet.isVisible && content.bounds.width > 0
                                && content.bounds.height > 0
                        }
                    }, evaluatedWith: window)
                window.contentView = NSHostingView(
                    rootView: FoundationOverviewAppearanceHost(scheme: scheme))
                window.orderFront(nil)
                defer { window.close() }
                await fulfillment(of: [beganSheet], timeout: 5)
                let sheet = try XCTUnwrap(window.attachedSheet)
                let content = try XCTUnwrap(sheet.contentView)
                content.layoutSubtreeIfNeeded()
                content.displayIfNeeded()
                XCTAssertEqual(
                    window.appearance?.name, parentAppearance, "The presenter is unchanged")
                let bitmap = try XCTUnwrap(
                    content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                let image = NSImage(size: content.bounds.size)
                image.addRepresentation(bitmap)
                let attachment = XCTAttachment(image: image)
                attachment.name =
                    "Native Mac overview \(scheme) from preferred dark native window appearance"
                attachment.lifetime = .keepAlways
                add(attachment)
                // Include the native frame as well: the reading view alone can omit the sheet's
                // title and confirmation chrome. Review this capture in both appearances.
                let frameView = content.superview ?? content
                frameView.layoutSubtreeIfNeeded()
                frameView.displayIfNeeded()
                let frameBitmap = try XCTUnwrap(
                    frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
                frameView.cacheDisplay(in: frameView.bounds, to: frameBitmap)
                let frameImage = NSImage(size: frameView.bounds.size)
                frameImage.addRepresentation(frameBitmap)
                let chrome = XCTAttachment(image: frameImage)
                chrome.name =
                    "Native Mac overview \(scheme) full sheet frame and confirmation chrome"
                chrome.lifetime = .keepAlways
                add(chrome)
                let footerColor = try XCTUnwrap(
                    frameBitmap.colorAt(
                        x: frameBitmap.pixelsWide / 8,
                        y: frameBitmap.pixelsHigh - frameBitmap.pixelsHigh / 25
                    )?.usingColorSpace(.sRGB))
                let footerLuma =
                    0.2126 * footerColor.redComponent
                    + 0.7152 * footerColor.greenComponent + 0.0722 * footerColor.blueComponent
                if scheme == .light {
                    XCTAssertGreaterThan(footerLuma, 0.7, "Reading footer must follow Light")
                } else {
                    XCTAssertLessThan(footerLuma, 0.3, "Reading footer must follow Dark")
                }

                // Sample only the reading interior, excluding native chrome, edges and scrollbar.
                // White-on-white inherited text cannot satisfy this contrast check.
                var foregroundPixels = 0
                var backgroundPixels = 0
                for y in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 2) {
                    for x in stride(
                        from: bitmap.pixelsWide / 8, to: bitmap.pixelsWide * 7 / 8, by: 2)
                    {
                        let color = try XCTUnwrap(
                            bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                        let luma =
                            0.2126 * color.redComponent + 0.7152 * color.greenComponent
                            + 0.0722 * color.blueComponent
                        if scheme == .light ? luma < 0.35 : luma > 0.65 {
                            foregroundPixels += 1
                        }
                        if scheme == .light ? luma > 0.8 : luma < 0.2 {
                            backgroundPixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(
                    foregroundPixels, 100, "Overview words must contrast with the sheet")
                XCTAssertGreaterThan(
                    backgroundPixels, 1000, "The reading surface must follow \(scheme)")
                let dismissed = expectation(
                    for: NSPredicate { _, _ in
                        MainActor.assumeIsolated { window.attachedSheet == nil }
                    }, evaluatedWith: window)
                let returnKey = try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: sheet.windowNumber, context: nil, characters: "\r",
                        charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
                XCTAssertTrue(
                    sheet.performKeyEquivalent(with: returnKey),
                    "Return must invoke the reading footer's default Done action")
                await fulfillment(of: [dismissed], timeout: 5)
            }
        }

    }

    private struct FoundationOverviewAppearanceHost: View {
        let scheme: ColorScheme
        @State private var presented = false

        var body: some View {
            Color.black
                .sheet(isPresented: $presented) {
                    FoundationOverviewSheet(
                        item: .init(
                            id: "synthetic-overview", title: "Synthetic Album", subtitle: "",
                            kind: .album, duration: nil),
                        overview: (1...12).map {
                            "Overview paragraph \($0). Native reading text remains legible when an immersive artwork page uses white controls."
                        }.joined(separator: "\n\n")
                    ) { presented = false }
                }
                .foregroundStyle(Color.white)
                .preferredColorScheme(.dark)
                .environment(\.colorScheme, .dark)
                .environment(\.foundationBrowsingColorScheme, scheme)
                .onAppear { presented = true }
        }
    }

#endif
