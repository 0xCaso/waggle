import CoreGraphics
import Testing
@testable import Knock

/// Issue 9: the two columns of a side-by-side ask split the offered width, never a measured one.
struct AskColumnsLayoutTests {
    @Test func theArtifactTakesItsShareInWholePoints() {
        #expect(AskColumnsLayout.widths(1000) == [570, 430])
        // A width with a fraction (the drift seen in issue 9): the artifact stays on a whole point.
        let widths = AskColumnsLayout.widths(1048.36)
        #expect(widths[0] == 597)
        #expect(abs(widths[1] - 451.36) < 0.001)
    }

    @Test func theColumnsFillTheWidthExactly() {
        for total: CGFloat in [1000, 1048.73, 1440, 1720.5] {
            let widths = AskColumnsLayout.widths(total)
            #expect(abs(widths[0] + widths[1] - total) < 0.001)
        }
    }

    @Test func theQuestionGetsAtLeastItsMinimumOnTheNarrowestSideBySidePage() {
        let narrowest = AskLayout.minSideBySideWidth
        #expect(AskLayout.layout(width: narrowest, hasArtifact: true) == .sideBySide)
        #expect(AskColumnsLayout.widths(narrowest)[1] >= AskLayout.minQuestionWidth)
    }

    @Test func noWidthGivesTwoEmptyColumns() {
        #expect(AskColumnsLayout.widths(0) == [0, 0])
    }
}
