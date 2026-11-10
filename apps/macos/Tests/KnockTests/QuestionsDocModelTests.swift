import Testing
import Foundation
@testable import Knock

/// The decision doc of an ask with questions (WAG-257, from WAG-252): protocol, progress, variants, bar.
struct QuestionsDocModelTests {
    private let questions: [Question] = [
        Question(
            id: "plans", title: "How many plans?", now: ["Three plans.", "Cards."],
            points: [QuestionPoint(id: "count", text: "How many?", options: ["Two", "Three"]), QuestionPoint(id: "badge", text: "Badge?", options: nil)],
            artifactRef: nil, variants: [QuestionVariant(id: "cards", label: "Cards"), QuestionVariant(id: "table", label: "Table")], variantLabel: "Layout"),
        Question(id: "cta", title: "Button label?", now: nil, points: [QuestionPoint(id: "label", text: "Which?", options: nil)], artifactRef: nil, variants: nil, variantLabel: nil),
    ]

    private func makeRequest(
        id: String = "c1", status: CaseStatus = .needsYou, answers: [PointAnswer] = [], questions: [Question]? = nil, message: String? = nil,
        optionsSeq: Int = 0, latestUpdateAt: String? = nil
    ) -> Case {
        Case(
            id: id, taskId: "t", kind: .question, title: "Pricing page\nmore", need: "Three decisions.\n\nSign-ups stall.", why: "Last screen.",
            recommendation: "R", recommendationWhy: "Because", options: [], status: status, hasArtifact: true,
            latestReplyMessage: message, latestReplyIntent: message == nil ? nil : .decision,
            updateCount: latestUpdateAt == nil ? nil : 1, latestUpdateAt: latestUpdateAt, createdAt: "2026-10-06T10:00:00Z", updatedAt: "2026-10-06T10:00:00Z",
            optionsSeq: optionsSeq, questions: questions ?? self.questions, latestReplyAnswers: answers)
    }

    // MARK: Protocol

