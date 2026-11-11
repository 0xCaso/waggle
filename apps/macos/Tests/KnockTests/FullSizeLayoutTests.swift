import Foundation
import Testing
@testable import Knock

/// Full size (C9, plan task 9): the decision column is 440 pt and narrows, down to 340 pt, when the artifact would
/// get under 60 % of the window. One / Set and Compare are segmented switches.
@MainActor
struct FullSizeLayoutTests {
    private func artifact(_ window: CGFloat) -> CGFloat { window - AskLayout.fullSizeColumnWidth(window: window) }

    @Test func wideWindowsKeepTheFullColumn() {
        // Full screen on a 16" (1728) and a 14" (1512) MacBook, a 13" window (1440), and 1280.
        for window: CGFloat in [1728, 1512, 1440, 1280] {
            #expect(AskLayout.fullSizeColumnWidth(window: window) == 440)
            #expect(artifact(window) >= window * 0.6)
        }
        #expect(artifact(1440) == 1000)
        #expect(artifact(1728) == 1288)
    }

    @Test func theColumnNarrowsWhenTheArtifactWouldGetUnderSixtyPercent() {
        // 1100 is the edge: 440 is exactly 40 %.
        #expect(AskLayout.fullSizeColumnWidth(window: 1100) == 440)
        #expect(AskLayout.fullSizeColumnWidth(window: 1000) == 400)
        #expect(AskLayout.fullSizeColumnWidth(window: 900) == 360)
        #expect(artifact(1000) == 600)
        #expect(artifact(900) == 540)
    }

    @Test func theColumnNeverGetsUnder340() {
        #expect(AskLayout.fullSizeColumnWidth(window: 850) == 340)
        #expect(AskLayout.fullSizeColumnWidth(window: 600) == 340)
        #expect(AskLayout.fullSizeColumnWidth(window: 0) == 340)
    }

    @Test func theWidthIsWholePointsAndNeverGrowsAsTheWindowShrinks() {
        var last = CGFloat.infinity
        for window in stride(from: CGFloat(1800), through: 700, by: -7) {
            let width = AskLayout.fullSizeColumnWidth(window: window)
            #expect(width == width.rounded())
            #expect(width <= last)
            last = width
        }
    }

    @Test func compareIsOneSwitchOffSideBySideSlider() {
        let compare = CompareModel()
        #expect(compare.choice == .off)
        compare.choose(.slider)
        #expect(compare.isOn && compare.layout == .slider && compare.choice == .slider)
        compare.sliderPosition = 0.8
        compare.choose(.slider)
        #expect(compare.sliderPosition == 0.8)
        compare.choose(.sideBySide)
        #expect(compare.choice == .sideBySide)
        compare.choose(.off)
        #expect(!compare.isOn && compare.choice == .off)
        #expect(CompareChoice.allCases.map(\.label) == ["Off", "Side by side", "Slider"])
    }
}
