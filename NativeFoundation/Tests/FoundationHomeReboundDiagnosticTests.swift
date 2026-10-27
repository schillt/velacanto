#if DEBUG
    import SwiftUI
    import XCTest
    #if os(iOS)
        import UIKit
    #endif

    @testable import VelacantoFoundation

    @MainActor
    final class FoundationHomeReboundDiagnosticTests: XCTestCase {
        #if os(iOS)
            func testPublicNativeSnapshotReadsRangeWithoutMutatingScrollView() {
                let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
                scroll.contentInsetAdjustmentBehavior = .never
                scroll.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 20, right: 0)
                scroll.contentSize = CGSize(width: 200, height: 1_000)
                scroll.contentOffset = CGPoint(x: 0, y: 100)
                let bounds = scroll.bounds
                let size = scroll.contentSize
                let inset = scroll.contentInset
                let adjusted = scroll.adjustedContentInset
                let offset = scroll.contentOffset
                let values = FoundationHomeNativeScrollSnapshot.facts(
                    scroll, identityConsistent: true)
                XCTAssertEqual(values["found"], 1)
                XCTAssertEqual(values["identityConsistent"], 1)
                XCTAssertEqual(values["legalMinY"], -10)
                XCTAssertEqual(values["legalMaxY"], 720)
                XCTAssertEqual(values["boundsHeight"], 300)
                XCTAssertEqual(values["offsetY"], 100)
                XCTAssertEqual(values["inWindow"], 0)
                XCTAssertTrue(values.values.allSatisfy(\.isFinite))
                XCTAssertEqual(scroll.bounds, bounds)
                XCTAssertEqual(scroll.contentSize, size)
                XCTAssertEqual(scroll.contentInset, inset)
                XCTAssertEqual(scroll.adjustedContentInset, adjusted)
                XCTAssertEqual(scroll.contentOffset, offset)
            }

            func testAbsentNativeViewportIsExplicitWithoutInventedRange() {
                let values = FoundationHomeNativeScrollSnapshot.facts(
                    nil, identityConsistent: false)
                XCTAssertEqual(values, ["found": 0, "identityConsistent": 0])
            }
        #endif

        func testIdleClearanceAndCriticalGeometryPersistWithoutAnotherPhaseCallback() throws {
            let directory = temporaryDirectory()
            let writer = FoundationHomeReboundWriter(directory: directory)
            let recorder = FoundationHomeReboundDiagnostic(buffer: buffer(), writer: writer)
            defer {
                recorder.homeActive(false)
                writer.waitUntilIdleForTests()
                try? FileManager.default.removeItem(at: directory)
            }
            recorder.homeActive(true)
            // A native bar tap changes layout while scrolling remains idle. The
            // accessory event's earlier flush must not be the last saved snapshot.
            recorder.accessory(.normal)
            recorder.clearance(
                .init(
                    host: CGRect(x: 0, y: 0, width: 402, height: 874),
                    accessory: nil, nativeBottomInset: 139, reserve: 4, hasQueue: true))
            writer.waitUntilIdleForTests()
            let first = try JSONDecoder().decode(
                FoundationHomeReboundSnapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent("current.json")))
            XCTAssertEqual(
                first.records.last(where: { $0.event == .clearance })?.facts?["reserve"], 4)
            let before = ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: 379),
                contentSize: CGSize(width: 402, height: 1_064),
                contentInsets: EdgeInsets(top: 56, leading: 0, bottom: 83, trailing: 0),
                containerSize: CGSize(width: 402, height: 629))
            let after = ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: 379),
                contentSize: CGSize(width: 402, height: 1_068),
                contentInsets: EdgeInsets(top: 56, leading: 0, bottom: 139, trailing: 0),
                containerSize: CGSize(width: 402, height: 573))
            recorder.geometry(from: before, to: after)
            writer.waitUntilIdleForTests()
            let second = try JSONDecoder().decode(
                FoundationHomeReboundSnapshot.self,
                from: Data(contentsOf: directory.appendingPathComponent("current.json")))
            XCTAssertEqual(
                second.records.last(where: { $0.event == .geometry })?.geometry?["bottom"], 139)
            XCTAssertFalse(second.records.contains { $0.event == .phase })
        }

        func testRecordingRequiresExactExplicitLaunchArgument() {
            XCTAssertFalse(FoundationHomeReboundDiagnostic.isRequested(arguments: []))
            XCTAssertFalse(
                FoundationHomeReboundDiagnostic.isRequested(arguments: ["diagnosticHomeRebound"]))
            XCTAssertFalse(
                FoundationHomeReboundDiagnostic.isRequested(arguments: ["-diagnosticHomeRebound=1"])
            )
            XCTAssertTrue(
                FoundationHomeReboundDiagnostic.isRequested(arguments: ["-diagnosticHomeRebound"]))
            XCTAssertNil(FoundationHomeReboundDiagnostic.shared)
        }

        func testDisabledRecorderAndUnusedWriterCreateNoDiagnosticFile() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = FoundationHomeReboundWriter(directory: directory)
            writer.waitUntilIdleForTests()
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }

        func testRecordAndGestureWindowsAreFinite() {
            var buffer = buffer()
            for index in 0..<2_048 {
                buffer.append(.init(event: .geometry), elapsed: Double(index) / 100)
            }
            XCTAssertEqual(buffer.snapshot.records.count, 1_024)
            XCTAssertEqual(buffer.snapshot.evictedRecords, 1_024)
            for index in 0..<20 {
                buffer.append(.init(event: .phase), elapsed: 30 + Double(index), newGesture: true)
            }
            XCTAssertEqual(Set(buffer.snapshot.records.map(\.gesture)), Set([17, 18, 19, 20]))
        }

        func testSamplingNeverSuppressesCriticalPhaseAndIsIndependentPerGeometrySource() {
            var buffer = buffer()
            buffer.append(.init(event: .geometry), elapsed: 0, critical: false)
            buffer.append(.init(event: .content), elapsed: 0, critical: false)
            buffer.append(.init(event: .geometry), elapsed: 0.001, critical: false)
            buffer.append(.init(event: .phase), elapsed: 0.001)
            XCTAssertEqual(buffer.snapshot.records.map(\.event), [.geometry, .content, .phase])
            XCTAssertEqual(buffer.snapshot.sampledGeometry, 1)
            buffer.append(.init(event: .geometry), elapsed: 0.04, critical: false)
            XCTAssertEqual(buffer.snapshot.records.count, 4)
        }

        func testFiveMinuteExpiryCannotRearmOrAppendLaterEvents() {
            var buffer = buffer()
            buffer.append(.init(event: .homeEntered), elapsed: 0)
            buffer.append(.init(event: .geometry), elapsed: .nan)
            XCTAssertEqual(buffer.snapshot.records.count, 1)
            buffer.append(.init(event: .geometry), elapsed: 300)
            XCTAssertTrue(buffer.snapshot.expired)
            XCTAssertEqual(buffer.snapshot.records.last?.event, .expired)
            let count = buffer.snapshot.records.count
            buffer.append(.init(event: .homeEntered), elapsed: 301, newGesture: true)
            buffer.append(.init(event: .geometry), elapsed: 0)
            XCTAssertEqual(buffer.snapshot.records.count, count)
        }

        func testLiveRecordSchemaContainsOnlyNumericDataAndAllowlistedEnumValues() throws {
            let directory = temporaryDirectory().appendingPathComponent(
                "private-user@example.invalid")
            defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
            let writer = FoundationHomeReboundWriter(directory: directory)
            let recorder = FoundationHomeReboundDiagnostic(buffer: buffer(), writer: writer)
            recorder.homeActive(true)
            let geometry = ScrollGeometry(
                contentOffset: CGPoint(x: 0, y: 379),
                contentSize: CGSize(width: 402, height: 1_064),
                contentInsets: EdgeInsets(top: 56, leading: 0, bottom: 83, trailing: 0),
                containerSize: CGSize(width: 402, height: 629))
            recorder.phase(from: .interacting, to: .decelerating, geometry: geometry)
            recorder.geometry(from: geometry, to: geometry)
            recorder.tracker(
                .viewportNotShrunk, phase: .decelerating, previous: nil,
                current: .init(geometry), facts: ["hasCandidate": 0])
            recorder.accessory(.minimized, frame: CGRect(x: 90, y: 798, width: 222, height: 48))
            recorder.frame(CGRect(x: 0, y: 106, width: 402, height: 768), event: .viewport)
            recorder.pointRequest(1_064, phase: .idle)
            recorder.homeActive(false)
            writer.waitUntilIdleForTests()
            let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
            let json = try JSONSerialization.jsonObject(with: data)
            let allowed = Set(
                FoundationHomeReboundEvent.allCases.map(\.rawValue)
                    + FoundationHomeReboundReason.allCases.map(\.rawValue)
                    + FoundationHomeReboundPhase.allCases.map(\.rawValue)
                    + FoundationHomeReboundPlacement.allCases.map(\.rawValue))
            func inspect(_ value: Any) {
                if let string = value as? String { XCTAssertTrue(allowed.contains(string)) }
                if let array = value as? [Any] { array.forEach(inspect) }
                if let object = value as? [String: Any] { object.values.forEach(inspect) }
            }
            inspect(json)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-user"))
            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }

        func testWriterCapsBytesWithoutProducingInvalidJSON() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var buffer = buffer()
            let metrics = Dictionary(
                uniqueKeysWithValues: (0..<256).map { ("metric_\($0)", Double($0)) })
            for _ in 0..<1_024 {
                buffer.append(.init(event: .geometry, geometry: metrics), elapsed: 1)
            }
            let writer = FoundationHomeReboundWriter(directory: directory)
            writer.submit(buffer.snapshot)
            writer.waitUntilIdleForTests()
            let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
            XCTAssertLessThanOrEqual(data.count, FoundationHomeReboundBuffer.maximumBytes)
            let saved = try JSONDecoder().decode(FoundationHomeReboundSnapshot.self, from: data)
            XCTAssertGreaterThan(saved.encodingEvictions, 0)
            XCTAssertFalse(saved.records.isEmpty)
            XCTAssertEqual(buffer.snapshot.records.count, 1_024)
        }

        func testCoalescedWriterFinishesWithLatestSnapshot() throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = FoundationHomeReboundWriter(directory: directory)
            for build in 1...64 {
                writer.submit(
                    FoundationHomeReboundBuffer(build: build, version: [0, 6, 0], os: [27]).snapshot
                )
            }
            writer.waitUntilIdleForTests()
            let data = try Data(contentsOf: directory.appendingPathComponent("current.json"))
            let saved = try JSONDecoder().decode(FoundationHomeReboundSnapshot.self, from: data)
            XCTAssertEqual(saved.build, 64)
        }

        private func buffer() -> FoundationHomeReboundBuffer {
            .init(build: 220, version: [0, 6, 0], os: [27, 0, 1])
        }

        private func temporaryDirectory() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        }
    }
#endif
