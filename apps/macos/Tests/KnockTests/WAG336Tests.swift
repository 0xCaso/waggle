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

    @Test func theRecommendedRowGetsASoftMarkOnlyWhileItIsNotTheState() {
        #expect(CalmOption.showsSoftMark(isRecommended: true, isSelected: false, isLeaning: false, isRuledOut: false, isLocked: false))
        #expect(!CalmOption.showsSoftMark(isRecommended: false, isSelected: false, isLeaning: false, isRuledOut: false, isLocked: false))
        #expect(!CalmOption.showsSoftMark(isRecommended: true, isSelected: true, isLeaning: false, isRuledOut: false, isLocked: false))
        #expect(!CalmOption.showsSoftMark(isRecommended: true, isSelected: false, isLeaning: true, isRuledOut: false, isLocked: false))
        #expect(!CalmOption.showsSoftMark(isRecommended: true, isSelected: false, isLeaning: false, isRuledOut: true, isLocked: false))
        #expect(!CalmOption.showsSoftMark(isRecommended: true, isSelected: false, isLeaning: false, isRuledOut: false, isLocked: true))
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

    @Test func aWideRowKeepsTheFullLabelAndTheField() {
        let plan = PromptBarLogic.controlsPlan(rowWidth: 700, quietLabels: [], pillLabels: pills)
        #expect(plan.sendPillLabel == "Rule out 3, keep talking" && !plan.ownRow)
    }

    @Test func aTightRowUsesTheShortLabelBeforeTheFieldGetsNarrower() {
        let full = PromptBarLogic.ControlsPlan(quietLabels: [], overflowLabels: [], sendPillLabel: "Rule out 3, keep talking")
        let short = PromptBarLogic.ControlsPlan(quietLabels: [], overflowLabels: [], sendPillLabel: "Rule out 3")
        let row = short.width + PromptBarLogic.controlSize + PromptBarLogic.controlGap * 2 + PromptBarLogic.minFieldWidth
        #expect(full.width > short.width)
        let plan = PromptBarLogic.controlsPlan(rowWidth: row, quietLabels: [], pillLabels: pills)
        #expect(plan.sendPillLabel == "Rule out 3" && !plan.ownRow)
        let layout = PromptBarLogic.layout(text: "", barWidth: row + PromptBarLogic.barPadding * 2, controlsWidth: plan.width, maxLines: 6, forcesOwnRow: plan.ownRow)
        #expect((layout.singleRowFieldWidth ?? 0) >= PromptBarLogic.minFieldWidth - 1)
    }

    @Test func whenEvenTheShortLabelLeavesTheFieldUnder200TheControlsTakeASecondRow() {
        let quiet = ["Back"]
        let plan = PromptBarLogic.controlsPlan(rowWidth: 330, quietLabels: quiet, pillLabels: pills)
        #expect(plan.ownRow)
        let layout = PromptBarLogic.layout(text: "", barWidth: 342, controlsWidth: plan.width, maxLines: 6, forcesOwnRow: plan.ownRow)
        #expect(layout.isMultiline)
    }

    // MARK: Titles and motion

    @Test func rowTitlesWrapToTwoLines() {
        #expect(CalmOption.rowTitleLines == 2)
    }

    @Test func theScrollGateRunsTheBodyEitherWay() {
        var ran = 0
        ReducedMotion.animate(reduceMotion: true) { ran += 1 }
        ReducedMotion.animate(reduceMotion: false) { ran += 1 }
        #expect(ran == 2)
    }
}

/// WAG-346: the Pen numbers of the prompt bar.
struct WAG346BarMetricsTests {
    @Test func aOneLineBarIs48TallWithTheControlsOnOneLine() {
        #expect(PromptBarLogic.barPadding == 10)
        #expect(PromptBarLogic.controlGap == 6)
        let layout = PromptBarLogic.layout(text: "", barWidth: 600, controlsWidth: 28, maxLines: 6)
        #expect(!layout.isMultiline)
        #expect(layout.fieldHeight == PromptBarLogic.controlSize)
        #expect(PromptBarLogic.barPadding * 2 + PromptBarLogic.controlSize == 48)
    }
}
