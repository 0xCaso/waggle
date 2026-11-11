import Foundation
import SwiftUI
import Testing
@testable import Knock

/// WAG-336: no pre-pick, soft recommended mark, suggested reply, change-request button, button label by width,
/// two-line titles, Reduce Motion gate.
@Suite(.serialized)
@MainActor
struct WAG336Tests {
    private let options = [
        Option(id: "a", label: "Approve the plan", title: "Approve the plan"),
        Option(id: "b", label: "Something else", title: "Something else"),
    ]

    private func makeCase(
        options: [Option]? = nil, recommendation: String = "a", why: String = "Fast", plan: PlanInfo? = nil
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick", need: "Need", why: "Why",
            recommendation: recommendation, recommendationWhy: why, options: options ?? self.options,
            status: .needsYou, hasArtifact: false, createdAt: "2026-10-09T10:00:00Z", updatedAt: "2026-10-09T10:00:00Z", plan: plan)
    }

    private func planInfo(_ name: PlanStageName) -> PlanInfo {
        PlanInfo(stage: PlanStage(name: name, step: 1, total: 3, totalIsEstimate: true), rounds: 1, answered: 0)
    }

    // MARK: No pre-pick

    @Test func noRequestShapePrePicksItsRecommendation() {
        for name in [PlanStageName.questions, .approaches, .design, .spec] {
            let composer = ComposerViewModel(knockCase: makeCase(plan: planInfo(name)))
            #expect(composer.selectedOptionId == nil && !composer.hasPrePick && !composer.hasPick, "stage \(name)")
        }
        let plain = ComposerViewModel(knockCase: makeCase())
        #expect(plain.selectedOptionId == nil && !plain.hasPick)
        #expect(!ComposerViewModel.preselectsRecommendation(makeCase(plan: planInfo(.questions))))
    }

    @Test func aPlanRoundWithNothingToSendShowsTheBareArrow() {
        #expect(PromptBarLogic.plansBareArrow(isPlanRound: true, hasOptions: true, canSend: false))
        #expect(!PromptBarLogic.plansBareArrow(isPlanRound: true, hasOptions: true, canSend: true))
        #expect(!PromptBarLogic.plansBareArrow(isPlanRound: false, hasOptions: true, canSend: false))
    }

    @Test func theRecommendedCardOpensUntilThePersonPicksAnother() {
        // Decision 2026-11-10: no honey edge on the recommendation; it is the open card until a pick.
        #expect(CalmOption.openPosition(selected: nil, recommended: 2, isCheckbox: false) == 2)
        #expect(CalmOption.openPosition(selected: 3, recommended: 2, isCheckbox: false) == 3)
        #expect(CalmOption.openPosition(selected: nil, recommended: nil, isCheckbox: false) == nil)
    }

    // MARK: Reply only

    @Test func aReplyOnlyAskOffersTheSuggestedReplyWithItsReason() {
        let free = makeCase(options: [], recommendation: "All quiet, with a small line.", why: "It is calm.")
        let suggestion = ComposerFooterView.suggestion(for: free, draftIsEmpty: true)
        #expect(suggestion == .init(text: "All quiet, with a small line.", why: "It is calm."))
        #expect(ComposerFooterView.suggestion(for: free, draftIsEmpty: false) == nil)
        #expect(ComposerFooterView.suggestion(for: makeCase(options: [], recommendation: "  ", why: ""), draftIsEmpty: true) == nil)
        #expect(ComposerFooterView.suggestion(for: makeCase(options: [], recommendation: "Yes", why: ""), draftIsEmpty: true)?.why == nil)
        #expect(ComposerFooterView.suggestion(for: makeCase(), draftIsEmpty: true) == nil)
    }

    /// Spec 2026-11-09 section 9: "Use this reply" is a quiet button of the send row, the last to go into More.
    @Test func useThisReplyIsTheLastQuietButtonOfTheSendRow() {
        #expect(PromptBarLogic.quietLabels(hasOpenReview: false, hasDetail: false, suggestsReply: true) == ["Use this reply"])
        #expect(PromptBarLogic.quietLabels(hasOpenReview: true, hasDetail: false, suggestsReply: true)
            == [PromptBarLogic.openReviewLabel, "Use this reply"])
        #expect(!PromptBarLogic.quietLabels(hasOpenReview: false, hasDetail: false).contains("Use this reply"))
    }

    // MARK: Request changes

    @Test func anAgentChangesOptionMeansNoSecondChangesButton() {
        let own = [Option(id: "a", label: "Approve the plan"), Option(id: "b", label: "Changes", title: "Changes")]
        #expect(PlanText.hasChangesOption(own))
        #expect(PlanText.hasChangesOption([Option(id: "x", label: "Request changes")]))
        #expect(!PlanText.hasChangesOption(options))
        let withOwn = ComposerViewModel(knockCase: makeCase(options: own, plan: planInfo(.spec)))
        #expect(withOwn.planSecondaryLabel == nil)
        let without = ComposerViewModel(knockCase: makeCase(plan: planInfo(.spec)))
        #expect(without.planSecondaryLabel == "Request changes")
        let design = ComposerViewModel(knockCase: makeCase(plan: planInfo(.design)))
        #expect(design.planSecondaryLabel == "Change")
        #expect(PlanText.whatShouldChange == "What should change?")
    }

    // MARK: Button label by width

    private let discuss = PromptBarLogic.discussLabels(leaning: [], ruledOut: [3])!
    private var pills: [String?] { PromptBarLogic.sendPillLabels(commentCount: 0, discuss: discuss) }

    @Test func aWideRowKeepsTheFullLabel() {
        let plan = PromptBarLogic.controlsPlan(rowWidth: 700, quietLabels: [], pillLabels: pills)
        #expect(plan.sendPillLabel == "Rule out 3, keep talking")
    }

    @Test func aTightRowUsesTheShortLabelBeforeAnythingIsCut() {
        let full = PromptBarLogic.ControlsPlan(quietLabels: [], overflowLabels: [], sendPillLabel: "Rule out 3, keep talking")
        let short = PromptBarLogic.ControlsPlan(quietLabels: [], overflowLabels: [], sendPillLabel: "Rule out 3")
        let leading = PromptBarLogic.attachWidth + PromptBarLogic.controlGap
        #expect(full.width > short.width)
        // Room for the short label, not the full one.
        let plan = PromptBarLogic.controlsPlan(rowWidth: leading + full.width - 1, quietLabels: [], pillLabels: pills)
        #expect(plan.sendPillLabel == "Rule out 3")
        #expect(plan.width + leading <= leading + full.width - 1)
        // Room for the full label: it keeps it.
        #expect(PromptBarLogic.controlsPlan(rowWidth: leading + full.width, quietLabels: [], pillLabels: pills).sendPillLabel
            == "Rule out 3, keep talking")
    }

    // MARK: Titles and motion

    @Test func cardsMatchTheMockupSizes() {
        // Case map mockup `.choice`, `.ch`, `.x`, `.tl`, `.key` (decision 2026-11-10).
        #expect(CalmOption.rowRadius == 10 && CalmOption.rowGap == 6)
        #expect(OptionCardStyle.openHeaderPadding == 9 && OptionCardStyle.slimHeaderPadding == 7 && OptionCardStyle.sidePadding == 12)
        #expect(OptionCardStyle.textIndent == OptionCardStyle.sidePadding + OptionCardStyle.markSize + OptionCardStyle.itemGap)
        #expect(OptionCardStyle.markSize == 16 && OptionCardStyle.dotSize == 8 && OptionCardStyle.boxRadius == 4)
        #expect(OptionCardStyle.keyHeight == CGFloat(18.5)) // 10.5 + 2 × 3 padding + 2 × 1 border
        #expect(OptionCardStyle.title.size == 13.5 && OptionCardStyle.body.size == 12 && OptionCardStyle.label.letterSpacing == 0.63)
    }

    @Test func theScrollGateRunsTheBodyEitherWay() {
        var ran = 0
        ReducedMotion.animate(reduceMotion: true) { ran += 1 }
        ReducedMotion.animate(reduceMotion: false) { ran += 1 }
        #expect(ran == 2)
    }
}

