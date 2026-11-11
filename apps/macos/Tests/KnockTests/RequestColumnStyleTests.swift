import Foundation
import Testing
@testable import Knock

/// The decision column drawn as the case map mockup (decision 2026-11-10): the CSS line heights, the table rules,
/// the need's fold, the round divider and the follow-up words.
struct RequestColumnStyleTests {
    @Test func cssStylesDrawTheCSSLineBox() {
        // `knockTextStyle` adds size × (lineHeight − 1) on top of the font's 1.21: the CSS 13/1.5 box is 19.5.
        let need = Theme.AskDoc.Column.need
        let drawn = need.size * Theme.Typography.sansNaturalLineHeight + need.size * ((need.lineHeight ?? 1) - 1)
        #expect(abs(drawn - 19.5) < 0.01)
        #expect(Theme.AskDoc.Column.title.size == 19)
        #expect(Theme.AskDoc.Column.title.letterSpacing == -0.38)
        #expect(AskHeaderWidth.narrow.titleStyle.size == 19)
        #expect(Theme.AskDoc.Radius.need == 10)
    }

    @Test func numberColumnsAreRightAlignedAndMutedCellsDoNotCount() {
        let rows = [["Order ahead", "$1,200", "High", "—"], ["Alerts", "—", "Low", "12 %"], ["List", "~5", "Medium", "n/a"]]
        #expect(AskTableRules.numericColumns(headers: ["Idea", "Cost", "Use", "Share"], rows: rows) == [1, 3])
        #expect(AskTableRules.isMuted("—"))
        #expect(AskTableRules.isMuted(" n/a "))
        #expect(!AskTableRules.isMuted("Low"))
        #expect(AskTableRules.isNumber("15:00"))
        #expect(!AskTableRules.isNumber("v2 of the artifact"))
    }

    @Test func longDetailsFoldBehindShowWithWhatTheyHold() {
        let table = "| A | B |\n|---|---|\n| 1 | 2 |"
        #expect(NeedText.foldsDetails(question: "Which one?", details: table))
        #expect(!NeedText.foldsDetails(question: "Which one?", details: "A short line."))
        #expect(!NeedText.foldsDetails(question: "", details: table))
        #expect(NeedText.foldsDetails(question: "Which one?", details: String(repeating: "word ", count: 60)))
        #expect(NeedText.showLabel(table + "\n\nMore text.") == "Show 1 more paragraph and a table")
        #expect(NeedText.showLabel("- a\n- b\n\nOne.\n\nTwo.") == "Show 2 more paragraphs and a list")
    }

    @Test func aRoundDividerOpensTheRowsAfterYourReply() {
        let at = Date(timeIntervalSince1970: 0)
        let entries = ConversationRules.entries([
            .asked(.init(need: "Pick one", meta: nil, at: at)),
            .replied(.init(summary: "B", meta: nil, at: at, pickedUp: nil)),
            .updated(.init(message: "Working", revision: nil, at: at, isWorking: true)),
            .updated(.init(message: "Done", revision: .init(n: 2, isLatest: true, prior: 1), at: at)),
        ])
        #expect(ConversationRules.roundDivider(entries, at: 0) == nil)
        #expect(ConversationRules.roundDivider(entries, at: 1) == nil)
        #expect(ConversationRules.roundDivider(entries, at: 2) == "round 2 · v2 of the artifact")
        #expect(ConversationRules.roundDivider(entries, at: 3) == nil)
        #expect(ConversationRules.latestPosition(entries) == 3)
    }
}
