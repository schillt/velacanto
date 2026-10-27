import Observation
import XCTest

@testable import VelacantoFoundation

#if os(macOS)
    @MainActor
    final class FoundationMacTitleRevealTests: XCTestCase {
        func testTitleIsHiddenUntilScrolledAndMeasuredThenUsesExistingSmoothstep() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateTitleBottom(76)
            reveal.updateScrolled(true)
            XCTAssertEqual(reveal.progress, 0)
            reveal.updateToolbarBottom(100)
            XCTAssertEqual(reveal.progress, 0.5)
            reveal.updateTitleBottom(88)
            XCTAssertEqual(reveal.progress, 0.15625)
            reveal.updateTitleBottom(64)
            XCTAssertEqual(reveal.progress, 0.84375)
            reveal.updateTitleBottom(52)
            XCTAssertEqual(reveal.progress, 1)
            reveal.updateScrolled(false)
            XCTAssertEqual(reveal.progress, 0)
        }

        func testHiddenScrollSamplesDoNotInvalidateTheObservedTitle() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateToolbarBottom(100)
            reveal.updateScrolled(true)
            let changes = TitleRevealObservationCounter()
            withObservationTracking {
                _ = reveal.progress
            } onChange: {
                MainActor.assumeIsolated { changes.count += 1 }
            }
            for titleBottom in stride(from: 2_000, through: 100, by: -1) {
                reveal.updateTitleBottom(CGFloat(titleBottom))
            }
            XCTAssertEqual(changes.count, 0)
            reveal.updateTitleBottom(99)
            XCTAssertEqual(changes.count, 1)
        }

        func testFullyRevealedScrollSamplesDoNotInvalidateButReverseCanRevealAgain() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateToolbarBottom(100)
            reveal.updateTitleBottom(52)
            reveal.updateScrolled(true)
            let changes = TitleRevealObservationCounter()
            withObservationTracking {
                _ = reveal.progress
            } onChange: {
                MainActor.assumeIsolated { changes.count += 1 }
            }
            for titleBottom in stride(from: 51, through: -2_000, by: -1) {
                reveal.updateTitleBottom(CGFloat(titleBottom))
            }
            XCTAssertEqual(changes.count, 0)
            reveal.updateTitleBottom(76)
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(reveal.progress, 0.5)
        }

        func testToolbarResizeUsesLatestRawTitlePositionEvenWhileFullyRevealed() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateToolbarBottom(100)
            reveal.updateTitleBottom(52)
            reveal.updateScrolled(true)
            reveal.updateTitleBottom(20)
            XCTAssertEqual(reveal.progress, 1)
            reveal.updateToolbarBottom(44)
            XCTAssertEqual(reveal.progress, 0.5)
            reveal.updateToolbarBottom(20)
            XCTAssertEqual(reveal.progress, 0)
        }

        func testRouteResetHidesPreviousTitleUntilFreshPositionAndScrollArrive() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateToolbarBottom(100)
            reveal.updateTitleBottom(0)
            reveal.updateScrolled(true)
            XCTAssertEqual(reveal.progress, 1)
            reveal.reset()
            XCTAssertEqual(reveal.progress, 0)
            reveal.updateScrolled(true)
            XCTAssertEqual(reveal.progress, 0)
            reveal.updateTitleBottom(76)
            XCTAssertEqual(reveal.progress, 0.5)
        }

        func testNonfiniteTitleAndUnavailableToolbarRemainHidden() {
            let reveal = FoundationMacTitleReveal()
            reveal.updateScrolled(true)
            reveal.updateToolbarBottom(100)
            for position: CGFloat in [.nan, .infinity, -.infinity] {
                reveal.updateTitleBottom(position)
                XCTAssertEqual(reveal.progress, 0)
            }
            reveal.updateTitleBottom(10)
            reveal.updateToolbarBottom(0)
            XCTAssertEqual(reveal.progress, 0)
        }
    }

    @MainActor private final class TitleRevealObservationCounter {
        var count = 0
    }
#endif