/// WAG-346, then the request page mockups (2026-11-10, `.ans`, `.note`, `.ans .tools`, `.send`): the numbers of
/// the prompt bar.
struct WAG346BarMetricsTests {
    @Test func theAnswerAreaHasTheMockupsNumbers() {
        // `.ans` padding 10 / 14 / 12; tools gap 14, margin-top 8.
        #expect(PromptBarLogic.barTopPadding == 10)
        #expect(PromptBarLogic.barPadding == 14)
        #expect(PromptBarLogic.barBottomPadding == 12)
        #expect(PromptBarLogic.controlGap == 14)
        #expect(PromptBarLogic.rowGap == 8)
        // `.note`: one line is 18 + 2 × 9 (padding 8 + border 1) = 36 tall; the text view is 28 inside the box.
        #expect(PromptBarLogic.contentHeight(usedTextHeight: PromptBarLogic.lineHeight) == PromptBarLogic.controlSize)
        #expect(PromptBarLogic.controlSize + PromptBarLogic.fieldBoxPadding.height * 2 == 36)
        #expect(PromptBarLogic.textInset.width + PromptBarLogic.fieldBoxPadding.width == 12)
        #expect(PromptBarLogic.fieldRadius == 9)
        #expect(PromptBarLogic.answerFontSize == 12.5)
        // `.send`: 12.5 / 1.45 + 2 × 8 ≈ 34, sides 12.
        #expect(PromptBarLogic.sendHeight == 34)
        #expect(PromptBarLogic.sendHorizontalPadding == 12)
        // The whole area with one line: 10 + 36 + 8 + 34 + 12.
        #expect(PromptBarLogic.barTopPadding + 36 + PromptBarLogic.rowGap + PromptBarLogic.sendHeight + PromptBarLogic.barBottomPadding == 100)
    }

