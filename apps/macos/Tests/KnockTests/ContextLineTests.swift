import Testing
@testable import Knock

/// C2: the header is the top bar plus at most one context line; stepped asks show numbers only; the previous answer
/// folds to "You chose X · Show".
struct ContextLineTests {
    private let options = [Option(id: "a", label: "A", title: "A · Calm"), Option(id: "b", label: "B", title: "B · Options in place")]

    private func item(
        follows: String? = nil, replaces: String? = nil, plan: PlanInfo? = nil, replyId: String? = nil,
        choice: String? = nil, choices: [String] = [], message: String? = nil, answers: [PointAnswer] = [],
        options custom: [Option]? = nil
    ) -> Case {
        Case(
            id: "c1", taskId: "t1", kind: .question, title: "Title", need: "", why: "", recommendation: "",
            recommendationWhy: "", options: custom ?? options, status: .needsYou, hasArtifact: false, latestReplyId: replyId,
            latestReplyChoice: choice, latestReplyMessage: message, latestReplyChoices: choices,
            followsCaseId: follows, replacesCaseId: replaces, createdAt: "2026-11-09T10:00:00Z",
            updatedAt: "2026-11-09T10:00:00Z", plan: plan, latestReplyAnswers: answers)
    }

    private let plan = PlanInfo(stage: PlanStage(name: .approaches), rounds: 2, answered: 1)

    // MARK: what the context line holds

    @Test func noContextMeansNoLine() {
        #expect(ContextLine.content(for: item()).isEmpty)
        #expect(ContextLine.content(for: item(), status: "").isEmpty)
    }

    @Test func aFollowUpHoldsTheLinkToTheEarlierAsk() {
        let content = ContextLine.content(for: item(follows: "c0"))
        #expect(content.link == .followUp(caseId: "c0") && content.plan == nil && !content.isEmpty)
        #expect(ContextLine.linkPrefix(.followUp(caseId: "c0")) == "↩ Follow-up to")
    }

    @Test func aReplaceHoldsTheReplacedAsk() {
        #expect(ContextLine.content(for: item(replaces: "c0")).link == .replaces(caseId: "c0"))
        #expect(ContextLine.linkPrefix(.replaces(caseId: "c0")) == "Replaces")
    }

    @Test func aFollowUpWinsOverAReplace() {
        #expect(ContextLine.content(for: item(follows: "c0", replaces: "c9")).link == .followUp(caseId: "c0"))
    }

    @Test func aPlanFollowUpHoldsTheLinkAndTheTrackOnOneLine() {
        let content = ContextLine.content(for: item(follows: "c0", plan: plan))
        #expect(content.link == .followUp(caseId: "c0") && content.plan == plan)
    }

    @Test func theStatusHasASlot() {
        let content = ContextLine.content(for: item(), status: "Session closed")
        #expect(!content.isEmpty && content.status == "Session closed")
    }

    // MARK: the plan track's tooltips

    @Test func eachStageWordSaysMoreInItsTooltip() {
        #expect(PlanText.trackHelp(.questions, state: .done, plan: plan) == "Questions: done")
        #expect(PlanText.trackHelp(.approaches, state: .current, plan: plan) == "Approaches · round 2")
        #expect(PlanText.trackHelp(.design, state: .upcoming, plan: plan) == "Design: not started")
        let design = PlanInfo(stage: PlanStage(name: .design, step: 1, total: 3), rounds: 1, answered: 0)
        #expect(PlanText.trackHelp(.design, state: .current, plan: design) == "Design · section 1 of 3")
        let question = PlanInfo(stage: PlanStage(name: .questions, step: 2, total: 5), rounds: 1, answered: 0)
        #expect(PlanText.trackHelp(.questions, state: .current, plan: question) == "Questions · Question 2 of 5")
    }

    // MARK: the previous answer, folded

    @Test func noReplyNoAnswerLine() {
        #expect(PreviousAnswer.label(item()) == nil)
        #expect(PreviousAnswer.foldTitle(item(), fallback: "Earlier round") == "Earlier round")
    }

    @Test func aPickReadsYouChoseItsTitle() {
        #expect(PreviousAnswer.label(item(replyId: "r", choice: "b", message: "A long message")) == "You chose B · Options in place")
        #expect(PreviousAnswer.label(item(replyId: "r", choices: ["a", "b"])) == "You chose A · Calm, B · Options in place")
    }

    @Test func answersAndWordsHaveTheirOwnLine() {
        let answers = [
            PointAnswer(questionId: "q1", pointId: "p1", choice: "x", note: nil),
            PointAnswer(questionId: "q2", pointId: "p2", choice: "y", note: nil),
        ]
        #expect(PreviousAnswer.label(item(replyId: "r", answers: answers, options: [])) == "You answered 2 questions")
        #expect(PreviousAnswer.label(item(replyId: "r", message: "Go ahead", options: [])) == "You replied")
    }

    // MARK: the step bar

    @Test func theStepBarShowsNumbersWithTheFullTitleInTheTooltip() {
        var first = Question(id: "q1", title: "Where does the decision sit on the page?", now: nil, points: [
            QuestionPoint(id: "p1", text: "Where?", options: ["Here", "There"])], artifactRef: nil, variants: nil, variantLabel: nil)
        first.groupTitle = "Base rules"
        let second = Question(id: "q2", title: "How do we show the options once?", now: nil, points: [
            QuestionPoint(id: "p2", text: "How?", options: ["One list", "Two"])], artifactRef: nil, variants: nil, variantLabel: nil)
        #expect(QuestionsDocModel.stepHelp(first, index: 0) == "1. Where does the decision sit on the page?\nBase rules")
        #expect(QuestionsDocModel.stepHelp(second, index: 1) == "2. How do we show the options once?")
        let send = QuestionsDocModel.StepPill(index: 2, title: "Send", isCurrent: false, isDone: false, isSend: true, help: "Review and send")
        let step = QuestionsDocModel.StepPill(index: 1, title: "How do…", isCurrent: true, isDone: false, isSend: false)
        #expect(send.number == "Send" && step.number == "2")
    }
}
