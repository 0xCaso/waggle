import CoreGraphics
import Testing
@testable import Knock

/// Request page tasks 5 and 6: the "Ask for…" button and panel (C5).
@MainActor
struct RequestPageOptionsTests {
    // MARK: - C5: the "Ask for…" panel keeps every chip and key

    @Test func thePanelListsEveryPillOfTheOldRow() {
        for pill in DetailPill.all {
            #expect(AskForPanel.lists(pill), "\(pill.label) has no row in the panel")
        }
    }

    @Test func thePanelRowsAreTheAsksThenScreenshotsThenTheFormatsThenSomethingElse() {
        let entries = AskForPanel.entries
        #expect(entries.count == 10)
        #expect(entries.prefix(5) == ArraySlice(zip(ComposerViewModel.detailChips, ComposerViewModel.detailChipUsageNames).map {
            AskForPanel.Entry.ask(text: $0, usage: $1)
        }))
        #expect(entries[5] == .ask(text: "Show me screenshots", usage: "screenshots"))
        #expect(Array(entries[6..<9]) == ReplyFormat.allCases.map(AskForPanel.Entry.format))
        #expect(entries.last == .somethingElse)
    }

    @Test func eachPanelRowHasItsOwnKey() {
        let keys = AskForPanel.entries.indices.compactMap(AskForPanel.key(at:))
        #expect(keys == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"])
        #expect(AskForPanel.key(at: 10) == nil)
    }

    @Test func theQuickRepliesStayInThePanel() {
        #expect(QuickReply.visible(hasComments: false).map(\.label) == ["Let's discuss", "Show me more"])
        #expect(QuickReply.visible(hasComments: true).map(\.label) == ["Let's discuss", "Look at my comments", "Show me more"])
    }

    @Test func theFooterPanelScrollsInsideItsCap() {
        #expect(ComposerFooterView.panelCap(availableHeight: 1000) == 450)
        #expect(ComposerFooterView.panelCap(availableHeight: 300) == 160)
        #expect(ComposerFooterView.panelCap(availableHeight: nil) == 360)
    }

    // MARK: - C5: "Ask for…" at the left of the send row

    @Test func theLeftOfTheSendRowIsThePlusAloneOrThePlusAndAskFor() {
        #expect(PromptBarLogic.leadingWidth(askForLabelWidth: nil) == PromptBarLogic.attachWidth)
        // "+" 16, the tools gap 14, "Ask for…" as plain text (request page mockups, 2026-11-10).
        #expect(PromptBarLogic.leadingWidth(askForLabelWidth: 50) == CGFloat(16 + 14 + 50))
    }

    @Test func askForTakesWidthFromTheFieldNotFromSend() {
        let plain = PromptBarLogic.sharedRowFieldWidth(barWidth: 440, controlsWidth: 100)
        let withAskFor = PromptBarLogic.sharedRowFieldWidth(
            barWidth: 440, controlsWidth: 100, leadingWidth: PromptBarLogic.leadingWidth(askForLabelWidth: 50))
        #expect(plain - withAskFor == CGFloat(16 + 14 + 50 - 28))
        // A row too narrow for the field beside "+", "Ask for…" and Send gives the controls their own row. There Send
        // takes its short form before anything is cut: "Ask for…" is never dropped, Send never shows "…".
        let forms: [String?] = ["Decide: B · Options in place", "Decide"]
        let plan = PromptBarLogic.controlsPlan(
            rowWidth: 280, quietLabels: [], pillLabels: forms, leadingWidth: PromptBarLogic.leadingWidth(askForLabelWidth: 50))
        #expect(plan.ownRow)
        #expect(plan.sendPillLabel == "Decide")
    }

    @Test func theOldQuietDetailButtonIsGone() {
        // The bar passes `hasDetail: false`: "Ask for…" is the one way in.
        #expect(PromptBarLogic.quietLabels(hasOpenReview: true, hasDetail: false) == [PromptBarLogic.openReviewLabel])
    }
}