    /// The plain decision names the pick: "Send: <option> ↵"; a narrow row gets "Send ↵", never a cut title.
    @Test func thePlainDecisionNamesThePick() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: "B", sendTitle: "B · Options in place")
            == ["Send: B · Options in place ↵", "Send ↵"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 2, decideTitle: "B", sendTitle: "B · Options in place")
            == ["Send: B · Options in place + 2 comments", "Send + 2 comments", "Send"])
        // An edit, leans, a typed change or a review keep today's words.
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, hasEdit: true, decideTitle: "B", sendTitle: "B").first ?? nil != "Send: B ↵")
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: "B", withChanges: .decide, sendTitle: "B")
            == PromptBarLogic.sendPillLabels(commentCount: 0, withChanges: .decide))
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, decideTitle: "Approve") == ["Decide"])
    }

    /// Under a field on its own row the tools give way first ("Show me more", then "Let's discuss"), then the
    /// quiet buttons, and only then does Send take its short form.
    @Test func theToolsGiveWayBeforeSendGetsShorter() {
        let widths = PromptBarLogic.ControlWidths(quiet: { _ in 80 }, send: { $0 == nil ? 34 : ($0!.count > 10 ? 180 : 60) })
        let tools = ["Let's discuss", "Show me more"]
        let forms: [String?] = ["Send: B · Options in place ↵", "Send ↵"]
        func plan(_ row: CGFloat, quiet: [String] = []) -> PromptBarLogic.ControlsPlan {
            PromptBarLogic.controlsPlan(
                rowWidth: row, quietLabels: quiet, pillLabels: forms, widths: widths, leadingWidth: 16,
                leadingLabels: tools)
        }
        // Room for everything: 16 + 14 + (80 + 14 + 80 + 14 + 180 + 8).
        let all = plan(16 + 14 + 376)
        #expect(all.leadingLabels == tools && all.overflowLabels.isEmpty && all.sendPillLabel == forms[0])
        let one = plan(16 + 14 + 375)
        #expect(one.leadingLabels == ["Let's discuss"] && one.overflowLabels == ["Show me more"] && one.sendPillLabel == forms[0])
        let none = plan(16 + 14 + 180 + 14 + 20 + 8)
        #expect(none.leadingLabels.isEmpty && none.overflowLabels == tools && none.sendPillLabel == forms[0])
        let short = plan(16 + 14 + 150)
        #expect(short.sendPillLabel == "Send ↵")
        // A quiet button ("Open review") goes after the tools.
        let quiet = plan(16 + 14 + 80 + 14 + 180 + 14 + 20 + 8, quiet: ["Open review"])
        #expect(quiet.quietLabels == ["Open review"] && quiet.overflowLabels == tools)
    }
}
