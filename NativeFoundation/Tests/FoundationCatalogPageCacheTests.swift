import XCTest

@testable import VelacantoFoundation

@MainActor
final class FoundationCatalogPageCacheTests: XCTestCase {
    private let album = FoundationItem(
        id: "synthetic-album", title: "Example album", subtitle: "Example artist",
        kind: .album, duration: nil)

    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testStorageMetricsCountOnlyCurrentAccountPageFilesAndBecomeUnavailableAfterRetirement()
        async throws
    {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "metrics/account-a", root: directory)
        let other = FoundationCatalogPageCache(scope: "metrics/account-b", root: directory)
        let before = await cache.storageBytes()
        XCTAssertEqual(before, 0)
        await cache.write(FoundationPage(items: [album], nextStartIndex: nil), key: "home")
        let scoped = directory.appendingPathComponent(cache.scope)
        let urls = try FileManager.default.contentsOfDirectory(
            at: scoped, includingPropertiesForKeys: [.fileSizeKey])
        let expected = try urls.reduce(Int64(0)) {
            $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        try Data(repeating: 0, count: 999).write(to: scoped.appendingPathComponent("unrelated.tmp"))
        let measured = await cache.storageBytes()
        let isolated = await other.storageBytes()
        XCTAssertGreaterThan(expected, 0)
        XCTAssertEqual(measured, expected)
        XCTAssertEqual(isolated, 0)
        _ = await cache.invalidate()
        let retired = await cache.storageBytes()
        XCTAssertNil(retired)
    }

