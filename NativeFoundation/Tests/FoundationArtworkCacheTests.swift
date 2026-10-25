import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import VelacantoFoundation

final class FoundationArtworkCacheTests: XCTestCase {
    func testArtistLogoContrastRespondsToAppearanceAndPreservesReadableOriginals() throws {
        func logo(_ white: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(
                CGColor(
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                    components: [white, white, white, alpha])!)
            context.fill(CGRect(x: 12, y: 4, width: 8, height: 24))
            return try XCTUnwrap(context.makeImage())
        }
        let black = try logo(0)
        let white = try logo(1)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: black, dark: true), .originalOnLight)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: black, dark: false), .original)
        XCTAssertEqual(FoundationArtistLogoContrast.presentation(for: white, dark: true), .original)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: white, dark: false), .originalOnDark)
        let gray = try logo(0.5)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: gray, dark: true), .original)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: gray, dark: false), .original)
        let opaqueContext = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        opaqueContext.setFillColor(
            CGColor(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0.5, 0.5, 0.5, 1])!
        )
        opaqueContext.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let opaque = try XCTUnwrap(opaqueContext.makeImage())
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: opaque, dark: true), .original)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: opaque, dark: false), .original)
        let translucent = try logo(1, alpha: 0.3)
        XCTAssertNotEqual(
            FoundationArtistLogoContrast.presentation(for: translucent, dark: false), .text)
        let empty = try logo(0, alpha: 0)
        XCTAssertEqual(FoundationArtistLogoContrast.presentation(for: empty, dark: true), .text)
    }

    func testArtistLogoRetainsColorsAndChecksTheLocalBackdropRegion() throws {
        func image(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
            let context = try XCTUnwrap(
                CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            draw(context)
            return try XCTUnwrap(context.makeImage())
        }
        func logo(_ color: CGColor) throws -> CGImage {
            try image(width: 32, height: 32) { context in
                context.setFillColor(color)
                context.fill(CGRect(x: 8, y: 4, width: 16, height: 24))
            }
        }
        let colorful = try logo(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: colorful, dark: false), .original)
        let opaqueDesign = try image(width: 32, height: 32) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 8, y: 4, width: 16, height: 24))
        }
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: opaqueDesign, dark: false), .original)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(for: opaqueDesign, dark: true), .original)
        let background = try image(width: 200, height: 100) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        }
        func region(_ x: CGFloat) -> FoundationArtistLogoContrast.Surface {
            .init(
                size: CGSize(width: 200, height: 100),
                logoFrame: CGRect(x: x, y: 0, width: 100, height: 100),
                frostStart: 1, frostEnd: 1, fadeStart: 1)
        }
        let white = try logo(CGColor(gray: 1, alpha: 1))
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: white, dark: true, backdrop: background, surface: region(0)), .originalOnDark)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: white, dark: true, backdrop: background, surface: region(100)), .original)
        let gold = try logo(CGColor(red: 1, green: 0.8, blue: 0.05, alpha: 1))
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: gold, dark: true, backdrop: background, surface: region(0)), .originalOnDark)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: gold, dark: true, backdrop: background, surface: region(100)), .original)
        let frosted = FoundationArtistLogoContrast.Surface(
            size: CGSize(width: 200, height: 100),
            logoFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            frostStart: 0, frostEnd: 0.001, fadeStart: 1)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: white, dark: true, backdrop: background, surface: frosted), .original)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: white, dark: false, backdrop: background, surface: frosted), .originalOnDark)
        XCTAssertEqual(
            FoundationArtistLogoContrast.presentation(
                for: white, dark: true, backdrop: background, surface: frosted,
                reduceTransparency: true), .original)
    }

    func testLogoSupportPreservesColoredArtworkAndRespondsToIncreasedContrast() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.05, alpha: 1))
        context.fill(CGRect(x: 8, y: 4, width: 16, height: 24))
        let gold = try XCTUnwrap(context.makeImage())
        let decision = FoundationArtistLogoContrast.decision(
            for: gold, dark: false, increasedContrast: true)
        XCTAssertEqual(decision.presentation, .originalOnDark)
        XCTAssertEqual(FoundationArtistLogoContrast.supportTint(dark: true), 0.12)
        XCTAssertEqual(FoundationArtistLogoContrast.supportTint(dark: false), 0.96)
        XCTAssertEqual(
            FoundationArtistLogoContrast.supportOpacity(reduceTransparency: true), 1)
    }

    func testMixedLogoRemainsOriginalWhenNoSurfacePassesCoverage() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 8, y: 4, width: 8, height: 24))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 16, y: 4, width: 8, height: 24))
        let logo = try XCTUnwrap(context.makeImage())
        let decision = FoundationArtistLogoContrast.decision(for: logo, dark: true)
        XCTAssertTrue([.originalOnLight, .originalOnDark].contains(decision.presentation))
        XCTAssertEqual(decision.reason, "Original retained with best local support")
    }

    func testOverviewForegroundUsesMeasuredBackdropAndFrostInsteadOfAppearanceAlone() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let backdrop = try XCTUnwrap(context.makeImage())
        func surface(_ x: CGFloat, frost: Double = 1) -> FoundationArtistLogoContrast.Surface {
            .init(
                size: CGSize(width: 200, height: 100),
                logoFrame: CGRect(x: x, y: 0, width: 100, height: 100),
                frostStart: frost, frostEnd: frost == 1 ? 1 : 0.001, fadeStart: 1)
        }
        XCTAssertFalse(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: backdrop, surface: surface(0), dark: true, reduceTransparency: false))
        XCTAssertTrue(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: backdrop, surface: surface(100), dark: false, reduceTransparency: false))
        XCTAssertTrue(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: backdrop, surface: surface(0, frost: 0), dark: true,
                reduceTransparency: true))
        XCTAssertFalse(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: nil, surface: nil, dark: false, reduceTransparency: false))
    }

    func testArtistBackdropLeavesMeasuredControlsClearAcrossHeroLayouts() {
        for (height, controls) in [(CGFloat(600), CGFloat(320)), (900, 390), (480, 400)] {
            let profile = FoundationArtistBackdropProfile(
                height: height, controlsBottom: controls, increasedContrast: false)
            XCTAssertGreaterThanOrEqual(
                profile.start * Double(height), Double(controls + 10) - 0.001)
            XCTAssertEqual(
                FoundationArtistBackdropProfile.eased(
                    Double(controls / height), from: profile.start, to: profile.blurEnd), 0)
            XCTAssertLessThanOrEqual(profile.start, profile.blurEnd)
            XCTAssertLessThanOrEqual(profile.blurEnd, profile.frostEnd)
            XCTAssertLessThan(profile.fadeStart, 1)
        }
        for height: CGFloat in [0, .nan, .infinity] {
            let profile = FoundationArtistBackdropProfile(
                height: height, controlsBottom: nil, increasedContrast: false)
            XCTAssertEqual(profile.start, 1)
            XCTAssertEqual(
                FoundationArtistBackdropProfile.eased(1, from: profile.start, to: profile.blurEnd),
                0)
        }
    }

    func testMacArtistFadeFeathersFromControlsMidpointWhileMobileKeepsItsBoundary() {
        let mobile = FoundationArtistBackdropProfile(
            height: 700, controlsBottom: 400, increasedContrast: false, overviewTop: 440)
        let desktop = FoundationArtistBackdropProfile(
            height: 700, controlsBottom: 400, increasedContrast: false,
            overviewTop: 440, controlsMidpoint: 360)
        XCTAssertEqual(mobile.start * 700, 410, accuracy: 0.001)
        XCTAssertFalse(mobile.smoothPageFade)
        XCTAssertEqual(desktop.start * 700, 360, accuracy: 0.001)
        XCTAssertTrue(desktop.smoothPageFade)
        XCTAssertGreaterThan(
            desktop.readingEnd - desktop.readingStart,
            mobile.readingEnd - mobile.readingStart)
        XCTAssertEqual(
            FoundationArtistBackdropProfile.eased(
                desktop.start, from: desktop.start, to: desktop.frostEnd), 0)
        XCTAssertLessThan(
            FoundationArtistBackdropProfile.eased(
                desktop.start + 0.001, from: desktop.start, to: desktop.frostEnd), 0.001)
    }

    func testArtistReadingFadeProtectsControlsAndReachesOverviewAcrossLayouts() {
        for (height, controls, overview) in [
            (CGFloat(680), CGFloat(350), CGFloat(480)), (900, 390, 430), (1200, 400, 850),
        ] {
            let profile = FoundationArtistBackdropProfile(
                height: height, controlsBottom: controls, increasedContrast: false,
                overviewTop: overview)
            XCTAssertGreaterThanOrEqual(profile.readingStart, profile.start)
            XCTAssertEqual(
                FoundationArtistBackdropProfile.eased(
                    Double(controls / height), from: profile.readingStart, to: profile.readingEnd),
                0)
            XCTAssertEqual(
                FoundationArtistBackdropProfile.eased(
                    Double(overview / height), from: profile.readingStart, to: profile.readingEnd),
                1, accuracy: 0.001)
        }
        let pending = FoundationArtistBackdropProfile(
            height: 700, controlsBottom: 350, increasedContrast: false)
        XCTAssertEqual(pending.readingOpacity, 0)
    }

    func testOverviewSamplingUsesBackdropMaterialStrength() throws {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        let image = try XCTUnwrap(context.makeImage())
        var region = FoundationArtistLogoContrast.Surface(
            size: CGSize(width: 20, height: 20),
            logoFrame: CGRect(x: 0, y: 0, width: 20, height: 20),
            frostStart: 0, frostEnd: 0.001, fadeStart: 1, frostOpacity: 0)
        XCTAssertFalse(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: image, surface: region, dark: true, reduceTransparency: false))
        region.readingStart = 0
        region.readingEnd = 0.001
        region.readingOpacity = 0.72
        XCTAssertTrue(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: image, surface: region, dark: true, reduceTransparency: false))
        region.readingOpacity = 0
        region.frostOpacity = 1
        XCTAssertTrue(
            FoundationArtistLogoContrast.prefersLightText(
                backdrop: image, surface: region, dark: true, reduceTransparency: false))
    }

    func testPreviewFailureRecoveryHonorsCancellationAndAccountFailures() {
        for error: FoundationLibraryError in [.network, .unavailable, .invalidResponse] {
            XCTAssertTrue(FoundationArtworkLoadRecovery.canAttemptTarget(after: error))
        }
        for error: FoundationLibraryError in [
            .cancelled, .authentication, .credentials, .secureConnection, .invalidServer,
        ] {
            XCTAssertFalse(FoundationArtworkLoadRecovery.canAttemptTarget(after: error))
        }
        XCTAssertFalse(
            FoundationArtworkLoadRecovery.canAttemptTarget(after: CancellationError()))
    }

    private func item(
        _ id: String = "album", tag: String? = "v1", kind: FoundationItem.Kind = .album
    )
        -> FoundationItem
    {
        FoundationItem(
            id: id, title: "", subtitle: "", kind: kind, duration: nil, primaryImageTag: tag)
    }

    func testArtistArtworkRevisionChangesPreserveUnchangedSiblingRoleIdentities() throws {
        var original = item("artist", tag: "portrait-v1", kind: .artist)
        original.logoImageTag = "logo-v1"
        original.backdropImageTag = "backdrop-v1"
        let roles: [FoundationItem.ArtworkRole] = [.primary, .logo, .backdrop]
        for changedRole in roles {
            var revised = original
            switch changedRole {
            case .primary: revised.primaryImageTag = "portrait-v2"
            case .logo: revised.logoImageTag = "logo-v2"
            case .backdrop: revised.backdropImageTag = "backdrop-v2"
            }
            for inspectedRole in roles {
                let before = try XCTUnwrap(original.artworkItem(for: inspectedRole))
                let after = try XCTUnwrap(revised.artworkItem(for: inspectedRole))
                let beforeKey = FoundationArtworkCache.key(before, pixels: 640)
                let afterKey = FoundationArtworkCache.key(after, pixels: 640)
                if inspectedRole == changedRole {
                    XCTAssertNotEqual(beforeKey, afterKey)
                } else {
                    XCTAssertEqual(beforeKey, afterKey)
                }
            }
        }
    }

    func testArtistHydrationDoesNotMaskRefreshedInputArtworkRevisionsOrScope() throws {
        var input = item("artist", tag: "portrait-v1", kind: .artist)
        input.logoImageTag = "logo-v1"
        input.backdropImageTag = "backdrop-v1"
        var detail = input
        detail.title = "Hydrated Artist"
        let hydration = FoundationArtistBrandingMetadata(
            scope: "account-a", inputRevision: input.artistBrandingRevision, detail: detail)
        XCTAssertEqual(hydration.resolved(for: input, scope: "account-a")?.title, "Hydrated Artist")
        XCTAssertNil(hydration.resolved(for: input, scope: "account-b"))
        for role in [FoundationItem.ArtworkRole.primary, .logo, .backdrop] {
            var refreshed = input
            switch role {
            case .primary: refreshed.primaryImageTag = "portrait-v2"
            case .logo: refreshed.logoImageTag = "logo-v2"
            case .backdrop: refreshed.backdropImageTag = "backdrop-v2"
            }
            XCTAssertEqual(refreshed.sharedArtworkIdentity, input.sharedArtworkIdentity)
            XCTAssertNotEqual(refreshed.artistBrandingRevision, input.artistBrandingRevision)
            XCTAssertNil(hydration.resolved(for: refreshed, scope: "account-a"))
        }
        var missingLogo = input
        missingLogo.logoImageTag = nil
        XCTAssertNil(hydration.resolved(for: missingLogo, scope: "account-a"))
    }

    func testArtistRolesHaveSeparateCacheAndRevisionIdentities() async throws {
        var artist = item("artist", tag: "portrait-v1", kind: .artist)
        artist.logoImageTag = "logo-v1"
        artist.backdropImageTag = "backdrop-v1"
        let logo = try XCTUnwrap(artist.artworkItem(for: .logo))
        let backdrop = try XCTUnwrap(artist.artworkItem(for: .backdrop))
        XCTAssertEqual(logo.resolvedArtworkRole, .logo)
        XCTAssertEqual(backdrop.resolvedArtworkRole, .backdrop)
        XCTAssertEqual(logo.primaryImageTag, "logo-v1")
        XCTAssertNotEqual(logo.sharedArtworkIdentity, artist.sharedArtworkIdentity)
        XCTAssertNotEqual(logo.sharedArtworkIdentity, backdrop.sharedArtworkIdentity)
        let keys = Set(
            [artist, logo, backdrop].map { FoundationArtworkCache.key($0, pixels: 640) })
        XCTAssertEqual(keys.count, 3)

        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic-artist", root: root)
        let data = try image()
        for projection in [artist, logo, backdrop] {
            _ = try await cache.result(for: projection, pixels: 640, allowsNetwork: true) { _, _ in
                data
            }
        }
        var untaggedPortrait = artist
        untaggedPortrait.primaryImageTag = nil
        let cachedPortrait = try await cache.cachedResult(for: untaggedPortrait, pixels: 640)
        let cachedLogo = try await cache.cachedResult(for: logo, pixels: 640)
        XCTAssertNotNil(cachedPortrait)
        XCTAssertNotNil(cachedLogo)
        XCTAssertNotEqual(cachedPortrait?.revision, cachedLogo?.revision)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testArtistBrandingAbsentOrEmptyTagsKeepsTextFallbackAndLegacyDecode() throws {
        var artist = item("artist", tag: nil, kind: .artist)
        XCTAssertNil(artist.artworkItem(for: .logo))
        XCTAssertNil(artist.artworkItem(for: .backdrop))
        artist.logoImageTag = ""
        XCTAssertNil(artist.artworkItem(for: .logo))
        let legacy = Data(
            #"{"id":"artist","title":"Synthetic Artist","subtitle":"","kind":"artist","genres":[],"playCount":0}"#
                .utf8)
        let decoded = try JSONDecoder().decode(FoundationItem.self, from: legacy)
        XCTAssertEqual(decoded.resolvedArtworkRole, .primary)
        XCTAssertNil(decoded.logoImageTag)
        XCTAssertEqual(
            FoundationArtworkCache.key(decoded, pixels: 640).identity,
            FoundationArtworkCache.digest("artist\0artist\0"))
        XCTAssertNil(item().artworkItem(for: .logo))
    }

    func testStorageMetricsSeparateOwnedArtworkDiskFromMemoryAndOtherAccounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "metrics/account-a", root: root)
        let other = FoundationArtworkCache(scope: "metrics/account-b", root: root)
        let scoped = root.appendingPathComponent(cache.scope)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 17).write(to: scoped.appendingPathComponent("fixture.art"))
        try Data(repeating: 0, count: 5).write(to: scoped.appendingPathComponent("revisions.plist"))
        try Data(repeating: 0, count: 999).write(to: scoped.appendingPathComponent("unrelated.tmp"))
        let measured = await cache.storageUsage()
        let isolated = await other.storageUsage()
        XCTAssertEqual(measured.disk, 22)
        XCTAssertEqual(measured.memory, 0)
        XCTAssertEqual(isolated.disk, 0)
        _ = await cache.invalidate(removeDisk: true)
        let retired = await cache.storageUsage()
        XCTAssertNil(retired.disk)
        XCTAssertEqual(retired.memory, 0)
    }

    func testStorageMetricsRejectSymbolicArtworkFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "metrics", root: root)
        let scoped = root.appendingPathComponent(cache.scope)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("private.bin")
        try Data(repeating: 0, count: 10).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: scoped.appendingPathComponent("linked.art"), withDestinationURL: target)
        let measured = await cache.storageUsage()
        XCTAssertNil(measured.disk)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    private func image(width: Int = 640, height: Int = 320) throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func cleanUp<Success: Sendable, Failure: Error>(
        _ task: Task<Success, Failure>, releasing probes: [ArtworkCacheProbe],
        cache: FoundationArtworkCache? = nil
    ) {
        addTeardownBlock {
            task.cancel()
            for probe in probes { await probe.release() }
            _ = await task.result
            if let cache { _ = await cache.invalidate(removeDisk: true) }
        }
    }

    private func recordTiming(_ stage: String, since start: ContinuousClock.Instant, count: Int) {
        let duration = start.duration(to: .now).components
        let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
        print("artworkFixture stage=\(stage) elapsedMs=\(milliseconds) count=\(count)")
    }

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
    }

    func testHomeAlbumAndLibraryTrackReuseOneDecodedResult() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic-account", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        let home = try await cache.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        let library = try await cache.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(home?.id, library?.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(home?.image.width, 160)
    }

    func testOmittedTagsReuseKnownRevisionIncludingColdOfflineLaunch() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let original = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: "album", title: "", primaryImageTag: nil))
        let omitted = try await cache.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(original?.id, omitted?.id)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let local = try await restored.result(
            for: track, pixels: 640, allowsNetwork: false, load: probe.load)
        XCTAssertEqual(local?.image.width, 160)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let newer = try await restored.result(
            for: item(tag: "v2"), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNotEqual(newer?.id, local?.id)
        let latest = try await restored.result(
            for: track, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(newer?.id, latest?.id)
        let finalCount = await probe.count
        XCTAssertEqual(finalCount, 2)
        _ = await restored.invalidate(removeDisk: true)
    }

    func testMissingTagUpgradeUsesKnownRevisionOnProviderRequest() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        _ = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let upgraded = try await cache.result(
            for: item(tag: nil), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.image.width, 640)
        let requestedTags = await probe.requestedTags
        XCTAssertEqual(requestedTags, ["v1", "v1"])
        let explicit = try await cache.result(
            for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.id, explicit?.id)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testLocalPreviewRemainsUsableDuringCancelledHeroUpgrade() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        let tile = try await cache.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        let held = ArtworkCacheProbe(data: try image(), held: true)
        let upgrade = Task {
            try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: held.load)
        }
        cleanUp(upgrade, releasing: [held], cache: cache)
        try await held.waitForCount(1)
        let preview = try await cache.cachedResult(for: album, pixels: 640)
        XCTAssertEqual(preview?.id, tile?.id)
        XCTAssertEqual(preview?.image.width, 160)
        upgrade.cancel()
        await held.release()
        _ = try? await upgrade.value
        let retained = try await cache.cachedResult(for: album, pixels: 640)
        XCTAssertNotNil(retained)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testArtistPlaylistAndGenreIdentityAndChangedRevision() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let fixtureStart = ContinuousClock.now
        let data = try image()
        recordTiming("identityJPEG", since: fixtureStart, count: 1)
        let probe = ArtworkCacheProbe(data: data)
        var operations = 0
        for kind in [FoundationItem.Kind.artist, .playlist, .genre, .album] {
            for _ in 0..<2 {
                let start = ContinuousClock.now
                _ = try await cache.result(
                    for: item("same", kind: kind), pixels: 160, allowsNetwork: true,
                    load: probe.load)
                operations += 1
                recordTiming("identityResult", since: start, count: operations)
            }
        }
        let start = ContinuousClock.now
        _ = try await cache.result(
            for: item("same", tag: "v2"), pixels: 160, allowsNetwork: true, load: probe.load)
        operations += 1
        recordTiming("identityResult", since: start, count: operations)
        let count = await probe.count
        XCTAssertEqual(count, 5, "Album representative and genre Primary must not alias")
    }

    func testHeroServesTileButTileRequiresHeroUpgrade() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        _ = try await cache.result(for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let hero = try await cache.result(
            for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(hero?.image.width, 640)
        let tile = try await cache.result(
            for: item("second"), pixels: 640, allowsNetwork: true, load: probe.load)
        let smaller = try await cache.result(
            for: item("second"), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(tile?.id, smaller?.id)
        let count = await probe.count
        XCTAssertEqual(count, 3)
    }

    func testColdLaunchOfflineDiskReuseAccountIsolationAndRemoval() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ArtworkCacheProbe(data: try image())
        let cache = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        _ = try await cache.result(for: item(), pixels: 640, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        let local = try await restored.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNotNil(local)
        let other = FoundationArtworkCache(scope: "server-b/account-a", root: root)
        let foreign = try await other.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(foreign)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let cleared = await restored.invalidate(removeDisk: true)
        XCTAssertTrue(cleared)
        let third = FoundationArtworkCache(scope: "server-a/account-a", root: root)
        let removed = try await third.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(removed)
    }

    func testMemoryAndDiskEvictionStayBoundedAndDoNotTouchRetainedDownloads() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retained = root.appendingPathComponent("download-owned")
        try Data("retained".utf8).write(to: retained)
        let data = try image()
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root,
            limits: .init(memoryBytes: 60_000, diskBytes: data.count + 1000))
        let probe = ArtworkCacheProbe(data: data)
        for id in ["one", "two", "three"] {
            _ = try await cache.result(
                for: item(id), pixels: 160, allowsNetwork: true, load: probe.load)
        }
        let usage = await cache.usage()
        XCTAssertLessThanOrEqual(usage.memory, 60_000)
        XCTAssertLessThanOrEqual(usage.disk, data.count + 1000)
        _ = await cache.invalidate(removeDisk: true)
        XCTAssertEqual(try Data(contentsOf: retained), Data("retained".utf8))
    }

    func testProbeCountWaitRetainsAnAlreadyEnteredSignal() async throws {
        let probe = ArtworkCacheProbe(data: Data())
        _ = try await probe.load(item(), 160)
        try await probe.waitForCount(1)
        let pending = await probe.pendingCountWaiterCount
        XCTAssertEqual(pending, 0)
    }

    func testProbeCountTimeoutRemovesWaiterWithoutLoading() async throws {
        let probe = ArtworkCacheProbe(data: Data())
        let start = ContinuousClock.now
        do {
            try await probe.waitForCount(1)
            XCTFail("Missing load must expire")
        } catch FoundationLibraryError.unavailable {}
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(5))
        let pending = await probe.pendingCountWaiterCount
        let count = await probe.count
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(count, 0)
    }

    func testProbeCancellationRemovesCountAndHeldLoadWaiters() async throws {
        let probe = ArtworkCacheProbe(data: Data(), held: true)
        let waiting = Task { try await probe.waitForCount(1) }
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("Cancelled count waiter succeeded")
        } catch is CancellationError {}
        let countWaiters = await probe.pendingCountWaiterCount
        XCTAssertEqual(countWaiters, 0)
        let artwork = item()
        let load = Task { try await probe.load(artwork, 160) }
        cleanUp(load, releasing: [probe])
        try await probe.waitForCount(1)
        load.cancel()
        do {
            _ = try await load.value
            XCTFail("Cancelled held load succeeded")
        } catch is CancellationError {}
        let heldLoads = await probe.pendingLoadCount
        let active = await probe.active
        XCTAssertEqual(heldLoads, 0)
        XCTAssertEqual(active, 0)
    }

    func testConcurrentRequestsCoalesceAndOneCancellationKeepsOtherConsumer() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        let album = item()
        let first = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        cleanUp(first, releasing: [probe], cache: cache)
        try await probe.waitForCount(1)
        let second = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        cleanUp(second, releasing: [probe], cache: cache)
        // Actor round trip after registering the second task.
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cache.consumerCount() < 2 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        first.cancel()
        await probe.release()
        _ = try await second.value
        do {
            _ = try await first.value
            XCTFail("Cancelled consumer returned artwork")
        } catch is CancellationError {}
        let count = await probe.count
        XCTAssertEqual(count, 1)
    }

    func testNowPlayingPromotesCoalescedArtworkWaitingForNetworkAdmission() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let admission = FoundationNetworkAdmission(limit: 3)
        await admission.updatePlaybackProtection(true, revision: 1)
        let browsePermit = try await admission.acquire()
        let cache = FoundationArtworkCache(
            scope: "synthetic-promoted", root: root, networkAdmission: admission)
        let album = item()
        let probe = ArtworkCacheProbe(data: try image())
        let load: @Sendable (FoundationItem, Int) async throws -> Data? = { item, pixels in
            let permit = try await admission.acquire()
            do {
                let data = try await probe.load(item, pixels)
                await admission.release(permit)
                return data
            } catch {
                await admission.release(permit)
                throw error
            }
        }
        let browse = Task {
            try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: load)
        }
        cleanUp(browse, releasing: [], cache: cache)
        addTeardownBlock { await admission.release(browsePermit) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await admission.pendingCount != 1 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        let current = Task {
            try await FoundationRequestIntent.$isPlayback.withValue(true) {
                try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: load)
            }
        }
        cleanUp(current, releasing: [], cache: cache)
        try await probe.waitForCount(1)
        let currentResult = try await current.value
        let browseResult = try await browse.value
        XCTAssertEqual(currentResult?.id, browseResult?.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        // Protected artwork finished while the ordinary permit was still held.
        await admission.release(browsePermit)
        _ = await cache.invalidate(removeDisk: false)
    }

    func testNowPlayingHasPendingCapacityWhenBrowsingBudgetIsFull() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic-pending", root: root,
            limits: .init(concurrentLoads: 2, pendingKeys: 3))
        let held = ArtworkCacheProbe(data: try image(), held: true)
        let ready = ArtworkCacheProbe(data: try image())
        let firstItem = item("first")
        let secondItem = item("second")
        let currentItem = item("current")
        let first = Task {
            try await cache.result(
                for: firstItem, pixels: 640, allowsNetwork: true, load: held.load)
        }
        cleanUp(first, releasing: [held], cache: cache)
        try await held.waitForCount(1)
        let second = Task {
            try await cache.result(
                for: secondItem, pixels: 640, allowsNetwork: true, load: ready.load)
        }
        cleanUp(second, releasing: [held], cache: cache)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cache.usage().pending != 2 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        let refusedBrowse = try await cache.result(
            for: item("excess"), pixels: 640, allowsNetwork: true, load: ready.load)
        XCTAssertNil(refusedBrowse)
        let current = try await FoundationRequestIntent.$isPlayback.withValue(true) {
            try await cache.result(
                for: currentItem, pixels: 640, allowsNetwork: true, load: ready.load)
        }
        XCTAssertNotNil(current)
        await held.release()
        _ = try await first.value
        _ = try await second.value
        _ = await cache.invalidate(removeDisk: false)
    }

    func testNowPlayingUsesReservedArtworkWorkerWhileBrowseLoadIsHeld() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic-reserved", root: root, limits: .init(concurrentLoads: 2))
        let held = ArtworkCacheProbe(data: try image(), held: true)
        let ready = ArtworkCacheProbe(data: try image())
        let firstItem = item("first")
        let currentItem = item("current")
        let first = Task {
            try await cache.result(
                for: firstItem, pixels: 640, allowsNetwork: true, load: held.load)
        }
        cleanUp(first, releasing: [held], cache: cache)
        try await held.waitForCount(1)
        let current = Task {
            try await FoundationRequestIntent.$isPlayback.withValue(true) {
                try await cache.result(
                    for: currentItem, pixels: 640, allowsNetwork: true, load: ready.load)
            }
        }
        cleanUp(current, releasing: [held], cache: cache)
        try await ready.waitForCount(1)
        let result = try await current.value
        XCTAssertNotNil(result)
        await held.release()
        _ = try await first.value
        _ = await cache.invalidate(removeDisk: false)
    }

    func testFetchConcurrencyAndQueuedCancellationAreBounded() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root, limits: .init(concurrentLoads: 3))
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        var tasks: [Task<FoundationCurrentArtwork.Result?, Error>] = []
        for index in 0..<6 {
            let album = item("album\(index)")
            tasks.append(
                Task {
                    try await cache.result(
                        for: album, pixels: 160, allowsNetwork: true, load: probe.load)
                })
        }
        for task in tasks { cleanUp(task, releasing: [probe], cache: cache) }
        try await probe.waitForCount(2)
        for task in tasks { task.cancel() }
        await probe.release()
        for task in tasks { _ = try? await task.value }
        _ = await cache.invalidate(removeDisk: false)
        let peak = await probe.peak
        XCTAssertLessThanOrEqual(peak, 2)
        let usage = await cache.usage()
        XCTAssertEqual(usage.active, 0)
        XCTAssertEqual(usage.pending, 0)
    }

    func testDecodedArtworkPublishesWhilePersistenceIsHeldAndRetirementRemovesIt() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic-held-persistence", root: root, limits: .init(memoryBytes: 0))
        let barrier = ArtworkCacheProbe(data: Data(), held: true)
        let artwork = item()
        await cache.setPersistenceBarrier { _ = try? await barrier.load(artwork, 160) }
        let probe = ArtworkCacheProbe(data: try image())
        let ready = expectation(description: "Decoded image publishes before persistence")
        let work = Task {
            defer { ready.fulfill() }
            return try await cache.result(
                for: artwork, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        cleanUp(work, releasing: [barrier], cache: cache)
        do {
            try await barrier.waitForCount(1)
        } catch {
            work.cancel()
            await barrier.release()
            _ = await work.result
            // Consume the expectation on the failure path without changing the first error.
            await fulfillment(of: [ready], timeout: 2)
            throw error
        }
        await fulfillment(of: [ready], timeout: 2)
        let image = try await work.value
        XCTAssertNotNil(image)
        // An oversized/uncached decoded result remains reusable while its write is pending.
        let reused = try await cache.result(
            for: artwork, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(image?.id, reused?.id)
        let reads = await probe.count
        XCTAssertEqual(reads, 1)
        let retired = Task { await cache.invalidate(removeDisk: true) }
        cleanUp(retired, releasing: [barrier], cache: cache)
        await barrier.release()
        let cleared = await retired.value
        XCTAssertTrue(cleared)
        let restored = FoundationArtworkCache(scope: "synthetic-held-persistence", root: root)
        let absent = try await restored.result(
            for: artwork, pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(absent)
        _ = await restored.invalidate(removeDisk: true)
    }

    func testInvalidationRejectsLateBytesAndNoDiskResurrection() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image(), held: true)
        let album = item()
        let task = Task {
            try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        }
        cleanUp(task, releasing: [probe], cache: cache)
        try await probe.waitForCount(1)
        let retire = Task { await cache.invalidate(removeDisk: true) }
        cleanUp(retire, releasing: [probe], cache: cache)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await cache.consumerCount() != 0 {
            guard ContinuousClock.now < deadline else { throw FoundationLibraryError.unavailable }
            await Task.yield()
        }
        await probe.release()
        let cleared = await retire.value
        XCTAssertTrue(cleared)
        do {
            _ = try await task.value
            XCTFail("Retired account returned late artwork")
        } catch is CancellationError {}
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let result = try await restored.result(
            for: album, pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(result)
    }

    func testMalformedImageIsNotRetainedAndOfflineDoesNotFetch() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: Data("invalid".utf8))
        let invalid = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNil(invalid)
        let offline = try await cache.result(
            for: item(), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(offline)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        let usage = await cache.usage()
        XCTAssertEqual(usage.memory, 0)
        let directory = root.appendingPathComponent(
            FoundationArtworkCache.digest("synthetic"), isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertTrue(files.allSatisfy { $0.lastPathComponent == "revisions.plist" })
        let metadataBytes = try files.reduce(0) { total, file in
            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            return total + (values.fileSize ?? 0)
        }
        XCTAssertEqual(usage.disk, metadataBytes)
        XCTAssertLessThanOrEqual(metadataBytes, 65_536)
        let cold = FoundationArtworkCache(scope: "synthetic", root: root)
        let restored = try await cold.result(
            for: item(tag: nil), pixels: 160, allowsNetwork: false, load: probe.load)
        XCTAssertNil(restored)
        let restoredCount = await probe.count
        XCTAssertEqual(restoredCount, 1)
    }
    @MainActor
    func testFastArtworkSkipsPreviewAndSlowArtworkShowsLocalFallback() async throws {
        let full = try XCTUnwrap(FoundationCurrentArtwork.decode(image(), maximumPixels: 640))
        let preview = try XCTUnwrap(FoundationCurrentArtwork.decode(image(), maximumPixels: 160))
        var published: [UUID] = []
        let fast = try await FoundationArtworkPresentation.load(
            target: { full },
            cached: {
                XCTFail("Fast artwork must not read or display a preview")
                return preview
            }, previewDelay: .seconds(30), onPreview: { published.append($0.id) })
        XCTAssertEqual(fast?.id, full.id)
        XCTAssertTrue(published.isEmpty)

        let probe = ArtworkCacheProbe(data: full.data, held: true)
        let artwork = item()
        let slow = Task {
            try await FoundationArtworkPresentation.load(
                target: {
                    _ = try await probe.load(artwork, 640)
                    return full
                }, cached: { preview }, previewDelay: .milliseconds(1)
            ) { published.append($0.id) }
        }
        cleanUp(slow, releasing: [probe])
        try await probe.waitForCount(1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while published.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(published, [preview.id])
        await probe.release()
        let final = try await slow.value
        XCTAssertEqual(final?.id, full.id)
    }

    @MainActor
    func testTargetFailurePreservesLocalPreviewButSecurityFailureDoesNotReadIt() async throws {
        let preview = try XCTUnwrap(FoundationCurrentArtwork.decode(image(), maximumPixels: 160))
        var published: [UUID] = []
        let missing = try await FoundationArtworkPresentation.load(
            target: { nil }, cached: { preview }, previewDelay: .seconds(30),
            onPreview: { published.append($0.id) })
        XCTAssertNil(missing)
        XCTAssertEqual(published, [preview.id])
        for error: FoundationLibraryError in [.network, .authentication] {
            published = []
            do {
                _ = try await FoundationArtworkPresentation.load(
                    target: { throw error },
                    cached: {
                        if error == .authentication {
                            XCTFail("Security failure must not read fallback")
                        }
                        return preview
                    }, previewDelay: .seconds(30), onPreview: { published.append($0.id) })
                XCTFail("The target failure must remain actionable")
            } catch let caught as FoundationLibraryError { XCTAssertEqual(caught, error) }
            XCTAssertEqual(published.count, error == .network ? 1 : 0)
        }
    }

    func testExplicitArtworkRetryBypassesOnlyAffectedFailure() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic-retry", root: root)
        let invalid = ArtworkCacheProbe(data: Data("invalid".utf8))
        for id in ["a", "b"] {
            _ = try await cache.result(
                for: item(id), pixels: 640, allowsNetwork: true, load: invalid.load)
        }
        await cache.clearFailures(for: item("a"))
        let valid = ArtworkCacheProbe(data: try image())
        let retried = try await cache.result(
            for: item("a"), pixels: 640, allowsNetwork: true, load: valid.load)
        let suppressed = try await cache.result(
            for: item("b"), pixels: 640, allowsNetwork: true, load: valid.load)
        XCTAssertNotNil(retried)
        XCTAssertNil(suppressed)
        let count = await valid.count
        XCTAssertEqual(count, 1)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testOversizedHeroDoesNotFlushReusableThumbnail() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(
            scope: "synthetic-admission", root: root, limits: .init(memoryBytes: 100_000))
        let probe = ArtworkCacheProbe(data: try image())
        let thumbnail = try await cache.result(
            for: item("small"), pixels: 160, allowsNetwork: true, load: probe.load)
        _ = try await cache.result(
            for: item("hero"), pixels: 640, allowsNetwork: true, load: probe.load)
        let retained = try await cache.cachedResult(for: item("small"), pixels: 160)
        XCTAssertEqual(retained?.id, thumbnail?.id)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testUntaggedExpiryAndBoundedFailureSuppression() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = ArtworkCacheClock()
        let cache = FoundationArtworkCache(scope: "synthetic", root: root, now: clock.read)
        let probe = ArtworkCacheProbe(data: try image())
        let untagged = item(tag: nil, kind: .artist)
        _ = try await cache.result(
            for: untagged, pixels: 160, allowsNetwork: true, load: probe.load)
        clock.advance(86_401)
        _ = try await cache.result(
            for: untagged, pixels: 160, allowsNetwork: true, load: probe.load)
        let count = await probe.count
        XCTAssertEqual(count, 2)
        let invalid = ArtworkCacheProbe(data: Data("invalid".utf8))
        let missing = item("missing")
        for _ in 0..<5 {
            _ = try await cache.result(
                for: missing, pixels: 160, allowsNetwork: true, load: invalid.load)
        }
        let suppressed = await invalid.count
        XCTAssertEqual(suppressed, 1)
        clock.advance(61)
        _ = try await cache.result(
            for: missing, pixels: 160, allowsNetwork: true, load: invalid.load)
        let retried = await invalid.count
        XCTAssertEqual(retried, 2)
        _ = await cache.invalidate(removeDisk: true)
    }

    func testStartupCleanupPreservesLiveAccountAndRemovesRetiredScopes() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ArtworkCacheProbe(data: try image())
        let retired = FoundationArtworkCache(scope: "old-account", root: root)
        _ = try await retired.result(
            for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        _ = await retired.invalidate(removeDisk: false)
        let live = FoundationArtworkCache(scope: "live-account", root: root)
        _ = try await live.result(for: item(), pixels: 160, allowsNetwork: true, load: probe.load)
        let cleared = await FoundationArtworkCache.clearStoredArtwork(root: root)
        XCTAssertTrue(cleared)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(retired.scope).path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(live.scope).path))
        _ = await live.invalidate(removeDisk: true)
    }

    func testProductionAdapterCoalescesAlbumAndTrackImageRequests() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let library = FoundationJellyfinLibrary(
            session: .init(
                serverURL: URL(string: "https://example.invalid")!, accessToken: "synthetic",
                userID: "user", deviceID: "device"),
            load: { request in
                let data = try await probe.load(
                    FoundationItem(id: "", title: "", subtitle: "", kind: .album, duration: nil),
                    160)!
                return (
                    data,
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "image/jpeg"])!
                )
            }, artworkCache: cache)
        let album = item("11111111111111111111111111111111")
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        async let home = library.artworkResult(for: album, size: 160, allowsNetwork: true)
        async let row = library.artworkResult(for: track, size: 160, allowsNetwork: true)
        let results = try await (home, row)
        XCTAssertEqual(results.0?.id, results.1?.id)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        _ = await cache.invalidate(removeDisk: true)
    }

    @MainActor
    func testCurrentOwnerReadsColdOfflineCacheWithoutChangingQueueOrPlaybackIntent() async throws {
        let root = root()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        _ = try await cache.result(for: album, pixels: 640, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let resolver = ArtworkCacheProbe(data: Data(), held: true)
        let player = FoundationPlayer(
            resolve: { item in
                _ = try await resolver.load(item, 0)
                try Task.checkCancellation()
                return URL(fileURLWithPath: "/synthetic")
            },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activateSession: {},
            deactivateSession: {}, startPlayback: { _ in })
        let track = FoundationItem(
            id: "song", title: "", subtitle: "", kind: .track, duration: nil,
            album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
        player.setQueue([track, track], selectedIndex: 0)
        let selectionTask = try XCTUnwrap(player.selectionTask)
        addTeardownBlock { @MainActor in
            player.stop()
            await resolver.release()
            await selectionTask.value
            _ = await restored.invalidate(removeDisk: true)
        }
        try await resolver.waitForCount(1)
        let selection = player.selectedEntryID
        let entries = player.queue.map(\.id)
        let state = player.state
        let wantsPlayback = player.wantsPlayback
        XCTAssertEqual(state, .loading)
        XCTAssertTrue(wantsPlayback)
        let current = FoundationCurrentArtwork(player: player) { item in
            try await restored.result(
                for: item, pixels: 640, allowsNetwork: false, load: probe.load)?.data
        }
        addTeardownBlock { @MainActor in current.invalidate() }
        await current.loadTask?.value
        XCTAssertNotNil(current.result(for: track))
        XCTAssertEqual(player.selectedEntryID, selection)
        XCTAssertEqual(player.queue.map(\.id), entries)
        XCTAssertEqual(player.state, state)
        XCTAssertEqual(player.wantsPlayback, wantsPlayback)
        let count = await probe.count
        XCTAssertEqual(count, 1)
        current.invalidate()
        player.stop()
        await resolver.release()
        await selectionTask.value
        _ = await restored.invalidate(removeDisk: true)
    }

    func testMalformedPersistentRecordRecoversWithOneFreshImageRead() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let album = item()
        _ = try await cache.result(for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        _ = await cache.invalidate(removeDisk: false)
        let directory = root.appendingPathComponent(cache.scope)
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "art" })
        try Data("corrupt".utf8).write(to: file)
        let restored = FoundationArtworkCache(scope: "synthetic", root: root)
        let result = try await restored.result(
            for: album, pixels: 160, allowsNetwork: true, load: probe.load)
        XCTAssertNotNil(result)
        let count = await probe.count
        XCTAssertEqual(count, 2)
        _ = await restored.invalidate(removeDisk: true)
    }

    @MainActor
    func testOfflineCurrentMissRecoversOnExplicitConnectivityRefresh() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "synthetic", root: root)
        let probe = ArtworkCacheProbe(data: try image())
        let availability = ArtworkCacheAvailability()
        let player = FoundationPlayer(
            resolve: { _ in URL(fileURLWithPath: "/synthetic") },
            makeItem: { _ in AVPlayerItem(asset: AVMutableComposition()) }, activateSession: {},
            deactivateSession: {}, startPlayback: { _ in })
        let album = item()
        player.setQueue(
            [
                FoundationItem(
                    id: "song", title: "", subtitle: "", kind: .track, duration: nil,
                    album: .init(id: album.id, title: "", primaryImageTag: album.primaryImageTag))
            ], selectedIndex: 0)
        let current = FoundationCurrentArtwork(player: player) { item in
            try await cache.result(
                for: item, pixels: 640, allowsNetwork: availability.read(), load: probe.load)?.data
        }
        await current.loadTask?.value
        XCTAssertNil(current.result)
        let before = await probe.count
        XCTAssertEqual(before, 0)
        availability.connect()
        current.refreshRetainedArtwork()
        await current.loadTask?.value
        XCTAssertNotNil(current.result)
        let after = await probe.count
        XCTAssertEqual(after, 1)
        current.invalidate()
        player.stop()
        _ = await cache.invalidate(removeDisk: true)
    }

    func testDiskLRURetainsRecentlyReadIdentity() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try image()
        let cache = FoundationArtworkCache(
            scope: "synthetic", root: root,
            // Include bounded revision metadata while retaining room for exactly two images.
            limits: .init(memoryBytes: 0, diskBytes: (data.count + 256) * 2 + 1_024))
        let probe = ArtworkCacheProbe(data: data)
        for id in ["one", "two"] {
            _ = try await cache.result(
                for: item(id), pixels: 160, allowsNetwork: true, load: probe.load)
        }
        await cache.flushPersistence()
        let directory = root.appendingPathComponent(cache.scope)
        for file in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path)
        }
        _ = try await cache.result(
            for: item("one"), pixels: 160, allowsNetwork: true, load: probe.load)
        _ = try await cache.result(
            for: item("three"), pixels: 160, allowsNetwork: true, load: probe.load)
        await cache.flushPersistence()
        let one = FoundationArtworkCache.key(item("one"), pixels: 160)
        let two = FoundationArtworkCache.key(item("two"), pixels: 160)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(one.identity)-160.art").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\(two.identity)-160.art").path))
        _ = await cache.invalidate(removeDisk: true)
    }

    #if DEBUG
        func testCoalescedWorkerPreservesInitiatingTraceContext() async throws {
            let root = root()
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = FoundationArtworkCache(scope: "synthetic", root: root)
            let data = try image()
            let expected = FoundationTrace.Context(origin: .home, page: .artwork)
            _ = try await FoundationTrace.$context.withValue(expected) {
                try await cache.result(for: item(), pixels: 160, allowsNetwork: true) { _, _ in
                    XCTAssertEqual(FoundationTrace.context?.owner, expected.owner)
                    return data
                }
            }
            _ = await cache.invalidate(removeDisk: true)
        }
    #endif

    func testLogoPreviewUpgradesWithoutAliasingPrimaryOrBackdrop() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FoundationArtworkCache(scope: "logo-upgrade", root: root)
        var artist = item("artist", kind: .artist)
        artist.logoImageTag = "logo-v1"
        let logo = try XCTUnwrap(artist.artworkItem(for: .logo))
        XCTAssertEqual(FoundationArtworkCache.key(logo, pixels: 1280).pixels, 1280)
        XCTAssertEqual(FoundationArtworkCache.key(artist, pixels: 1280).pixels, 1280)
        let probe = ArtworkCacheProbe(data: try image(width: 1280, height: 640))
        let preview = try await cache.result(
            for: logo, pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(preview?.image.width, 640)
        let upgraded = try await cache.result(
            for: logo, pixels: 1280, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.image.width, 1280)
        let calls = await probe.count
        XCTAssertEqual(calls, 2)
    }

    func testBackdropHighResolutionUpgradesWarmAndColdPreviews() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        var artist = item("artist", tag: "portrait", kind: .artist)
        artist.backdropImageTag = "backdrop"
        let backdrop = try XCTUnwrap(artist.artworkItem(for: .backdrop))
        XCTAssertEqual(FoundationArtworkCache.key(backdrop, pixels: 2048).pixels, 2048)
        XCTAssertEqual(FoundationArtworkCache.key(artist, pixels: 2048).pixels, 2048)
        let probe = ArtworkCacheProbe(data: try image(width: 2048, height: 1024))
        let warm = FoundationArtworkCache(scope: "synthetic-upgrade", root: root)
        let preview = try await warm.result(
            for: backdrop, pixels: 640, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(preview?.image.width, 640)
        let warmPreview = try await warm.cachedResult(for: backdrop, pixels: 2048)
        XCTAssertEqual(warmPreview?.image.width, 640)
        let upgraded = try await warm.result(
            for: backdrop, pixels: 2048, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(upgraded?.image.width, 2048)
        let warmLoads = await probe.count
        XCTAssertEqual(warmLoads, 2)
        _ = await warm.invalidate(removeDisk: true)

        let seed = FoundationArtworkCache(scope: "synthetic-upgrade", root: root)
        _ = try await seed.result(for: backdrop, pixels: 160, allowsNetwork: true, load: probe.load)
        _ = await seed.invalidate(removeDisk: false)
        let cold = FoundationArtworkCache(scope: "synthetic-upgrade", root: root)
        let coldPreview = try await cold.cachedResult(for: backdrop, pixels: 2048)
        XCTAssertEqual(coldPreview?.image.width, 160)
        let coldUpgrade = try await cold.result(
            for: backdrop, pixels: 2048, allowsNetwork: true, load: probe.load)
        XCTAssertEqual(coldUpgrade?.image.width, 2048)
        let coldLoads = await probe.count
        XCTAssertEqual(coldLoads, 4)
        _ = await cold.invalidate(removeDisk: false)
        let offline = FoundationArtworkCache(scope: "synthetic-upgrade", root: root)
        let retained = try await offline.result(for: backdrop, pixels: 2048, allowsNetwork: false) {
            _, _ in
            XCTFail("Offline high-resolution hit must not request artwork")
            return nil
        }
        XCTAssertEqual(retained?.image.width, 2048)
        _ = await offline.invalidate(removeDisk: true)
    }

    func testExplicitBackdropDecodeDoesNotRaiseDefaultPlaybackArtworkResolution() throws {
        let data = try image(width: 2048, height: 1024)
        XCTAssertEqual(FoundationCurrentArtwork.decode(data)?.image.width, 640)
        XCTAssertEqual(
            FoundationCurrentArtwork.decode(data, maximumPixels: 2048)?.image.width, 2048)
        XCTAssertNil(FoundationCurrentArtwork.decode(data, maximumPixels: 2049))
        XCTAssertNil(
            FoundationCurrentArtwork.decode(
                Data(repeating: 0, count: FoundationCurrentArtwork.maximumBytes + 1),
                maximumPixels: 2048))
    }

}

