import Foundation
import SwiftUI
import Testing
@testable import Knock

/// WAG-303: the workspace uses the shared pick box and rows; counts, lean icon, discuss in Review/*.
@Suite(.serialized)
@MainActor
struct WAG303Tests {
    private let options = [
        Option(id: "a", label: "Compact layout with a sidebar", title: "Compact", pros: ["Fast", "Small", "Clear"], cons: ["Dense", "Hard to extend"]),
        Option(id: "b", label: "Detailed layout with tabs", title: "Detailed", pros: ["Roomy"], cons: ["Slow"]),
        Option(id: "c", label: "Wizard layout, one step at a time", title: "Wizard"),
    ]

    private func makeCase(plan: PlanInfo? = nil, intent: ReplyIntent? = nil, message: String? = nil) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Pick a layout", need: "Need", why: "Why",
            recommendation: "a", recommendationWhy: "Because it is fast", options: options,
            status: intent == nil ? .needsYou : .waitingOnAgent, hasArtifact: true,
            latestReplyId: intent == nil ? nil : "r1", latestReplyMessage: message, latestReplyIntent: intent,
            createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z", plan: plan)
    }

    private func planCase() -> Case {
        makeCase(plan: PlanInfo(stage: PlanStage(name: .questions, step: 1, total: 3, totalIsEstimate: true), rounds: 1, answered: 0))
    }

    // MARK: - Shared block and rows

    @Test func theWorkspaceShowsThePickBlockForASingleChoiceAskBeforeAnyPick() {
        #expect(AskPanelLayout.showsPickBlock(makeCase()))
        let composer = ComposerViewModel(knockCase: makeCase())
        let block = CalmOption.pickBlock(
            options: composer.options, selectedId: composer.selectedOptionId,
            recommendationId: "a", pickIsDefault: composer.pickIsDefault)
        #expect(block?.option.id == "a" && block?.isPick == false)
        #expect(CalmOption.blockLabel(position: 1, isPick: false) == "RECOMMENDED · 1")
    }

    @Test func noPickBlockForAFreeTextAsk() {
        let free = Case(
            id: "c2", taskId: "t1", kind: .question, title: "T", need: "N", why: "W", recommendation: "", recommendationWhy: "",
            options: [], status: .needsYou, hasArtifact: false, createdAt: "2026-10-08T10:00:00Z", updatedAt: "2026-10-08T10:00:00Z")
        #expect(!AskPanelLayout.showsPickBlock(free))
    }

    @Test func aTapMakesItYourPick() {
        let composer = ComposerViewModel(knockCase: makeCase())
        composer.selectOption("b")
        let block = CalmOption.pickBlock(options: composer.options, selectedId: composer.selectedOptionId, recommendationId: "a", pickIsDefault: composer.pickIsDefault)
        #expect(block?.option.id == "b" && block?.isPick == true)
        #expect(CalmOption.blockLabel(position: 2, isPick: true) == "YOUR PICK · 2")
    }

    // MARK: - RECOMMENDED vs YOUR PICK in a plan round

    @Test func aPlanRoundPreselectsNothingAndReadsRecommendedUntilATouch() {
        let composer = ComposerViewModel(knockCase: planCase())
        #expect(composer.selectedOptionId == nil)
        #expect(!composer.pickIsDefault)
        let before = CalmOption.pickBlock(options: composer.options, selectedId: nil, recommendationId: "a", pickIsDefault: false)
        #expect(before?.isPick == false && before?.position == 1)
        composer.selectOption("b")
        #expect(!composer.pickIsDefault)
        #expect(CalmOption.isPick(selectedId: composer.selectedOptionId, pickIsDefault: composer.pickIsDefault))
    }

    @Test func aLeanOrRuleOutAlsoEndsTheDefault() {
        let composer = ComposerViewModel(knockCase: planCase())
        composer.toggleLean("b")
        #expect(!composer.pickIsDefault)
    }

    @Test func resetClearsThePick() {
        let composer = ComposerViewModel(knockCase: planCase())
        composer.selectOption("b")
        composer.reset()
        #expect(composer.selectedOptionId == nil && !composer.pickIsDefault)
    }

    @Test func aDecisionAskStartsWithNoPickAndNoDefaultFlag() {
        let composer = ComposerViewModel(knockCase: makeCase())
        #expect(composer.selectedOptionId == nil && !composer.pickIsDefault)
    }

    // MARK: - Counts and tooltips

    @Test func aClosedCardShowsTheFirstProTheFirstConAndTheRest() {
        // Mockup `.tl`: no ✓N ⚠N counts any more (decision 2026-11-10).
        let teaser = CalmOption.teaser(pros: options[0].pros, cons: options[0].cons)
        #expect(teaser == CalmOption.Teaser(pro: options[0].pros[0], con: options[0].cons[0], more: 3))
        #expect(CalmOption.moreText(3) == "+3" && CalmOption.moreTip(3) == "3 more")
        #expect(![CalmOption.moreText(3), CalmOption.moreTip(3)].contains { $0.contains("—") })
    }

    @Test func theRowTooltipStillOpensWithTheLists() {
        #expect(CompactOptionRow.hasTip(description: nil, pros: ["a"], cons: [], note: nil))
        #expect(!CompactOptionRow.hasTip(description: nil, pros: [], cons: [], note: nil))
    }

    // MARK: - Dock cap

    @Test func theDockCapIsAShareOfTheColumnAndNeverTiny() {
        #expect(AskPanelLayout.dockCap(columnHeight: 1000) == 400)
        #expect(AskPanelLayout.dockCap(columnHeight: 200) == DecisionDock.minCap)
        #expect(AskPanelLayout.dockCap(columnHeight: 1000) < CasePaneDetailView.maxOptionsHeight + 1)
    }

    @Test func theFadeShowsOnlyWhileContentRunsUnderTheDock() {
        #expect(AskPanelLayout.showsBottomFade(contentHeight: 900, viewportHeight: 500))
        #expect(!AskPanelLayout.showsBottomFade(contentHeight: 400, viewportHeight: 500))
        #expect(!AskPanelLayout.showsBottomFade(contentHeight: 900, viewportHeight: 0))
    }

    // MARK: - Discuss reply in Review/*

    private func discussReply() throws -> Reply {
        let json = #"{"id":"r1","case_id":"c1","idempotency_key":"k","comments":[],"captures":[],"intent":"discuss","leaning":["a","b"],"ruled_out":["c"],"message":"Does the sidebar hide?","state":"queued","created_at":"2026-10-08T10:00:00Z"}"#
        return try JSONDecoder().decode(Reply.self, from: Data(json.utf8))
    }

    @Test func aDiscussReplyHasNoEmptyYouRepliedCard() throws {
        let item = makeCase(intent: .discuss, message: "Does the sidebar hide?")
        #expect(item.isTalkingItOver)
        let answer = SentAnswerCopy.answer(for: item, reply: try discussReply())
        #expect(answer.label != "YOU REPLIED" && answer.label != "YOU PICKED")
        #expect(answer.title == "Leaning: Compact, Detailed\nRuled out: Wizard")
        #expect(answer.note == "Does the sidebar hide?")
        #expect(SentAnswerCopy.claudeApp(answer).label == answer.label)
    }

    @Test func aDiscussReplyWithNoIdsStillSaysSomething() {
        let answer = SentAnswerCopy.answer(for: makeCase(intent: .discuss), reply: nil)
        #expect(answer.title == "Talking it over" && answer.note == nil)
    }

    @Test func aDiscussReplyIsNotARevisionPriorSoItArrivesLikeMoreDetail() throws {
        let revision = try JSONDecoder().decode(
            Revision.self, from: Data(#"{"id":"r_1","case_id":"c1","n":1,"created_at":"2026-10-08T10:00:00Z","author":"agent"}"#.utf8))
        let detail = CaseDetail(
            case: makeCase(), task: KnockTask(id: "t1", name: "n", project: "p"), messages: [], revisions: [revision],
            comments: [], replies: [try discussReply()])
        #expect(detail.revisionArrival != nil)
        let plain = CaseDetail(
            case: makeCase(), task: KnockTask(id: "t1", name: "n", project: "p"), messages: [], revisions: [revision],
            comments: [], replies: [])
        #expect(plain.revisionArrival == nil)
    }

    @Test func discussLinesNameLeansAndRuleOuts() {
        #expect(DiscussCopy.lines(leaning: ["A"], ruledOut: []) == ["Leaning: A"])
        #expect(DiscussCopy.lines(leaning: [], ruledOut: ["B", "C"]) == ["Ruled out: B, C"])
        #expect(DiscussCopy.titles(["a", "zz"], in: options) == ["Compact", "zz"])
    }
}