    @Test func decodesQuestionsAndAnswers() throws {
        let json = #"""
        {"id":"plans","title":"How many plans?","now":["Three plans."],
         "points":[{"id":"count","text":"How many?","options":["Two","Three"]},{"id":"badge","text":"Badge?"}],
         "artifact_ref":"a_1","variants":[{"id":"cards","label":"Cards"},{"id":"table","label":"Table"}],"variant_label":"Layout"}
        """#
        let question = try JSONDecoder().decode(Question.self, from: Data(json.utf8))
        #expect(question.points[0].choiceLabels == ["Two", "Three"])
        #expect(question.points[1].choiceLabels == ["Yes", "No", "Talk with the team"])
        #expect(question.artifactRef == "a_1" && question.variantLabel == "Layout" && question.variants?.count == 2)
        let answer = try JSONDecoder().decode(PointAnswer.self, from: Data(#"{"question_id":"plans","point_id":"count","choice":"Two","note":"ok"}"#.utf8))
        #expect(answer == PointAnswer(questionId: "plans", pointId: "count", choice: "Two", note: "ok"))
    }

    @Test func anOptionMayBeAStringOrAnObjectWithProsAndCons() throws {
        let json = #"""
        {"id":"p","text":"Which layout?","options":["Plain",{"label":"Cards","pros":["Easy to scan"],"cons":["Takes room","Hard on a phone"]},{"label":"Table"}]}
        """#
        let point = try JSONDecoder().decode(QuestionPoint.self, from: Data(json.utf8))
        #expect(point.choiceLabels == ["Plain", "Cards", "Table"])
        #expect(point.options?[1].pros == ["Easy to scan"] && point.options?[1].cons == ["Takes room", "Hard on a phone"])
        #expect(point.options?[0].pros == [] && point.options?[2].cons == [])
    }

    @Test func aPlainOptionEncodesAsAStringAndOneWithPointsAsAnObject() throws {
        let plain = try JSONEncoder().encode(PointOption(label: "A"))
        #expect(String(data: plain, encoding: .utf8) == "\"A\"")
        let rich = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PointOption(label: "B", pros: ["x"], cons: []))) as? [String: Any]
        #expect(rich?["label"] as? String == "B" && (rich?["pros"] as? [String]) == ["x"] && rich?["cons"] == nil)
    }

    @Test func aReplyWithAnswersEncodesThem() throws {
        let params = ReplySubmitParams(
            caseId: "c1", idempotencyKey: "k", choice: nil, message: nil, comments: [], captures: [], intent: .decision,
            answers: [PointAnswer(questionId: "plans", pointId: "count", choice: "Two", note: nil)])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(params)) as? [String: Any]
        let answers = object?["answers"] as? [[String: Any]]
        #expect(answers?.first?["question_id"] as? String == "plans")
        #expect(answers?.first?["choice"] as? String == "Two")
    }

    @Test func aCaseWithoutQuestionsDecodesAsBefore() throws {
        let request = makeRequest(questions: [])
        #expect(request.questions.isEmpty && request.latestReplyAnswers.isEmpty)
        #expect(AskBarMode.forCase(request) != .answers)
    }

    // MARK: Progress

    @Test func countsPointsPerQuestionAndInTotal() {
        var model = QuestionsDocModel(request: makeRequest())
        #expect(model.totalPoints == 3 && model.answeredCount == 0)
        model.choose("Two", question: "plans", point: "count")
        model.choose("Yes", question: "cta", point: "label")
        #expect(model.progress == [false, true])
    }

    @Test func pickingTheChosenAnswerAgainClearsIt() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Two", question: "plans", point: "count")
        model.choose("Two", question: "plans", point: "count")
        #expect(model.answeredCount == 0)
    }

    @Test func aChoiceThatThePointDoesNotOfferIsIgnored() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Five", question: "plans", point: "count")
        model.choose("Maybe", question: "cta", point: "label")
        model.choose("Yes", question: "nope", point: "label")
        #expect(model.answeredCount == 0)
    }

    @Test func anAnswerGoesBackAsTheLabelOfAnObjectOption() {
        let rich = Question(
            id: "q", title: "T", now: nil,
            points: [QuestionPoint(id: "p", text: "Which?", options: [PointOption(label: "Cards", pros: ["Easy"], cons: ["Big"]), "Table"])],
            artifactRef: nil, variants: nil, variantLabel: nil)
        var model = QuestionsDocModel(request: makeRequest(questions: [rich]))
        model.choose("Cards", question: "q", point: "p")
        #expect(model.answers() == [PointAnswer(questionId: "q", pointId: "p", choice: "Cards", note: nil)])
    }

    // MARK: Bar

    @Test func theBarCountsAndLabelsTheSend() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Two", question: "plans", point: "count")
        model.choose("Yes", question: "cta", point: "label")
        model.note = "  "
        #expect(model.message == nil)
        model.note = "Ship it"
        #expect(model.message == "Ship it")
    }

    @Test func aNoteAloneSendsAsFeedback() {
        var model = QuestionsDocModel(request: makeRequest())
        #expect(!model.canSend && model.sendLabel == "Send answers" && !model.isFeedbackOnly)
        model.note = "   "
        #expect(!model.canSend && model.sendLabel == "Send answers")
        model.note = "The prototype should be a page one can navigate."
        #expect(model.canSend && model.isFeedbackOnly && model.sendLabel == "Send feedback")
        #expect(model.answers().isEmpty && model.message == "The prototype should be a page one can navigate.")
    }

    @Test func answersWithANoteStayAnAnswersSend() {
        var model = QuestionsDocModel(request: makeRequest())
        model.note = "Also shorter copy."
        model.choose("Two", question: "plans", point: "count")
        #expect(model.canSend && !model.isFeedbackOnly && model.sendLabel == "Send 1 answer")
        #expect(model.message == "Also shorter copy.")
    }

    @Test func pinnedCommentsJoinTheLabel() {
        var model = QuestionsDocModel(request: makeRequest())
        model.note = "Fix the page."
        #expect(model.sendLabel(comments: 3) == "Send feedback + 3 comments")
        #expect(model.sendLabel(comments: 1) == "Send feedback + 1 comment")
        model.choose("Two", question: "plans", point: "count")
        #expect(model.sendLabel(comments: 2) == "Send 1 answer + 2 comments")
        #expect(model.sendLabel(comments: 0) == "Send 1 answer")
    }

    @Test func sentFeedbackLocksTheBar() {
        var model = QuestionsDocModel(request: makeRequest())
        model.note = "Fix the page."
        model.markSent()
        #expect(!model.canSend)
    }

    @Test func feedbackIsTheLatestReplyOfTheCase() {
        let feedback = makeRequest(status: .waitingOnAgent, message: "Fix the page.")
        #expect(feedback.isFeedbackReply)
        let answered = makeRequest(
            status: .waitingOnAgent, answers: [PointAnswer(questionId: "cta", pointId: "label", choice: "Yes", note: nil)], message: "Ok")
        #expect(!answered.isFeedbackReply)
        #expect(!makeRequest(status: .waitingOnAgent).isFeedbackReply)
        #expect(makeRequest(status: .waitingOnAgent, message: "Fix it").latestReplyIntent == .decision)
    }

    @Test func theStatusSaysFeedbackWhileTheAgentWorksOnIt() {
        let feedback = Case(
            id: "c1", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "R", recommendationWhy: "B",
            options: [], status: .waitingOnAgent, hasArtifact: true, latestReplyMessage: "Fix the page.", latestReplyIntent: .decision,
            createdAt: "2026-10-06T10:00:00Z", updatedAt: "2026-10-06T10:00:00Z", questions: questions)
        #expect(AgentStatusCopy.headline(status: .working, runtime: "Claude Code", item: feedback) == "Claude Code is working on your feedback")
        #expect(AgentStatusCopy.headline(status: .working, runtime: "Claude Code", item: nil) == "Claude Code is working on your reply")
    }

    @Test func aNoteWithNoOptionPickedIsFeedbackOnTheOptionsBar() {
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, isFeedback: true) == ["Send feedback"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 3, isFeedback: true) == ["Send feedback + 3 comments", "Send feedback"])
        #expect(PromptBarLogic.sendPillLabels(commentCount: 0, isFeedback: false) == [nil])
    }

    @Test func sentAnswersLockThePage() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Two", question: "plans", point: "count")
        model.markSent()
        model.choose("Three", question: "plans", point: "count")
        #expect(model.draft("plans", "count").choice == "Two")
        #expect(!model.canSend)
    }

    @Test func changeAnswerOpensTheSentAnswersAgain() {
        let answers = [PointAnswer(questionId: "plans", pointId: "count", choice: "Three", note: nil)]
        var model = QuestionsDocModel(request: makeRequest(status: .waitingOnAgent, answers: answers))
        model.unlock()
        model.choose("Two", question: "plans", point: "count")
        #expect(model.draft("plans", "count").choice == "Two")
        #expect(model.canSend)
    }

    @Test func aRequestWhoseReplyWentOutShowsItsAnswersLocked() {
        let answers = [PointAnswer(questionId: "plans", pointId: "count", choice: "Three", note: "ok")]
        let model = QuestionsDocModel(request: makeRequest(status: .waitingOnAgent, answers: answers, message: "Thanks"))
        #expect(model.isLocked && model.draft("plans", "count").choice == "Three" && model.draft("plans", "count").note == "ok")
    }

    @Test func freshDataKeepsYourAnswersButAnotherRequestStartsClean() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Two", question: "plans", point: "count")
        model.selectVariant("table", question: "plans")
        model.note = "hello"
        model.refresh(with: makeRequest())
        #expect(model.draft("plans", "count").choice == "Two" && model.note == "hello")
        #expect(model.selectedVariant(for: questions[0]) == "table")
        model.refresh(with: makeRequest(id: "c2"))
        #expect(model.answeredCount == 0 && model.note.isEmpty)
    }

    // MARK: Variants

    @Test func aQuestionShowsItsFirstVariantUntilOneIsPicked() {
        var model = QuestionsDocModel(request: makeRequest())
        #expect(model.selectedVariant(for: questions[0]) == "cards")
        #expect(model.fragment(for: questions[0]) == "plans")
        model.selectVariant("table", question: "plans")
        #expect(model.fragment(for: questions[0]) == "plans?variant=table")
        model.selectVariant("nope", question: "plans")
        #expect(model.selectedVariant(for: questions[0]) == "table")
        #expect(model.selectedVariant(for: questions[1]) == nil)
        #expect(model.fragment(for: questions[1]) == "cta")
    }

    @Test func theLabelsReadLikeThePrototype() {
        let model = QuestionsDocModel(request: makeRequest())
        #expect(model.sectionLabel(of: questions[1]) == "QUESTION 2 OF 2")
        #expect(QuestionsDocModel.toDecideLabel(questions[0]) == "DECIDE · 2")
        #expect(QuestionsDocModel.nowLabel(["a"]) == "How it works now · 1 point")
        #expect(QuestionsDocModel.nowLabel(["a", "b"]) == "How it works now · 2 points")
        #expect(QuestionsDocModel.questionId(inFragment: "plans?variant=table") == "plans")
    }
}

// MARK: Steps (WAG-287)

extension QuestionsDocModelTests {
    private static let three: [Question] = [
        Question(id: "a", title: "Who can open the shared link without signing in?", now: nil,
                 points: [QuestionPoint(id: "p1", text: "P1", options: ["Yes", "No"]), QuestionPoint(id: "p2", text: "P2", options: ["Yes", "No"])],
                 artifactRef: nil, variants: nil, variantLabel: nil),
        Question(id: "b", title: "Comments", now: nil, points: [QuestionPoint(id: "p3", text: "P3", options: ["Yes", "No"])],
                 artifactRef: nil, variants: nil, variantLabel: nil),
        Question(id: "c", title: "What it shows", now: nil, points: [QuestionPoint(id: "p4", text: "P4", options: ["Yes", "No"])],
                 artifactRef: nil, variants: nil, variantLabel: nil),
    ]

    private func stepped(status: CaseStatus = .needsYou, answers: [PointAnswer] = []) -> QuestionsDocModel {
        QuestionsDocModel(request: Case(
            id: "s1", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "R", recommendationWhy: "B",
            options: [], status: status, hasArtifact: false, latestReplyMessage: nil, latestReplyIntent: nil,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z", questions: Self.three, latestReplyAnswers: answers))
    }

    // MARK: One format (WAG-304)

    @Test func everyAnswerIsARowStringsAndRichOnesAlike() {
        let rich = QuestionPoint(id: "r", text: "Layout?", options: [PointOption(label: "Cards", pros: ["Scans well"], cons: ["Takes room"]), "Table"])
        let plain = QuestionPoint(id: "s", text: "Badge?", options: ["Yes", "No"])
        // One row per choice, in order, for both kinds; a string row has no counts.
        #expect(rich.choices.map(\.label) == ["Cards", "Table"] && plain.choices.map(\.label) == ["Yes", "No"])
        #expect(CalmOption.chipCounts(pros: plain.choices[0].pros, cons: plain.choices[0].cons) == (0, 0))
        #expect(CalmOption.chipCounts(pros: rich.choices[0].pros, cons: rich.choices[0].cons) == (1, 1))
    }

    @Test func eachPointHasItsOwnPickBlockAndNoRecommendationBeforeAPick() {
        let first = QuestionPoint(id: "p1", text: "P1", options: [PointOption(label: "A", pros: ["x"]), "B"])
        let second = QuestionPoint(id: "p2", text: "P2", options: ["Yes", "No"])
        #expect(CalmOption.pointPick(first, choice: "A")?.option.pros == ["x"])
        #expect(CalmOption.pointPick(second, choice: "No")?.position == 2)
        // A point carries no recommendation, so before a pick there is no block at all.
        #expect(CalmOption.pointPick(first, choice: nil) == nil && CalmOption.pointPick(second, choice: nil) == nil)
    }

    @Test func theDocNeedShowsOnEveryQuestionStepButNotTheReview() {
        var model = stepped()
        #expect(model.showsDocNeed)
        model.next()
        #expect(model.showsDocNeed)
        model.jump(to: model.reviewStep)
        #expect(!model.showsDocNeed)
    }

    @Test func askForMoreDetailIsOnEachStepButNotOnReviewOrWhenSent() {
        var model = stepped()
        #expect(model.showsAskForDetail)
        model.next()
        #expect(model.showsAskForDetail)
        model.next(); model.next()
        #expect(model.isReview && !model.showsAskForDetail)
        #expect(!stepped(status: .resolved).showsAskForDetail)
    }

    @Test func theDetailMessageNamesTheQuestion() {
        #expect(SendFlowController.detailMessage(about: "Who sees a flag first?", typed: nil) == "About: Who sees a flag first?")
        #expect(SendFlowController.detailMessage(about: "Q?", typed: "Show me a prototype") == "About: Q?\nShow me a prototype")
        #expect(SendFlowController.detailMessage(about: nil, typed: "Show me a prototype") == "Show me a prototype")
        #expect(SendFlowController.detailMessage(about: nil, typed: nil) == nil)
    }

    @Test func oneQuestionIsNotStepped() {
        let model = QuestionsDocModel(request: makeRequest(questions: [questions[1]]))
        #expect(!model.isStepped && model.nextLabel == nil && model.currentQuestion == nil && !model.canGoBack)
    }

    @Test func nextBackAndJumpMoveThroughTheSteps() {
        var model = stepped()
        #expect(model.step == 0 && model.currentQuestion?.id == "a" && !model.canGoBack)
        #expect(model.stepCrumb == "Decision 1 of 3" && model.nextLabel == "Next")
        model.next(); model.next()
        #expect(model.currentQuestion?.id == "c" && model.canGoBack && model.nextLabel == "Review and send")
        model.next()
        #expect(model.isReview && model.currentQuestion == nil && model.nextLabel == nil && model.stepCrumb == "Review")
        model.next()
        #expect(model.step == 3)
        model.back(); model.back(); model.back(); model.back()
        #expect(model.step == 0)
        model.jump(to: 2)
        #expect(model.step == 2)
        model.jump(to: 9)
        #expect(model.isReview)
        model.jump(to: -4)
        #expect(model.step == 0)
    }

    @Test func pillsHaveAShortTitleACheckAndALastSendPill() {
        var model = stepped()
        model.choose("Yes", question: "a", point: "p1")
        #expect(model.stepPills.map(\.isDone) == [false, false, false, false])
        model.choose("No", question: "a", point: "p2")
        model.jump(to: 1)
        let pills = model.stepPills
        #expect(pills.count == 4 && pills[0].isDone && pills[1].isCurrent && !pills[0].isCurrent)
        #expect(pills[3].isSend && pills[3].title == "Send" && !pills[0].isSend)
        #expect(pills[0].title == "Who can open the…" && pills[1].title == "Comments")
        model.jump(to: 3)
        #expect(model.stepPills[3].isCurrent)
    }

    @Test func reviewRowsListThePicksOrNotDecided() {
        var model = stepped()
        model.choose("Yes", question: "a", point: "p1")
        model.choose("No", question: "a", point: "p2")
        model.choose("No", question: "c", point: "p4")
        let rows = model.reviewRows
        #expect(rows.map(\.summary) == ["Yes · No", "Not decided", "No"])
        #expect(rows.map(\.isDecided) == [true, false, true])
        #expect(rows[1].title == "Comments" && rows[2].index == 2)
    }

    @Test func aSentAskOpensOnTheReview() {
        let model = stepped(status: .waitingOnAgent, answers: [PointAnswer(questionId: "a", pointId: "p1", choice: "Yes", note: nil)])
        #expect(model.isLocked && model.isReview && model.reviewRows[0].picks == ["Yes"])
    }

    // MARK: A new round on a sent ask (WAG-346)

    private var roundTwoQuestions: [Question] { [Question(id: "next", title: "Which next?", now: nil, points: [QuestionPoint(id: "p", text: "Pick", options: ["A", "B"])], artifactRef: nil, variants: nil, variantLabel: nil)] }

    @Test func aNewRoundAfterMarkSentOpensFreshAndUnlocked() {
        var model = QuestionsDocModel(request: makeRequest())
        model.choose("Two", question: "plans", point: "count")
        model.jump(to: 1)
        model.markSent()
        // The same data again: the daemon has not caught up, the sent page stays.
        model.refresh(with: makeRequest())
        #expect(model.isLocked && model.answeredCount == 1)
        // The agent came back with round 2 on the same case.
        model.refresh(with: makeRequest(questions: roundTwoQuestions, optionsSeq: 1))
        #expect(!model.isLocked && model.questions == roundTwoQuestions)
        #expect(model.answeredCount == 0 && model.step == 0 && model.note.isEmpty)
        #expect(model.canSend(comments: 0, hasFiles: true))
    }

    @Test func aNewRoundOnADocLockedFromWaitingOpensFresh() {
        var model = QuestionsDocModel(request: makeRequest(status: .waitingOnAgent, message: "decision"))
        #expect(model.isLocked)
        model.refresh(with: makeRequest(status: .waitingOnAgent, message: "decision"))
        #expect(model.isLocked)
        model.refresh(with: makeRequest(status: .needsYou, message: "decision", optionsSeq: 2))
        #expect(!model.isLocked && model.step == 0 && model.answeredCount == 0)
    }

    /// WAG-383: "more detail" sent, the agent answers with a message only. The round stays, the page opens again.
    @Test func anAgentMessageOnTheSameRoundOpensTheSentPage() {
        var model = QuestionsDocModel(request: makeRequest(latestUpdateAt: "2026-10-17T10:00:21Z"))
        model.markSent()
        // The daemon has not caught up: same round, same newest message. The page stays locked.
        model.refresh(with: makeRequest(latestUpdateAt: "2026-10-17T10:00:21Z"))
        #expect(model.isLocked)
        model.refresh(with: makeRequest(status: .waitingOnAgent, latestUpdateAt: "2026-10-17T10:00:21Z"))
        #expect(model.isLocked)
        // The agent's message-only answer: needs you again, same round, a newer message.
        model.refresh(with: makeRequest(latestUpdateAt: "2026-10-17T10:01:25Z"))
        #expect(!model.isLocked)
        model.choose("Two", question: "plans", point: "count")
        #expect(model.answeredCount == 1)
    }

    @Test func aNewRoundWithTheSameQuestionsStillUnlocksByItsNumber() {
        var model = QuestionsDocModel(request: makeRequest())
        model.markSent()
        model.refresh(with: makeRequest(optionsSeq: 1))
        #expect(!model.isLocked)
    }

    @MainActor @Test func aNewRoundThroughTheControllerOpensUnlocked() {
        let controller = AskDocController(client: KnockClient(socketPath: "/tmp/knock-test-none.sock"), request: makeRequest())
        controller.doc?.markSent()
        controller.refresh(with: makeRequest())
        #expect(controller.doc?.isLocked == true)
        // A questions-only case whose round brought new questions (a later round with one item drops the doc, WAG-343).
        controller.refresh(with: makeRequest(questions: roundTwoQuestions))
        #expect(controller.doc?.isLocked == false)
        #expect(controller.doc?.questions == roundTwoQuestions)
        #expect(controller.doc?.step == 0)
    }

    @Test func sendNeedsAnAnswerANoteOrPinnedComments() {
        var model = stepped()
        #expect(!model.canSend(comments: 0) && model.sendLabel(comments: 0) == "Send answers")
        // Comments alone: "Send feedback", sent with the fixed message.
        #expect(model.canSend(comments: 2) && model.sendLabel(comments: 2) == "Send feedback")
        #expect(QuestionsDocModel.commentsOnlyMessage == "See my comments on the page.")
        model.note = "Change the title"
        #expect(model.sendLabel(comments: 2) == "Send feedback + 2 comments")
        model.note = ""
        model.choose("Yes", question: "a", point: "p1")
        #expect(model.canSend(comments: 0) && model.sendLabel(comments: 0) == "Send 1 answer")
        #expect(model.sendLabel(comments: 1) == "Send 1 answer + 1 comment")
        model.markSent()
        #expect(!model.canSend(comments: 3))
    }
}

@MainActor
struct AskDocMemoryTests {
    @Test func keepsOpenWorkAndDropsASentAsk() {
        let memory = AskDocMemory()
        let request = Case(
            id: "m1", taskId: "t", kind: .question, title: "T", need: "N", why: "W", recommendation: "R", recommendationWhy: "B",
            options: [], status: .needsYou, hasArtifact: false, latestReplyMessage: nil, latestReplyIntent: nil,
            createdAt: "2026-10-07T10:00:00Z", updatedAt: "2026-10-07T10:00:00Z",
            questions: [
                Question(id: "a", title: "A", now: nil, points: [QuestionPoint(id: "p", text: "P", options: ["Yes"])], artifactRef: nil, variants: nil, variantLabel: nil),
                Question(id: "b", title: "B", now: nil, points: [QuestionPoint(id: "q", text: "Q", options: ["Yes"])], artifactRef: nil, variants: nil, variantLabel: nil),
            ], latestReplyAnswers: [])
        var doc = QuestionsDocModel(request: request)
        doc.choose("Yes", question: "a", point: "p")
        doc.next()
        memory.save(doc)
        #expect(memory.doc(for: "m1")?.step == 1 && memory.doc(for: "m1")?.answeredCount == 1)
        doc.markSent()
        memory.save(doc)
        #expect(memory.doc(for: "m1") == nil)
    }
}
