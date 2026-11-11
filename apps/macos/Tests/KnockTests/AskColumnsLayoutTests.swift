import CoreGraphics
import Testing
@testable import Knock

/// C1: one layout for every request page. The decision column is 440 pt beside the artifact; the artifact folds to
/// the pinned bar when it would get under 480 pt; with no artifact the column is the page, at most 640 pt wide.
struct AskColumnsLayoutTests {
    @Test func theColumnIs440BesideTheArtifact() {
        #expect(AskLayout.columnWidth == 440)
        #expect(AskLayout.columnWidth(.beside, width: 1400) == 440)
        #expect(AskLayout.columnWidth(.beside, width: 2560) == 440)
    }

    @Test func theArtifactFoldsUnder480() {
        #expect(AskLayout.minArtifactWidth == 480)
        // 920 = 440 column + 480 artifact: the narrowest pane with both.
        #expect(AskLayout.layout(width: 920, hasArtifact: true) == .beside)
        #expect(AskLayout.layout(width: 919.5, hasArtifact: true) == .folded)
        #expect(AskLayout.layout(width: 700, hasArtifact: true) == .folded)
        #expect(AskLayout.layout(width: 1600, hasArtifact: true) == .beside)
    }

    @Test func withNoArtifactTheColumnIsThePageAtMost640() {
        #expect(AskLayout.layout(width: 1600, hasArtifact: false) == .page)
        #expect(AskLayout.layout(width: 500, hasArtifact: false) == .page)
        #expect(AskLayout.pageMaxWidth == 640)
        #expect(AskLayout.columnWidth(.page, width: 1600) == 640)
        #expect(AskLayout.columnWidth(.page, width: 500) == 500)
        // A folded artifact leaves the same page column.
        #expect(AskLayout.columnWidth(.folded, width: 900) == 640)
    }

    @Test func theArtifactTakesTheRestInWholePoints() {
        #expect(AskColumnsLayout.widths(1000) == [560, 440])
        // A width with a fraction (the drift seen in issue 9): both columns stay on whole points.
        #expect(AskColumnsLayout.widths(1048.36) == [608, 440])
    }

    @Test func theArtifactNeverGetsUnderItsMinimumBesideTheColumn() {
        for total: CGFloat in [920, 1048.73, 1440, 1720.5] {
            #expect(AskLayout.layout(width: total, hasArtifact: true) == .beside)
            let widths = AskColumnsLayout.widths(total)
            #expect(widths[0] >= AskLayout.minArtifactWidth)
            #expect(widths[1] == AskLayout.columnWidth)
            #expect(widths[0] + widths[1] <= total)
        }
    }

    @Test func noWidthGivesTwoEmptyColumns() {
        #expect(AskColumnsLayout.widths(0) == [0, 0])
    }

    /// The step's points sit in the column where the bar showed them: an open answer, nothing in flight. The
    /// "Ask for…" panel takes their place there, in the column (C5), so the slot stays while it is open.
    @Test func theStepPointsShowInTheColumnOnlyWhileTheStepCanBeAnswered() {
        #expect(StepPointsInColumn.shows(isLocked: false, deliveryIdle: true))
        #expect(!StepPointsInColumn.shows(isLocked: true, deliveryIdle: true))
        #expect(!StepPointsInColumn.shows(isLocked: false, deliveryIdle: false))
    }
}