    func testStorageMetricsRejectSymbolicPageFilesWithoutReadingTarget() async throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "metrics", root: directory)
        let scoped = directory.appendingPathComponent(cache.scope)
        try FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("private.bin")
        try Data(repeating: 0, count: 10).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: scoped.appendingPathComponent("linked.page"), withDestinationURL: target)
        let measured = await cache.storageBytes()
        XCTAssertNil(measured)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testRelaunchRestoresOfflineWithoutAnyLoaderRead() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "account-a/server-a", root: directory)
        let first = FoundationBrowseModel()
        first.configureCache(cache, key: "home.recent")
        await first.loadPending { _ in FoundationPage(items: [self.album], nextStartIndex: 24) }
        let relaunched = FoundationBrowseModel()
        relaunched.configureCache(cache, key: "home.recent")
        await relaunched.loadPending(allowsNetwork: false) { _ in
            XCTFail("Offline restore started network work")
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        XCTAssertEqual(relaunched.items, [album])
        XCTAssertEqual(relaunched.nextStartIndex, 24)
        XCTAssertTrue(relaunched.loaded)
    }

    func testServerAccountAndGenreKeysAreIsolated() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = FoundationCatalogPageCache(scope: "account-a/server-a", root: directory)
        let second = FoundationCatalogPageCache(scope: "account-a/server-b", root: directory)
        let third = FoundationCatalogPageCache(scope: "account-b/server-a", root: directory)
        await first.write(FoundationPage(items: [album], nextStartIndex: nil), key: "genre.a")
        let same = await first.read("genre.a")
        let genre = await first.read("genre.b")
        let server = await second.read("genre.a")
        let account = await third.read("genre.a")
        XCTAssertEqual(same?.page.items, [album])
        XCTAssertNil(genre)
        XCTAssertNil(server)
        XCTAssertNil(account)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(names.allSatisfy { $0.count == 64 && $0.allSatisfy(\.isHexDigit) })
    }

    func testRefreshRetainsSnapshotThrottlesReentryAndManualRefreshBypasses() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory)
        await cache.write(FoundationPage(items: [album], nextStartIndex: nil), key: "new")
        var date = Date()
        let model = FoundationBrowseModel(now: { date })
        model.configureCache(cache, key: "new")
        var reads = 0
        let loader: (Int) async throws -> FoundationPage = { _ in
            XCTAssertEqual(model.items, [self.album])
            reads += 1
            throw URLError(.timedOut)
        }
        await model.loadPending(using: loader)
        await model.loadPending(using: loader)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.items, [album])
        model.request(.refresh)
        await model.loadPending(using: loader)
        XCTAssertEqual(reads, 2)
        date = date.addingTimeInterval(61)
        await model.loadPending(using: loader)
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(model.items, [album])
    }

    func testCancelledAndSupersededResponseCannotReachDisk() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory)
        let model = FoundationBrowseModel()
        model.configureCache(cache, key: "home")
        let started = expectation(description: "request suspended")
        var release: CheckedContinuation<FoundationPage, Never>?
        let old = Task {
            await model.loadPending { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        old.cancel()
        await model.load(.refresh) { _ in FoundationPage(items: [self.album], nextStartIndex: nil) }
        release?.resume(returning: FoundationPage(items: [], nextStartIndex: nil))
        await old.value
        let record = await cache.read("home")
        XCTAssertEqual(record?.page.items, [album])
        let permit = FoundationPageWritePermit()
        permit.revoke()
        await cache.write(
            FoundationPage(items: [], nextStartIndex: nil), key: "home", permit: permit)
        let retained = await cache.read("home")
        XCTAssertEqual(retained?.page.items, [album])
    }

    func testPendingRefreshSupersedesSuspendedReadWithoutStarvation() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory)
        let model = FoundationBrowseModel()
        model.configureCache(cache, key: "home")
        let started = expectation(description: "old read suspended")
        var release: CheckedContinuation<FoundationPage, Never>?
        let old = Task {
            await model.loadPending { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoading)
        model.request(.refresh)
        var refreshReads = 0
        await model.loadPending { offset in
            XCTAssertEqual(offset, 0)
            refreshReads += 1
            return FoundationPage(items: [self.album], nextStartIndex: nil)
        }
        XCTAssertEqual(refreshReads, 1)
        XCTAssertEqual(model.items, [album])
        XCTAssertFalse(model.isLoading)
        release?.resume(returning: FoundationPage(items: [], nextStartIndex: 24))
        await old.value
        XCTAssertEqual(model.items, [album])
        XCTAssertNil(model.nextStartIndex)
        let persisted = await cache.read("home")
        XCTAssertEqual(persisted?.page.items, [album])
    }

    func testExplicitRefreshWaitsForNetworkPermissionWithoutLosingCachedShelf() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory)
        await cache.write(FoundationPage(items: [album], nextStartIndex: nil), key: "home")
        let model = FoundationBrowseModel()
        model.configureCache(cache, key: "home")
        model.request(.refresh)
        var reads = 0
        let loader: (Int) async throws -> FoundationPage = { _ in
            reads += 1
            return FoundationPage(items: [self.album], nextStartIndex: nil)
        }
        await model.loadPending(allowsNetwork: false, using: loader)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(model.items, [album])
        await model.loadPending(ifActive: false, using: loader)
        XCTAssertEqual(reads, 0)
        await model.loadPending(allowsNetwork: true, using: loader)
        await model.loadPending(allowsNetwork: true, using: loader)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.items, [album])
    }

    func testCancelledSuspendedOwnerAllowsReplacementAppearanceToLoad() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory)
        let model = FoundationBrowseModel()
        model.configureCache(cache, key: "home")
        let started = expectation(description: "cancelled load suspended")
        var release: CheckedContinuation<FoundationPage, Never>?
        let old = Task {
            await model.loadPending { _ in
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoading)
        await model.loadPending { _ in
            XCTFail("A genuinely live shared owner must not start a duplicate load")
            return FoundationPage(items: [], nextStartIndex: nil)
        }
        old.cancel()
        var replacementReads = 0
        await model.loadPending { offset in
            XCTAssertEqual(offset, 0)
            replacementReads += 1
            return FoundationPage(items: [self.album], nextStartIndex: nil)
        }
        XCTAssertEqual(replacementReads, 1)
        XCTAssertEqual(model.items, [album])
        XCTAssertFalse(model.isLoading)
        release?.resume(returning: FoundationPage(items: [], nextStartIndex: 24))
        await old.value
        XCTAssertEqual(model.items, [album])
        XCTAssertNil(model.nextStartIndex)
        let persisted = await cache.read("home")
        XCTAssertEqual(persisted?.page.items, [album])
    }

    func testBoundsRejectOversizedPagesAndEvictOldest() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = FoundationCatalogPageCache.Limits()
        limits.pages = 2
        limits.itemsPerPage = 1
        let cache = FoundationCatalogPageCache(scope: "fixture", root: directory, limits: limits)
        await cache.write(
            FoundationPage(items: [album, album], nextStartIndex: nil), key: "oversized")
        let oversized = await cache.read("oversized")
        XCTAssertNil(oversized)
        for (index, key) in ["one", "two", "three"].enumerated() {
            await cache.write(FoundationPage(items: [album], nextStartIndex: nil), key: key)
            let file = directory.appendingPathComponent(cache.scope)
                .appendingPathComponent(FoundationArtworkCache.digest(key) + ".page")
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(Double(index - 3))],
                ofItemAtPath: file.path)
        }
        let first = await cache.read("one")
        let last = await cache.read("three")
        XCTAssertNil(first)
        XCTAssertEqual(last?.page.items, [album])
        limits.entryBytes = 10
        let tiny = FoundationCatalogPageCache(scope: "tiny", root: directory, limits: limits)
        await tiny.write(FoundationPage(items: [album], nextStartIndex: nil), key: "tiny")
        let rejected = await tiny.read("tiny")
        XCTAssertNil(rejected)
    }

    func testExpiredAndCorruptMetadataAreOptionalMisses() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = Date()
        let original = FoundationCatalogPageCache(scope: "fixture", root: directory, now: { saved })
        await original.write(FoundationPage(items: [album], nextStartIndex: nil), key: "expired")
        let later = FoundationCatalogPageCache(
            scope: "fixture", root: directory, now: { saved.addingTimeInterval(8 * 24 * 60 * 60) })
        let expired = await later.read("expired")
        XCTAssertNil(expired)
        let file = directory.appendingPathComponent(original.scope)
            .appendingPathComponent(FoundationArtworkCache.digest("corrupt") + ".page")
        try? Data("invalid metadata".utf8).write(to: file)
        let corrupt = await original.read("corrupt")
        XCTAssertNil(corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAccountCleanupCannotRemoveNewSameScopeOwner() async {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = FoundationCatalogPageCache(scope: "fixture", root: directory)
        let new = FoundationCatalogPageCache(scope: "fixture", root: directory)
        await new.write(FoundationPage(items: [album], nextStartIndex: nil), key: "home")
        let retired = await old.invalidate(removeDisk: true)
        let cleared = await FoundationCatalogPageCache.clearStoredPages(root: directory)
        XCTAssertTrue(retired)
        XCTAssertTrue(cleared)
        let preserved = await new.read("home")
        XCTAssertEqual(preserved?.page.items, [album])
        let removed = await new.invalidate(removeDisk: true)
        XCTAssertTrue(removed)
        let dead = await new.read("home")
        XCTAssertNil(dead)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(new.scope).path))
    }
}