private actor ArtworkCacheProbe {
    let data: Data
    var held: Bool
    var count = 0
    var requestedTags: [String?] = []
    var active = 0
    var peak = 0
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private struct CountWaiter {
        let expected: Int
        let continuation: CheckedContinuation<Void, Error>
        let deadline: ContinuousClock.Instant
        let timeout: Task<Void, Never>
    }
    private var countWaiters: [UUID: CountWaiter] = [:]
    var pendingLoadCount: Int { waiters.count }
    var pendingCountWaiterCount: Int { countWaiters.count }

    init(data: Data, held: Bool = false) {
        self.data = data
        self.held = held
    }

    func load(_ item: FoundationItem, _ pixels: Int) async throws -> Data? {
        try Task.checkCancellation()
        count += 1
        requestedTags.append(item.primaryImageTag)
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        let ready = countWaiters.compactMap { $0.value.expected <= count ? $0.key : nil }
        for id in ready { finishCountWaiter(id, error: nil) }
        if held {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiters[id] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelLoad(id) }
            }
        }
        try Task.checkCancellation()
        return data
    }

    private func cancelLoad(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func release() {
        held = false
        let pending = waiters.values
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForCount(_ expected: Int) async throws {
        try Task.checkCancellation()
        if count >= expected { return }
        let id = UUID()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let timeout = Task.detached { [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: deadline)
                        await self?.finishCountWaiter(id, error: FoundationLibraryError.unavailable)
                    } catch {}
                }
                countWaiters[id] = CountWaiter(
                    expected: expected, continuation: continuation,
                    deadline: deadline, timeout: timeout)
            }
        } onCancel: {
            Task { await self.finishCountWaiter(id, error: CancellationError()) }
        }
        try Task.checkCancellation()
    }

    private func finishCountWaiter(_ id: UUID, error: Error?) {
        guard let waiter = countWaiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        if let error {
            waiter.continuation.resume(throwing: error)
        } else if ContinuousClock.now >= waiter.deadline {
            waiter.continuation.resume(throwing: FoundationLibraryError.unavailable)
        } else {
            waiter.continuation.resume()
        }
    }

}

private final class ArtworkCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }
    func advance(_ seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        date.addTimeInterval(seconds)
    }
}

private final class ArtworkCacheAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }
    func connect() {
        lock.lock()
        defer { lock.unlock() }
        connected = true
    }
}
