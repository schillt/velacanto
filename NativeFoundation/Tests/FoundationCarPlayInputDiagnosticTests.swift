#if DEBUG && os(iOS)
    import Foundation
    import XCTest

    @testable import VelacantoFoundation

    @MainActor
    final class FoundationCarPlayInputDiagnosticTests: XCTestCase {
        func testDisabledProbeDoesNotResolveOrCreateItsDestination() {
            var requested = false
            let probe = FoundationCarPlayInputDiagnostic.make(arguments: []) {
                requested = true
                return URL(fileURLWithPath: "/unused-diagnostic-destination")
            }
            XCTAssertNil(probe)
            XCTAssertFalse(requested)
        }

        func testExplicitFlagEnablesProbeWithoutStartingItsWindow() {
            let destination = temporaryFile()
            let probe = FoundationCarPlayInputDiagnostic.make(
                arguments: [FoundationCarPlayInputDiagnostic.flag], destination: { destination })
            XCTAssertNotNil(probe)
            XCTAssertTrue(probe?.snapshot.records.isEmpty == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }

        func testRecordCapIsFiniteAndDoesNotGrowAfterFurtherCallbacks() async throws {
            let destination = temporaryFile()
            defer {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            let probe = FoundationCarPlayInputDiagnostic(destination: destination, clock: { 10 })
            for _ in 0..<1_000 {
                probe.note(.update, length: 10, owned: true, navigating: false)
            }
            XCTAssertEqual(probe.snapshot.records.count, 128)
            XCTAssertTrue(probe.snapshot.recordLimitReached)
            await probe.waitForWrites()
            let stored = try JSONDecoder().decode(
                FoundationCarPlayInputDiagnostic.Snapshot.self, from: Data(contentsOf: destination))
            XCTAssertEqual(stored.records.count, 128)
        }

        func testExpiredWindowCannotRearmAfterTimeMovesOrConnectionEvents() async throws {
            var now: TimeInterval = 10
            let destination = temporaryFile()
            defer {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            let probe = FoundationCarPlayInputDiagnostic(destination: destination, clock: { now })
            probe.note(.connected, navigating: false)
            now = 311
            probe.note(.update, navigating: false)
            now = 10
            probe.note(.disconnected, navigating: false)
            probe.note(.connected, navigating: false)
            XCTAssertTrue(probe.snapshot.expired)
            XCTAssertEqual(probe.snapshot.records.count, 1)
            await probe.waitForWrites()
            let stored = try JSONDecoder().decode(
                FoundationCarPlayInputDiagnostic.Snapshot.self, from: Data(contentsOf: destination))
            XCTAssertTrue(stored.expired)
        }

        func testNativeCompletionAndQueryMetadataHaveOnlyDeclaredScalarSchema() async throws {
            let destination = temporaryFile()
            defer {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            let probe = FoundationCarPlayInputDiagnostic(
                destination: destination, build: 220, appVersionComponents: [0, 6, 0],
                osVersionComponents: [27, 0, 1], clock: { 10 })
            let sequence = probe.beginQuery(length: 100_000, owned: true, navigating: true)
            probe.note(
                .inputContext, sequence: sequence, owned: true, current: true, top: .options,
                navigating: true)
            probe.note(
                .cancelWork, owned: true, current: false, navigating: false,
                removalReason: .prepare, contextMismatch: 64, contextRetained: true,
                delegateOwned: true)
            probe.note(
                .keyboardRestrictions, navigating: false, keyboardRestricted: true)
            probe.note(
                .sceneActivation, navigating: false, sceneEvent: .enteredBackground)
            probe.completed(sequence: sequence, rows: 4, navigating: false)
            await probe.waitForWrites()
            let data = try Data(contentsOf: destination)
            XCTAssertLessThanOrEqual(data.count, 1_048_576)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                Set(json.keys),
                [
                    "version", "build", "appVersionComponents", "osVersionComponents", "records",
                    "recordLimitReached", "expired",
                ])
            XCTAssertEqual(json["version"] as? Int, 2)
            XCTAssertEqual(json["build"] as? Int, 220)
            XCTAssertEqual(json["appVersionComponents"] as? [Int], [0, 6, 0])
            XCTAssertEqual(json["osVersionComponents"] as? [Int], [27, 0, 1])
            let records = try XCTUnwrap(json["records"] as? [[String: Any]])
            let allowed: Set<String> = [
                "elapsed", "event", "sequence", "queryLength", "owned", "current", "top",
                "navigating", "success", "rows", "completions", "removalReason", "contextMismatch",
                "contextRetained", "delegateOwned", "keyboardRestricted", "sceneEvent",
            ]
            for record in records {
                XCTAssertTrue(Set(record.keys).isSubset(of: allowed))
                for (key, value) in record where key != "event" && key != "top" {
                    XCTAssertTrue(value is NSNumber, "Only declared enums may contain text")
                }
            }
            let cancellation = try XCTUnwrap(
                records.first { $0["event"] as? String == "cancelWork" })
            XCTAssertEqual(cancellation["removalReason"] as? Int, 2)
            XCTAssertEqual(cancellation["contextMismatch"] as? Int, 64)
            XCTAssertEqual(cancellation["delegateOwned"] as? Bool, true)
            XCTAssertEqual(cancellation["contextRetained"] as? Bool, true)
            let restriction = try XCTUnwrap(
                records.first { $0["event"] as? String == "keyboardRestrictions" })
            XCTAssertEqual(restriction["keyboardRestricted"] as? Bool, true)
            let activation = try XCTUnwrap(
                records.first { $0["event"] as? String == "sceneActivation" })
            XCTAssertEqual(activation["sceneEvent"] as? Int, 4)
            XCTAssertEqual(probe.snapshot.records.first?.queryLength, 4_096)
            XCTAssertEqual(probe.snapshot.records.last?.completions, 1)
            XCTAssertEqual(probe.snapshot.records.last?.rows, 4)
            XCTAssertEqual(
                try destination.resourceValues(forKeys: [.isExcludedFromBackupKey])
                    .isExcludedFromBackup, true)
        }

        func testCoalescedWriterRetainsTheLatestBoundedSnapshot() async throws {
            let destination = temporaryFile()
            defer {
                try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            }
            let probe = FoundationCarPlayInputDiagnostic(destination: destination, clock: { 10 })
            for length in 0..<80 {
                probe.note(.update, length: length, owned: true, navigating: false)
            }
            await probe.waitForWrites()
            let stored = try JSONDecoder().decode(
                FoundationCarPlayInputDiagnostic.Snapshot.self, from: Data(contentsOf: destination))
            XCTAssertEqual(stored.records.count, 80)
            XCTAssertEqual(stored.records.last?.queryLength, 79)
        }

        private func temporaryFile() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("CarPlayInputProbe-" + UUID().uuidString, isDirectory: true)
                .appendingPathComponent("current.json")
        }
    }
#endif
