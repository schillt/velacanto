import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationRemoteListeningProgressTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func activity(
        elapsed: Double? = 30, duration: Double? = 180, checkedInAt: Date? = nil,
        observedAt: Date? = nil
    ) -> FoundationRemoteListeningActivity {
        .init(
            id: "fixture", deviceKey: "fixture-device", deviceLabel: "Browser",
            checkedInAt: checkedInAt ?? anchor,
            item: FoundationItem(
                id: "fixture-track", title: "Track", subtitle: "Artist", kind: .track,
                duration: duration), albumTitle: "Album", elapsed: elapsed,
            observedAt: observedAt ?? checkedInAt ?? anchor)
    }

    func testV12EstimatedPositionDoesNotCountOldCheckInAgeTwice() throws {
        let owner = String(repeating: "1", count: 32)
        let row: [String: Any] = [
            "Id": String(repeating: "2", count: 32), "UserId": owner,
            "Client": "Jellyfin Web", "DeviceId": "remote-browser", "IsActive": true,
            "LastPlaybackCheckIn": ISO8601DateFormatter().string(
                from: anchor.addingTimeInterval(-30)),
            "NowPlayingItem": [
                "Id": String(repeating: "3", count: 32), "Type": "Audio", "Name": "Synthetic",
                "RunTimeTicks": 3_000_000_000,
            ],
            "PlayState": ["IsPaused": false, "PositionTicks": 600_000_000],
        ]
        let decoded = try FoundationRemoteListeningActivity.decode(
            JSONSerialization.data(withJSONObject: [row]), userID: owner,
            ownDeviceID: "receiver", now: anchor)
        let report = try XCTUnwrap(decoded.first)
        XCTAssertEqual(report.observedAt, anchor)
        XCTAssertEqual(report.presentationProgress(at: anchor).elapsed, 60)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(1)).elapsed, 61)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(5)).elapsed, 65)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(60)).elapsed, 120)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(600)).elapsed, 120)
        XCTAssertEqual(report.elapsed, 60)
        XCTAssertEqual(report.checkedInAt, anchor.addingTimeInterval(-30))
    }

    func testV12RemoteSeekReanchorsAtNewObservationEvenWithSameCheckIn() {
        let checkIn = anchor.addingTimeInterval(-30)
        let first = activity(elapsed: 60, checkedInAt: checkIn, observedAt: anchor)
        XCTAssertEqual(first.presentationProgress(at: anchor.addingTimeInterval(10)).elapsed, 70)
        let seek = activity(
            elapsed: 8, checkedInAt: checkIn, observedAt: anchor.addingTimeInterval(10))
        XCTAssertEqual(seek.presentationProgress(at: anchor.addingTimeInterval(10)).elapsed, 8)
        XCTAssertEqual(seek.presentationProgress(at: anchor.addingTimeInterval(11)).elapsed, 9)
    }

    func testAlreadyStaleOrExcessivelyFutureReportDoesNotEstimate() {
        for offset in [-91.0, 6.0] {
            let report = activity(
                elapsed: 30, checkedInAt: anchor.addingTimeInterval(offset), observedAt: anchor)
            XCTAssertEqual(
                report.presentationProgress(at: anchor.addingTimeInterval(10)), report.progress)
        }
    }

    func testToleratedFutureCheckInOnlyExtendsExistingFreshnessDeadline() {
        let report = activity(
            elapsed: 30, duration: 500, checkedInAt: anchor.addingTimeInterval(5),
            observedAt: anchor)
        XCTAssertEqual(report.presentationProgress(at: anchor).elapsed, 30)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(1)).elapsed, 31)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(95)).elapsed, 125)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(600)).elapsed, 125)
    }

    func testProgressAdvancesBetweenReportsWithoutMutatingSnapshot() {
        let report = activity()
        XCTAssertEqual(report.presentationProgress(at: anchor).elapsed, 30)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(1)).elapsed, 31)
        XCTAssertEqual(
            report.presentationProgress(at: anchor.addingTimeInterval(12)).label, "0:42 / 3:00")
        XCTAssertEqual(report.elapsed, 30)
        XCTAssertEqual(report.checkedInAt, anchor)
        XCTAssertEqual(report.progress.label, "0:30 / 3:00")
    }

    func testNewReportReanchorsIncludingRemoteSeekBackwards() {
        let first = activity()
        XCTAssertEqual(first.presentationProgress(at: anchor.addingTimeInterval(20)).elapsed, 50)
        let updated = activity(elapsed: 8, checkedInAt: anchor.addingTimeInterval(20))
        XCTAssertEqual(updated.presentationProgress(at: anchor.addingTimeInterval(21)).elapsed, 9)
    }

    func testProgressStopsAtDurationWithoutChangingReportedPosition() {
        let report = activity(elapsed: 175)
        let display = report.presentationProgress(at: anchor.addingTimeInterval(20))
        XCTAssertEqual(display.elapsed, 180)
        XCTAssertEqual(display.fraction, 1)
        XCTAssertEqual(report.elapsed, 175)
        XCTAssertEqual(activity(elapsed: 200).presentationProgress(at: anchor).elapsed, 180)
    }

    func testEstimateFreezesAtFreshnessLimitInsteadOfRunningIndefinitely() {
        let report = activity(duration: 500)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(89)).elapsed, 119)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(90)).elapsed, 120)
        XCTAssertEqual(
            report.presentationProgress(at: anchor.addingTimeInterval(3_600)).elapsed, 120)
    }

    func testSmallFutureClockSkewDoesNotSubtractOrAdvancePosition() {
        let report = activity()
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(-5)).elapsed, 30)
        XCTAssertEqual(report.presentationProgress(at: anchor.addingTimeInterval(-1)).elapsed, 30)
    }

    func testUntrustedFutureAnchorDoesNotEstimate() {
        let report = activity(elapsed: 200)
        XCTAssertEqual(
            report.presentationProgress(at: anchor.addingTimeInterval(-6)), report.progress)
    }

    func testUnknownOrInvalidElapsedDoesNotInventPosition() {
        let date = anchor.addingTimeInterval(10)
        XCTAssertNil(activity(elapsed: nil).presentationProgress(at: date).elapsed)
        XCTAssertEqual(
            activity(elapsed: -1).presentationProgress(at: date).label, "Unavailable / 3:00")
        XCTAssertEqual(activity(elapsed: .infinity).presentationProgress(at: date).fraction, 0)
        XCTAssertTrue(activity(elapsed: .nan).presentationProgress(at: date).elapsed!.isNaN)
    }

    func testUnknownOrInvalidDurationDoesNotInventDurationOrFraction() {
        let durations: [Double?] = [nil, 0, -1, .infinity, .nan]
        for duration in durations {
            let display = activity(duration: duration).presentationProgress(
                at: anchor.addingTimeInterval(10))
            XCTAssertEqual(display.elapsed, 40)
            XCTAssertEqual(display.fraction, 0)
        }
        XCTAssertEqual(
            activity(duration: nil).presentationProgress(at: anchor.addingTimeInterval(10)).label,
            "0:40 / Unavailable")
    }

    func testNonFiniteClockDoesNotEstimate() {
        let report = activity()
        XCTAssertEqual(
            report.presentationProgress(at: Date(timeIntervalSince1970: .infinity)), report.progress
        )
        XCTAssertEqual(
            report.presentationProgress(at: Date(timeIntervalSince1970: .nan)), report.progress)
    }
}
