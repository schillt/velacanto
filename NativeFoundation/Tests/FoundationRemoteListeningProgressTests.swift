import Foundation
import XCTest

@testable import VelacantoFoundation

final class FoundationRemoteListeningProgressTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    private func activity(
        elapsed: Double? = 30, duration: Double? = 180, checkedInAt: Date? = nil
    ) -> FoundationRemoteListeningActivity {
        .init(
            id: "fixture", deviceKey: "fixture-device", deviceLabel: "Browser",
            checkedInAt: checkedInAt ?? anchor,
            item: FoundationItem(
                id: "fixture-track", title: "Track", subtitle: "Artist", kind: .track,
                duration: duration), albumTitle: "Album", elapsed: elapsed)
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
